// Regression for the game's complete update/render callback with generation
// disabled, using identical fixed timestamps and game RNG in both versions.
const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');
const hook=`
window.__offPerf=async function(quality){
 multicore.setEnabled(false);frameGeneration.setMode('off');visualSettings.quality=quality;applyResize();
 setGameSeed(24681357);newGame();suspendGameLoop();game.player.xpNext=1e12;game.player.hp=game.player.maxHp=1e9;
 input.keys.clear();input.keys.add('KeyD');resetFrameClock(0);const times=[];
 for(let i=1;i<=140;i++){
  await new Promise(requestAnimationFrame);const begin=performance.now();loop(i*1000/60);suspendGameLoop();
  if(i>40)times.push(performance.now()-begin);
 }
 input.keys.clear();return {times,combat:{t:game.t,rng:gameRandomDraws,kills:game.kills,hp:game.player.hp,
  player:[game.player.x,game.player.y],enemies:game.enemies.map(e=>[e.id,e.x,e.y,e.hp])}};
};
`;
const instrument=html=>{const at=html.lastIndexOf('\n})();');assert(at>0);return html.slice(0,at)+hook+html.slice(at);};
const pages={fg3:instrument(require('./fixtures/fg3-reference.cjs')()),fg4:instrument(fs.readFileSync(path.join(root,'app/src/main/assets/index.html'),'utf8'))};
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(pages[req.url.slice(1)]||pages.fg4);});
const summary=list=>{const s=list.slice().sort((a,b)=>a-b);return {median:s[Math.floor(s.length*.5)],p95:s[Math.floor(s.length*.95)],mean:s.reduce((a,b)=>a+b,0)/s.length};};
const report={startedAt:new Date().toISOString(),cases:[],errors:[],conditions:{mode:'off',order:['fg3','fg4','fg4','fg3'],warmup:40,samplesPerVersion:200,timing:'whole game callback; Linux Chromium CPU timing, not Android FPS'}};
let browser;
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage','--mute-audio']});
 const tabs={},contexts=[];
 for(const version of ['fg3','fg4']){
  const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true,locale:'ja-JP'});contexts.push(context);
  await context.addInitScript(()=>{Object.defineProperty(navigator,'deviceMemory',{get:()=>4});Element.prototype.requestFullscreen=()=>Promise.resolve();window.ElementalNative={ready(){},setFrameGenerationActive(){}};});
  const page=await context.newPage();page.on('pageerror',e=>report.errors.push(String(e)));tabs[version]=page;
  await page.goto('http://127.0.0.1:'+server.address().port+'/'+version,{waitUntil:'load'});await page.waitForTimeout(400);
 }
 for(const quality of ['auto','ultra']){
  const values={fg3:[],fg4:[]};let combat=null;
  for(const version of report.conditions.order){
   const r=await tabs[version].evaluate(q=>__offPerf(q),quality);values[version].push(...r.times);
   if(combat)assert.deepEqual(r.combat,combat,'OFF combat must be identical across versions and repetitions');else combat=r.combat;
  }
  const result={quality,before:summary(values.fg3),after:summary(values.fg4),combatIdentical:true};report.cases.push(result);console.log('OFF callback',JSON.stringify(result));
 }
 assert.deepEqual(report.errors,[]);report.passed=true;for(const c of contexts)await c.close();
})().catch(e=>{report.failure=e.stack;process.exitCode=1;console.error(e);}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'off-performance-results.json'),JSON.stringify(report,null,2));if(browser)await browser.close();server.close();
});
