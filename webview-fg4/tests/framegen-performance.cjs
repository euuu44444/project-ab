// CPU timing and pixel regression against the exact uploaded fg.3 HTML.
// Both versions use the same Chromium instance, viewport, fixtures and order.
// Each measured pair is newly captured: pair-cache reuse alone cannot make
// this comparison look faster than the production capture/replay cycle.
const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict'),crypto=require('crypto');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');fs.mkdirSync(out,{recursive:true});
const fixture=fs.readFileSync(path.join(__dirname,'framegen-game.cjs'),'utf8').match(/const hook=`([\s\S]*?)`;\nconst at=/);
assert(fixture,'Game fixture hook is required');
const hook=fixture[1]+`
window.__fgPerf={
 prepare(quality,pan,dense=false){
  suspendGameLoop();multicore.setEnabled(false);frameGeneration.setMode('off');
  visualSettings.quality=quality;visualSettings.lighting=false;visualSettings.markers=false;applyResize();
  setGameSeed(424242);newGame();suspendGameLoop();__fgTest.fixtures();
  if(dense){
   for(let i=0;i<40;i++){spawnEnemy(i%10===0?'elite':'swarm');const e=game.enemies.at(-1);e.x=12870+(i%8)*38;e.y=12800+Math.floor(i/8)*65;e.vx=22;e.vy=9;e.telegraph=0;}
   const friendly=game.projectiles.slice(),hostile=game.enemyProjectiles.slice(),orbs=game.xpOrbs.slice();
   for(let i=0;i<220;i++)game.projectiles.push({...friendly[i%friendly.length],x:12870+(i%10)*28,y:12700+Math.floor(i/10)*26});
   for(let i=0;i<200;i++)game.enemyProjectiles.push({...hostile[i%hostile.length],x:12870+(i%10)*28,y:12720+Math.floor(i/10)*26});
   for(let i=0;i<200;i++)game.xpOrbs.push({...orbs[i%orbs.length],x:12870+(i%10)*28,y:12720+Math.floor(i/10)*26});
   __fgTest.records=[];for(const k of ['enemies','projectiles','enemyProjectiles','xpOrbs','particles'])for(const o of game[k])__fgTest.records.push({o,x:o.x,y:o.y,vx:o.vx||30,vy:o.vy||0});
  }
  this.pan=pan;this.target=document.createElement('canvas');this.target.width=canvas.width;this.target.height=canvas.height;
  this.ctx=this.target.getContext('2d',{alpha:false});__fgTest.pose(0,pan);frameGeneration.capture(performance.now());
 },
 async pairs(count=80,warmup=24){
  const capture=[],observe=[],replay=[],total=[];
  for(let i=1;i<=count+warmup;i++){
   // Let Chromium submit each pair before producing the next one. Sending
   // eight full pairs in one JS callback measures an artificial raster queue
   // backlog, which is not the game's one-presentation-per-rAF workload.
   await new Promise(requestAnimationFrame);
   __fgTest.pose(i*.5,this.pan);
   const begin=performance.now();frameGeneration.observeNow();const seen=performance.now();
   const frame=frameGeneration.capture(seen);const captured=performance.now();
   const stats=SwarmFrameSynthesis.replay(frameGeneration.previous,frame,.5,this.ctx);const end=performance.now();
   if(frame.fault||stats.detached)throw new Error('Benchmark capture fault: '+frame.fault+' detached='+stats.detached);
   if(i>warmup){observe.push(seen-begin);capture.push(captured-seen);replay.push(end-captured);total.push(end-begin);}
  }
  const f=frameGeneration.current;
  return {capture,observe,replay,total,snapshotPixels:f.snapshotPixels,paints:f.ops.length,nodes:f.nodes.size,borrowed:f.borrowed.size,
   buffer:[canvas.width,canvas.height],entities:{enemies:game.enemies.length,projectiles:game.projectiles.length,enemyProjectiles:game.enemyProjectiles.length,orbs:game.xpOrbs.length}};
 },
 image(){
  __fgTest.pose(0,this.pan);frameGeneration.reset('pixel-fixture',true);frameGeneration.capture(performance.now());
  __fgTest.pose(.5,this.pan);frameGeneration.observeNow();__fgTest.pose(1,this.pan);frameGeneration.capture(performance.now());
  const pictures=[];for(const t of [0,.25,.5,.75,1]){
   SwarmFrameSynthesis.replay(frameGeneration.previous,frameGeneration.current,t,this.ctx);
   pictures.push(this.target.toDataURL());
  }return pictures;
 },
 lifetime(){
  this.prepare('auto',0);const a=frameGeneration.current,source=[...a.borrowed].find(x=>typeof x.getContext==='function');
  if(!source)return {found:false};
  const width=source.width;disposeVisualSurface(source);const held=source.width===width;
  frameGeneration.reset('retained-source-test',true);const released=source.width===1&&source.height===1;
  releaseVolatileRenderCaches();return {found:true,held,released};
 }
};
`;
function instrument(source){const at=source.lastIndexOf('\n})();');assert(at>0);return source.slice(0,at)+hook+source.slice(at);}
const baselineHtml=require('./fixtures/fg3-reference.cjs')(),currentHtml=fs.readFileSync(path.join(root,'app/src/main/assets/index.html'),'utf8');
const pages={'/fg3':instrument(baselineHtml),'/fg4':instrument(currentHtml)};
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(pages[req.url]||pages['/fg4']);});
const percentile=(list,p)=>{const s=list.slice().sort((a,b)=>a-b);return s[Math.min(s.length-1,Math.floor(s.length*p))];};
const summary=list=>({median:percentile(list,.5),p95:percentile(list,.95),mean:list.reduce((a,b)=>a+b,0)/list.length});
const report={startedAt:new Date().toISOString(),sourceSha256:{fg3:crypto.createHash('sha256').update(baselineHtml).digest('hex'),fg4:crypto.createHash('sha256').update(currentHtml).digest('hex')},conditions:{order:['fg3','fg4','fg4','fg3'],count:80,warmup:24,
 viewport:{width:390,height:844},dpr:3,deviceMemory:4,workers:'off for controlled comparison',cadence:'one new capture/replay pair per requestAnimationFrame',timing:'CPU callback/submission time; no Android FPS/power claim'},cases:[],errors:[]};
let browser;
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--mute-audio']});
 report.browser=await browser.version();
 const system=await (await browser.newBrowserCDPSession()).send('SystemInfo.getInfo');report.gpu=system.gpu;
 const base='http://127.0.0.1:'+server.address().port,contexts={},tabs={};
 for(const version of ['fg3','fg4']){
  const context=await browser.newContext({viewport:report.conditions.viewport,deviceScaleFactor:3,isMobile:true,hasTouch:true,locale:'ja-JP'});
  await context.addInitScript(()=>{Object.defineProperty(navigator,'deviceMemory',{get:()=>4});Element.prototype.requestFullscreen=()=>Promise.resolve();window.ElementalNative={ready(){},setFrameGenerationActive(){}};});
  const page=await context.newPage();page.on('pageerror',e=>report.errors.push({version,error:String(e)}));
  await page.goto(base+'/'+version,{waitUntil:'load'});await page.waitForFunction(()=>window.__fgPerf&&window.elementalFrameGeneration);
  await page.waitForTimeout(400);contexts[version]=context;tabs[version]=page;
 }
 for(const o of [{quality:'eco',pan:0},{quality:'eco',pan:12},{quality:'auto',pan:0},{quality:'auto',pan:12},
   {quality:'ultra',pan:0},{quality:'ultra',pan:12},{quality:'auto',pan:0,dense:true},{quality:'ultra',pan:12,dense:true}]){
  const samples={fg3:{capture:[],observe:[],replay:[],total:[]},fg4:{capture:[],observe:[],replay:[],total:[]}},details={};
  for(const version of report.conditions.order){
   const page=tabs[version];await page.evaluate(o=>__fgPerf.prepare(o.quality,o.pan,o.dense),o);
   const values=await page.evaluate(()=>__fgPerf.pairs());details[version]=values;
   for(const key of ['capture','observe','replay','total'])samples[version][key].push(...values[key]);
  }
  const result={...o,samplesPerVersion:samples.fg3.total.length,before:{},after:{}};
  for(const key of ['capture','observe','replay','total']){result.before[key]=summary(samples.fg3[key]);result.after[key]=summary(samples.fg4[key]);}
  result.reductionPercent=100*(1-result.after.total.median/result.before.total.median);
  for(const [version,key] of [['fg3','before'],['fg4','after']])for(const k of ['snapshotPixels','paints','nodes','borrowed','buffer','entities'])result[key][k]=details[version][k];
  assert.equal(result.before.paints,result.after.paints);assert.equal(result.before.nodes,result.after.nodes);
  const images={};for(const version of ['fg3','fg4']){
   await tabs[version].evaluate(o=>__fgPerf.prepare(o.quality,o.pan,o.dense),o);
   images[version]=await tabs[version].evaluate(()=>__fgPerf.image());
  }
  result.pixels=[];
  for(let i=0;i<images.fg3.length;i++){
   const comparison=await tabs.fg4.evaluate(async({a,b})=>{
    const load=src=>new Promise((resolve,reject)=>{const im=new Image();im.onload=()=>resolve(im);im.onerror=reject;im.src=src;});
    const [x,y]=await Promise.all([load(a),load(b)]),c=document.createElement('canvas');c.width=x.width;c.height=x.height;
    const g=c.getContext('2d',{willReadFrequently:true});g.drawImage(x,0,0);const p=g.getImageData(0,0,c.width,c.height).data;
    g.clearRect(0,0,c.width,c.height);g.drawImage(y,0,0);const q=g.getImageData(0,0,c.width,c.height).data;
    let sum=0,max=0,bad=0;for(let i=0;i<p.length;i+=4){let changed=false;for(let k=0;k<4;k++){const d=Math.abs(p[i+k]-q[i+k]);sum+=d;max=Math.max(max,d);if(d>3)changed=true;}if(changed)bad++;}
    return {mae:sum/p.length,max,changedFraction:bad/(c.width*c.height)};
   },{a:images.fg3[i],b:images.fg4[i]});
   result.pixels.push({t:[0,.25,.5,.75,1][i],...comparison});
   assert(comparison.mae<.01&&comparison.changedFraction<.0001,'fg.3 pixel regression: '+JSON.stringify({o,i,comparison}));
  }
  report.cases.push(result);console.log('CPU',JSON.stringify({quality:o.quality,pan:o.pan,dense:!!o.dense,before:result.before.total,after:result.after.total,reductionPercent:result.reductionPercent}));
 }
 const lifetime=await tabs.fg4.evaluate(()=>__fgPerf.lifetime());assert.deepEqual(lifetime,{found:true,held:true,released:true});report.lifetime=lifetime;
 assert.deepEqual(report.errors,[]);report.passed=true;
 for(const context of Object.values(contexts))await context.close();
})().catch(e=>{report.failure=e.stack;process.exitCode=1;console.error(e);}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'performance-results.json'),JSON.stringify(report,null,2));
 if(browser)await browser.close();server.close();
});
