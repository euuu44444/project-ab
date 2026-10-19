// This file is embedded inside the game's closure by build_frame_generation.cjs.
function makeFrameGeneration(){
  const S=window.SwarmFrameSynthesis;
  const HUD_IDS=new Set(['hud/reaction-buffs','overlay/threat-markers','overlay/low-hp','overlay/screen-flash','overlay/damage-flash']);
  // Full-screen overlays are not interpolated; a generated frame shows them
  // from one real frame so tint and light maps are never drawn twice.
  const DISCRETE_LAYERS=new Set(['overlay/ambient']);
  const COLLECTIONS=['enemies','projectiles','enemyProjectiles','xpOrbs','lootDrops','hazards',
    'turrets','saplings','particles','spriteFx','signatureFx','enemyBeams','enemyGroundAttacks'];
  // The run continues through choice screens: buffers and the native
  // high-refresh request are kept there (buffers not on low-memory devices).
  const RUN_STATES=new Set(['playing','levelup','chest','special','ability','abilityIntro']);
  const REFRESH_CLASSES=[60,72,90,96,120,144,165];
  // Backoff per failure class: first wait, growth factor and cap in ms.
  const BACKOFF={budget:[2000,2,60000],resource:[5000,2,120000],content:[10000,3,90000],exception:[15000,4,120000]};
  let owner=null,metadata=new WeakMap(),live=new Map(),nextId=1,epoch=0;
  let previous=null,current=null,recorder=null,active=false;
  // Presentation clock: each callback shows content time clock-lag, captured
  // only when the simulation has a new state (see step()).
  let lag=0,stride=1,observedAt=NaN,periodFlag=0;
  const lagWindow=[];
  let bufferIndex=0,buffers=[],lastStep=-Infinity,inactiveSince=0;
  let cooldownUntil=0,requestedNative=false,mode=visualSettings.frameGeneration||'auto';
  let lastUi=-Infinity,lastReason='initial',presentTime=-Infinity;
  let cpuCapture=0,cpuGenerated=0,error='',lastSynthesis=null,lastSession=null;
  const events=[],deferred=new Set();
  const totals={captured:0,real:0,generated:0,warmup:0,holds:0,drops:0,yields:0,rejectedPairs:0,resets:0,errors:0,
    lateCallbacks:0,nonMonotonic:0,observations:0};
  const failures={budget:0,resource:0,content:0,exception:0};
  // Display period from callback timestamps. Our own load can only lengthen
  // deltas, so it never lowers the estimate while generation is active.
  const refresh={deltas:[],period:0,stable:0,slowRun:0,lastNow:NaN,openHz:0};
  const gate={open:false,openAt:Infinity};
  // Whole-callback budget: recent costs in ms, late callbacks while active,
  // the late share with generation off, and learned post-callback cost.
  const cost={capture:[],replay:[],blit:[],normal:[],periods:[],late:[],heavyLate:[],dropRun:0,baseLate:.02,post:0,lastNow:NaN,
    lastLateAt:-Infinity,postDecayAt:0,skip:0,warm:0,restart:true,heavy:false,prevHeavy:false,yielding:false,yieldedLast:false,transition:false};
  const backoff={level:{budget:0,resource:0,content:0,exception:0},cls:'',failedAt:-Infinity,normalAtFail:0,trialUntil:0,healthy:0};

  // Closable images (worker terrain chunks, light maps) are referenced, not
  // copied, by the retained frames. The game's release waits until no
  // retained frame can draw them again.
  function holds(surface){
    return !!(previous?.borrowed?.has(surface)||current?.borrowed?.has(surface)||recorder?.picture.borrowed.has(surface));
  }
  function deferRelease(surface){if(!holds(surface))return false;deferred.add(surface);return true;}
  function flushReleased(){for(const surface of deferred)if(!holds(surface)){deferred.delete(surface);surface.close();}}
  function remember(list,value,size=16){list.push(value);if(list.length>size)list.shift();}
  function quantile(list,q){if(!list.length)return 0;const sorted=list.slice().sort((a,b)=>a-b);return sorted[Math.min(sorted.length-1,Math.floor(sorted.length*q))];}
  function predict(list,scale){return list.length>=4?quantile(list,.5)*scale:0;}
  function releaseBuffers(){for(const c of buffers){c.width=1;c.height=1;}buffers=[];}
  function reset(reason='reset',release=false){
    if(active&&events.length){
      const s=status();if(s.realFPS+s.generatedFPS>0)lastSession={realFPS:s.realFPS,generatedFPS:s.generatedFPS};
    }
    S.dispose(previous);S.dispose(current);previous=current=null;recorder=null;flushReleased();
    lag=0;lagWindow.length=0;observedAt=NaN;periodFlag=0;
    if(active)cost.transition=true;
    cost.heavy=false;cost.yieldedLast=false;
    active=false;lastStep=-Infinity;presentTime=-Infinity;
    owner=null;metadata=new WeakMap();live.clear();nextId=1;epoch=0;
    events.length=0;lastReason=reason;totals.resets++;
    if(reason==='clock')reconfirmRefresh();
    if(release)releaseBuffers();
  }
  function snapPeriod(ms){const hz=1000/ms;for(const c of REFRESH_CLASSES)if(Math.abs(hz-c)<=c*.04)return 1000/c;return ms;}
  function periodMs(){return refresh.period||Math.max(4,displayIntervalMs);}
  function refreshConfident(){return refresh.period>0&&refresh.stable>=16;}
  function reconfirmRefresh(){refresh.deltas.length=0;refresh.stable=0;refresh.slowRun=0;refresh.lastNow=NaN;gate.open=false;gate.openAt=Infinity;}
  function adoptPeriod(period,now){
    const slower=refresh.period>0&&period>refresh.period;
    refresh.period=period;refresh.stable=0;refresh.slowRun=0;
    // A panel that switched to a slower mode first looks like a budget
    // failure; refund that level. Load can also produce a slower estimate, so
    // the wait already scheduled stays as it is.
    if(slower&&backoff.cls==='budget'&&now-backoff.failedAt<4000){
      backoff.level.budget=Math.max(0,backoff.level.budget-1);
    }
  }
  function sampleRefresh(now){
    const delta=now-refresh.lastNow;refresh.lastNow=now;
    if(!(delta>=3&&delta<=50))return;
    const deltas=refresh.deltas;remember(deltas,delta,64);
    if(deltas.length<12)return;
    // Lower envelope of the deltas, refined over its cluster and snapped to
    // a common panel rate.
    const candidate=quantile(deltas,.15);let sum=0,n=0;
    for(const value of deltas)if(Math.abs(value-candidate)<=candidate*.08){sum+=value;n++;}
    if(n<Math.max(8,deltas.length*.2))return;
    const period=snapPeriod(sum/n);
    if(!refresh.period||period<refresh.period*.95){adoptPeriod(period,now);return;}
    if(period>refresh.period*1.05){
      refresh.slowRun=active?0:refresh.slowRun+1;
      if(refresh.slowRun>=48)adoptPeriod(period,now);
      return;
    }
    refresh.slowRun=0;refresh.stable++;
  }
  // AUTO opens at 88 Hz or more once the period is confirmed, after a 250 ms
  // dwell for a newly seen rate, and closes only when a rate of 80 Hz or
  // less is adopted.
  function updateGate(now){
    const hz=1000/periodMs();
    if(gate.open){if(refresh.period&&hz<=80){gate.open=false;gate.openAt=Infinity;}return;}
    if(!refreshConfident()||hz<88){gate.openAt=Infinity;return;}
    if(gate.openAt===Infinity)gate.openAt=now+(Math.round(hz)===refresh.openHz?0:250);
    if(now>=gate.openAt){gate.open=true;refresh.openHz=Math.round(hz);}
  }
  function requestNative(on){
    const wanted=on&&mode!=='off';if(wanted===requestedNative)return;
    requestedNative=wanted;if(wanted)reconfirmRefresh();
    if(window.ElementalNative&&typeof ElementalNative.setFrameGenerationActive==='function')
      ElementalNative.setFrameGenerationActive(wanted);
  }
  function stateChanged(next){
    const run=RUN_STATES.has(next);
    reset('state-'+next,!run||MOBILE_LOW_MEMORY);requestNative(run);syncUi(true);
  }
  function setMode(value){
    if(!['off','auto','2x'].includes(value))return;
    mode=value;error='';cooldownUntil=0;
    for(const key in backoff.level)backoff.level[key]=0;backoff.cls='';backoff.trialUntil=0;backoff.healthy=0;
    __set_visualSettings({...visualSettings,frameGeneration:mode});saveVisualSettings();
    cost.restart=true;reset('mode-change',true);lastSession=null;requestNative(RUN_STATES.has(state));resetFrameClock();syncUi(true);
    if(game)render();
  }
  function eligible(){return !!S&&state==='playing'&&!!game&&!game.awaitingChoice&&!nativeActivityPaused&&!document.hidden;}
  function wants(now=performance.now()){
    if(!eligible()||mode==='off'||now<cooldownUntil)return false;
    return mode!=='auto'||gate.open;
  }
  function observe(){
    if(!game)return;
    const fresh=owner!==game;
    if(fresh){owner=game;metadata=new WeakMap();live.clear();nextId=1;epoch=0;}
    epoch++;const time=game.t;
    function visit(object){
      if(!object||typeof object!=='object')return;
      const x=Number(object.x??object.x1),y=Number(object.y??object.y1);
      if(!Number.isFinite(x)||!Number.isFinite(y))return;
      let meta=metadata.get(object);
      const reused=meta&&meta.lastAge!=null&&object.age!=null&&object.age+1e-5<meta.lastAge;
      if(!meta||meta.deadAt!==Infinity||reused){
        if(meta)meta.deadAt=Math.min(meta.deadAt,time);
        meta={id:nextId++,bornAt:fresh?-Infinity:time,deadAt:Infinity,history:[],epoch};
        metadata.set(object,meta);live.set(meta.id,meta);
      }
      const old=meta.history[meta.history.length-1];
      if(!old||time>old.time+1e-8){
        const discontinuous=!!old&&Math.hypot(x-old.x,y-old.y)>96;
        meta.history.push({time,x,y,discontinuous});
        while(meta.history.length>12)meta.history.shift();
      }
      meta.x=x;meta.y=y;meta.lastAge=object.age;meta.epoch=epoch;
    }
    visit(game.player);
    for(const key of COLLECTIONS){const list=game[key];if(Array.isArray(list))for(const object of list)visit(object);}
    for(const [id,meta]of live)if(meta.epoch!==epoch){meta.deadAt=time;live.delete(id);}
    totals.observations++;observedAt=time;
  }
  function observeIfNeeded(){if(wants()||active)observe();}
  function mark(object){
    if(!recorder||!object||typeof object!=='object')return;
    const meta=metadata.get(object);if(meta)recorder.object({id:meta.id,x:meta.x,y:meta.y,meta});
  }
  function staticObject(id,x,y){
    if(recorder)recorder.object({id:'static:'+id,x,y,meta:{bornAt:-Infinity,deadAt:Infinity}});
  }
  function layer(id,index){
    if(!recorder)return;
    const discrete=DISCRETE_LAYERS.has(id);
    recorder.beginLayer(id,index,discrete?'screen':'world',discrete);
  }
  function ensureBuffers(){
    if(buffers.length!==2||buffers.some(c=>c.width!==canvas.width||c.height!==canvas.height)){
      reset('buffer-size',true);
      buffers=[S.surface(canvas.width,canvas.height),S.surface(canvas.width,canvas.height)];
      bufferIndex=0;cost.warm=3;
    }
  }
  function drawHud(){
    ctx.setTransform(dpr,0,0,dpr,0,0);ctx.globalAlpha=1;ctx.globalCompositeOperation='source-over';
    for(const system of RENDER_SYSTEMS){if(!HUD_IDS.has(system.id))continue;
      if(system.when!==null&&!system.when())continue;system.run(0);}
  }
  function image(picture){
    const start=performance.now(),raw=ctx;raw.save();raw.setTransform(1,0,0,1,0,0);raw.globalAlpha=1;
    raw.globalCompositeOperation='copy';raw.drawImage(picture.color,0,0);raw.restore();
    S.writeState(raw,picture.finalState);drawHud();if(!cost.warm)remember(cost.blit,performance.now()-start);
  }
  function stamp(kind,now,time){
    if(time<presentTime-1e-7){totals.nonMonotonic++;throw new Error('Non-monotonic frame timestamp');}
    presentTime=time;totals[kind]++;events.push({now,kind});
    while(events.length&&now-events[0].now>1000)events.shift();
  }
  function capture(now){
    // loop() already observed this simulation state after its fixed update.
    ensureBuffers();if(owner!==game||observedAt!==game.t)observe();
    S.dispose(previous);previous=current;current=null;flushReleased();
    const c=buffers[bufferIndex];bufferIndex^=1;
    const target=c.getContext('2d',{alpha:false,desynchronized:true});
    const raw=ctx;
    S.writeState(target,S.readState(raw));
    const start=performance.now();
    recorder=new S.Recorder(target,{time:game.t,camera:game.camera,scale:dpr,
      maxSnapshotPixels:MOBILE_LOW_MEMORY?2097152:4194304,maxOps:24000,maxNodes:80000});
    try{
      ctx=recorder.context;render();current=recorder.finish();current.color=c;current.capturedAt=now;
    }finally{ctx=raw;recorder=null;}
    const ms=performance.now()-start;cpuCapture=cpuCapture?cpuCapture*.85+ms*.15:ms;if(!cost.warm)remember(cost.capture,ms);
    totals.captured++;
    return current;
  }
  function validPair(){
    if(!previous||!current||previous.fault||current.fault)return false;
    const delta=current.time-previous.time;
    if(!(delta>1e-7&&delta<=.067))return false;
    if(Math.hypot(current.camera.x-previous.camera.x,current.camera.y-previous.camera.y)>Math.min(viewW,viewH)*.2)return false;
    return previous.width===current.width&&previous.height===current.height&&previous.scale===current.scale;
  }
  function failureClass(reason){
    if(/^(generation-budget|deadline-miss|budget-)/.test(reason))return 'budget';
    if(/^(snapshot-budget|paint-budget|path-budget|invalid-image-source)$/.test(reason))return 'resource';
    if(/^(unsupported-|unbalanced-canvas-state)/.test(reason))return 'content';
    return 'exception';
  }
  function fail(reason,now){
    // A failure during the trial after a resume escalates one extra level.
    const cls=failureClass(String(reason)),[first,factor,cap]=BACKOFF[cls];
    const level=backoff.level[cls]=Math.min(8,backoff.level[cls]+(now<backoff.trialUntil?2:1));
    const wait=Math.min(cap,first*factor**(level-1));
    error=String(reason);totals.errors++;failures[cls]++;cooldownUntil=now+wait;
    backoff.cls=cls;backoff.failedAt=now;backoff.trialUntil=0;backoff.healthy=0;
    backoff.normalAtFail=cost.normal.length>=8?quantile(cost.normal,.75):0;cost.restart=true;
    // Short budget waits keep the two buffers so the resume does not reallocate.
    reset('fallback',!(cls==='budget'&&wait<=8000&&!MOBILE_LOW_MEMORY));inactiveSince=now;syncUi(true);
  }
  // The work of one callback must end this long after its vsync.
  function deadline(){const period=periodMs();return period-Math.max(.5,.06*period)-cost.post;}
  // Lateness of the previous callback, attributed to generation only when it
  // was active. Returns the callback delta in ms.
  function noteCallback(now){
    const delta=now-cost.lastNow;cost.lastNow=now;
    if(!(delta>0&&delta<=250)){cost.prevHeavy=false;return 0;}
    const late=delta>1.5*periodMs();
    if(late)cost.lastLateAt=now;
    if(active){
      if(cost.skip>0)cost.skip--;else remember(cost.late,late?1:0,32);
      // Heavy callbacks that fitted on the CPU and are still often late show
      // cost after the callback (style, raster, GPU). One stall is not enough.
      if(cost.prevHeavy){
        remember(cost.heavyLate,late?1:0,32);
        const n=cost.heavyLate.length,sum=cost.heavyLate.reduce((a,b)=>a+b,0);
        if(n>=8&&sum>=3&&sum/n-cost.baseLate>.1){cost.post=Math.min(.3*periodMs(),cost.post+.25);cost.heavyLate.length=0;}
      }
    }else cost.baseLate+=((late?1:0)-cost.baseLate)/32;
    if(now-cost.lastLateAt>=2000&&now>=cost.postDecayAt){cost.post=Math.max(0,cost.post-.1);cost.postDecayAt=now+2000;}
    cost.prevHeavy=false;
    return delta;
  }
  function presentationRate(now){
    while(events.length&&now-events[0].now>1000)events.shift();
    return events.length?events.length/Math.min(1,Math.max(.25,(now-events[0].now)/1000)):0;
  }
  // Sustained evidence only, judged at a capture. Misses and drops do not
  // pause while generation still shows clearly more distinct frames than
  // normal rendering (at most one per fixed step).
  function overBudget(now){
    if(cost.capture.length>=4&&quantile(cost.capture,.5)>2000*FIXED_DT)return 'budget-capture';
    if(presentationRate(now)>=1.2/FIXED_DT)return '';
    if(cost.late.length>=24){
      const rate=cost.late.reduce((a,b)=>a+b,0)/cost.late.length;
      if(rate-cost.baseLate>(now<backoff.trialUntil?.1:.25))return 'deadline-miss';
    }
    if(cost.periods.length>=16&&cost.periods.reduce((a,b)=>a+b,0)>=4)return 'budget-drops';
    return '';
  }
  function earlyResume(now){
    // A budget wait ends early once normal rendering became much cheaper.
    if(now>=cooldownUntil||backoff.cls!=='budget'||now-backoff.failedAt<2000)return;
    if(backoff.normalAtFail>0&&cost.normal.length>=16&&quantile(cost.normal,.75)<=.6*backoff.normalAtFail)cooldownUntil=now;
  }
  function strideFor(hz){
    // 2x below 72 Hz captures every other fixed step; at 60 Hz every callback
    // has a new step, so stride 1 would generate nothing.
    return mode==='2x'&&hz<72?2:1;
  }
  // clock is the continuous simulation time in seconds (game.t plus the
  // unspent accumulator). Each callback presents content time clock-lag:
  // a blit of a real frame at an endpoint, otherwise a replay in between.
  // workStart is the loop's performance.now() at the start of the callback.
  function step(now,clock=game?game.t+Math.max(0,simAccumulator):0,workStart=-1){
    cost.yielding=false;cost.heavy=false;if(cost.warm)cost.warm--;
    const delta=noteCallback(now);sampleRefresh(now);updateGate(now);
    requestNative(RUN_STATES.has(state));earlyResume(now);
    if(!wants(now)){
      if(active||current){reset(now<cooldownUntil?'cost-fallback':'inactive');inactiveSince=now;cost.restart=true;}
      if(buffers.length&&now-inactiveSince>8000)releaseBuffers();
      syncUi();return false;
    }
    const interval=periodMs(),seconds=interval/1000;
    if(Number.isFinite(lastStep)&&now-lastStep>Math.max(80,interval*5)){
      totals.lateCallbacks++;reset('callback-stall');
    }
    try{
      ensureBuffers();
      const nextStride=strideFor(1000/interval);
      if(nextStride!==stride){stride=nextStride;if(current)reset('stride');}
      if(!active){
        active=true;
        // A fresh start (not an internal reset) restarts the budget windows
        // and, after a failure, a stricter trial.
        if(cost.restart){
          cost.restart=false;cost.late.length=0;cost.periods.length=0;cost.heavyLate.length=0;cost.dropRun=0;
          cost.capture.length=0;cost.replay.length=0;cost.blit.length=0;cost.skip=4;if(backoff.cls)backoff.trialUntil=now+600;}
      }
      else if((backoff.healthy+=Math.min(50,delta))>=10000){
        // Ten healthy seconds lower every backoff level by one.
        backoff.healthy=0;let any=false;
        for(const key in backoff.level){if(backoff.level[key])backoff.level[key]--;any||=backoff.level[key]>0;}
        if(!any)backoff.cls='';
      }
      lastStep=now;
      const elapsed=()=>workStart>=0?performance.now()-workStart:0;
      if(!current||game.t-current.time>=stride*FIXED_DT-1e-6){
        const reason=overBudget(now);if(reason){fail(reason,now);return false;}
        const spent=elapsed();
        if(current&&!cost.yieldedLast&&spent>.25*deadline()&&spent+predict(cost.capture,1.1)+predict(cost.blit,1.1)>deadline()){
          // This callback's update leaves no room for a capture: render
          // normally and capture on the next callback, which usually has none.
          totals.yields++;remember(cost.periods,1);cost.yielding=true;cost.yieldedLast=true;syncUi();return false;
        }
        cost.yieldedLast=false;
        if(current)remember(cost.periods,periodFlag);
        periodFlag=0;
        capture(now);cost.heavy=true;
        if(current.fault){fail(current.fault,now);return false;}
        if(previous&&!validPair())totals.rejectedPairs++;
      }
      const pair=validPair();
      // The smallest lag that never needs content newer than the last
      // capture: the largest recent clock-current.time. It rises at once
      // and falls by at most 4% of an interval per callback.
      lagWindow.push(clock-current.time);
      const size=Math.max(24,Math.ceil(250/interval));
      while(lagWindow.length>size)lagWindow.shift();
      const wanted=Math.min(stride*FIXED_DT,Math.max(...lagWindow));
      lag=wanted>lag?wanted:Math.max(wanted,lag-.04*seconds);
      let target=Math.min(clock-lag,current.time);
      target=pair?Math.max(target,previous.time):current.time;
      target=Math.max(target,presentTime);
      const snap=.2*seconds;
      if(current.time-target<=snap)target=current.time;
      else if(pair&&target-previous.time<=snap&&previous.time>=presentTime)target=previous.time;
      if(target<=presentTime)totals.holds++;
      else if(target===current.time){image(current);stamp('real',now,target);}
      else if(target===previous.time){image(previous);stamp('real',now,target);}
      else if(cost.dropRun<8&&elapsed()+predict(cost.replay,1.1)>deadline()){
        // The replay would miss this vsync: show the newer real frame now.
        totals.drops++;periodFlag=1;cost.dropRun++;
        if(current.time>presentTime){image(current);stamp('real',now,current.time);}else totals.holds++;
      }else{
        const t=(target-previous.time)/(current.time-previous.time);
        // After 8 consecutive drops one replay is forced so the prediction
        // can recover; its sample replaces the stale window.
        if(cost.dropRun>=8)cost.replay.length=0;
        cost.dropRun=0;
        const start=performance.now();lastSynthesis=S.replay(previous,current,t,ctx);
        const ms=performance.now()-start;cpuGenerated=cpuGenerated?cpuGenerated*.85+ms*.15:ms;remember(cost.replay,ms);
        drawHud();stamp('generated',now,target);cost.heavy=true;
      }
      syncUi();return true;
    }catch(failure){fail(failure?.message||failure,now);return false;}
  }
  // Called by loop() after the callback's work. Returns true when the sample
  // must not reach adaptive quality: generation owned or shaped it.
  function endCallback(now,work,owned){
    const skip=owned||cost.yielding||cost.transition;
    cost.prevHeavy=owned&&cost.heavy&&work<=deadline();
    cost.heavy=false;cost.yielding=false;if(!owned)cost.transition=false;
    return skip;
  }
  function sampleNormal(ms){
    remember(cost.normal,ms,32);
    if(active&&game)presentTime=Math.max(presentTime,game.t);
  }
  function direct(){if(cost.yielding)return;if((current||previous||active)&&!recorder)reset('direct-render');}
  function autoState(now){
    if(mode==='off')return 'off';
    if(now<cooldownUntil)return 'backoff';
    if(active)return 'active';
    if(!RUN_STATES.has(state))return 'idle';
    if(mode==='auto'){
      if(!refreshConfident())return 'measuring';
      if(!gate.open)return 1000/periodMs()<88?'low-refresh':'arming';
    }
    return 'ready';
  }
  function status(){
    const now=performance.now();while(events.length&&now-events[0].now>1000)events.shift();
    const real=events.filter(e=>e.kind==='real').length,generated=events.length-real;
    const elapsed=events.length?Math.min(1,Math.max(.25,(now-events[0].now)/1000)):1;
    const ready=elapsed>=.75;
    return {mode,active,supported:!!S,method:S?.method,displayHzEstimate:Math.round(1000/periodMs()),
      refreshHz:refresh.period?Math.round(1000/refresh.period):null,refreshConfident:refreshConfident(),
      autoGate:gate.open,autoState:autoState(now),
      realFPS:ready?Math.round(real/elapsed):0,generatedFPS:ready?Math.round(generated/elapsed):0,
      presentationsPerSecond:ready?Math.round(events.length/elapsed):0,lastSession,
      captureCpuMs:+cpuCapture.toFixed(3),generationCpuMs:+cpuGenerated.toFixed(3),
      addedPresentationDelayMs:active?+(lag*1000).toFixed(2):0,stride,
      deadlineMs:+deadline().toFixed(2),learnedPostMs:+cost.post.toFixed(2),
      medianMs:{capture:quantile(cost.capture,.5),replay:quantile(cost.replay,.5),blit:quantile(cost.blit,.5),normal:quantile(cost.normal,.5)},
      missRate:cost.late.length?+(cost.late.reduce((a,b)=>a+b,0)/cost.late.length).toFixed(3):0,
      baselineMissRate:+cost.baseLate.toFixed(3),
      backoff:{class:backoff.cls,level:{...backoff.level},resumeInMs:Math.max(0,Math.round(cooldownUntil-now))},failures:{...failures},
      cacheBytesEstimate:buffers.reduce((n,c)=>n+c.width*c.height*4,0)+
        (previous?.snapshotPixels||0)*4+(current?.snapshotPixels||0)*4+
        ((previous?.ops.length||0)+(current?.ops.length||0))*256+
        ((previous?.nodes.size||0)+(current?.nodes.size||0))*128,
      cachedPaints:current?.ops.length||0,cachedNodes:current?.nodes.size||0,
      fallback:now<cooldownUntil,error,lastReason,lastSynthesis,
      presentationTime:Number.isFinite(presentTime)?presentTime:null,...totals};
  }
  function syncUi(force=false){
    const now=performance.now();if(!force&&now-lastUi<500)return;lastUi=now;
    const s=status(),wait=Math.max(1,Math.ceil(s.backoff.resumeInMs/1000));
    const label=mode==='off'?'OFF':s.fallback?(backoff.cls==='budget'?`負荷のため休止（${wait}秒後に再試行）`:`描画の制限のため休止（${wait}秒後に再試行）`):s.active?
      `実 ${s.realFPS} / 生成 ${s.generatedFPS} / 表示 ${s.presentationsPerSecond}/s`:
      state!=='playing'&&lastSession?`直前 実 ${lastSession.realFPS} / 生成 ${lastSession.generatedFPS}`:
      mode==='auto'?(state!=='playing'?'AUTO':s.autoState==='measuring'?'表示速度を測定中':
        s.autoState==='low-refresh'?`90Hz以上で動作（現在 ${s.displayHzEstimate}Hz）`:'90Hz以上で動作'):'2x（プレイ中に動作）';
    document.querySelectorAll('[data-framegen-status]').forEach(el=>el.textContent=label);
    document.querySelectorAll('[data-framegen-mode]').forEach(button=>button.setAttribute('aria-checked',String(button.dataset.framegenMode===mode)));
  }
  // Test-only: start from a confirmed display rate instead of measuring it.
  function testSeedRefresh(hz){
    refresh.deltas.length=0;for(let i=0;i<64;i++)refresh.deltas.push(1000/hz);
    refresh.period=snapPeriod(1000/hz);refresh.stable=16;refresh.slowRun=0;refresh.lastNow=NaN;
    gate.open=1000/refresh.period>=88;gate.openAt=gate.open?0:Infinity;refresh.openHz=gate.open?Math.round(1000/refresh.period):0;
  }
  document.querySelectorAll('[data-framegen-mode]').forEach(button=>button.addEventListener('click',()=>setMode(button.dataset.framegenMode)));
  syncUi(true);
  return {step,reset,direct,release:deferRelease,endCallback,sampleNormal,
    observe:observeIfNeeded,observeNow:observe,mark,staticObject,layer,
    isHud:id=>HUD_IDS.has(id),stateChanged,status,setMode,syncUi,
    get recording(){return !!recorder;},
    // Internal methods are retained for the in-memory test harness; the
    // shipping window API exposes status and normal user configuration only.
    capture,drawHud,testSeedRefresh,get previous(){return previous;},get current(){return current;}
  };
}
frameGeneration=makeFrameGeneration();
window.elementalFrameGeneration=Object.freeze({getStatus:()=>frameGeneration.status(),setMode:mode=>frameGeneration.setMode(mode)});
