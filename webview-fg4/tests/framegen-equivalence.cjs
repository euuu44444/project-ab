// Differential rendering against the uploaded fg.3 engine. This exercises
// immutable snapshots, persistent paths and cached pairs through public APIs.
const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');
fs.mkdirSync(out,{recursive:true});
const before=fs.readFileSync(path.join(__dirname,'fixtures/fg3-frame-synthesis.js'),'utf8');
const after=fs.readFileSync(path.join(root,'frame_generation/frame-synthesis.js'),'utf8');
const html='<script>'+before+';window.FG3=SwarmFrameSynthesis;</script><script>'+after+'</script>';
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html);});
let browser;const report={startedAt:new Date().toISOString(),checks:[],errors:[]};
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
 const page=await browser.newPage();page.on('pageerror',e=>report.errors.push(String(e)));
 await page.goto('http://127.0.0.1:'+server.address().port);
 const checks=await page.evaluate(()=>{
  const W=384,H=256,results=[];
  const canvas=(w=W,h=H)=>{const c=document.createElement('canvas');c.width=w;c.height=h;return c;};
  const pixels=c=>c.getContext('2d').getImageData(0,0,W,H).data;
  function diff(a,b){let total=0,max=0,bad=0;for(let i=0;i<a.length;i++){
   const d=Math.abs(a[i]-b[i]);total+=d;max=Math.max(max,d);if(d>2)bad++;
  }return {mae:total/a.length,max,bad};}
  for(const scenario of ['nested state and appended paths','layers and lifetimes','gradients and mutable images']){
   const meta=Array.from({length:6},(_,i)=>({id:i+1,bornAt:i===4?.5:-Infinity,deadAt:i===5?.5:Infinity,
    history:[{time:0,x:30+i*48,y:140},{time:1,x:52+i*48,y:150,discontinuous:i===3}]}));
   function capture(S,t){
    const c=canvas(),image=canvas(24,24),stable=canvas(24,24);
    const g=image.getContext('2d');g.fillStyle=t?'#77ccff':'#ffaa33';g.fillRect(0,0,24,24);
    const g2=stable.getContext('2d');g2.fillStyle='#abcdef';g2.fillRect(0,0,24,24);
    if(S.markImmutable)S.markImmutable(stable);
    const rec=new S.Recorder(c.getContext('2d'),{time:t,camera:{x:t*7,y:t*3},scale:1});
    const ctx=rec.context;
    rec.beginLayer('background',0,'screen');ctx.fillStyle='#132837';ctx.fillRect(0,0,W,H);
    rec.beginLayer('shapes',1,'world');
    if(scenario==='nested state and appended paths'){
     ctx.save();ctx.translate(80+20*t,66);ctx.rotate(.17+t*.21);ctx.scale(t?-.9:1,1.1);
     ctx.fillStyle='#53bc97';ctx.strokeStyle='#e9c647';ctx.lineWidth=3;ctx.setLineDash([3,5]);
     ctx.beginPath();ctx.moveTo(-24,-21);ctx.lineTo(25,-12);ctx.lineTo(10,20);ctx.closePath();ctx.fill();
     // Appending after a paint must not mutate the earlier retained path.
     ctx.moveTo(-18,18);ctx.quadraticCurveTo(0,35,28,18);ctx.stroke();
     ctx.save();ctx.globalAlpha=.4+t*.3;ctx.shadowColor='#ff3577';ctx.shadowBlur=3;ctx.fillRect(-9,-7,18,14);ctx.restore();
     ctx.fillStyle='invalid-colour';ctx.globalAlpha=7;ctx.lineWidth=-1;ctx.fillRect(15,20,13,9);ctx.restore();
     ctx.fillStyle='#dd88aa';ctx.font='15px monospace';ctx.fillText('state '+t,180,40);
     ctx.resetTransform();ctx.fillRect(2,2,5,5);
    }else if(scenario==='layers and lifetimes'){
     // One path contains several owners, with a birth, death and teleport.
     ctx.strokeStyle='#8febff';ctx.lineWidth=2;ctx.beginPath();
     for(const m of meta){
      if((t===0&&m.id===5)||(t===1&&m.id===6))continue;
      const x=30+(m.id-1)*48+22*t,y=140+10*t;
      rec.object({id:m.id,x,y,meta:m});ctx.moveTo(x,y);ctx.lineTo(x+14,y-17);
     }ctx.stroke();
     for(const m of meta){
      if((t===0&&m.id===5)||(t===1&&m.id===6))continue;
      const x=30+(m.id-1)*48+22*t;rec.object({id:m.id,x,y:140+10*t,meta:m});
      ctx.fillStyle=t?'#f2816a':'#7295e8';ctx.fillRect(x,160,24,21);
     }
     // Unusual insertion order must still use the stable layer sort.
     rec.beginLayer(t?'new':'old',t?2:4,'screen');ctx.fillStyle='#c3da79';ctx.fillRect(270,40,70,70);
     rec.beginLayer('shared',3,'screen');ctx.fillStyle='#926bc4';ctx.fillRect(290,60,70,70);
    }else{
     ctx.save();ctx.translate(40+t*20,40);const grad=ctx.createLinearGradient(0,0,100+t*10,70);
     grad.addColorStop(0,'#ffe986');grad.addColorStop(1,'#7299e8');ctx.fillStyle=grad;ctx.fillRect(0,0,100,70);
     ctx.fillRect(6,80,100,15);ctx.restore();
     ctx.drawImage(image,170+t*20,60,48,48);ctx.drawImage(stable,240+t*20,70,48,48);
     rec.beginLayer('ambient',8,'screen',true);ctx.fillStyle=t?'rgba(20,50,180,.16)':'rgba(180,20,50,.16)';ctx.fillRect(0,0,W,H);
    }
    const frame=rec.finish();
    // A mutable input may change as soon as capture returns.
    g.fillStyle='#ff00ff';g.fillRect(0,0,24,24);
    return frame;
   }
   const old=[capture(FG3,0),capture(FG3,1)],next=[capture(SwarmFrameSynthesis,0),capture(SwarmFrameSynthesis,1)];
   for(const t of [0,.125,.49,.5,.875,1,.25,.75]){
    const a=canvas(),b=canvas(),ctx=b.getContext('2d');ctx.translate(3,7);ctx.globalAlpha=.37;
    const state=SwarmFrameSynthesis.readState(ctx);
    FG3.replay(...old,t,a.getContext('2d'));SwarmFrameSynthesis.replay(...next,t,ctx);
    const difference=diff(pixels(a),pixels(b)),restored=SwarmFrameSynthesis.readState(ctx);
    results.push({name:scenario,t,...difference,contextRestored:state.globalAlpha===restored.globalAlpha&&state.matrix.every((n,i)=>n===restored.matrix[i])});
   }
   if(scenario==='gradients and mutable images')results.push({name:'write-once source saves one snapshot',
    savedPixels:old[1].snapshotPixels-next[1].snapshotPixels,borrowed:next[1].borrowed.size});
   for(const p of old)FG3.dispose(p);for(const p of next)SwarmFrameSynthesis.dispose(p);
  }
  // Immutable state sharing is observable here; later writes and saves must
  // never alter a paint that has already been retained.
  const rec=new SwarmFrameSynthesis.Recorder(canvas().getContext('2d'),{time:0,camera:{x:0,y:0}}),c=rec.context;
  c.fillStyle='#ff0000';c.fillRect(1,1,5,5);c.save();c.translate(10,5);c.fillStyle='#0000ff';c.fillRect(1,1,5,5);c.restore();c.fillRect(2,2,5,5);
  const p=rec.finish();results.push({name:'recorded state is immutable across save and restore',
   colours:p.ops.map(o=>o.state.fillStyle),translations:p.ops.map(o=>o.state.matrix.slice(4))});
  for(const linear of [[1,0,0,1],[0,0,0,1],[1,1,1,1],[1e-10,0,0,1],[-1,0,0,1],[.8,.6,-.6,.8]]){
   for(const offset of [1e-11,12])for(const t of [.25,.75]){
    const a=[...linear,0,0],b=[...linear,offset,offset/2];
    const before=FG3.affine(a,b,t),after=SwarmFrameSynthesis.affine(a,b,t);
    results.push({name:'affine boundary',linear,offset,t,affineError:Math.max(...before.map((n,i)=>Math.abs(n-after[i])))});
   }
  }
  return results;
 });
 for(const check of checks){
  if('mae'in check){assert(check.mae<.001&&check.bad===0,JSON.stringify(check));assert(check.contextRestored);}
  else if('affineError'in check)assert(check.affineError<1e-12,JSON.stringify(check));
  else if('savedPixels'in check){assert.equal(check.savedPixels,24*24);assert.equal(check.borrowed,1);}
  else{assert.deepEqual(check.colours,['#ff0000','#0000ff','#ff0000']);assert.deepEqual(check.translations,[[0,0],[10,5],[0,0]]);}
 }
 report.checks=checks;assert.deepEqual(report.errors,[]);report.passed=true;
 console.log('PASS fg.3 differential rendering and snapshot ownership',checks.length);
})().catch(e=>{report.failure=e.stack;process.exitCode=1;console.error(e);}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'equivalence-results.json'),JSON.stringify(report,null,2));
 if(browser)await browser.close();server.close();
});
