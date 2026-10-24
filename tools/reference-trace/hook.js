// Test hook for the reference trace (design section 9.2). tools/reference-trace/capture.mjs inserts this file, as text, in front
// of the closing `})();` of the original game's script, in an in-memory copy of original.html that it serves over HTTP. The
// file on disk is never touched. Being inside the game's closure, the code sees the game's own functions and variables
// (update, game, input, gameRandomDraws, UPDATE_*_SYSTEMS, ...); nothing here runs until capture.mjs calls window.__trace.run().
//
// What run() does, all in one synchronous call (no timer, requestAnimationFrame or audio callback can interleave, which is
// what keeps the recording reproducible):
//   1. replaces Math.random by the game's own seeded generator makeSeededRandom(fxSeed). The only Math.random readers on the
//      simulation's path are fxRandom (particles) and audioRandom (sound variation); neither feeds gameRandom, so this only
//      makes the effects reproducible and the capture byte-for-byte repeatable;
//   2. setGameSeed(seed); selectedCharacter / selectedDifficulty / selectedGameMode; newGame(); suspendGameLoop(); in the
//      explicitly non-standard "long run" variant only (a.overrides, see capture.mjs --long-run) player.xpNext, hp and maxHp are
//      then set to huge values, so that no level-up is queued and the player does not die: the run can go on through the waves;
//   3. wraps the run function of every slot of UPDATE_INTRO_SYSTEMS, UPDATE_MAIN_SYSTEMS and UPDATE_KO_SYSTEMS so that the
//      draws of gameRandom (the counter gameRandomDraws, which setGameSeed's wrapper increments on every call) are credited
//      to the slot that makes them: "<list>:<index>" -> count, only non-zero counts are kept;
//   4. per step: applies the scripted input, capturePreviousTransforms(), update(FIXED_DT), and records the state AFTER the
//      step as one JSON line;
//   5. stops after the first step in which game.pendingLevelUps > 0 ("level_up"), state !== "playing" ("state:<state>"), the
//      wave a.untilWave has been reached ("wave:<n>", optional) or the step cap ("max_steps").
//
// What loop() does around update() and why this driver does not need it for M1 (catalyst, normal difficulty, standard mode, a
// fresh profile):
//   * per display frame, before stepping: sampleDisplayInterval, updateAbilityIntro (state "abilityIntro" only) and
//     revealDelayedLevelUpChoice (only when levelUpChoiceReadyAt > 0, which is set by the first level-up: the capture stops there);
//   * the time accounting (elapsed, simAccumulator, MAX_STEPS_PER_FRAME): it decides how many fixed steps a display frame
//     runs, never what a step does, and the driver steps exactly once per recorded line;
//   * per step: capturePreviousTransforms(); update(FIXED_DT);  <- the only two calls the driver needs, in this order;
//   * after the steps: render() and adaptiveSample(). They read the game and write render-only state (canvas, light map,
//     render pacing). The one path from them back to gameplay is adaptive.tier -> visualFxCount() -> the number of particles ->
//     the gate `game.particles.length >= damageLabelParticleLimit()` of showDamageNumber, which decides whether the three
//     gameRandom draws of a damage number happen. The tier is 0 (adaptiveReset in newGame, quality "auto" scale 1) with the
//     loop suspended; the gate needs 1100 particles (560 in eco quality). Every row records counts.particles, run() throws
//     if it ever reaches 560, and mode `emulateLoop` (render() + adaptiveSample() after every step) was used to check that
//     the recording does not change when they do run (see verification/godot/s4/capture.txt).
//   * document.hidden handling, scheduleGameLoop and wakeGameLoop only schedule frames.
// The wall clock is not read by the simulation (performance.now / Date.now feed render pacing, debug metrics and saves only).
// The viewport is: viewW x viewH decide the radius of the enemy spawn ring (createEnemyFieldSpawnPlan), so run() checks them.
window.__trace = (() => {
  const dv = new DataView(new ArrayBuffer(8));

  /** A JavaScript number as 16 lowercase hex digits of its big-endian IEEE-754 bit pattern. NaN is canonical (7ff8000000000000);
   *  undefined counts as 0 (a field the game has not written yet, such as prevX of an enemy spawned in this very step). */
  function hexOf(value, what) {
    if (value === undefined) value = 0;
    if (typeof value !== 'number') throw new Error(`reference trace: ${what} is ${typeof value}, a number is expected`);
    if (value !== value) return '7ff8000000000000';
    dv.setFloat64(0, value);
    return dv.getUint32(0).toString(16).padStart(8, '0') + dv.getUint32(4).toString(16).padStart(8, '0');
  }
  function intOf(value, what) {
    if (value === undefined) return 0;
    if (!Number.isInteger(value)) throw new Error(`reference trace: ${what} is ${value}, an integer is expected`);
    return value;
  }
  function stringOf(value) {
    return value === undefined || value === null ? '' : String(value);
  }
  function boolOf(value, what) {
    if (value === undefined) return false;
    if (typeof value !== 'boolean') throw new Error(`reference trace: ${what} is ${typeof value}, a boolean is expected`);
    return value;
  }

  // "undefined counts as 0 / '' / false" is meant for a field the game has not written yet at that moment (the prevX of an enemy
  // spawned in this very step). It would also turn a misspelt field name into a column of silent zeros, so every read is counted:
  // a field that was read at least once and never found defined is reported (stats.never_defined) and capture.mjs refuses the trace.
  let coverage = {};
  function resetCoverage() { coverage = {}; }
  function neverDefined() {
    return Object.entries(coverage).filter(([, c]) => c.defined === 0).map(([name, c]) => `${name} (read ${c.read}x)`).sort();
  }

  // The schema. Each group lists [field name, type, optional getter]; the type is f (float64, hex), i (integer), s (string), b (boolean).
  // The header of a trace carries these as "name:type"; tools/reference-trace/FORMAT.md documents the meaning of each field.
  // To record more, add a line here and capture again; readers take the field list from the header.
  const SCHEMA = {
    player: [
      ['x', 'f'], ['y', 'f'], ['vx', 'f'], ['vy', 'f'], ['ax', 'f'], ['ay', 'f'], ['prevX', 'f'], ['prevY', 'f'],
      ['hp', 'f'], ['maxHp', 'f'], ['xp', 'f'], ['level', 'i'], ['xpNext', 'f'], ['xpBaseNext', 'f'],
      ['lastFacing', 'f'], ['attackAnim', 'f'], ['attackAngle', 'f'], ['koTimer', 'f'], ['walkPhase', 'f'], ['controlSlow', 'f'],
      ['lastHit', 'f'],
    ],
    camera: [['x', 'f'], ['y', 'f'], ['prevX', 'f'], ['prevY', 'f']],
    wave: [
      ['t', 'f'], ['wave', 'i'], ['waveClock', 'f'], ['directorClock', 'f'], ['spawnBudget', 'f'], ['dayPhase', 'f'],
      ['pendingLevelUps', 'i'], ['nextEnemyId', 'i'], ['damageFlash', 'f'], ['screenFlash', 'f'], ['kills', 'i'],
      ['levelUpChoiceReadyAt', 'f'],
      // The enemy director (steps S5): what spawnDirectorEnemyBatch / prepareEnemyWaveTheme / refreshEnemyAiLevel keep between
      // ticks. The waveSpawnTheme fields are undefined (recorded as 0 / '' / false) while the theme is null (special waves, before
      // the first tick); objects and arrays are flattened to strings: theme counts "kind=n,kind=n" in insertion order, the other
      // lists comma separated.
      ['pendingDirectorEnemyKind', 's'], ['waveFeaturedChangeChance', 'f'], ['enemyAiTier', 'i'], ['enemyAiSkill', 'f'],
      ['enemiesVersion', 'i'],
      ['themeWave', 'i', (g) => (g.waveSpawnTheme ? g.waveSpawnTheme.wave : undefined)],
      ['themeBaseKind', 's', (g) => (g.waveSpawnTheme ? g.waveSpawnTheme.baseKind : undefined)],
      ['themeFeaturedKind', 's', (g) => (g.waveSpawnTheme ? g.waveSpawnTheme.featuredKind : undefined)],
      ['themeChanged', 'b', (g) => (g.waveSpawnTheme ? g.waveSpawnTheme.changed : undefined)],
      ['themeChangeChance', 'f', (g) => (g.waveSpawnTheme ? g.waveSpawnTheme.changeChance : undefined)],
      ['themeTotalSpawned', 'i', (g) => (g.waveSpawnTheme ? g.waveSpawnTheme.totalSpawned : undefined)],
      ['themeCounts', 's', (g) => (g.waveSpawnTheme ? Object.keys(g.waveSpawnTheme.counts).map((k) => `${k}=${g.waveSpawnTheme.counts[k]}`).join(',') : undefined)],
      ['themeRecentMixed', 's', (g) => (g.waveSpawnTheme ? g.waveSpawnTheme.recentMixed.join(',') : undefined)],
      ['featuredEnemyHistory', 's', (g) => (Array.isArray(g.featuredEnemyHistory) ? g.featuredEnemyHistory.join(',') : undefined)],
    ],
    // The nine floats from shootCd to dotNumberTimer (strafeDir is an integer) are the values spawnEnemy draws from gameRandom
    // (in the order shootCd, aiTimer, abilityCd, strafeDir, aiSeed, thinkCd, animPhase, tacticCd, dotNumberTimer) as they stand
    // after the step; r, speed, damage and spawnWave are the enemySpec / spawn values. They let step S5 check every spawn roll
    // and the order of the draws, not only the positions. flash, telegraph, attackAnim and tacticPulse are the timers that
    // updateEnemies / tickEnemyTimersAndStatus write every step (flash is also set by damage, which is S6).
    enemy: [
      ['id', 'i'], ['kind', 's'], ['x', 'f'], ['y', 'f'], ['vx', 'f'], ['vy', 'f'], ['hp', 'f'], ['maxHp', 'f'],
      ['prevX', 'f'], ['prevY', 'f'], ['r', 'f'], ['speed', 'f'], ['facing', 'f'], ['aiState', 's'],
      ['shootCd', 'f'], ['aiTimer', 'f'], ['abilityCd', 'f'], ['strafeDir', 'i'], ['aiSeed', 'f'], ['thinkCd', 'f'],
      ['animPhase', 'f'], ['tacticCd', 'f'], ['dotNumberTimer', 'f'],
      ['damage', 'f'], ['spawnWave', 'i'], ['flash', 'f'], ['telegraph', 'f'], ['attackAnim', 'f'], ['tacticPulse', 'f'],
    ],
    projectile: [
      ['x', 'f'], ['y', 'f'], ['vx', 'f'], ['vy', 'f'], ['life', 'f'], ['age', 'f'], ['r', 'f'], ['damage', 'f'],
      ['weapon', 's', (o) => o.weapon && o.weapon.id],
    ],
    xp_orb: [['x', 'f'], ['y', 'f'], ['value', 'f'], ['r', 'f']],
  };

  function compile(group) {
    const fields = SCHEMA[group];
    return (o) => {
      const out = new Array(fields.length);
      for (let i = 0; i < fields.length; i++) {
        const [name, type, getter] = fields[i];
        const v = getter ? getter(o) : o[name];
        const what = `${group}.${name}`;
        const seen = coverage[what] || (coverage[what] = { read: 0, defined: 0 });
        seen.read++;
        if (v !== undefined) seen.defined++;
        out[i] = type === 'f' ? hexOf(v, what) : type === 'i' ? intOf(v, what) : type === 'b' ? boolOf(v, what) : stringOf(v);
      }
      return out;
    };
  }
  const readers = {};
  for (const group of Object.keys(SCHEMA)) readers[group] = compile(group);
  const schemaForHeader = () => {
    const out = {};
    for (const [group, fields] of Object.entries(SCHEMA)) out[group] = fields.map(([name, type]) => `${name}:${type}`);
    return out;
  };

  // ---- input ---------------------------------------------------------------------------------------------------------------
  // The real handlers are applied, not their results: keyup is `input.keys.delete(e.code)`, keydown (for the eight movement
  // codes, while state === "playing") ends in `input.keys.add(e.code)`, and the touch stick goes through touchStart / touchMove /
  // touchEnd, which call beginMoveTouch / updateTouchStick / releaseMoveTouch. They are called directly with synthetic touch
  // objects instead of dispatching DOM events, because keydown / pointerdown also call audio.unlock(), which creates an
  // AudioContext whose state is asynchronous and would make audioRandom's call pattern timing dependent.
  const MOVEMENT_KEYS = new Set(['KeyW', 'KeyA', 'KeyS', 'KeyD', 'ArrowUp', 'ArrowLeft', 'ArrowDown', 'ArrowRight']);
  const TOUCH_ID = 1;
  // Where the touch begins: inside inMoveZone (clientX < viewW * 0.55 and clientY > viewH * 0.4), away from the edges so
  // that the full 42 px stick range stays on the screen.
  const TOUCH_ORIGIN = { x: 80, y: 600 };
  const touchAt = (x, y) => ({ identifier: TOUCH_ID, clientX: x, clientY: y, target: document.body });

  function validateScript(script) {
    if (!script || !Array.isArray(script.segments) || script.segments.length === 0) throw new Error('input script: "segments" must be a non-empty array');
    for (const [i, seg] of script.segments.entries()) {
      if (!Number.isInteger(seg.steps) || seg.steps < 1) throw new Error(`input script: segment ${i} needs an integer "steps" >= 1`);
      if (seg.stick !== undefined && !(Array.isArray(seg.stick) && seg.stick.length === 2 && seg.stick.every(Number.isFinite))) {
        throw new Error(`input script: segment ${i}: "stick" must be [dx, dy] in CSS pixels`);
      }
      for (const code of seg.keys || []) {
        if (!MOVEMENT_KEYS.has(code)) throw new Error(`input script: segment ${i}: "${code}" is not a movement key (${[...MOVEMENT_KEYS].join(', ')})`);
      }
      if (seg.move !== undefined && !(Array.isArray(seg.move) && seg.move.length === 2 && seg.move.every(Number.isFinite))) {
        throw new Error(`input script: segment ${i}: "move" must be [moveX, moveY]`);
      }
    }
  }
  function segmentAt(script, n) {
    const period = script.segments.reduce((sum, s) => sum + s.steps, 0);
    let k = n - 1;
    if (k >= period) {
      if (!script.repeat) return null;
      k %= period;
    }
    for (const seg of script.segments) {
      if (k < seg.steps) return seg;
      k -= seg.steps;
    }
    return null;
  }
  /** Brings `input` to what segment `seg` asks for (null: nothing held), by the transitions the real handlers make. */
  function applyInput(seg) {
    const wantKeys = new Set(seg && seg.keys ? seg.keys : []);
    for (const code of [...input.keys]) if (!wantKeys.has(code)) input.keys.delete(code);
    if (state === 'playing') for (const code of wantKeys) input.keys.add(code);

    const stick = seg && seg.stick ? seg.stick : null;
    if (stick) {
      const pos = touchAt(TOUCH_ORIGIN.x + stick[0], TOUCH_ORIGIN.y + stick[1]);
      if (input.touchId === null) {
        touchStart({ changedTouches: [touchAt(TOUCH_ORIGIN.x, TOUCH_ORIGIN.y)], cancelable: false });
        if (input.touchId !== TOUCH_ID) throw new Error('input: the game did not take the touch (inMoveZone / state)');
      }
      touchMove({ changedTouches: [pos], cancelable: false });
    } else if (input.touchId !== null) {
      touchEnd({ changedTouches: [touchAt(0, 0)], touches: [] });
      if (input.touchId !== null || input.moveX !== 0 || input.moveY !== 0) throw new Error('input: the touch was not released');
    }
    // "move" sets the stick values directly (bypassing the handlers). It exists for cross-checks against older tools that
    // drove input.moveX / moveY with literals; the committed scripts use "stick".
    if (seg && seg.move) { input.moveX = seg.move[0]; input.moveY = seg.move[1]; }
  }

  // ---- the run ---------------------------------------------------------------------------------------------------------
  function checkEnvironment() {
    const problems = [];
    if (IS_COARSE_POINTER !== true) problems.push('IS_COARSE_POINTER is not true');
    if (viewW !== 390 || viewH !== 844) problems.push(`viewW x viewH is ${viewW} x ${viewH}, not 390 x 844`);
    if (DEBUG_ENABLED) problems.push('DEBUG_ENABLED (location.hash contains "debug")');
    if (visualSettings.quality === 'eco') problems.push('visual quality is "eco" (smaller particle limits)');
    // A fresh profile is not an empty localStorage: the game's own boot writes its save-delta record of this tab (the name
    // carries a random id) and migrates the meta progress to its defaults. Anything else (visual settings, last difficulty,
    // unlocks, onboarding, a best score ...) would mean that an earlier session left data behind.
    const bootKeys = (key) => key === 'elementalSwarmMetaProgressV2' || key.startsWith('__elementalSwarmSaveDeltaV1:');
    const foreign = [];
    for (let i = 0; i < localStorage.length; i++) if (!bootKeys(localStorage.key(i))) foreign.push(localStorage.key(i));
    if (foreign.length) problems.push(`localStorage holds data that the game's boot does not write (${foreign.join(', ')}): not a fresh profile`);
    if (problems.length) throw new Error(`reference trace environment: ${problems.join('; ')}`);
    return {
      is_coarse_pointer: IS_COARSE_POINTER, view_w: viewW, view_h: viewH, device_pixel_ratio: devicePixelRatio,
      quality: visualSettings.quality, max_projectiles: MAX_PROJECTILES, max_xp_orbs: MAX_XP_ORBS,
      max_enemy_projectiles: MAX_ENEMY_PROJECTILES, base_max_enemies: BASE_MAX_ENEMIES, max_hazards: MAX_HAZARDS,
    };
  }

  const ALLOWED_OVERRIDES = new Set(['player.xpNext', 'player.hp', 'player.maxHp']);
  const LISTS = [['intro', () => UPDATE_INTRO_SYSTEMS], ['main', () => UPDATE_MAIN_SYSTEMS], ['ko', () => UPDATE_KO_SYSTEMS]];

  return {
    schema: schemaForHeader,
    /**
     * a = { seed, fxSeed, character, difficulty, mode, script, maxSteps, emulateLoop, overrides ({ "player.xpNext": n, ... } | {}),
     *       untilWave (integer | null) }
     * Returns { env, slots, newGameDraws, fixedDt, body: the JSON lines of all steps joined by "\n", stop: { reason, step }, stats }.
     */
    run(a) {
      validateScript(a.script);
      suspendGameLoop();
      resetCoverage();
      const env = checkEnvironment();

      Math.random = makeSeededRandom(a.fxSeed);
      setGameSeed(a.seed);
      selectedCharacter = a.character;
      selectedDifficulty = a.difficulty;
      selectedGameMode = a.mode;
      if (newGame() === false) throw new Error('newGame() refused to start the run');
      suspendGameLoop(); // newGame() wakes the loop (requestAnimationFrame); the driver steps by itself
      if (state !== 'playing' || !game) throw new Error(`newGame() left state "${state}"`);
      if (game.mode !== a.mode || game.difficulty !== a.difficulty || game.char.id !== a.character) {
        throw new Error(`newGame() made mode ${game.mode} / difficulty ${game.difficulty} / character ${game.char.id}`);
      }
      env.adaptive_tier = adaptiveTier();
      env.tutorial_active = !!tutorialState.active;
      const newGameDraws = gameRandomDraws;
      // The deliberate deviations from the game, only when asked for (capture.mjs --long-run), applied right after newGame():
      // a.overrides maps "player.<name>" to a number. A level-up needs the player to choose an upgrade, which the driver does
      // not do, so the standard traces end at the first one (13-38 s into the run) and the player, with the starting weapon only,
      // dies about 55-65 s in. With player.xpNext huge gainXp's loop `while (p.xp >= p.xpNext)` never runs, and with player.hp /
      // maxHp huge the knock-out never comes: the run goes on through waves 3 and 4 (assassins, the theme draws of the director).
      // The header carries the overrides ("overrides": name -> hex) and the port applies the same values after its newGame.
      const overrides = {};
      for (const [key, value] of Object.entries(a.overrides || {})) {
        if (!ALLOWED_OVERRIDES.has(key)) throw new Error(`override ${key} is not one of ${[...ALLOWED_OVERRIDES].join(', ')}`);
        if (!(value > 1e6)) throw new Error(`override ${key} must be a number above 1e6, got ${value}`);
        game.player[key.slice('player.'.length)] = value;
        overrides[key] = hexOf(value, key);
      }
      env.overrides = overrides;

      // Credit every draw to the slot that makes it.
      const slotIds = {}; const originals = []; let current = null;
      for (const [name, getList] of LISTS) {
        const list = getList();
        slotIds[name] = list.map((s) => s.id);
        list.forEach((s, i) => {
          const original = s.run; const key = `${name}:${i}`;
          const wrapper = (dt) => {
            const before = gameRandomDraws;
            try { return original(dt); } finally {
              const drawn = gameRandomDraws - before;
              if (drawn) current[key] = (current[key] || 0) + drawn;
            }
          };
          s.run = wrapper;
          if (s.run !== wrapper) throw new Error(`could not wrap ${key}`);
          originals.push([s, original]);
        });
      }

      const lines = []; const stats = { max_particles: 0, max_enemies: 0, draws_outside_slots: 0 };
      let stop = null; let renderMs = 0;
      try {
        for (let n = 1; stop === null; n++) {
          applyInput(segmentAt(a.script, n));
          const inputRow = { moveX: hexOf(input.moveX, 'input.moveX'), moveY: hexOf(input.moveY, 'input.moveY'), keys: [...input.keys].sort() };
          current = {};
          const before = gameRandomDraws;
          capturePreviousTransforms();
          update(FIXED_DT);
          if (a.emulateLoop) { // what loop() does after its steps (render and the adaptive quality sample)
            const t0 = performance.now();
            render();
            adaptiveSample(performance.now() - t0, t0, true);
            renderMs += performance.now() - t0;
          }
          const total = gameRandomDraws - before;
          let inSlots = 0; for (const key of Object.keys(current)) inSlots += current[key];
          const outside = total - inSlots;
          stats.draws_outside_slots += outside;
          const counts = {
            enemies: game.enemies.length, projectiles: game.projectiles.length, xp_orbs: game.xpOrbs.length,
            particles: game.particles.length, enemy_projectiles: game.enemyProjectiles.length, hazards: game.hazards.length,
          };
          if (counts.particles > stats.max_particles) stats.max_particles = counts.particles;
          if (counts.enemies > stats.max_enemies) stats.max_enemies = counts.enemies;
          if (counts.particles >= 560) throw new Error(`step ${n}: ${counts.particles} particles reach the damage-number gate (eco limit 560, normal 1100): the draws would depend on effects`);
          lines.push(JSON.stringify({
            n, input: inputRow, state, draws: gameRandomDraws, slot_draws: current, outside_draws: outside,
            player: readers.player(game.player), camera: readers.camera(game.camera), wave: readers.wave(game), counts,
            enemies: game.enemies.map(readers.enemy), projectiles: game.projectiles.map(readers.projectile), xp_orbs: game.xpOrbs.map(readers.xp_orb),
          }));
          if (game.pendingLevelUps > 0) stop = { reason: 'level_up', step: n };
          else if (state !== 'playing') stop = { reason: `state:${state}`, step: n };
          else if (a.untilWave && game.wave >= a.untilWave) stop = { reason: `wave:${game.wave}`, step: n };
          else if (n >= a.maxSteps) stop = { reason: 'max_steps', step: n };
        }
      } finally {
        for (const [s, original] of originals) s.run = original;
        suspendGameLoop();
      }
      if (a.emulateLoop) stats.render_ms = Math.round(renderMs);
      stats.never_defined = neverDefined();
      return { env, slots: slotIds, newGameDraws, fixedDt: hexOf(FIXED_DT, 'FIXED_DT'), body: lines.join('\n'), stop, stats, userAgent: navigator.userAgent };
    },
  };
})();
