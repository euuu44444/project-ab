// Golden vectors for the S3 simulation loop (topic "sim_scripts" -> godot/tests/golden/sim_scripts.json): scripted input
// sequences run through the ORIGINAL update() / runSystems() with the ORIGINAL system lists, from the state that the
// ORIGINAL newGame literal produces. The Godot side is tests/test_sim_movement.gd.
//
// Real (cut out of original.html by name, nothing retyped): update, runSystems, sys, FRAME_PHASE, UPDATE_INTRO_SYSTEMS,
// UPDATE_MAIN_SYSTEMS, UPDATE_KO_SYSTEMS, capturePreviousTransforms, inputVector, advanceFrameClock, updateDayCycle,
// tickPlayerReactionBuffs, updatePlayerMovement (with updatePlayerControlHazards, effectivePlayerMoveSpeedMul and its whole
// closure: archivistBank*, berserker*, abilityRank, pathfinderAddDistance, metaAbilityOnMove, activeMetaAbilities),
// followPlayerWithCamera, tickKnockOutMotion, decayScreenFlashes, isPlayerAlive, enterKnockOutIfDead, mikoActive, clamp, dist2.
//
// Stubbed, and nothing else: every other function that the three system lists call is defined as a no-op, plus two functions
// that touch the DOM or the result screen:
//   clearTransientInput  clears input.keys / moveX / moveY (the DOM part, ui.stick, is dropped)
//   endRun               sets game.ended, game.runWon and state = "ended" (scores, meta progress and the result screen are dropped)
// The no-op stubs are NOT no-ops in the real game for a running fight: updateWave, updateEnemies, updateWeapons, updateProjectiles,
// updateXp, cleanupDeadEnemies, rebuild*Index/Grid, updateParticles, openNextPendingChoice, applyPlayerRegen, updateHud, ... belong to
// steps S5/S6/S8. The scripts here contain no enemies and no weapon fire, and the recorded fields (clock, day phase, player
// position/velocity/acceleration/animation, camera, flashes, KO state) are not written by those functions in that situation; the
// exact list of stubbed names is part of the output (`stubbed_noop`) so that a reader sees what was not simulated.
import { encodeF64, hex64, makeRng } from './_codec.mjs';
import { evaluateNewGame, original, sandboxWith } from './_defs_vm.mjs';
import { cutNames, evaluateCuts } from '../lib/js_source.mjs';

export const name = 'sim_scripts';

const REAL_FUNCTIONS = [
  'update', 'runSystems', 'sys', 'capturePreviousTransforms', 'inputVector', 'advanceFrameClock', 'updateDayCycle',
  'tickPlayerReactionBuffs', 'updatePlayerMovement', 'updatePlayerControlHazards', 'effectivePlayerMoveSpeedMul',
  'archivistBankMoveSpeedMul', 'archivistBankStat', 'archivistBankPower', 'archivistBankPowerFor', 'archivistBankCount',
  'archivistBankOutputMul', 'archivistBankAmpMul', 'abilityRank', 'berserkerMoveSpeedMul', 'berserkerFrenzy', 'berserkerActive',
  'berserkerConvergeMoveMul', 'sanitizeBerserkerNumber', 'pathfinderAddDistance', 'pathfinderActive', 'metaAbilityOnMove',
  'activeMetaAbilities', 'followPlayerWithCamera', 'tickKnockOutMotion', 'decayScreenFlashes', 'isPlayerAlive',
  'enterKnockOutIfDead', 'mikoActive', 'clamp', 'dist2',
];
const REAL_DECLARATIONS = [
  'FRAME_PHASE', 'UPDATE_INTRO_SYSTEMS', 'UPDATE_MAIN_SYSTEMS', 'UPDATE_KO_SYSTEMS', 'MAP_W', 'MAP_H', 'WAVE_DURATION',
  'DAY_CYCLE_SECONDS', 'CHARACTER_ANIMATION_FPS', 'BERSERKER_CONFIG', 'BERSERKER_EPSILON', 'ARCHIVIST_BANK_CAPS',
  'ARCHIVIST_BANK_OUTPUT_SCALE', 'ARV_BANK', 'BSK_CONV', 'EMPTY_ABILITY_LIST',
];
const CUSTOM_STUBS = {
  clearTransientInput: 'function clearTransientInput(){input.keys.clear();input.moveX=0;input.moveY=0;}',
  endRun: 'function endRun(win){if(!game||game.ended)return;game.ended=true;game.runWon=!!win;state="ended";}',
};

/** Function names that the run/when closures of the three system lists call (the lists are evaluated without any function). */
export function listedFunctions() {
  const cuts = cutNames(original().text, ['sys', 'FRAME_PHASE', 'UPDATE_INTRO_SYSTEMS', 'UPDATE_MAIN_SYSTEMS', 'UPDATE_KO_SYSTEMS']);
  const sandbox = evaluateCuts(cuts, { expose: ['UPDATE_INTRO_SYSTEMS', 'UPDATE_MAIN_SYSTEMS', 'UPDATE_KO_SYSTEMS'], filename: 'system-lists.js' });
  const lists = {};
  const calledNames = new Set();
  for (const [key, list] of Object.entries(sandbox.__api)) {
    lists[key] = list.map((slot) => {
      const runSource = slot.run.toString();
      const m = /^(?:\(\)|dt)=>([A-Za-z0-9_$]+)\((?:dt|false)?\)$/.exec(runSource);
      if (!m) throw new Error(`unexpected run closure in ${slot.id}: ${runSource}`);
      calledNames.add(m[1]);
      let whenSource = null;
      if (slot.when !== null) {
        whenSource = slot.when.toString();
        for (const call of whenSource.matchAll(/([A-Za-z_$][\w$]*)\(/g)) calledNames.add(call[1]);
      }
      return { id: slot.id, phase: slot.phase, fn: m[1], when: whenSource };
    });
  }
  return { lists, calledNames };
}

function buildSandbox(characterGame) {
  const { lists, calledNames } = listedFunctions();
  const real = new Set(REAL_FUNCTIONS);
  const noop = [...calledNames].filter((n) => !real.has(n) && !CUSTOM_STUBS[n]).sort();
  const stubCode = noop.map((n) => `function ${n}(){}`).join('\n');
  const prelude = `var game=null,state="playing";
var input={keys:new Set(),moveX:0,moveY:0};
function __setInput(keys,mx,my){input.keys=new Set(keys);input.moveX=mx;input.moveY=my;}
${Object.values(CUSTOM_STUBS).join('\n')}
${stubCode}`;
  const sandbox = sandboxWith([...REAL_FUNCTIONS, ...REAL_DECLARATIONS], { prelude });
  sandbox.game = characterGame;
  return { sandbox, noop, lists };
}

// Recorded columns, in order. A property the game leaves undefined is recorded as 0 (the game reads those with `||0`).
const COLUMNS = [
  's:step', 's:state', 'f:t', 'f:dayPhase', 'f:hp', 'f:koTimer', 'b:ended', 'f:screenFlash', 'f:damageFlash',
  'f:x', 'f:y', 'f:prevX', 'f:prevY', 'f:vx', 'f:vy', 'f:ax', 'f:ay', 'f:walkPhase', 'f:lastFacing', 'f:attackAnim', 'f:controlSlow',
  'f:hazardDefenseBonus', 'f:prismResonance', 'f:voidEcho', 'f:camX', 'f:camY', 'f:camPrevX', 'f:camPrevY',
];

function record(sb, step) {
  const g = sb.game;
  const p = g.player;
  const n = (v) => (v === undefined ? 0 : v);
  return [
    String(step), sb.state, hex64(g.t), hex64(g.dayPhase), hex64(p.hp), hex64(p.koTimer), g.ended ? '1' : '0', hex64(n(g.screenFlash)), hex64(n(g.damageFlash)),
    hex64(p.x), hex64(p.y), hex64(n(p.prevX)), hex64(n(p.prevY)), hex64(n(p.vx)), hex64(n(p.vy)), hex64(n(p.ax)), hex64(n(p.ay)),
    hex64(p.walkPhase), hex64(p.lastFacing), hex64(p.attackAnim), hex64(p.controlSlow), hex64(p.hazardDefenseBonus),
    hex64(p.reactionBuffs.prismResonance), hex64(p.reactionBuffs.voidEcho),
    hex64(g.camera.x), hex64(g.camera.y), hex64(n(g.camera.prevX)), hex64(n(g.camera.prevY)),
  ].join(' ');
}

/** Sets "a.b.c" on the game; the values are plain numbers. */
function setPath(game, dotted, value) {
  const parts = dotted.split('.');
  let target = game;
  for (const part of parts.slice(0, -1)) target = target[part];
  target[parts[parts.length - 1]] = value;
}

const KEY_BITS = { KeyA: 1, ArrowLeft: 1, KeyD: 2, ArrowRight: 2, KeyW: 4, ArrowUp: 4, KeyS: 8, ArrowDown: 8 };

/** Expands the segments of a script into one input per step: { keys, mx, my, dt, sets: [[path, value]...] }. */
function expand(script) {
  const inputs = [];
  let step = 0;
  for (const segment of script.steps) {
    for (let i = 0; i < segment.n; i++) {
      const pick = (value, fallback) => (typeof value === 'function' ? value(step) : (value ?? fallback));
      inputs.push({
        keys: pick(segment.keys, []),
        mx: pick(segment.mx, 0),
        my: pick(segment.my, 0),
        dt: pick(segment.dt, 1 / 60),
        sets: i === 0 ? Object.entries(segment.set ?? {}) : [],
      });
      step++;
    }
  }
  return inputs;
}

function runScript(script) {
  const { game } = evaluateNewGame({ character: 'catalyst', mode: 'normal', difficulty: 'normal' });
  const { sandbox: sb, noop } = buildSandbox(game);
  const inputs = expand(script);
  const rows = [];
  const recordEvery = script.recordEvery ?? 1;
  const recordFirst = script.recordFirst ?? 0;
  inputs.forEach((input, index) => {
    for (const [key, value] of input.sets) setPath(sb.game, key, value);
    sb.__setInput(input.keys, input.mx, input.my);
    sb.capturePreviousTransforms();
    sb.update(input.dt);
    const step = index + 1;
    if (step <= recordFirst || step % recordEvery === 0 || step === inputs.length) rows.push(record(sb, step));
  });
  return { rows, noop, inputs };
}

function buildScripts() {
  const rng = makeRng(424242);
  const wasd = [['KeyD'], ['KeyW', 'KeyD'], ['KeyW'], ['KeyA', 'KeyW'], ['KeyA'], ['KeyS', 'KeyA'], ['KeyS'], ['KeyS', 'KeyD'], []];
  const still = { mx: 0.6, my: -0.8 };
  const scripts = [
    { name: 'idle', steps: [{ n: 240 }], recordEvery: 20, recordFirst: 3 },
    { name: 'stick_diag', steps: [{ n: 180, ...still }], recordFirst: 12, recordEvery: 12 },
    { name: 'keys_wasd', steps: wasd.map((keys) => ({ n: 30, keys })), recordEvery: 6, recordFirst: 4 },
    { name: 'stick_and_keys_mixed', steps: [{ n: 40, keys: ['ArrowRight'], mx: 0.5, my: 0.5 }, { n: 40, keys: ['KeyA', 'ArrowLeft'], mx: -1, my: 1 }, { n: 20 }],
      recordEvery: 5 },
    { name: 'stick_ramp', steps: [{ n: 300, mx: (s) => Math.sin(s * 0.05) * 1.2, my: (s) => Math.cos(s * 0.031) }], recordEvery: 10, recordFirst: 2 },
    { name: 'random_stick', steps: [{ n: 200, mx: () => rng() * 2 - 1, my: () => rng() * 2 - 1 }], recordEvery: 8, recordFirst: 2 },
    { name: 'edge_clamp_top_left', steps: [{ n: 90, keys: ['KeyA', 'KeyW'], set: { 'player.x': 40.5, 'player.y': 60.25 } }, { n: 30, keys: ['KeyD'] }],
      recordEvery: 4, recordFirst: 3 },
    { name: 'edge_clamp_bottom_right', steps: [{ n: 90, mx: 1, my: 1, set: { 'player.x': 25950.5, 'player.y': 25970.75 } }, { n: 30, keys: ['KeyA'] }],
      recordEvery: 4, recordFirst: 3 },
    { name: 'variable_dt', steps: [
      { n: 3, ...still, dt: 1 / 60 }, { n: 2, ...still, dt: 0.5 }, { n: 2, ...still, dt: NaN }, { n: 2, ...still, dt: Infinity },
      { n: 2, ...still, dt: -1 }, { n: 2, ...still, dt: 1 / 30 }, { n: 2, ...still, dt: 1e-9 }, { n: 2, ...still, dt: 0.01 },
      { n: 2, ...still, dt: 1 / 120 }, { n: 2, mx: -0.3, my: 0.2, dt: 0.0333333 }, { n: 5, dt: 1 / 60 },
    ] },
    { name: 'screen_flash_decay', steps: [{ n: 90, set: { screenFlash: 1, damageFlash: 0.8 } }], recordEvery: 10, recordFirst: 2 },
    { name: 'reaction_buffs_decay', steps: [{ n: 120, mx: 0.3, my: 0.3, set: { 'player.reactionBuffs.prismResonance': 1.5, 'player.reactionBuffs.voidEcho': 0.2 } }],
      recordEvery: 10, recordFirst: 2 },
    // The player dies (hp 0) while moving: enterKnockOutIfDead clears the input, the KO list plays the 0.96 s animation, then endRun.
    { name: 'knock_out', steps: [{ n: 40, keys: ['KeyD'], mx: 0.2, my: -0.5 }, { n: 100, keys: ['KeyD'], mx: 0.2, my: -0.5, set: { 'player.hp': 0 } }, { n: 20, keys: ['KeyD'] }],
      recordEvery: 4 },
    // koTimer already running when the update starts (the INTRO list runs, then the KO list)
    { name: 'knock_out_timer_preset', steps: [{ n: 70, keys: ['KeyS'], set: { 'player.koTimer': 0.5, 'player.hp': 0 } }], recordEvery: 5, recordFirst: 2 },
  ];
  const out = [];
  let noop = null;
  for (const script of scripts) {
    const result = runScript(script);
    noop = result.noop;
    const n = result.inputs.length;
    const triples = [];
    for (const input of result.inputs) triples.push(input.mx, input.my, input.dt);
    out.push({
      name: script.name,
      steps: n,
      // per step: stick x, stick y, dt as little-endian doubles (base64), the key mask (bit 0 left, 1 right, 2 up, 3 down; A/ArrowLeft count once)
      input_f64: encodeF64(triples),
      input_keys: Buffer.from(result.inputs.map((input) => input.keys.reduce((m, k) => m | KEY_BITS[k], 0))).toString('base64'),
      // assignments made on the game just before a step (1-based step number): [step, path, value bits]
      sets: result.inputs.flatMap((input, i) => input.sets.map(([path, value]) => [i + 1, path, hex64(value)])),
      rows: result.rows,
    });
  }
  return { scripts: out, noop };
}

export function generate(_extract) {
  const src = original();
  const { scripts, noop } = buildScripts();
  return {
    format: 1,
    generated_by: 'tools/golden/defs_sim_scripts.mjs',
    source: 'webview-fg4/tests/fixtures/original.html',
    source_sha256: src.sha256,
    real_functions: REAL_FUNCTIONS,
    real_declarations: REAL_DECLARATIONS,
    custom_stubs: Object.keys(CUSTOM_STUBS),
    stubbed_noop: noop,
    columns: COLUMNS,
    scripts,
  };
}

