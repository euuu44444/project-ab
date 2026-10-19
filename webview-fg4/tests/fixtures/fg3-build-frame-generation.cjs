const fs=require('fs'),path=require('path');
let acorn;
try{acorn=require('acorn');}catch(_){acorn=require(path.resolve(__dirname,'../../build-tools/js/node_modules/acorn'));}
const root=path.resolve(__dirname,'..'),baseline=path.join(__dirname,'baseline_mobile1.html');
let html=fs.readFileSync(baseline,'utf8');
const match=html.match(/<script>([\s\S]*?)<\/script>/);if(!match)throw new Error('Game script missing');
let script=match[1];
const tree=acorn.parse(script,{ecmaVersion:'latest'}),inserts=[];
function insert(at,text){inserts.push({at,text});}
const objectNames=new Set(['p','e','h','o','d','fx','b','a','f','target','enemy','turret','sapling']);
function traverse(node,parent=null,draw=false){
 if(!node||typeof node!=='object'||!node.type)return;
 if(node.type==='FunctionDeclaration')draw=/^(draw|ultra|mikoDraw|traceEnemy)/.test(node.id?.name||'');
 if(draw&&node.type==='ForOfStatement'&&node.left.type==='VariableDeclaration'){
  const id=node.left.declarations[0]?.id;
  if(id?.type==='Identifier'){
   const code='if(frameGeneration?.recording)frameGeneration.mark('+id.name+');';
   if(node.body.type==='BlockStatement')insert(node.body.start+1,code);
   else{insert(node.body.start,'{'+code);insert(node.body.end,'}');}
  }
 }
 if(draw&&node.type==='VariableDeclaration'&&!['ForStatement','ForOfStatement','ForInStatement'].includes(parent?.type)){
  const names=node.declarations.filter(d=>d.id.type==='Identifier'&&objectNames.has(d.id.name)&&d.init).map(d=>d.id.name);
  if(names.length)insert(node.end,';if(frameGeneration?.recording){'+names.map(n=>'frameGeneration.mark('+n+');').join('')+'}');
 }
 for(const [key,value]of Object.entries(node)){
  if(key==='start'||key==='end')continue;
  if(Array.isArray(value)){for(const child of value)if(child?.type)traverse(child,node,draw);}
  else if(value?.type)traverse(value,node,draw);
 }
}
traverse(tree);
for(const edit of inserts.sort((a,b)=>b.at-a.at))script=script.slice(0,edit.at)+edit.text+script.slice(edit.at);
function replace(old,value,count=1){const actual=script.split(old).length-1;if(actual!==count)throw new Error('Expected '+count+', got '+actual+': '+old.slice(0,100));script=script.replaceAll(old,()=>value);}
replace('var nativeActivityPaused=false;',`var nativeActivityPaused=false;var frameGeneration=null;
var FG_ENEMY_PROJECTILE_OBJECTS=[],FG_XP_ORB_OBJECTS=[],FG_ECO_PROJECTILE_OBJECTS=[],FG_ECO_BUCKET_OBJECTS=new Map();`);
replace('const defaults={quality:"auto",scanlines:false,flashes:false,lighting:false,markers:false};','const defaults={quality:"auto",scanlines:false,flashes:false,lighting:false,markers:false,frameGeneration:"auto"};');
replace('markers:bool("markers")};','markers:bool("markers"),frameGeneration:["off","auto","2x"].includes(saved.frameGeneration)?saved.frameGeneration:"auto"};');
replace('function __set_state(v){return state=v;}','function __set_state(v){if(state!==v)frameGeneration?.stateChanged(v);return state=v;}');
replace('function __set_game(v){multicore?.stop();return game=v;}','function __set_game(v){frameGeneration?.reset("game-change",true);multicore?.stop();return game=v;}');
replace('function applyResize(){const nextDpr=', 'function applyResize(){frameGeneration?.reset("resize",true);const nextDpr=');
replace('function resetFrameClock(now=performance.now()){','function resetFrameClock(now=performance.now()){frameGeneration?.reset("clock");');
replace('function releaseVolatileRenderCaches(){','function releaseVolatileRenderCaches(){frameGeneration?.reset("cache-release",true);');
replace('function render(){if(nativeActivityPaused)return;', 'function render(){if(nativeActivityPaused)return;if(!frameGeneration?.recording)frameGeneration?.direct();');
replace('  s.run(dt);','  if(list===RENDER_SYSTEMS&&frameGeneration?.recording){if(frameGeneration.isHud(s.id))continue;frameGeneration.layer(s.id,i);}\n  s.run(dt);');
replace('update(FIXED_DT);simAccumulator-=FIXED_DT;', 'update(FIXED_DT);frameGeneration?.observe();simAccumulator-=FIXED_DT;');
replace('const activeInterval=activeFrameIntervalMs();let holdRender=', 'const generatedPresentation=frameGeneration?.step(now,game.t+simAccumulator,workStart)||false;const activeInterval=activeFrameIntervalMs();let holdRender=');
replace('if(!holdRender){render();commitActiveFrameDeadline(now,activeInterval);lastIdleRender=now;}', 'if(generatedPresentation){lastIdleRender=now;}else if(!holdRender){const fgNormalStart=performance.now();render();frameGeneration?.sampleNormal(performance.now()-fgNormalStart);commitActiveFrameDeadline(now,activeInterval);lastIdleRender=now;}');
// Callbacks owned or shaped by frame generation do not reach adaptive
// quality, eco pacing or autoPace, so its cost never changes the quality tier.
replace('adaptiveSample(performance.now()-workStart,now,!holdRender);','{const fgWork=performance.now()-workStart;if(!frameGeneration?.endCallback(now,fgWork,generatedPresentation))adaptiveSample(fgWork,now,!holdRender);}');
// The visible grid changes at cell boundaries. Its iteration ordinal is not
// a stable identity: use world coordinates for the animated grass cells.
replace('const x=wx-left,y=wy-top;', 'const x=wx-left,y=wy-top;if(frameGeneration?.recording)frameGeneration.staticObject("ground:"+gx+":"+gy,wx,wy);');
// Keep the batched native drawing paths; associate their vertices with the
// original objects so reordering/removal does not mix up motion vectors.
replace('const base=offset;buffer[offset++]=px(sx);', 'const base=offset;if(frameGeneration?.recording)FG_ENEMY_PROJECTILE_OBJECTS[base]=p;buffer[offset++]=px(sx);');
replace('const o=indices[i],', 'if(frameGeneration?.recording)frameGeneration.mark(FG_ENEMY_PROJECTILE_OBJECTS[indices[i]]);const o=indices[i],',9);
replace('buffer[offset++]=px(sx);buffer[offset++]=px(sy);buffer[offset++]=o.r;count++;', 'if(frameGeneration?.recording)FG_XP_ORB_OBJECTS[count]=o;buffer[offset++]=px(sx);buffer[offset++]=px(sy);buffer[offset++]=o.r;count++;');
replace('const n=i*3,x=buffer[n],y=buffer[n+1],r=buffer[n+2];ctx.rect(', 'if(frameGeneration?.recording)frameGeneration.mark(FG_XP_ORB_OBJECTS[i]);const n=i*3,x=buffer[n],y=buffer[n+1],r=buffer[n+2];ctx.rect(');
replace('const n=i*3;ctx.rect(px(buffer[n]-1)', 'if(frameGeneration?.recording)frameGeneration.mark(FG_XP_ORB_OBJECTS[i]);const n=i*3;ctx.rect(px(buffer[n]-1)');
replace('buffer[offset++]=x;buffer[offset++]=y;buffer[offset++]=r;count++;const color=', 'if(frameGeneration?.recording)FG_ECO_PROJECTILE_OBJECTS[count]=p;buffer[offset++]=x;buffer[offset++]=y;buffer[offset++]=r;count++;const color=');
replace('bucket.push(x,y,r);', 'if(frameGeneration?.recording){let objects=FG_ECO_BUCKET_OBJECTS.get(color);if(!objects){objects=[];FG_ECO_BUCKET_OBJECTS.set(color,objects);}if(!bucket.length)objects.length=0;objects.push(p);}bucket.push(x,y,r);');
replace('const o=i*3,x=buffer[o],y=buffer[o+1],r=buffer[o+2]+2;', 'if(frameGeneration?.recording)frameGeneration.mark(FG_ECO_PROJECTILE_OBJECTS[i]);const o=i*3,x=buffer[o],y=buffer[o+1],r=buffer[o+2]+2;');
replace('const x=bucket[i],y=bucket[i+1],r=bucket[i+2];ctx.rect(', 'if(frameGeneration?.recording)frameGeneration.mark(FG_ECO_BUCKET_OBJECTS.get(color)?.[i/3]);const x=bucket[i],y=bucket[i+1],r=bucket[i+2];ctx.rect(');
replace('const o=i*3,x=buffer[o],y=buffer[o+1];', 'if(frameGeneration?.recording)frameGeneration.mark(FG_ECO_PROJECTILE_OBJECTS[i]);const o=i*3,x=buffer[o],y=buffer[o+1];');
// Worker terrain chunks and light maps are ImageBitmaps referenced by the
// retained real frames. Closing one early makes the generated frame throw.
replace('  if(typeof surface.close==="function")surface.close();','  if(typeof surface.close==="function"){if(frameGeneration?.release(surface))return;surface.close();}');
// The eco ground translation wraps every 64 px tile. Interpolating across the
// wrap shifts the pattern by half a tile, so recorded frames use the unwrapped
// translation. The rounded pattern phase and covered pixels are unchanged.
replace('ctx.translate(px((-cam.x+viewW*0.5)%64),px((-cam.y+viewH*0.5)%64));ctx.fillStyle=pattern||"#294c3e";ctx.fillRect(-64,-64,viewW+128,viewH+128);',
 'if(frameGeneration?.recording){const tx=px(-cam.x+viewW*0.5),ty=px(-cam.y+viewH*0.5);ctx.translate(tx,ty);ctx.fillStyle=pattern||"#294c3e";ctx.fillRect(-64-tx,-64-ty,viewW+128,viewH+128);}else{ctx.translate(px((-cam.x+viewW*0.5)%64),px((-cam.y+viewH*0.5)%64));ctx.fillStyle=pattern||"#294c3e";ctx.fillRect(-64,-64,viewW+128,viewH+128);}');
replace('frameGeneration:false','frameGeneration:!!frameGeneration?.status().active,frameGenerationStatus:frameGeneration?.status()');
replace('11.11.9-mobile.1','11.11.9-fg.3',2);
const runtime=fs.readFileSync(path.join(__dirname,'frame-generation-runtime.js'),'utf8');
replace('// Android shell integration is deliberately limited',runtime+'\n// Android shell integration is deliberately limited');
const core=fs.readFileSync(path.join(__dirname,'frame-synthesis.js'),'utf8');
acorn.parse(core+'\n'+script,{ecmaVersion:'latest'});
html=html.replace(match[0],()=>'<script>\n'+core+'\n'+script+'</script>');
const controls=`
<div class="frameGenerationSettings">
 <div class="visualSettingsHead"><span>フレーム生成</span><span class="visualStatus" data-framegen-status>AUTO</span></div>
 <div class="visualPresetRow" role="radiogroup" aria-label="フレーム生成">
  <button class="btn visualPreset" type="button" role="radio" data-framegen-mode="off" aria-checked="false">OFF</button>
  <button class="btn visualPreset" type="button" role="radio" data-framegen-mode="auto" aria-checked="true">AUTO</button>
  <button class="btn visualPreset" type="button" role="radio" data-framegen-mode="2x" aria-checked="false">2x</button>
 </div>
 <p class="visualHint">中間の画面を生成して動きを滑らかにします。AUTOは90Hz以上で使用します。2xは60Hzでも使用します。表示の遅れと処理負荷が増える場合があります。</p>
</div>`;
html=html.replaceAll('<div class="visualSettings" data-visual-panel>','<div class="visualSettings" data-visual-panel>'+controls);
html=html.replace(/<p class="visualHint">描画倍率は[^<]*(?:[\s\S]*?)<\/p>/g,
 '<p class="visualHint">自動設定は端末に合わせて描画解像度と演出量を調整します。軽量は1x、鮮明・最高は高い描画解像度を使用します。</p>');
fs.writeFileSync(path.join(root,'app/src/main/assets/index.html'),html);
console.log('Embedded frame synthesis, renderer instrumentation sites:',inserts.length,'bytes:',Buffer.byteLength(html));
