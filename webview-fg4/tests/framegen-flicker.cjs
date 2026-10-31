const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');fs.mkdirSync(out,{recursive:true});
let html=fs.readFileSync(path.join(root,'app/src/main/assets/index.html'),'utf8');
// Every presented frame is compared with the normal renderer at the same game
// time. Generated frames used to alternate with real frames while the
// time-of-day tint changed, which showed as full-screen flicker.
const hook=`
window.__fgFlicker={
 setup(o){
  frameGeneration.setMode(o.mode);visualSettings.quality=o.quality;visualSettings.lighting=!!o.lighting;
  visualSettings.markers=false;visualSettings.flashes=false;applyResize();
  setGameSeed(24681357);newGame();suspendGameLoop();frameGeneration.reset('flicker-start',true);
  game.dayPhase=o.dayPhase;displayIntervalMs=1000/60;this.now=performance.now();this.truth=new Map();
  this.target=document.createElement('canvas');this.target.width=canvas.width;this.target.height=canvas.height;
  this.tctx=this.target.getContext('2d',{alpha:false,willReadFrequently:true});
 },
 renderTruth(){
  const saved=ctx;ctx=this.tctx;ctx.setTransform(dpr,0,0,dpr,0,0);ctx.imageSmoothingEnabled=false;__set_screenPointCursor(0);
  try{for(const s of RENDER_SYSTEMS)if(s.when===null||s.when())s.run(0);}finally{ctx=saved;}
  this.truth.set(game.t.toFixed(6),this.tctx.getImageData(0,0,canvas.width,canvas.height).data);
  while(this.truth.size>4)this.truth.delete(this.truth.keys().next().value);
 },
 tint(p){const op=p?.ops.find(o=>o.layer.id==='overlay/ambient'&&o.kind==='fillRect'&&o.state.fillStyle!=='#050912');return op?.state.fillStyle||null;},
 compare(tau){
  const data=ctx.getImageData(0,0,canvas.width,canvas.height).data,ref=this.truth.get(tau.toFixed(6));
  if(!ref)return null;let abs=0,signed=0;const n=data.length/4;
  for(let i=0;i<data.length;i+=4){
   signed+=.299*(data[i]-ref[i])+.587*(data[i+1]-ref[i+1])+.114*(data[i+2]-ref[i+2]);
   abs+=Math.max(Math.abs(data[i]-ref[i]),Math.abs(data[i+1]-ref[i+1]),Math.abs(data[i+2]-ref[i+2]));
  }
  return {mae:abs/n,signedLuma:signed/n};
 },
 async run(o){
  this.setup(o);input.keys.clear();for(const k of o.keys)input.keys.add(k);
  const frames=[];const before=frameGeneration.status();
  for(let i=0;i<o.ticks&&state==='playing'&&!game.awaitingChoice;i++){
   capturePreviousTransforms();update(FIXED_DT);frameGeneration.observe();this.renderTruth();
   this.now+=1000/60;const s0=frameGeneration.status();
   if(!frameGeneration.step(this.now,game.t))render();
   const s1=frameGeneration.status();
   if(s1.generated>s0.generated){
    const m=this.compare(s1.presentationTime);
    if(m)frames.push({...m,tintChanged:this.tint(frameGeneration.previous)!==this.tint(frameGeneration.current)});
   }
   if(o.yieldMs)await new Promise(r=>setTimeout(r,o.yieldMs));
  }
  input.keys.clear();const after=frameGeneration.status();
  return {name:o.name,generated:after.generated-before.generated,errors:after.errors-before.errors,error:after.error,
   compared:frames.length,tintChanged:frames.filter(f=>f.tintChanged).length,
   maxAbsSignedLuma:Math.max(0,...frames.map(f=>Math.abs(f.signedLuma))),maxMae:Math.max(0,...frames.map(f=>f.mae))};
 }
};
`;
const at=html.lastIndexOf('\n})();');html=html.slice(0,at)+hook+html.slice(at);
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html);});
let browser;const report={checks:[],errors:[],startedAt:new Date().toISOString()};
const check=(name,data)=>{report.checks.push({name,...data});console.log('PASS',name,JSON.stringify(data));};
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--mute-audio']});
 async function scenario(o){
  const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true,locale:'ja-JP'});
  await context.addInitScript(()=>{
   Object.defineProperty(navigator,'deviceMemory',{get:()=>4});
   Element.prototype.requestFullscreen=()=>Promise.resolve();
   window.ElementalNative={ready(){},setFrameGenerationActive(){},exportSave(){},copySave(){},importSave(){}};
  });
  const page=await context.newPage();page.on('pageerror',e=>report.errors.push(String(e)));
  await page.goto('http://127.0.0.1:'+server.address().port,{waitUntil:'load'});
  await page.waitForFunction(()=>window.__fgFlicker&&window.elementalFrameGeneration);
  const result=await page.evaluate(o=>__fgFlicker.run(o),o);await context.close();return result;
 }
 // Dusk to night changes the tint string about every 60 ms of game time.
 const dusk=await scenario({name:'dusk tint',mode:'2x',quality:'auto',dayPhase:.70,ticks:150,keys:['KeyD']});
 assert(dusk.tintChanged>=10,'The tint must change between real frames');
 assert(dusk.maxAbsSignedLuma<1,'Generated frames must not shift full-screen brightness');
 assert.equal(dusk.errors,0);check('time-of-day tint is not doubled',dusk);
 // The eco ground translation wraps every 64 px while moving diagonally.
 const eco=await scenario({name:'eco ground',mode:'2x',quality:'eco',dayPhase:.31,ticks:150,keys:['KeyD','KeyS']});
 assert(eco.compared>=60&&eco.maxMae<3,'Eco ground must not shift by half a tile');
 assert.equal(eco.errors,0);check('eco ground pattern stays aligned',eco);
 // Worker light maps are replaced and closed while frames are retained.
 const light=await scenario({name:'worker light map',mode:'2x',quality:'auto',lighting:true,dayPhase:.80,ticks:240,keys:['KeyD'],yieldMs:16});
 assert.equal(light.errors,0,'Closed light maps must not stop generation: '+light.error);
 assert(light.generated>=100&&light.maxAbsSignedLuma<3,'Light map must not be drawn twice');
 check('worker light map is shown once and stays usable',light);
 assert.deepEqual(report.errors,[]);
 report.passed=true;
})().catch(e=>{report.failure=e.stack;process.exitCode=1;console.error(e);}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'flicker-results.json'),JSON.stringify(report,null,2));
 if(browser)await browser.close();server.close();
});
