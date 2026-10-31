const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');fs.mkdirSync(out,{recursive:true});
let html=fs.readFileSync(path.join(root,'app/src/main/assets/index.html'),'utf8');
const hook=`
window.__fgTest={
 stop:suspendGameLoop,
 snapshot(){return {state,time:game?.t,x:game?.player.x,y:game?.player.y,rng:gameRandomDraws,status:frameGeneration.status()};},
 fixtures(){
  suspendGameLoop();frameGeneration.reset('fixture',true);
  if(state!=='playing')__set_state('playing');
  visualSettings.lighting=false;visualSettings.markers=false;
  game.camera.x=game.camera.y=13000;game.player.x=game.player.y=13000;
  game.enemies=[];game.projectiles=[];game.enemyProjectiles=[];game.xpOrbs=[];game.particles=[];
  game.lootDrops=[];game.hazards=[];game.signatureFx=[];game.spriteFx=[];
  game.turrets=[];game.saplings=[];game.enemyGroundAttacks=[];game.enemyBeams=[];
  game.awaitingChoice=false;game.contracts.night=false;
  setGameSeed(424242);
  for(let i=0;i<5;i++){
   spawnEnemy(i===4?'elite':'swarm');const e=game.enemies[game.enemies.length-1];
   e.x=12880+i*55;e.y=12930+(i%2)*100;e.vx=48;e.vy=0;e.telegraph=0;
  }
  const ids=['pulse','blades','wand','boomerang','nova','seeker','orbital','shotgun','turret'];
  for(let i=0;i<ids.length;i++)game.projectiles.push({x:12870+(i%5)*60,y:12870+Math.floor(i/5)*80,
   vx:240,vy:30,r:4,color:['#ff5a36','#338cff','#82ecff'][i%3],weapon:{id:ids[i],elements:[]},shape:'orb',age:.2,life:4,sizeMul:1});
  for(let i=0;i<12;i++)game.enemyProjectiles.push({x:12870+(i%6)*45,y:13070+Math.floor(i/6)*45,vx:-120,vy:25,r:4,tier:i%3});
  for(let i=0;i<20;i++)game.xpOrbs.push({x:12860+(i%10)*30,y:13130+Math.floor(i/10)*30,r:3});
  this.base=game.t;
  this.records=[];
  for(const key of ['enemies','projectiles','enemyProjectiles','xpOrbs','particles'])for(const o of game[key])this.records.push({o,x:o.x,y:o.y,vx:o.vx||30,vy:o.vy||0});
 },
 pose(t,pan=0){
  game.t=10+t/30;game.camera.x=13000+pan*t;game.camera.y=13000;
  game.player.x=13000+20*t;game.player.y=13000;game.player.vx=48;game.player.vy=0;game.player.walkPhase=.15+t*.03;
  game.player.attackAnim=0;game.player.koTimer=0;
  for(const r of this.records){r.o.x=r.x+r.vx*t/30;r.o.y=r.y+r.vy*t/30;if(r.o.age!=null)r.o.age=.2+t/30;}
 },
 world(target){
  const saved=ctx;ctx=target;ctx.setTransform(dpr,0,0,dpr,0,0);ctx.imageSmoothingEnabled=false;__set_screenPointCursor(0);
  try{for(const system of RENDER_SYSTEMS)if(!frameGeneration.isHud(system.id)&&(!system.when||system.when()))system.run(0);}
  finally{ctx=saved;}
 },
 quality(quality,pan){
  visualSettings.quality=quality;applyResize();this.fixtures();
  const make=()=>{const c=document.createElement('canvas');c.width=canvas.width;c.height=canvas.height;return c;};
  this.pose(0,pan);const a=frameGeneration.capture(performance.now());
  const imageA=a.color.getContext('2d').getImageData(0,0,canvas.width,canvas.height);
  this.pose(.5,pan);frameGeneration.observeNow();
  this.pose(1,pan);const b=frameGeneration.capture(performance.now()+1000/30);
  const imageB=b.color.getContext('2d').getImageData(0,0,canvas.width,canvas.height);
  const generated=make(),endpoint=make(),truth=make(),hold=make(),blend=make();
  this.pose(.5,pan);this.world(truth.getContext('2d',{alpha:false}));
  const before=JSON.stringify([game.t,game.player.x,game.player.y,game.player.hp,game.enemies.map(e=>[e.x,e.y,e.hp]),gameRandomDraws]);
  const start=performance.now();const stats=SwarmFrameSynthesis.replay(a,b,.5,generated.getContext('2d',{alpha:false}));const genMs=performance.now()-start;
  const after=JSON.stringify([game.t,game.player.x,game.player.y,game.player.hp,game.enemies.map(e=>[e.x,e.y,e.hp]),gameRandomDraws]);
  SwarmFrameSynthesis.replay(a,b,1,endpoint.getContext('2d',{alpha:false}));
  hold.getContext('2d').putImageData(imageA,0,0);
  const mix=blend.getContext('2d');mix.putImageData(imageA,0,0);mix.globalAlpha=.5;mix.drawImage(b.color,0,0);
  const reference=truth.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;
  const mask=new Uint8Array(canvas.width*canvas.height);
  for(let p=0;p<mask.length;p++){const i=p*4;if(Math.max(Math.abs(imageA.data[i]-imageB.data[i]),Math.abs(imageA.data[i+1]-imageB.data[i+1]),Math.abs(imageA.data[i+2]-imageB.data[i+2]))>3)mask[p]=1;}
  function compare(c,ref=reference){
   const data=c.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;
   let abs=0,sq=0,masked=0,n=0,changed=0;
   for(let p=0;p<mask.length;p++){let bad=false;for(let k=0;k<3;k++){
    const delta=Math.abs(data[p*4+k]-ref[p*4+k]);abs+=delta;sq+=delta*delta;if(mask[p])masked+=delta;if(delta>3)bad=true;
   }if(mask[p])n++;if(bad)changed++;}
   const mse=sq/(mask.length*3);return {mae:abs/(mask.length*3),motionMae:n?masked/(n*3):0,motionPixels:n,
    psnr:mse?10*Math.log10(255*255/mse):99,changedFraction:changed/mask.length};
  }
  const times={normal:[],generated:[]};
  for(let i=0;i<16;i++){
   let now=performance.now();this.world(truth.getContext('2d',{alpha:false}));let elapsed=performance.now()-now;if(i>=4)times.normal.push(elapsed);
   now=performance.now();SwarmFrameSynthesis.replay(a,b,.5,generated.getContext('2d',{alpha:false}));elapsed=performance.now()-now;if(i>=4)times.generated.push(elapsed);
  }
  const percentile=(list,p)=>{const sorted=list.slice().sort((a,b)=>a-b);return sorted[Math.min(sorted.length-1,Math.floor(sorted.length*p))];};
  const result={quality,pan,generated:compare(generated),held:compare(hold),blended:compare(blend),endpoint:compare(endpoint,imageB.data),
    stateUnchanged:before===after,initialGenMs:genMs,normalMedianMs:percentile(times.normal,.5),generatedMedianMs:percentile(times.generated,.5),
    generatedP95Ms:percentile(times.generated,.95),paints:b.ops.length,nodes:b.nodes.size,fault:a.fault||b.fault,snapshotPixels:b.snapshotPixels,stats,
    generatedPng:generated.toDataURL(),truthPng:truth.toDataURL()};
  const captureTimes=[];
  for(let i=0;i<10;i++){
   this.pose(2+i,pan);const now=performance.now();frameGeneration.capture(now);
   if(i>=2)captureTimes.push(performance.now()-now);
  }
  result.captureMedianMs=percentile(captureTimes,.5);result.captureP95Ms=percentile(captureTimes,.95);
  result.pairCpuMs=result.captureMedianMs+result.generatedMedianMs;
  result.twoNormalFramesCpuMs=result.normalMedianMs*2;
  return result;
 }
};
`;
const at=html.lastIndexOf('\n})();');html=html.slice(0,at)+hook+html.slice(at);
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html);});
let browser;const report={checks:[],quality:[],startedAt:new Date().toISOString(),errors:[]};
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--mute-audio']});
 const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true,locale:'ja-JP'});
 await context.addInitScript(()=>{
  Object.defineProperty(navigator,'deviceMemory',{get:()=>4});
  Element.prototype.requestFullscreen=()=>Promise.resolve();
  window.ElementalNative={ready(){},setFrameGenerationActive(){},exportSave(){},copySave(){},importSave(){}};
 });
 const page=await context.newPage();page.on('pageerror',e=>report.errors.push(String(e)));
 await page.goto('http://127.0.0.1:'+server.address().port,{waitUntil:'load'});
 await page.waitForFunction(()=>window.elementalFrameGeneration&&window.__fgTest);
 await page.evaluate(()=>elementalFrameGeneration.setMode('2x'));
 await page.locator('#startBtn').click();
 await page.waitForFunction(()=>__fgTest.snapshot().state==='playing');
 await page.waitForTimeout(1500);
 const running=await page.evaluate(()=>__fgTest.snapshot());report.running=running;console.log('RUNNING',JSON.stringify(running));
 assert(running.status.generated>=10,'Must actually generate frames');
 assert.equal(running.status.nonMonotonic,0);assert.equal(running.status.errors,0);
 report.checks.push('real rAF 2x frame generation and monotonic presentation');
 await page.screenshot({path:path.join(out,'frame-generation-running.png')});
 await page.evaluate(()=>__fgTest.stop());
 for(const quality of ['eco','auto','ultra'])for(const pan of [0,12]){
  const result=await page.evaluate(({quality,pan})=>__fgTest.quality(quality,pan),{quality,pan});
  for(const name of ['generatedPng','truthPng']){fs.writeFileSync(path.join(out,`game-${quality}-${pan}-${name}.png`),Buffer.from(result[name].split(',')[1],'base64'));delete result[name];}
  report.quality.push(result);console.log('QUALITY',JSON.stringify(result));
 }
 assert.equal(report.errors.length,0,JSON.stringify(report.errors));
 assert(report.quality.every(q=>q.stateUnchanged&&!q.fault));
 assert(report.quality.every(q=>q.endpoint.mae<.01),'Recorded real-frame endpoint must reproduce actual image');
 assert(report.quality.every(q=>q.generated.motionMae<q.blended.motionMae),'Must improve moving regions over a frame blend');
 report.passed=true;
})().catch(error=>{report.failure=error.stack;report.passed=false;console.error(error);process.exitCode=1;}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'game-results.json'),JSON.stringify(report,null,2));if(browser)await browser.close();server.close();
});
