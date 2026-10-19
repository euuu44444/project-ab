const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict'),crypto=require('crypto');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');fs.mkdirSync(out,{recursive:true});
let html=fs.readFileSync(path.join(root,'app/src/main/assets/index.html'),'utf8');
const hook=`
window.__fgRuntime={
 stop:suspendGameLoop,
 start(){this.setup('2x',60);resetFrameClock();wakeGameLoop();},
 snap(){return {state,t:game?.t,status:frameGeneration.status(),nativePaused:nativeActivityPaused};},
 setup(mode='2x',hz=120){
  frameGeneration.setMode(mode);visualSettings.quality='eco';applyResize();
  setGameSeed(24681357);newGame();suspendGameLoop();frameGeneration.reset('test-start',true);
  displayIntervalMs=1000/hz;frameGeneration.testSeedRefresh(hz);this.now=performance.now();this.interval=1000/hz;this.faults=[];this.lastErrors=frameGeneration.status().errors;
 },
 advance(dt){capturePreviousTransforms();update(dt);frameGeneration.observeNow();},
 tick(clock=game.t){this.now+=this.interval;const handled=frameGeneration.step(this.now,clock);if(!handled)render();const s=frameGeneration.status();if(s.errors>this.lastErrors){this.faults.push({error:s.error,time:game.t});this.lastErrors=s.errors;}return handled;},
 virtual(mode,hz){
  this.setup(mode,hz);const before=frameGeneration.status();let accumulator=0,handled=0;
  for(let i=0;i<hz*2;i++){
   accumulator+=1/hz;
   while(accumulator>=FIXED_DT-1e-9){this.advance(FIXED_DT);accumulator-=FIXED_DT;}
   if(this.tick(game.t+Math.max(0,accumulator)))handled++;
  }
  const after=frameGeneration.status();return {mode,hz,seconds:game.t,handled,
   real:after.real-before.real,generated:after.generated-before.generated,
   warmup:after.warmup-before.warmup,rejected:after.rejectedPairs-before.rejectedPairs,
   errors:after.errors-before.errors,nonMonotonic:after.nonMonotonic-before.nonMonotonic};
 },
 deterministic(mode){
  this.setup(mode,120);const baseline=frameGeneration.status();
  for(let i=0;i<600&&state==='playing';i++){
   input.keys.clear();if(i<120)input.keys.add('KeyD');else if(i<240)input.keys.add('KeyW');
   this.advance(FIXED_DT);this.tick(game.t);this.tick(game.t+FIXED_DT/2);
  }
  input.keys.clear();suspendGameLoop();
  return {combat:{state,t:game.t,wave:game.wave,waveClock:game.waveClock,kills:game.kills,score:game.score,
   player:{x:game.player.x,y:game.player.y,hp:game.player.hp,level:game.player.level,xp:game.player.xp},
   enemies:game.enemies.map(e=>({id:e.id,type:e.type,x:e.x,y:e.y,hp:e.hp})),
   projectiles:game.projectiles.map(p=>({x:p.x,y:p.y,vx:p.vx,vy:p.vy})),
   enemyProjectiles:game.enemyProjectiles.map(p=>({x:p.x,y:p.y,vx:p.vx,vy:p.vy})),rngDraws:gameRandomDraws},
   generated:frameGeneration.status().generated-baseline.generated,errors:frameGeneration.status().errors-baseline.errors,faults:this.faults};
 },
 characters(){
  const saved=selectedCharacter,results=[];
  try{for(const c of CHARACTERS){
   selectedCharacter=c.id;this.setup('2x',60);const before=frameGeneration.status();
   for(let i=0;i<60&&state==='playing';i++){this.advance(FIXED_DT);this.tick();}
   const after=frameGeneration.status();results.push({id:c.id,state,generated:after.generated-before.generated,errors:after.errors-before.errors,faults:this.faults});
  }}finally{selectedCharacter=saved;}
  return results;
 },
 discontinuities(){
  // Each pulse is one fixed update followed by two callbacks, the second half
  // a step later, so the presentation lag is positive and generation is
  // possible whenever a pair is valid.
  const pulse=()=>{this.advance(FIXED_DT);this.tick(game.t);this.tick(game.t+FIXED_DT/2);};
  this.setup();const base=frameGeneration.status().generated;pulse();pulse();pulse();pulse();
  let a=frameGeneration.status();const control=a.generated-base;
  game.camera.x+=1000;this.advance(FIXED_DT);game.camera.x+=1000;this.tick(game.t);
  let b=frameGeneration.status();const cut={generated:b.generated-a.generated,rejected:b.rejectedPairs-a.rejectedPairs};
  this.tick(game.t+FIXED_DT/2);this.now+=500;this.advance(FIXED_DT);a=frameGeneration.status();this.tick(game.t);b=frameGeneration.status();
  const stall={late:b.lateCallbacks-a.lateCallbacks,generated:b.generated-a.generated};
  // The follow camera is still converging after the jump; put it back so pairs are valid again.
  game.camera.x=game.player.x;game.camera.y=game.player.y;
  const beforeResize=b.resets;applyResize();const resize=frameGeneration.status();
  pulse();pulse();pulse();pulse();pulse();
  const c=frameGeneration.status();frameGeneration.setMode('off');const off=frameGeneration.status();
  return {control,cut,stall,resumed:c.generated-b.generated,resize:{resets:resize.resets-beforeResize,cache:resize.cacheBytesEstimate},off:{active:off.active,cache:off.cacheBytesEstimate},errors:c.errors-b.errors,nonMonotonic:c.nonMonotonic};
 },
 budget(){
  this.setup();const images=Array.from({length:3},()=>{const c=document.createElement('canvas');c.width=c.height=1024;return c;});
  const test=sys('test/resource-budget',FRAME_PHASE.FX,()=>{for(const c of images)ctx.drawImage(c,0,0,2,2);},'');
  RENDER_SYSTEMS.push(test);
  const before=frameGeneration.status();let handled;
  try{this.advance(FIXED_DT);handled=this.tick();}finally{RENDER_SYSTEMS.pop();}
  const after=frameGeneration.status();frameGeneration.setMode('2x');
  return {handled,fallback:after.fallback,reason:after.error,active:after.active,cache:after.cacheBytesEstimate,errors:after.errors-before.errors};
 }
};
`;
const at=html.lastIndexOf('\n})();');html=html.slice(0,at)+hook+html.slice(at);
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html);});
let browser;const report={checks:[],pacing:[],errors:[],startedAt:new Date().toISOString()};
const check=(name,data)=>{report.checks.push({name,...data});console.log('PASS',name,JSON.stringify(data));};
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--mute-audio']});
 const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true,locale:'ja-JP'});
 await context.addInitScript(()=>{Object.defineProperty(navigator,'deviceMemory',{get:()=>4});Element.prototype.requestFullscreen=()=>Promise.resolve();window.__nativeRates=[];window.ElementalNative={ready(){},setFrameGenerationActive(v){__nativeRates.push(v);}};});
 const page=await context.newPage();page.on('pageerror',e=>report.errors.push(String(e)));
 await page.goto('http://127.0.0.1:'+server.address().port,{waitUntil:'load'});
 await page.waitForFunction(()=>window.__fgRuntime&&window.elementalFrameGeneration);
 await page.evaluate(()=>__fgRuntime.stop());
 for(const mode of ['auto','2x'])for(const hz of [60,90,120,144]){
  const r=await page.evaluate(({mode,hz})=>__fgRuntime.virtual(mode,hz),{mode,hz});report.pacing.push(r);
  assert.equal(r.errors,0);assert.equal(r.nonMonotonic,0);assert(Math.abs(r.seconds-2)<1e-5);
  if(mode==='auto'&&hz===60){assert.equal(r.generated,0);assert.equal(r.handled,0);}
  else{assert(r.generated>hz*.7);if(hz===120)assert(r.generated>=118);}
  check('virtual pacing '+mode+' '+hz+'Hz',r);
 }
 const off=await page.evaluate(()=>__fgRuntime.deterministic('off'));
 const on=await page.evaluate(()=>__fgRuntime.deterministic('2x'));
 report.deterministic={off,on};console.log('DETERMINISM',JSON.stringify({offErrors:off.errors,onErrors:on.errors,generated:on.generated,faults:on.faults}));
 assert.equal(off.errors,0);assert.equal(on.errors,0);assert(on.generated>590);
 assert.deepEqual(on.combat,off.combat);
 const original=JSON.parse(fs.readFileSync(path.join(out,'mobile-regression/combat-original.json'),'utf8'));
 assert.deepEqual(JSON.parse(JSON.stringify(on.combat)),original);
 const sha256=crypto.createHash('sha256').update(JSON.stringify(on.combat)).digest('hex');
 check('600-step active generation combat and RNG regression',{sha256,generated:on.generated,rngDraws:on.combat.rngDraws,seconds:on.combat.t});
 fs.writeFileSync(path.join(out,'combat-frame-generation.json'),JSON.stringify(on.combat,null,2));
 const characters=await page.evaluate(()=>__fgRuntime.characters());report.characters=characters;
 assert(characters.every(c=>c.state==='playing'&&c.generated>=28&&c.errors===0),JSON.stringify(characters));
 check('all character startup render smoke',{characters:characters.length,ids:characters.map(c=>c.id)});
 const discontinuities=await page.evaluate(()=>__fgRuntime.discontinuities());
 assert(discontinuities.control>=2,'Generation must work before the cut: '+JSON.stringify(discontinuities));
 assert.equal(discontinuities.cut.generated,0);assert.equal(discontinuities.cut.rejected,1);
 assert.equal(discontinuities.stall.late,1);assert.equal(discontinuities.stall.generated,0);
 assert(discontinuities.resumed>=2,'Generation must resume after the stall and resize: '+JSON.stringify(discontinuities));
 assert(discontinuities.resize.resets>0);assert.equal(discontinuities.resize.cache,0);
 assert.equal(discontinuities.off.active,false);assert.equal(discontinuities.off.cache,0);assert.equal(discontinuities.errors,0);
 check('camera cut, callback stall, resize and disable',discontinuities);
 const budget=await page.evaluate(()=>__fgRuntime.budget());
 assert.equal(budget.fallback,true);assert.equal(budget.reason,'snapshot-budget');assert.equal(budget.active,false);assert.equal(budget.cache,0);assert.equal(budget.errors,1);assert.equal(budget.handled,false);
 check('real oversized canvas resource falls back safely',budget);
 // Real browser rAF and lifecycle, not virtual callbacks.
 await page.evaluate(()=>__fgRuntime.start());
 await page.waitForTimeout(1400);
 const live=await page.evaluate(()=>__fgRuntime.snap());assert(live.status.active&&live.status.generated>10);
 await page.evaluate(()=>elementalAndroid.pause());const paused=await page.evaluate(()=>__fgRuntime.snap());
 await page.waitForTimeout(250);const later=await page.evaluate(()=>__fgRuntime.snap());
 assert.equal(paused.state,'paused');assert.equal(later.t,paused.t);assert.equal(paused.status.cacheBytesEstimate,0);assert.equal(paused.status.active,false);
 await page.evaluate(()=>elementalAndroid.resume());assert.equal((await page.evaluate(()=>__fgRuntime.snap())).state,'paused');
 await page.locator('#resumeBtn').click();await page.waitForTimeout(500);
 const resumed=await page.evaluate(()=>__fgRuntime.snap());assert.equal(resumed.status.active,true);
 check('active generation native pause and manual resume',{timeFrozen:later.t===paused.t,cacheReleased:true,resumed:true,nativeRequests:await page.evaluate(()=>__nativeRates.slice(-5))});
 await page.evaluate(()=>elementalAndroid.back());
 const statusText=await page.locator('[data-framegen-status]:visible').first().textContent();
 await page.locator('[data-framegen-mode="off"]:visible').click();assert.equal(await page.evaluate(()=>elementalFrameGeneration.getStatus().mode),'off');
 await page.locator('[data-framegen-mode="2x"]:visible').click();assert.equal(await page.locator('[data-framegen-mode="2x"]:visible').getAttribute('aria-checked'),'true');
 await page.reload();await page.waitForFunction(()=>window.elementalFrameGeneration);
 assert.equal(await page.evaluate(()=>elementalFrameGeneration.getStatus().mode),'2x');
 check('visible mode controls and persistent selection',{statusText,persistedMode:'2x'});
 assert.equal(report.errors.length,0,JSON.stringify(report.errors));report.passed=true;
})().catch(e=>{report.failure=e.stack;report.passed=false;console.error(e);process.exitCode=1;}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'runtime-results.json'),JSON.stringify(report,null,2));if(browser)await browser.close();server.close();
});
