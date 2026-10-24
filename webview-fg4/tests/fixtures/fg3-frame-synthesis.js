/* Elemental Swarm frame synthesis. Original implementation, no vendor SDK.
 * Captures Canvas paint primitives and image resources on real frames, then
 * reprojects them at an intermediate time without executing game renderers.
 * Engine identity/lifetime and layer order supply motion and visibility.
 */
(function(root){
  'use strict';
  const PROPERTIES=['fillStyle','strokeStyle','globalAlpha','globalCompositeOperation',
    'lineWidth','lineCap','lineJoin','miterLimit','lineDashOffset','font','textAlign',
    'textBaseline','direction','imageSmoothingEnabled','imageSmoothingQuality',
    'shadowColor','shadowBlur','shadowOffsetX','shadowOffsetY','filter'];
  const PATH_METHODS=new Set(['moveTo','lineTo','rect','arc','ellipse','quadraticCurveTo','bezierCurveTo','closePath','arcTo','roundRect']);
  const PAINT_METHODS=new Set(['drawImage','fillRect','strokeRect','clearRect','fillText','strokeText','fill','stroke']);
  const IDENTITIES=new WeakMap();let nextIdentity=1;
  const GRADIENTS=new WeakMap();
  const clamp=(x,a,b)=>Math.min(b,Math.max(a,x));
  const lerp=(a,b,t)=>a+(b-a)*t;
  function identity(object){
    if(!object||typeof object!=='object')return String(object);
    let id=IDENTITIES.get(object);if(!id){id=nextIdentity++;IDENTITIES.set(object,id);}return id;
  }
  function surface(width,height){
    const c=typeof OffscreenCanvas==='function'?new OffscreenCanvas(width,height):document.createElement('canvas');
    c.width=width;c.height=height;return c;
  }
  function matrixMultiply(a,b){return [
    a[0]*b[0]+a[2]*b[1],a[1]*b[0]+a[3]*b[1],
    a[0]*b[2]+a[2]*b[3],a[1]*b[2]+a[3]*b[3],
    a[0]*b[4]+a[2]*b[5]+a[4],a[1]*b[4]+a[3]*b[5]+a[5]
  ];}
  function affine(a,b,t){
    if(a.every((value,i)=>Math.abs(value-b[i])<1e-10))return a;
    const decompose=m=>{
      const sx=Math.hypot(m[0],m[1]);
      if(sx<1e-8)return null;
      return {angle:Math.atan2(m[1],m[0]),sx,sy:(m[0]*m[3]-m[1]*m[2])/sx,
        shear:(m[0]*m[2]+m[1]*m[3])/sx};
    };
    const p=decompose(a),q=decompose(b);
    if(!p||!q||p.sy*q.sy<=0)return (t<.5?a:b).slice();
    let angle=q.angle-p.angle;angle=Math.atan2(Math.sin(angle),Math.cos(angle));
    const r=p.angle+angle*t,c=Math.cos(r),s=Math.sin(r),sx=lerp(p.sx,q.sx,t),sy=lerp(p.sy,q.sy,t),sh=lerp(p.shear,q.shear,t);
    return [c*sx,s*sx,c*sh-s*sy,s*sh+c*sy,lerp(a[4],b[4],t),lerp(a[5],b[5],t)];
  }
  function readState(ctx){
    const state={};for(const p of PROPERTIES)state[p]=ctx[p];
    const m=ctx.getTransform();state.matrix=[m.a,m.b,m.c,m.d,m.e,m.f];
    state.lineDash=ctx.getLineDash();return state;
  }
  function cloneState(s){return {...s,matrix:s.matrix.slice(),lineDash:s.lineDash.slice()};}
  function writeState(ctx,state){
    for(const p of PROPERTIES)if(state[p]!==undefined)ctx[p]=state[p];
    ctx.setLineDash(state.lineDash);ctx.setTransform(...state.matrix);
  }
  function material(value){
    const gradient=value&&typeof value==='object'?GRADIENTS.get(value):null;
    if(gradient)return 'gradient:'+gradient.kind+':'+gradient.stops.map(s=>s.join(':')).join(',');
    return typeof value==='string'?value:'resource:'+identity(value);
  }
  function sourceIsMutable(image){return image&&typeof image.getContext==='function';}
  // A closed ImageBitmap reports zero size and makes drawImage throw.
  function usable(image){return !(image&&typeof image.close==='function'&&image.width===0&&image.height===0);}

  class Recorder {
    constructor(ctx,options){
      this.target=ctx;this.options=options;this.state=readState(ctx);this.stack=[];this.path=[];
      this.layer={id:'root',index:0,space:'world'};this.currentTag=null;
      this.picture={time:options.time,camera:{...options.camera},width:ctx.canvas.width,height:ctx.canvas.height,
        scale:options.scale||1,ops:[],byKey:new Map(),nodes:new Map(),sources:[],borrowed:new Set(),snapshotPixels:0,fault:'',finalState:null};
      this.counters=new Map();this.nodeCounters=new Map();this.looseCounters=new Map();this.frozen=new WeakMap();
      this.methods=new Map();this.context=this.makeProxy();
    }
    beginLayer(id,index,space='world',discrete=false){
      this.layer={id,index,space,discrete};this.currentTag=null;
    }
    object(tag){if(tag)this.currentTag={id:tag.id,x:tag.x,y:tag.y,meta:tag.meta||tag,sampleTime:this.picture.time};}
    tag(){return this.currentTag;}
    count(map,key){const n=map.get(key)||0;map.set(key,n+1);return n;}
    freeze(image){
      if(!sourceIsMutable(image))return image;
      let frozen=this.frozen.get(image);if(frozen)return frozen;
      const width=image.width|0,height=image.height|0;
      if(width<=0||height<=0){this.picture.fault='invalid-image-source';return image;}
      const pixels=width*height;
      if(this.picture.snapshotPixels+pixels>(this.options.maxSnapshotPixels||4194304)){
        this.picture.fault='snapshot-budget';return image;
      }
      frozen=surface(width,height);const ctx=frozen.getContext('2d',{alpha:true});
      ctx.drawImage(image,0,0);this.frozen.set(image,frozen);
      this.picture.sources.push(frozen);this.picture.snapshotPixels+=pixels;return frozen;
    }
    recordPath(kind,args){
      const tag=this.tag(),base=this.layer.id+'|'+(tag?.id||'world')+'|'+kind;
      const key=base+'|'+this.count(this.nodeCounters,base);
      const node={kind,args:args.slice(),matrix:this.state.matrix.slice(),tag,layer:this.layer,key};
      this.path.push(node);this.picture.nodes.set(key,node);
      if(this.picture.nodes.size>(this.options.maxNodes||80000))this.picture.fault='path-budget';
    }
    recordPaint(kind,args){
      const isPath=kind==='fill'||kind==='stroke';
      // A path belonging to one object keeps that object's identity. Batched
      // paths spanning several objects keep identity on individual vertices.
      const firstTag=isPath?this.path[0]?.tag:null;
      const tag=isPath?(firstTag&&this.path.every(n=>n.tag?.id===firstTag.id)?firstTag:null):this.tag();
      const s=cloneState(this.state),image=kind==='drawImage'?args[0]:null;
      const style=kind==='stroke'||kind==='strokeRect'||kind==='strokeText'?s.strokeStyle:s.fillStyle;
      const text=kind==='fillText'||kind==='strokeText'?String(args[0]):'';
      const base=this.layer.id+'|'+(tag?.id||'world')+'|'+kind+'|'+(image?identity(image):material(style))+'|'+text;
      const key=base+'|'+this.count(this.counters,base);
      // Owner and draw order only. Used to pair a primitive whose colour,
      // image or text changed between the two real frames.
      const looseBase=this.layer.id+'|'+(tag?.id||'world')+'|'+kind;
      const looseKey=looseBase+'|'+this.count(this.looseCounters,looseBase);
      const stored=args.slice();if(image)stored[0]=this.freeze(image);
      // Closable sources are not copied; the runtime defers their release.
      if(image&&typeof image.close==='function')this.picture.borrowed.add(image);
      const fullScreen=(kind==='fillRect'||kind==='clearRect')&&!tag&&args[0]<=0&&args[1]<=0&&
        args[2]>=this.picture.width/this.picture.scale&&args[3]>=this.picture.height/this.picture.scale;
      const op={kind,args:stored,state:s,tag,layer:this.layer,key,looseKey,path:isPath?this.path.slice():null,
        imageId:image?identity(image):0,order:this.picture.ops.length,fullScreen};
      this.picture.ops.push(op);this.picture.byKey.set(key,op);
      if(this.picture.ops.length>(this.options.maxOps||24000))this.picture.fault='paint-budget';
    }
    makeProxy(){
      const self=this,raw=this.target;
      return new Proxy(raw,{
        get(target,property){
          if(typeof raw[property]!=='function')return raw[property];
          if(self.methods.has(property))return self.methods.get(property);
          const method=function(...args){
            if(property==='save')self.stack.push(cloneState(self.state));
            else if(property==='restore'){if(self.stack.length)self.state=self.stack.pop();}
            else if(property==='beginPath')self.path=[];
            else if(property==='translate')self.state.matrix=matrixMultiply(self.state.matrix,[1,0,0,1,args[0],args[1]]);
            else if(property==='scale')self.state.matrix=matrixMultiply(self.state.matrix,[args[0],0,0,args[1],0,0]);
            else if(property==='rotate'){
              const c=Math.cos(args[0]),s=Math.sin(args[0]);self.state.matrix=matrixMultiply(self.state.matrix,[c,s,-s,c,0,0]);
            }else if(property==='transform')self.state.matrix=matrixMultiply(self.state.matrix,args);
            else if(property==='setTransform'){
              const m=args[0];self.state.matrix=args.length===6?args.slice():[m.a,m.b,m.c,m.d,m.e,m.f];
            }else if(property==='resetTransform')self.state.matrix=[1,0,0,1,0,0];
            else if(property==='setLineDash')self.state.lineDash=Array.from(args[0]);
            else if(property==='clip'||property==='putImageData')self.picture.fault='unsupported-'+property;
            if(PATH_METHODS.has(property))self.recordPath(property,args);
            if(PAINT_METHODS.has(property))self.recordPaint(property,args);
            const result=raw[property](...args);
            if(property==='createLinearGradient'||property==='createRadialGradient'){
              const meta={kind:property,args:args.slice(),matrix:self.state.matrix.slice(),tag:self.tag(),layer:self.layer,stops:[]};
              GRADIENTS.set(result,meta);const add=result.addColorStop.bind(result);
              result.addColorStop=function(offset,color){meta.stops.push([offset,color]);return add(offset,color);};
            }
            return result;
          };
          self.methods.set(property,method);return method;
        },
        set(target,property,value){
          raw[property]=value;
          if(PROPERTIES.includes(property))self.state[property]=raw[property];
          return true;
        }
      });
    }
    finish(){
      if(this.stack.length)this.picture.fault='unbalanced-canvas-state';
      this.picture.finalState=cloneState(this.state);return this.picture;
    }
  }

  function alive(tag,time){
    if(!tag)return true;const m=tag.meta;
    return time>=(m.bornAt??-Infinity)-1e-7&&time<(m.deadAt??Infinity)-1e-7;
  }
  function pose(tag,time,fallbackTime){
    const history=tag?.meta?.history;
    if(!history||history.length<1)return {x:tag?.x||0,y:tag?.y||0};
    let a=history[0],b=history[history.length-1];
    for(let i=1;i<history.length;i++)if(history[i].time>=time){a=history[i-1];b=history[i];break;}
    if(time<a.time||time>b.time+1e-7)return {x:tag.x,y:tag.y};
    if(b.discontinuous)return time<b.time?{x:a.x,y:a.y}:{x:b.x,y:b.y};
    const t=b.time>a.time?clamp((time-a.time)/(b.time-a.time),0,1):0;
    return {x:lerp(a.x,b.x,t),y:lerp(a.y,b.y,t)};
  }
  function shiftedMatrix(node,source,previous,current,t,targetTime){
    const m=node.matrix.slice(),tag=node.tag;
    if(node.layer.space==='screen')return m;
    const camera={x:lerp(previous.camera.x,current.camera.x,t),y:lerp(previous.camera.y,current.camera.y,t)};
    let dx=source.camera.x-camera.x,dy=source.camera.y-camera.y;
    if(tag){const p=pose(tag,targetTime,source.time);dx+=p.x-tag.x;dy+=p.y-tag.y;}
    m[4]+=dx*current.scale;m[5]+=dy*current.scale;return m;
  }
  function safePair(a,b,kind,loose=false){
    if(!a||!b||a.kind!==b.kind||a.args.length!==b.args.length)return false;
    if((a.tag?.id||0)!==(b.tag?.id||0))return false;
    if(a.tag?.meta?.history){
      const start=Math.min(a.tag.sampleTime,b.tag.sampleTime),end=Math.max(a.tag.sampleTime,b.tag.sampleTime);
      if(a.tag.meta.history.some(p=>p.discontinuous&&p.time>start+1e-7&&p.time<=end+1e-7))return false;
    }
    if(kind==='drawImage'&&a.imageId!==b.imageId&&!loose)return false;
    return true;
  }
  function sameGeometry(a,b){
    const skip=a.kind==='drawImage'||a.kind==='fillText'||a.kind==='strokeText'?1:0;
    for(let i=skip;i<a.args.length;i++)if(a.args[i]!==b.args[i])return false;
    return a.state.matrix.every((value,i)=>value===b.state.matrix[i]);
  }
  function loosePartners(previous,current,t){
    // A colour, image or text change gives a primitive a new strict key, and
    // both versions would be drawn. Pair the unmatched versions once by owner
    // and draw order. Ownerless primitives must also keep their geometry.
    const partners=new Map(),pending=new Map();
    for(const a of previous.ops)if(a.looseKey&&!current.byKey.has(a.key))pending.set(a.looseKey,a);
    if(!pending.size)return partners;
    for(const b of current.ops){
      if(previous.byKey.has(b.key))continue;
      const a=pending.get(b.looseKey);
      if(!a||a.args.length!==b.args.length)continue;
      if(!a.tag&&!(a.fullScreen&&b.fullScreen)&&(a.path||!sameGeometry(a,b)))continue;
      pending.delete(b.looseKey);
      partners.set(a.key,{a,b,skip:t>=.5});partners.set(b.key,{a,b,skip:t<.5});
    }
    return partners;
  }
  function geometryArgs(a,b,t,kind){
    if(a.args.every((value,i)=>value===b.args[i]))return b.args;
    const pick=t<.5?a:b,args=pick.args.slice();
    for(let i=0;i<args.length;i++){
      // Sprite source rectangles and text content are discrete. Only geometry
      // in the destination domain may be interpolated.
      if(kind==='drawImage'&&(i===0||(args.length===9&&i<5)))continue;
      if((kind==='fillText'||kind==='strokeText')&&i===0)continue;
      if(typeof a.args[i]==='number'&&typeof b.args[i]==='number')args[i]=lerp(a.args[i],b.args[i],t);
    }
    return args;
  }
  function dispose(picture){
    if(!picture)return;
    for(const image of picture.sources||[]){image.width=1;image.height=1;}
    picture.sources=[];picture.ops=[];picture.byKey?.clear();picture.nodes?.clear();picture.borrowed?.clear();
  }
  function mergedKeys(previous,current){
    // The 2D layer order is the depth order. Keep prior relative order and
    // insert newly visible primitives before their next surviving neighbor.
    const result=[],pending=[];let cursor=0;
    const present=new Set(previous.ops.map(o=>o.key));
    const before=new Map();
    for(const op of current.ops){
      if(present.has(op.key)){if(pending.length){before.set(op.key,pending.splice(0));}}
      else pending.push(op.key);
    }
    for(const op of previous.ops){for(const key of before.get(op.key)||[])result.push(key);result.push(op.key);}
    result.push(...pending);
    const index=key=>(current.byKey.get(key)||previous.byKey.get(key)).layer.index;
    return result.map((key,n)=>({key,n,layer:index(key)})).sort((a,b)=>a.layer-b.layer||a.n-b.n).map(x=>x.key);
  }

  function replay(previous,current,t,ctx,options={}){
    if(!previous||!current)throw new Error('Two real frames are required.');
    if(previous.width!==current.width||previous.height!==current.height||previous.scale!==current.scale)
      throw new Error('Frame dimensions changed.');
    t=clamp(t,0,1);
    const targetTime=lerp(previous.time,current.time,t),stats={paints:0,pathNodes:0,rejected:0,unmatched:0,loosePairs:0,discrete:0,detached:0};
    const gradients=new WeakMap();let lastMatrix=null,lastStyles={};
    const setMatrix=m=>{
      if(!lastMatrix||m.some((x,i)=>Math.abs(x-lastMatrix[i])>1e-9)){ctx.setTransform(...m);lastMatrix=m;}
    };
    const gradientValue=(value,paired,source)=>{
      const g=value&&typeof value==='object'?GRADIENTS.get(value):null;
      if(!g)return value;
      let copy=gradients.get(value);if(copy)return copy;
      const other=paired&&typeof paired==='object'?GRADIENTS.get(paired):null;
      // Gradient coordinates are consumed in the paint call's coordinate
      // space. Moving the CTM only while creating a gradient does not move
      // its color ramp when the later paint uses a different CTM.
      const args=other&&other.kind===g.kind?g.args.map((value,i)=>
        source===current?lerp(other.args[i],value,t):lerp(value,other.args[i],t)):g.args;
      copy=ctx[g.kind](...args);for(const stop of g.stops)copy.addColorStop(...stop);
      gradients.set(value,copy);return copy;
    };
    const applyState=(state,paired,source)=>{
      for(const p of PROPERTIES){
        let value=state[p];
        if((p==='globalAlpha'||p==='lineWidth'||p==='lineDashOffset')&&paired&&typeof paired[p]==='number')
          value=source===current?lerp(paired[p],value,t):lerp(value,paired[p],t);
        if(p==='fillStyle'||p==='strokeStyle')value=gradientValue(value,paired?.[p],source);
        if(value!==undefined&&lastStyles[p]!==value){ctx[p]=value;lastStyles[p]=value;}
      }
      const dash=state.lineDash.join(',');if(lastStyles.dash!==dash){ctx.setLineDash(state.lineDash);lastStyles.dash=dash;}
    };
    const keys=t===0?previous.ops.map(o=>o.key):t===1?current.ops.map(o=>o.key):mergedKeys(previous,current);
    const partners=t>0&&t<1?loosePartners(previous,current,t):new Map();
    const chosen=t<.5?previous:current,discreteDone=new Set();
    const drawExact=op=>{
      if(op.kind==='drawImage'&&!usable(op.args[0])){stats.detached++;return;}
      applyState(op.state,null,chosen);
      if(op.path){
        ctx.beginPath();
        for(const node of op.path){setMatrix(node.matrix);ctx[node.kind](...node.args);}
        stats.pathNodes+=op.path.length;
      }
      setMatrix(op.state.matrix);ctx[op.kind](...op.args);stats.paints++;stats.discrete++;
    };
    ctx.save();
    try{
      ctx.setTransform(1,0,0,1,0,0);ctx.globalCompositeOperation='source-over';ctx.globalAlpha=1;
      ctx.clearRect(0,0,current.width,current.height);ctx.imageSmoothingEnabled=false;
      for(const key of keys){
        let a=previous.byKey.get(key),b=current.byKey.get(key),loose=false;
        const layer=(b||a).layer;
        if(layer.discrete){
          // Screen overlays such as the time-of-day tint and light map are shown
          // from one real frame, exactly as the normal renderer drew them.
          if(discreteDone.has(layer.id))continue;discreteDone.add(layer.id);
          for(const op of chosen.ops)if(op.layer.id===layer.id)drawExact(op);
          continue;
        }
        const mate=partners.get(key);
        if(mate){if(mate.skip)continue;({a,b}=mate);loose=true;}
        let op=t<.5?(a||b):(b||a),source=op===b?current:previous;
        if(op.kind==='drawImage'&&!usable(op.args[0])){
          const fallback=op===a?b:a;
          if(!fallback||!usable(fallback.args[0])){stats.detached++;continue;}
          op=fallback;source=op===b?current:previous;
          if(source===current)a=null;else b=null;
        }
        if(!alive(op.tag,targetTime)){stats.rejected++;continue;}
        const pair=safePair(a,b,op.kind,loose)&&t>0&&t<1;
        if(!pair&&t>0&&t<1)stats.unmatched++;
        if(pair&&loose)stats.loosePairs++;
        const other=pair?(source===current?a:b):null;
        applyState(op.state,other?.state,source);
        if(op.path){
          ctx.beginPath();
          const pathKeys=op.path.map(n=>n.key),known=new Set(pathKeys);
          const alternate=source===current?a:b;
          if(t>0&&t<1&&!op.tag&&alternate?.path)for(const n of alternate.path)if(!known.has(n.key)){pathKeys.push(n.key);known.add(n.key);}
          let visibleNodes=0;
          for(const nodeKey of pathKeys){
            const p=previous.nodes.get(nodeKey),q=current.nodes.get(nodeKey),node=t<.5?(p||q):(q||p);
            if(!node||!alive(node.tag,targetTime))continue;
            const nodeSource=node===q?current:previous;
            const compatible=safePair(p,q,node.kind)&&t>0&&t<1;
            const matrix=compatible?affine(p.matrix,q.matrix,t):shiftedMatrix(node,nodeSource,previous,current,t,targetTime);
            const args=compatible?geometryArgs(p,q,t,node.kind):node.args;
            setMatrix(matrix);ctx[node.kind](...args);visibleNodes++;
          }
          if(!visibleNodes)continue;
          // Stroke widths and gradients are defined in the paint call's CTM.
          const matrix=pair?affine(a.state.matrix,b.state.matrix,t):
            shiftedMatrix({matrix:op.state.matrix,tag:null,layer:{...op.layer,space:'screen'}},source,previous,current,t,targetTime);
          setMatrix(matrix);ctx[op.kind](...op.args);stats.pathNodes+=visibleNodes;
        }else{
          const matrix=pair?affine(a.state.matrix,b.state.matrix,t):
            op.fullScreen?op.state.matrix:shiftedMatrix({matrix:op.state.matrix,tag:op.tag,layer:op.layer},source,previous,current,t,targetTime);
          setMatrix(matrix);const args=pair?geometryArgs(a,b,t,op.kind):op.args;
          ctx[op.kind](...args);
        }
        stats.paints++;
      }
    }finally{ctx.restore();}
    return stats;
  }
  root.SwarmFrameSynthesis=Object.freeze({Recorder,replay,dispose,readState,writeState,surface,affine,
    version:'1.0.0',method:'engine-assisted retained-paint reprojection'});
})(typeof window==='object'?window:globalThis);
