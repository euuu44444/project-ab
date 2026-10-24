const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');
const hook=`
window.__cacheTest=function(){
 multicore.setEnabled(false);frameGeneration.setMode('off');visualSettings.quality='auto';applyResize();setGameSeed(424242);newGame();suspendGameLoop();
 game.enemies=[];game.projectiles=[];game.enemyProjectiles=[];game.particles=[];game.spriteFx=[];game.signatureFx=[];game.xpOrbs=[];
 buildFlashAtlas('enemies',ART_IMAGES.enemies);
 const sources=[ART_FLASH_IMAGES.enemies,lowResAtlasSource('effects','fire',18),rangeFxTintSource(0,'#fa8154')];
 if(sources.some(x=>!x||!x.width))throw Error('Static cache fixture unavailable');
 const test=sys('test/static-caches',FRAME_PHASE.FX,()=>{
  ctx.drawImage(sources[0],0,0,64,64,50,80,64,64);ctx.drawImage(sources[1],150,80,48,48);ctx.drawImage(sources[2],70,190,120,120);
 },'');RENDER_SYSTEMS.push(test);
 let a,b;try{game.t=10;a=frameGeneration.capture(performance.now());game.t+=FIXED_DT;b=frameGeneration.capture(performance.now());}finally{RENDER_SYSTEMS.pop();}
 const target=document.createElement('canvas');target.width=canvas.width;target.height=canvas.height;
 const result={fault:a.fault||b.fault,snapshotPixels:b.snapshotPixels,borrowed:sources.map(s=>b.borrowed.has(s)),images:[]};
 for(const t of [0,.25,.5,.75,1]){SwarmFrameSynthesis.replay(a,b,t,target.getContext('2d',{alpha:false}));result.images.push(target.toDataURL());}
 releaseVolatileRenderCaches();result.released=sources.map(s=>s.width===1&&s.height===1);return result;
};
`;
const instrument=html=>{const at=html.lastIndexOf('\n})();');return html.slice(0,at)+hook+html.slice(at);};
const pages={fg3:instrument(require('./fixtures/fg3-reference.cjs')()),fg4:instrument(fs.readFileSync(path.join(root,'app/src/main/assets/index.html'),'utf8'))};
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(pages[req.url.slice(1)]||pages.fg4);});
let browser;const report={startedAt:new Date().toISOString(),checks:[],errors:[]};
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--mute-audio']});
 const values={},contexts=[];let comparePage;
 for(const version of ['fg3','fg4']){
  const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true});contexts.push(context);
  await context.addInitScript(()=>{Object.defineProperty(navigator,'deviceMemory',{get:()=>4});Element.prototype.requestFullscreen=()=>Promise.resolve();window.ElementalNative={ready(){},setFrameGenerationActive(){}};});
  const page=await context.newPage();page.on('pageerror',e=>report.errors.push(String(e)));comparePage=page;
  await page.goto('http://127.0.0.1:'+server.address().port+'/'+version,{waitUntil:'load'});await page.waitForTimeout(500);
  values[version]=await page.evaluate(()=>__cacheTest());assert.equal(values[version].fault,'');assert(values[version].released.every(Boolean));
 }
 assert(values.fg3.snapshotPixels>0);assert.equal(values.fg4.snapshotPixels,0);assert(values.fg4.borrowed.every(Boolean));
 for(let i=0;i<5;i++){
  const result=await comparePage.evaluate(async({a,b})=>{
   const load=src=>new Promise(resolve=>{const im=new Image();im.onload=()=>resolve(im);im.src=src;});const [x,y]=await Promise.all([load(a),load(b)]);
   const c=document.createElement('canvas');c.width=x.width;c.height=x.height;const g=c.getContext('2d',{willReadFrequently:true});g.drawImage(x,0,0);const p=g.getImageData(0,0,c.width,c.height).data;
   g.clearRect(0,0,c.width,c.height);g.drawImage(y,0,0);const q=g.getImageData(0,0,c.width,c.height).data;
   let bad=0,max=0;for(let i=0;i<p.length;i++){const d=Math.abs(p[i]-q[i]);if(d)bad++;max=Math.max(max,d);}return {bad,max};
  },{a:values.fg3.images[i],b:values.fg4.images[i]});assert.equal(result.bad,0);report.checks.push({t:[0,.25,.5,.75,1][i],...result});
 }
 for(const v of Object.values(values))delete v.images;report.sources=values;assert.deepEqual(report.errors,[]);report.passed=true;
 console.log('PASS flash atlas, low-resolution FX and range FX: identical pixels, zero snapshots, cache release');
 for(const c of contexts)await c.close();
})().catch(e=>{report.failure=e.stack;process.exitCode=1;console.error(e);}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'static-cache-results.json'),JSON.stringify(report,null,2));if(browser)await browser.close();server.close();
});
