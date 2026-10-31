const fs=require('fs');
const path=require('path');
const http=require('http');
const assert=require('assert/strict');
const crypto=require('crypto');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..');
const out=path.join(root,'verification/framegen/mobile-regression');fs.mkdirSync(out,{recursive:true});
const original=fs.readFileSync(path.join(root,'tests/fixtures/original.html'),'utf8');
const optimized=fs.readFileSync(path.join(root,'app/src/main/assets/index.html'),'utf8');
const java=fs.readFileSync(path.join(root,'app/src/main/java/com/elementalswarm/mobile/MainActivity.java'),'utf8');
const csp=[...java.match(/private static final String CSP = ([\s\S]*?)\n\n/)[1].matchAll(/"([^"\n]*)"/g)].map(x=>x[1]).join('');
const testHook=`
window.__swarmTest={
 snapshot(){return {state,time:game?.t,x:game?.player.x,y:game?.player.y,hp:game?.player.hp,
  input:{x:input.moveX,y:input.moveY,touchId:input.touchId,keys:input.keys.size},
  scale:dpr,quality:visualSettings.quality,buffer:[canvas.width,canvas.height],viewport:[viewW,viewH],
  workers:multicore.status(),raf:loopRaf!==null,idle:idleLoopTimer!==null};},
 seededCombat(){
  suspendGameLoop();setGameSeed(24681357);newGame();suspendGameLoop();
  for(let i=0;i<600&&state==='playing';i++){
   input.keys.clear();if(i<120)input.keys.add('KeyD');else if(i<240)input.keys.add('KeyW');
   capturePreviousTransforms();update(FIXED_DT);
  }
  input.keys.clear();suspendGameLoop();
  return {state,t:game.t,wave:game.wave,waveClock:game.waveClock,kills:game.kills,score:game.score,
   player:{x:game.player.x,y:game.player.y,hp:game.player.hp,level:game.player.level,xp:game.player.xp},
   enemies:game.enemies.map(e=>({id:e.id,type:e.type,x:e.x,y:e.y,hp:e.hp})),
   projectiles:game.projectiles.map(p=>({x:p.x,y:p.y,vx:p.vx,vy:p.vy})),
   enemyProjectiles:game.enemyProjectiles.map(p=>({x:p.x,y:p.y,vx:p.vx,vy:p.vy})),
   rngDraws:gameRandomDraws};
 },
 exportSave(){return buildSaveExportJson();},
 stop:suspendGameLoop
};
`;
function instrument(source){const p=source.lastIndexOf('\n})();');assert(p>0);return source.slice(0,p)+testHook+source.slice(p);}
const server=http.createServer((req,res)=>{
 const pathname=new URL(req.url,'http://localhost').pathname;
 const base=pathname.includes('original')?original:optimized;
 if(!['/original.html','/mobile.html','/mobile-plain.html'].includes(pathname)){res.writeHead(404);res.end();return;}
 res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Content-Security-Policy':csp});
 res.end(pathname==='/mobile-plain.html'?base:instrument(base));
});

const report={startedAt:new Date().toISOString(),browser:'',checks:[],layouts:[],errors:[],csp,limitations:['No Android device or emulator is available. Native WebView/SAF/insets installation tests are not performed.']};
function check(name,details={}){report.checks.push({name,passed:true,...details});console.log('PASS',name,JSON.stringify(details));}
const hash=x=>crypto.createHash('sha256').update(JSON.stringify(x)).digest('hex');
let browser;
async function openPage(base,profile,native=false,route='/mobile.html'){
 const ctx=await browser.newContext({viewport:{width:profile.w,height:profile.h},deviceScaleFactor:profile.dpr,
  isMobile:profile.coarse,hasTouch:profile.coarse,locale:'ja-JP'});
 await ctx.addInitScript(({memory,native})=>{
  Object.defineProperty(navigator,'deviceMemory',{get:()=>memory});
  Element.prototype.requestFullscreen=()=>Promise.resolve();
  if(native){window.__nativeCalls=[];window.ElementalNative={
   ready:v=>window.__nativeCalls.push({type:'ready',v}),
   exportSave:text=>window.__nativeCalls.push({type:'export',text}),
   copySave:text=>window.__nativeCalls.push({type:'copy',text}),
   importSave:()=>window.__nativeCalls.push({type:'import'})
  };}
 },{memory:profile.memory??4,native});
 const page=await ctx.newPage();
 page.on('pageerror',e=>report.errors.push(String(e)));
 page.on('console',m=>{if(m.type()==='error'&&/content security|refused to|uncaught/i.test(m.text()))report.errors.push(m.text());});
 const external=[];
 page.on('request',r=>{if(/^https?:/.test(r.url())&&!r.url().startsWith(base))external.push(r.url());});
 await page.goto(base+route,{waitUntil:'load'});
 await page.waitForFunction(()=>window.elementalMulticore&&document.querySelector('#characterCards .card'));
 if(route!=='/mobile-plain.html')await page.waitForFunction(()=>window.__swarmTest);
 await page.waitForTimeout(200);
 return {ctx,page,external};
}

(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const base='http://127.0.0.1:'+server.address().port;
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',
  headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--mute-audio']});
 report.browser=await browser.version();
 const profiles=[
  {name:'phone-portrait',w:390,h:844,dpr:3,coarse:true,memory:4},
  {name:'phone-small',w:320,h:568,dpr:2,coarse:true,memory:2},
  {name:'phone-landscape',w:844,h:390,dpr:3,coarse:true,memory:4},
  {name:'tablet-portrait',w:800,h:1280,dpr:2,coarse:true,memory:8},
  {name:'tablet-landscape-low-memory',w:1280,h:800,dpr:2,coarse:true,memory:4},
  {name:'desktop',w:1280,h:720,dpr:1,coarse:false,memory:8}
 ];
 for(const p of (process.env.SWARM_TOUCH_DIAGNOSTIC?[]:profiles)){
  const {ctx,page,external}=await openPage(base,p);
  const actual=await page.evaluate(()=>({...elementalAndroid.getStatus(),
   overflow:document.documentElement.scrollWidth>innerWidth,
   startVisible:!!document.querySelector('#startBtn')?.getBoundingClientRect().width,
   readyImages:[...document.images].filter(i=>i.complete&&i.naturalWidth>0).length}));
  assert.equal(actual.overflow,false,p.name+' document overflow');assert(actual.startVisible);
  if(p.coarse)assert(actual.renderScale<=1.5);else assert.equal(actual.renderScale,2);
  assert.equal(actual.frameGeneration,false);assert.equal(external.length,0);
  report.layouts.push({profile:p,...actual});
  await page.screenshot({path:path.join(out,p.name+'.png')});
  check('layout '+p.name,{scale:actual.renderScale,buffer:[actual.bufferWidth,actual.bufferHeight]});
  await ctx.close();
 }
 const phone=profiles[0];
 // Exact combat-state regression against the uploaded HTML under the same inputs/seed.
 const deterministic=[];
 for(const route of (process.env.SWARM_TOUCH_DIAGNOSTIC?[]:['/original.html','/mobile.html'])){
  const {ctx,page}=await openPage(base,phone,false,route);
  const result=await page.evaluate(()=>__swarmTest.seededCombat());deterministic.push(result);
  await ctx.close();
 }
 if(deterministic.length){
  fs.writeFileSync(path.join(out,'combat-original.json'),JSON.stringify(deterministic[0],null,2));
  fs.writeFileSync(path.join(out,'combat-mobile.json'),JSON.stringify(deterministic[1],null,2));
  assert.deepEqual(deterministic[1],deterministic[0]);
  check('seeded combat regression',{sha256:hash(deterministic[0]),seconds:deterministic[0].t,rngDraws:deterministic[0].rngDraws});
 }

 const {ctx,page,external}=await openPage(base,phone,true);
 assert.equal(await page.evaluate(()=>__nativeCalls.filter(x=>x.type==='ready').length),1);
 await page.locator('#startBtn').click();
 await page.waitForFunction(()=>__swarmTest.snapshot().state==='playing');
 const initial=await page.evaluate(()=>__swarmTest.snapshot());
 const cdp=await ctx.newCDPSession(page);
 let move={x:100,y:700,id:1};
 await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[move]});
 move={x:155,y:700,id:1};
 await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[move]});
 await page.waitForTimeout(450);
 const moving=await page.evaluate(()=>__swarmTest.snapshot());assert(moving.x>initial.x+10);
 check('touch joystick moves player',{distanceX:moving.x-initial.x});
 const pause=await page.locator('#mobilePauseBtn').boundingBox();assert(pause);assert(pause.height>=44);
 if(process.env.SWARM_TOUCH_DIAGNOSTIC)await page.evaluate(()=>{
  window.__touchLog=[];
  for(const type of ['touchstart','touchmove','touchend','touchcancel'])addEventListener(type,e=>__touchLog.push({type,target:e.target.id,changed:[...e.changedTouches].map(t=>({id:t.identifier,x:t.clientX,y:t.clientY})),live:[...e.touches].map(t=>t.identifier)}),true);
 });
 const second={x:pause.x+pause.width/2,y:pause.y+pause.height/2,id:2};
 await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[move,second]});
 await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[second]});
 if(process.env.SWARM_TOUCH_DIAGNOSTIC){
  await page.waitForTimeout(300);
  console.log('TOUCH DIAGNOSTIC',JSON.stringify(await page.evaluate(()=>({snapshot:__swarmTest.snapshot(),events:__touchLog,pause:document.querySelector('#mobilePauseBtn').outerHTML}))),pause);
  await page.screenshot({path:path.join(out,'touch-diagnostic.png')});
 }
 await page.waitForFunction(()=>__swarmTest.snapshot().state==='paused');
 const paused=await page.evaluate(()=>__swarmTest.snapshot());assert.equal(paused.input.x,0);
 await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[move]});
 check('multitouch pause while moving',{pauseButtonHeight:pause.height});
 await page.locator('#resumeBtn').click();
 await page.waitForFunction(()=>__swarmTest.snapshot().state==='playing');
 await page.evaluate(()=>elementalAndroid.pause());
 const bg=await page.evaluate(()=>({status:elementalAndroid.getStatus(),snap:__swarmTest.snapshot()}));
 await page.waitForTimeout(350);
 const bgLater=await page.evaluate(()=>__swarmTest.snapshot());
 assert.equal(bg.status.nativePaused,true);assert.equal(bgLater.state,'paused');
 assert.equal(bgLater.time,bg.snap.time);assert.equal(bgLater.workers.workers,0);
 assert.equal(bgLater.raf,false);assert.equal(bgLater.idle,false);
 await page.evaluate(()=>elementalAndroid.resume());
 assert.equal(await page.evaluate(()=>__swarmTest.snapshot().state),'paused');
 check('native lifecycle pause and resume',{backgroundTimeUnchanged:true,workersStopped:true,manualResumeRequired:true});
 await page.locator('#resumeBtn').click();
 await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:100,y:700,id:3}]});
 await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:150,y:700,id:3}]});
 assert((await page.evaluate(()=>__swarmTest.snapshot())).input.x>0);
 await page.setViewportSize({width:844,height:390});
 await page.waitForFunction(()=>elementalAndroid.getStatus().viewportWidth===844);
 assert.equal((await page.evaluate(()=>__swarmTest.snapshot())).input.touchId,null);
 await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
 assert.equal(await page.evaluate(()=>elementalAndroid.back()),true);
 assert.equal(await page.evaluate(()=>__swarmTest.snapshot().state),'paused');
 await page.screenshot({path:path.join(out,'game-landscape-paused.png')});
 check('rotation clears active input; Android back pauses');
 for(const quality of ['eco','sharp','ultra','auto']){
  await page.locator(`[data-visual-quality="${quality}"]:visible`).first().click();
  await page.waitForFunction(q=>elementalAndroid.getStatus().quality===q,quality);
  const status=await page.evaluate(()=>elementalAndroid.getStatus());
  assert(status.bufferWidth>0&&status.bufferHeight>0);
  check('quality '+quality,{scale:status.renderScale});
 }
 await page.evaluate(()=>elementalAndroid.memoryPressure());
 assert.equal(await page.evaluate(()=>__swarmTest.snapshot().state),'paused');
 check('memory-pressure cache release preserves pause state');
 await ctx.close();

 // Save bridge, import confirmation, native reload, and browser download fallback.
 const save=await openPage(base,phone,true);
 await save.page.locator('#startAdvanced').evaluate(e=>e.open=true);
 await save.page.locator('#saveExportBtn').click();
 const payload=await save.page.locator('#saveBackupJson').inputValue();
 assert.equal(JSON.parse(payload).format,'elemental-swarm-save');
 await save.page.locator('#saveBackupDownloadBtn').click();
 assert.equal(await save.page.evaluate(()=>__nativeCalls.find(x=>x.type==='export').text),payload);
 await save.page.locator('#saveBackupCopyBtn').click();
 assert.equal(await save.page.evaluate(()=>__nativeCalls.find(x=>x.type==='copy').text),payload);
 await save.page.locator('#androidImportFileBtn').click();
 assert.equal(await save.page.evaluate(()=>__nativeCalls.filter(x=>x.type==='import').length),1);
 await save.page.evaluate(text=>elementalAndroid.loadSave(text),payload);
 assert.equal(await save.page.locator('#saveBackupJson').inputValue(),payload);
 assert.equal(await save.page.locator('#saveBackupJson').evaluate(e=>e.readOnly),false);
 save.page.once('dialog',dialog=>dialog.accept());
 await Promise.all([save.page.waitForNavigation({waitUntil:'load'}),save.page.locator('#saveBackupApplyBtn').click()]);
 await save.page.waitForFunction(()=>window.elementalAndroid&&__nativeCalls.some(x=>x.type==='ready'));
 assert.equal(await save.page.evaluate(()=>elementalAndroid.getStatus().state),'menu');
 check('native save export/copy/import bridge and reload',{bytes:Buffer.byteLength(payload)});
 assert.equal(save.external.length,0);await save.ctx.close();
 const fallback=await openPage(base,phone,false);
 await fallback.page.locator('#startAdvanced').evaluate(e=>e.open=true);
 await fallback.page.locator('#saveExportBtn').click();
 const downloadPromise=fallback.page.waitForEvent('download');
 await fallback.page.locator('#saveBackupDownloadBtn').click();
 const download=await downloadPromise;assert(download.suggestedFilename().endsWith('.json'));
 assert.equal(await download.failure(),null);
 check('browser JSON download fallback');await fallback.ctx.close();

 const plain=await openPage(base,phone,true,'/mobile-plain.html');
 await plain.page.locator('#startBtn').click();
 await plain.page.waitForFunction(()=>elementalAndroid.getStatus().state==='playing');
 await plain.page.waitForTimeout(800);
 await plain.page.screenshot({path:path.join(out,'game-portrait.png')});
 assert.equal(plain.external.length,0);check('unmodified delivery HTML starts without test instrumentation');
 await plain.ctx.close();
 assert.equal(external.length,0);assert.equal(report.errors.length,0,JSON.stringify(report.errors));
 report.passed=true;
 console.log('TOTAL PASSED',report.checks.length);
})().catch(error=>{report.passed=false;report.failure=error.stack;console.error(error);process.exitCode=1;})
.finally(async()=>{report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'web-results.json'),JSON.stringify(report,null,2));if(browser)await browser.close();server.close();});
