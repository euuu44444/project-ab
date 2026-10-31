const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict');
const {chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES?path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'):'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'verification/framegen');fs.mkdirSync(out,{recursive:true});
const engine=fs.readFileSync(path.join(root,'frame_generation/frame-synthesis.js'),'utf8');
const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end('<!doctype html><html><body><script>'+engine+'</script></body></html>');});
let browser;const report={cases:[],startedAt:new Date().toISOString()};
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({executablePath:process.env.SWARM_CHROME_BINARY||'chrome-headless-shell',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
 const page=await browser.newPage();await page.goto('http://127.0.0.1:'+server.address().port);
 const results=await page.evaluate(async()=>{
  const S=SwarmFrameSynthesis,W=320,H=192;
  const canvas=()=>{const c=document.createElement('canvas');c.width=W;c.height=H;return c;};
  const diff=(a,b)=>{const x=a.getContext('2d').getImageData(0,0,W,H).data,y=b.getContext('2d').getImageData(0,0,W,H).data;let abs=0,sq=0,bad=0,max=0;
   for(let i=0;i<x.length;i+=4){let pixelBad=false;for(let k=0;k<3;k++){const d=Math.abs(x[i+k]-y[i+k]);abs+=d;sq+=d*d;max=Math.max(max,d);if(d>3)pixelBad=true;}if(pixelBad)bad++;}
   const mse=sq/(W*H*3);return {mae:abs/(W*H*3),psnr:mse?10*Math.log10(255*255/mse):99,changedFraction:bad/(W*H),max};};
  const meta=(id,x0,y0,x1,y1,extra={})=>({id,x:x1,y:y1,bornAt:-Infinity,deadAt:Infinity,history:[{time:0,x:x0,y:y0},{time:1,x:x1,y:y1}],...extra});
  const tag=(r,m,t)=>{if(r)r.object({id:m.id,x:m.history[0].x+(m.x-m.history[0].x)*t,y:m.history[0].y+(m.y-m.history[0].y)*t,meta:m});};
  const checker=(ctx,t,cam)=>{
   ctx.fillStyle='#152634';ctx.fillRect(0,0,W,H);
   for(let y=-32;y<H+32;y+=16)for(let x=-32;x<W+64;x+=16){ctx.fillStyle=((x/16+y/16)&1)?'#34596f':'#2a4654';ctx.fillRect(x-cam,y,16,16);}
  };
  const results=[];
  function run(name,render,options={}){
   const a=canvas(),b=canvas(),truth=canvas(),generated=canvas(),endpoint=canvas();
   function capture(c,t){const camera={x:(options.pan||0)*t,y:0};const rec=new S.Recorder(c.getContext('2d'),{time:t,camera,scale:1});
    rec.beginLayer('terrain',0,'screen');checker(rec.context,t,camera.x);
    rec.beginLayer('objects',1,'world');render(rec.context,t,rec,camera.x);return rec.finish();}
   const p=capture(a,0),q=capture(b,1);
   const c=truth.getContext('2d');checker(c,.5,(options.pan||0)*.5);render(c,.5,null,(options.pan||0)*.5);
   const start=performance.now();const stats=S.replay(p,q,.5,generated.getContext('2d'));const ms=performance.now()-start;
   S.replay(p,q,1,endpoint.getContext('2d'));const endpointDiff=diff(b,endpoint),quality=diff(truth,generated);
   results.push({name,quality,endpoint: endpointDiff,ms,stats,generated:generated.toDataURL(),truth:truth.toDataURL()});
  }
  const moving=meta(1,35,64,95,64);
  run('linear translation / revealed background',(c,t,r,cam)=>{tag(r,moving,t);c.fillStyle='#f85b3f';c.fillRect(35+60*t-cam,64,32,32);});
  const crossingA=meta(2,48,72,128,72),crossingB=meta(3,128,72,48,72);
  run('crossing opaque sprites',(c,t,r,cam)=>{
   tag(r,crossingA,t);c.fillStyle='#f85b3f';c.fillRect(48+80*t-cam,72,40,40);
   tag(r,crossingB,t);c.fillStyle='#55ceff';c.fillRect(128-80*t-cam,72,40,40);
  });
  run('alpha sprite without double image',(c,t,r,cam)=>{
   tag(r,moving,t);c.save();c.globalAlpha=.45;c.fillStyle='#f8d744';c.fillRect(35+60*t-cam,64,32,32);c.restore();
  });
  const rotated=meta(4,160,96,160,96);
  run('rotation preserves scale',(c,t,r)=>{
   tag(r,rotated,t);c.save();c.translate(160,96);c.rotate(t*Math.PI/2);c.fillStyle='#83fa57';c.fillRect(-32,-6,64,12);c.restore();
  });
  const birth=meta(5,190,48,190,48,{bornAt:.75});
  const death=meta(6,110,110,110,110,{deadAt:.75});
  run('birth and death visibility',(c,t,r)=>{
   if(t<.75){tag(r,death,t);c.fillStyle='#ac80ff';c.fillRect(110,110,24,24);}
   if(t>=.75){tag(r,birth,t);c.fillStyle='#ffe26d';c.fillRect(190,48,24,24);}
  });
  const batch=[meta(7,35,30,100,30),meta(8,85,50,130,50),meta(9,135,70,160,70)];
  run('batched paths / different entity order',(c,t,r)=>{
   c.fillStyle='#55c8ff';c.beginPath();const list=t>.5?[batch[2],batch[0],batch[1]]:batch;
   for(const m of list){tag(r,m,t);const p=m.history[0];c.rect(p.x+(m.x-p.x)*t,p.y,12,12);}c.fill();
  });
  run('camera pan and sprite movement',(c,t,r,cam)=>{tag(r,moving,t);c.fillStyle='#f85b3f';c.fillRect(35+60*t-cam,64,32,32);},{pan:24});
  const teleport=meta(10,30,140,260,140,{history:[{time:0,x:30,y:140},{time:.75,x:260,y:140,discontinuous:true},{time:1,x:260,y:140}]});
  run('teleport / no invented middle position',(c,t,r)=>{
   if(r)r.object({id:10,x:t<.75?30:260,y:140,meta:teleport});
   c.fillStyle='#f8abff';c.fillRect(t<.75?30:260,140,24,24);
  });
  run('moving gradient remains attached',(c,t,r)=>{
   tag(r,moving,t);const x=35+60*t;
   const g=c.createLinearGradient(x,64,x+32,64);g.addColorStop(0,'#ff0066');g.addColorStop(1,'#55ccff');
   c.fillStyle=g;c.fillRect(x,64,32,32);
  });
  const atlas=document.createElement('canvas');atlas.width=64;atlas.height=32;
  const atlasCtx=atlas.getContext('2d');atlasCtx.fillStyle='#ff5533';atlasCtx.fillRect(0,0,32,32);atlasCtx.fillStyle='#3399ff';atlasCtx.fillRect(32,0,32,32);
  run('atlas source rectangle stays discrete',(c,t,r)=>{
   tag(r,moving,t);c.drawImage(atlas,t<.5?0:32,0,32,32,35+60*t,64,32,32);
  });
  run('world cell identity survives viewport entry',(c,t,r,cam)=>{
   const first=t>.5?1:0;
   for(let i=first;i<8;i++){
    if(r)r.object({id:'cell:'+i,x:i*48,y:120,meta:{bornAt:-Infinity,deadAt:Infinity}});
    c.fillStyle=i%2?'#77b266':'#366a53';c.fillRect(i*48-cam,120,24,10);
    c.beginPath();c.moveTo(i*48+4-cam,120);c.lineTo(i*48+8-cam,110);c.strokeStyle='#cadd99';c.stroke();
   }
  },{pan:64});
  // A cached canvas may be recycled by the game after capture. Replaying a
  // real-frame endpoint must still reproduce the frozen original pixels.
  const mutable=document.createElement('canvas');mutable.width=mutable.height=16;
  const mc=mutable.getContext('2d');mc.fillStyle='#cc2233';mc.fillRect(0,0,16,16);
  const ca=canvas(),cb=canvas(),replayed=canvas();
  function frozen(c,t){const r=new S.Recorder(c.getContext('2d'),{time:t,camera:{x:0,y:0},scale:1});r.beginLayer('terrain',0,'screen');checker(r.context,t,0);r.beginLayer('image',1);r.context.drawImage(mutable,40,40);return r.finish();}
  const fp=frozen(ca,0);mc.fillStyle='#3388ee';mc.fillRect(0,0,16,16);const fq=frozen(cb,1);
  mc.fillStyle='#33ff55';mc.fillRect(0,0,16,16);S.replay(fp,fq,1,replayed.getContext('2d'));
  results.push({name:'mutable image source survives cache reuse',quality:diff(cb,replayed),endpoint:diff(cb,replayed),snapshotPixels:fq.snapshotPixels,generated:replayed.toDataURL(),truth:cb.toDataURL()});
  // A one-level colour change gives the primitive a new strict key. Before
  // loose pairing, both versions were drawn and the overlay doubled.
  run('colour change does not double a full-screen overlay',(c,t)=>{
   c.save();c.globalAlpha=.2;c.fillStyle=t<.5?'#aa798d':'#aa798e';c.fillRect(0,0,W,H);c.restore();
  });
  run('tagged colour flash is drawn once',(c,t,r,cam)=>{
   tag(r,moving,t);c.save();c.globalAlpha=.6;c.fillStyle=t<.5?'#f85b3f':'#ffffff';c.fillRect(35+60*t-cam,64,32,32);c.restore();
  });
  // Screen overlays whose source image changes identity every frame, such as
  // worker light maps, are shown from one real frame.
  const shade=()=>{const c=canvas(),g=c.getContext('2d');g.fillStyle='rgba(5,9,18,.45)';g.fillRect(0,0,W,H);g.fillStyle='rgba(255,255,255,.5)';g.fillRect(140,70,40,40);return c;};
  function overlay(c,t,r,image){
   const ctx=r?r.context:c.getContext('2d');
   if(r)r.beginLayer('terrain',0,'screen');checker(ctx,t,0);
   if(r)r.beginLayer('ambient',1,'screen',true);
   ctx.globalAlpha=.16;ctx.fillStyle=t<.5?'#aa798d':'#aa798e';ctx.fillRect(0,0,W,H);ctx.globalAlpha=.5;ctx.drawImage(image,0,0);ctx.globalAlpha=1;
   return r?r.finish():null;
  }
  const oa=canvas(),ob=canvas(),otruth=canvas(),ogenerated=canvas(),oendpoint=canvas();
  const op0=overlay(oa,0,new S.Recorder(oa.getContext('2d'),{time:0,camera:{x:0,y:0},scale:1}),shade());
  const oq1=overlay(ob,1,new S.Recorder(ob.getContext('2d'),{time:1,camera:{x:0,y:0},scale:1}),shade());
  overlay(otruth,1,null,shade());
  const overlayStats=S.replay(op0,oq1,.5,ogenerated.getContext('2d'));S.replay(op0,oq1,1,oendpoint.getContext('2d'));
  results.push({name:'discrete overlay layer uses one real frame',quality:diff(otruth,ogenerated),endpoint:diff(ob,oendpoint),stats:overlayStats,generated:ogenerated.toDataURL(),truth:otruth.toDataURL()});
  // Worker terrain chunks and light maps are ImageBitmaps that the game may
  // close after capture. Replay must not throw or leave the context saved.
  const tile=document.createElement('canvas');tile.width=tile.height=24;
  const tc=tile.getContext('2d');tc.fillStyle='#e8c35a';tc.fillRect(0,0,24,24);
  const bitmaps=[await createImageBitmap(tile),await createImageBitmap(tile)];
  function bitmapFrame(c,t,image){
   const r=new S.Recorder(c.getContext('2d'),{time:t,camera:{x:0,y:0},scale:1});
   r.beginLayer('terrain',0,'screen');checker(r.context,t,0);r.beginLayer('objects',1);r.context.drawImage(image,100,60);return r.finish();
  }
  const ba=canvas(),bb=canvas(),btruth=canvas(),bgenerated=canvas(),bearly=canvas(),bendpoint=canvas();
  const bp=bitmapFrame(ba,0,bitmaps[0]),bq=bitmapFrame(bb,1,bitmaps[1]);bitmaps[0].close();
  const btc=btruth.getContext('2d');checker(btc,.5,0);btc.drawImage(tile,100,60);
  const gctx=bgenerated.getContext('2d'),bitmapStats=S.replay(bp,bq,.5,gctx);
  const earlyStats=S.replay(bp,bq,.25,bearly.getContext('2d'));S.replay(bp,bq,1,bendpoint.getContext('2d'));
  const identity=gctx.getTransform().isIdentity&&gctx.globalAlpha===1;
  results.push({name:'closed ImageBitmap in a retained frame is skipped',quality:diff(btruth,bgenerated),endpoint:diff(bb,bendpoint),
   early:diff(btruth,bearly),stats:bitmapStats,earlyStats,contextRestored:identity,generated:bgenerated.toDataURL(),truth:btruth.toDataURL()});
  return results;
 });
 for(const item of results){
  fs.writeFileSync(path.join(out,item.name.replace(/[^a-z0-9]+/gi,'-')+'-generated.png'),Buffer.from(item.generated.split(',')[1],'base64'));
  fs.writeFileSync(path.join(out,item.name.replace(/[^a-z0-9]+/gi,'-')+'-truth.png'),Buffer.from(item.truth.split(',')[1],'base64'));
  delete item.generated;delete item.truth;report.cases.push(item);console.log(JSON.stringify(item));
 }
 report.passed=report.cases.every(c=>c.quality.mae<.15&&c.endpoint.mae===0&&(!c.early||c.early.mae<.15)&&c.contextRestored!==false);
 if(!report.passed)process.exitCode=1;
})().catch(e=>{report.failure=e.stack;process.exitCode=1;console.error(e);}).finally(async()=>{
 report.finishedAt=new Date().toISOString();fs.writeFileSync(path.join(out,'synthesis-results.json'),JSON.stringify(report,null,2));if(browser)await browser.close();server.close();
});
