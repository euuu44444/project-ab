const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');fs.mkdirSync(out,{recursive:true});
let html=fs.readFileSync(path.join(root,'app/src/main/assets/index.html'),'utf8');
// Drives the game's real loop(now) with virtual vsync timestamps. Costs are
// injected with busy waits: capture and normal rendering through a render
// system, the HUD after every presentation, and the replay through a wrapper
// installed before the engine loads (test page only). A callback that ends
// after the next vsync delays the next one, as a browser does.
const hook=`
window.__fgBudget={
 async run(o){
  frameGeneration.setMode(o.mode);visualSettings.quality='auto';visualSettings.lighting=false;
  visualSettings.markers=false;visualSettings.flashes=false;applyResize();
  setGameSeed(24681357);newGame();suspendGameLoop();frameGeneration.reset('budget-start',true);
  game.player.xpNext=1e12;game.player.maxHp=game.player.hp=1e9;
  input.keys.clear();input.keys.add('KeyD');
  window.requestAnimationFrame=()=>1;
  const P=1000/o.hz,schedule=o.schedule,spin=ms=>{if(ms>0){const end=performance.now()+ms;while(performance.now()<end);}};
  let phase=schedule[0],normalRenders=0;
  const hud=RENDER_SYSTEMS.find(s=>s.id==='hud/reaction-buffs'),hudRun=hud.run;
  hud.run=function(...args){spin(phase.hud||0);return hudRun.apply(this,args);};
  const costSystem=sys('test/cost',FRAME_PHASE.FX,()=>spin(frameGeneration.recording?phase.capture:phase.normal),'');
  RENDER_SYSTEMS.push(costSystem);
  const baseRender=render;
  render=function(){if(!frameGeneration?.recording)normalRenders++;return baseRender.apply(this,arguments);};
  let vt=Math.ceil(performance.now()/P)*P+P*4;
  resetFrameClock(vt-P);displayIntervalMs=P;
  if(o.seed!==false)frameGeneration.testSeedRefresh(o.hz);
  const start=vt,end=start+o.seconds*1000,bins=[],samples0=adaptive.samples;
  let content=null,lastPresent=null,callbacks=0;
  try{
   while(vt<end&&state==='playing'){
    const t=vt-start;phase=schedule.filter(p=>p.from<=t).at(-1);window.__replaySpin=phase.replay||0;
    const s0=frameGeneration.status(),n0=normalRenders,w0=performance.now();
    loop(vt);callbacks++;
    const work=performance.now()-w0,s1=frameGeneration.status();
    let presented=false;
    if(normalRenders>n0){presented=true;content=game.t;}
    else if(s1.generated>s0.generated||s1.real>s0.real){presented=true;content=s1.presentationTime;}
    const bin=Math.floor(t/1000);
    const b=bins[bin]||(bins[bin]={distinct:0,generated:0,callbacks:0,active:0});
    b.callbacks++;if(s1.active)b.active++;
    if(s1.generated>s0.generated)b.generated++;
    if(presented&&(lastPresent===null||content>lastPresent+1e-9)){b.distinct++;lastPresent=content;}
    vt=Math.max(vt+P,Math.ceil((vt+work+.5)/P-1e-9)*P);
   }
  }finally{render=baseRender;hud.run=hudRun;RENDER_SYSTEMS.splice(RENDER_SYSTEMS.indexOf(costSystem),1);input.keys.clear();window.__replaySpin=0;}
  const s=frameGeneration.status();
  return {bins,callbacks,adaptiveSamples:adaptive.samples-samples0,errors:s.errors,error:s.error,stride:s.stride,refreshHz:s.refreshHz,
   drops:s.drops,yields:s.yields,holds:s.holds,backoff:s.backoff,failures:s.failures,nonMonotonic:s.nonMonotonic,state};
 }
};
`;
const at=html.lastIndexOf('\n})();');html=html.slice(0,at)+hook+html.slice(at);
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html);});
let browser;const report={checks:[],errors:[],startedAt:new Date().toISOString()};
const check=(name,data)=>{report.checks.push({name,...data});console.log('PASS',name,JSON.stringify(data));};
const mean=(bins,from,to,key)=>{const part=bins.slice(from,to).filter(Boolean);return part.length?part.reduce((n,b)=>n+(key==='active'?b.active/Math.max(1,b.callbacks):b[key]),0)/part.length:0;};
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--mute-audio']});
 async function scenario(options){
  const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true,locale:'ja-JP'});
  await context.addInitScript(()=>{
   Object.defineProperty(navigator,'deviceMemory',{get:()=>4});
   Element.prototype.requestFullscreen=()=>Promise.resolve();
   window.ElementalNative={ready(){},setFrameGenerationActive(){},exportSave(){},copySave(){},importSave(){}};
   let wrapper=null;window.__replaySpin=0;
   Object.defineProperty(window,'SwarmFrameSynthesis',{configurable:true,
    get(){return wrapper;},
    set(engine){wrapper={...engine,replay(...args){const end=performance.now()+window.__replaySpin;while(performance.now()<end);return engine.replay(...args);}};}});
  });
  const page=await context.newPage();page.on('pageerror',e=>report.errors.push(String(e)));
  await page.goto('http://127.0.0.1:'+server.address().port,{waitUntil:'load'});
  await page.waitForFunction(()=>window.__fgBudget&&window.elementalFrameGeneration);
  await page.waitForTimeout(500);
  const result=await page.evaluate(o=>__fgBudget.run(o),options);await context.close();return result;
 }
 const light=[{from:0,capture:1,normal:.5,hud:.1,replay:.5}];
 // Light load: nothing may pause, drop or yield, and generation-owned
 // callbacks must not feed adaptive quality.
 const on=await scenario({mode:'auto',hz:120,seconds:4,schedule:light});
 assert.equal(on.errors,0,JSON.stringify(on));assert(on.drops+on.yields<=8,'Light load may only drop or yield now and then: '+JSON.stringify(on));assert.equal(on.nonMonotonic,0);
 assert(mean(on.bins,1,4,'distinct')>=110,'Light load must show about 120 distinct frames/s: '+JSON.stringify(on.bins));
 assert(mean(on.bins,1,4,'active')>=.95);
 const off=await scenario({mode:'off',hz:120,seconds:4,schedule:light});
 assert(off.adaptiveSamples>=100,'Adaptive quality must sample normal callbacks: '+off.adaptiveSamples);
 assert(on.adaptiveSamples<=12,'Generation-owned callbacks must not feed adaptive quality: '+on.adaptiveSamples);
 check('light load stays active and adaptive quality is not fed',{distinctPerSecond:mean(on.bins,1,4,'distinct'),adaptiveSamplesOn:on.adaptiveSamples,adaptiveSamplesOff:off.adaptiveSamples});
 // Costs measured during a burst must not survive the pause, whether the
 // burst is in the replay or in the capture: the retry has to recover.
 const normal={capture:1,normal:.5,hud:.1,replay:.5};
 for(const [name,burstCost] of [['replay',{...normal,replay:12}],['capture',{...normal,capture:36}]]){
  const burst=await scenario({mode:'auto',hz:120,seconds:14,schedule:[{from:0,...normal},{from:1500,...burstCost},{from:name==='capture'?2500:2300,...normal}]});
  assert(burst.errors>=1&&burst.errors<=2,'The '+name+' burst must pause generation a bounded number of times: '+JSON.stringify(burst));
  assert(mean(burst.bins,10,14,'distinct')>=105,'Generation must recover after the '+name+' burst: '+JSON.stringify(burst.bins));
  assert(mean(burst.bins,10,14,'active')>=.9);
  check('transient '+name+' burst pauses and generation recovers',{failures:burst.failures,backoff:burst.backoff,distinctAfter:mean(burst.bins,10,14,'distinct'),activeAfter:mean(burst.bins,10,14,'active')});
 }
 // A game that never fits falls back to normal rendering with growing waits.
 // The wait already scheduled must not be cut short when load makes the
 // refresh estimate look slower.
 const heavy=await scenario({mode:'2x',hz:120,seconds:40,schedule:[{from:0,capture:7,normal:9,hud:.3,replay:3}]});
 assert(heavy.errors>=1&&heavy.errors<=8,'Fallbacks must be bounded under steady overload: '+JSON.stringify(heavy));
 assert(heavy.backoff.level.budget>=2,'The wait must escalate: '+JSON.stringify(heavy.backoff));
 assert(mean(heavy.bins,28,40,'distinct')>=30,'Normal rendering must carry on: '+JSON.stringify(heavy.bins));
 check('steady overload falls back with growing waits',{failures:heavy.failures,backoff:heavy.backoff,distinctPerSecond:mean(heavy.bins,28,40,'distinct')});
 // A 75 Hz panel in 2x mode captures every step, not every other one.
 const rate=await scenario({mode:'2x',hz:75,seconds:3,seed:false,schedule:light});
 assert.equal(rate.stride,1,JSON.stringify(rate));assert(rate.refreshHz>=74&&rate.refreshHz<=76,String(rate.refreshHz));
 assert.equal(rate.errors,0);
 check('2x on a 75 Hz panel uses stride 1',{stride:rate.stride,refreshHz:rate.refreshHz});
 assert.deepEqual(report.errors,[]);report.passed=true;
})().catch(e=>{report.failure=e.stack;report.passed=false;console.error(e);process.exitCode=1;}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'budget-results.json'),JSON.stringify(report,null,2));
 if(browser)await browser.close();server.close();
});
