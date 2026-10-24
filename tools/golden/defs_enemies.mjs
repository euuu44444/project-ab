// Golden vectors for the S5 enemy code (topic "enemies" -> godot/tests/golden/enemies.json). Every expected value is produced by running
// the ORIGINAL functions, cut out of original.html by name, in a node:vm context with an empty sandbox (tools/lib/js_source.mjs);
// nothing is typed by hand. The Godot side is tests/test_enemy_golden.gd.
//
// What is real, per section (the same statement sits in `provenance` of the output):
//   plans, points, safe_points, spawn_enemy, picks, waves   the enemy director: updateWave, advanceWave, onWaveStart, awardWaveScore,
//       refreshEnemyAiLevel, spawnDirectorEnemyBatch, createEnemyFieldSpawnPlan, enemyFieldSpawnPoint, safePointAround,
//       safeEnemySpawnPoint, solidSpawnClearance, spawnEnemy, enemySpec, pickWaveDirectedEnemyKind, pickBalancedMixedEnemyKind,
//       unlockedNormalEnemyKinds, enemyCount, registerDirectorEnemySpawn, currentEnemyWaveTheme, prepareEnemyWaveTheme (with its
//       whole closure), on the `game` that the original newGame literal builds (tools/golden/_defs_vm.mjs evaluateNewGame, seeded:
//       setGameSeed + makeSeededRandom, so every gameRandom draw is the game's own).
//       Stubbed (no-ops): metaOnWaveStart, resolveTimedContractAtWaveEnd, applyEndlessWaveClearScaling, maybeSpawnTimedContractTarget,
//       unlock (a persistent profile), assignSpecialAbilities, attachEnemyToNightmareSquad, audio.wave; showMessage keeps only
//       `game.messageUntil = game.t + seconds`.
//   cleanup    cleanupDeadEnemies, killEnemy, spawnXp, pushXpOrb, enemyXpDropMultiplier, awardEnemyScore, rawEnemyScore, abilitiesActive.
//       Stubbed (their M1 effect is nothing; each one is named here): archivistReleaseRecordForDeath, findGroveAt (null), spreadSuperconductOnDeath,
//       spreadDeepErosionOnDeath, berserkerOnKill, mikoActive, abilityOnKill, spawnBossDefeatFx / spawnEliteDefeatFx, audio.kill, burst
//       (particles, effects generator only), detachEnemyFromSquad, spawnLootDrop.
//   grid       rebuildEnemySeparationGrid (both of its paths), enemySeparationGridKey, queryEnemiesAabb, queryEnemiesCircleBroad, nearestEnemy.
//
// Math.sin / Math.cos inside the context are replaced by tools/golden/_glibc_sin.mjs (the sin/cos of Chromium's V8; Node 22's differ
// in the last bit for about 3% of the inputs); atan2, hypot and exp of Node 22 give Chromium's bits (tools/verify_golden_chromium.mjs).
import vm from 'node:vm';
import { encodeF64, encodeI32, hex64, makeRng } from './_codec.mjs';
import { evaluateNewGame, original, row } from './_defs_vm.mjs';
import { cutNames } from '../lib/js_source.mjs';
import { glibcCos, glibcSin } from './_glibc_sin.mjs';

export const name = 'enemies';

export const DT = 1 / 60;

// ---------------------------------------------------------------------------------------------------
// The sandbox of the director
// ---------------------------------------------------------------------------------------------------
const DIRECTOR_NAMES = [
  'updateWave', 'advanceWave', 'onWaveStart', 'awardWaveScore', 'refreshEnemyAiLevel', 'enemyAiSkill', 'enemyAiTier',
  'spawnDirectorEnemyBatch', 'createEnemyFieldSpawnPlan', 'enemyFieldSpawnPoint', 'safePointAround', 'safeEnemySpawnPoint',
  'solidSpawnClearance', 'spawnEnemy', 'enemySpec', 'pickWaveDirectedEnemyKind', 'pickBalancedMixedEnemyKind',
  'unlockedNormalEnemyKinds', 'enemyCount', 'registerDirectorEnemySpawn', 'currentEnemyWaveTheme', 'currentDifficulty',
  'currentDifficultyKey', 'isDifficulty', 'highDifficultySpawnConfig', 'contractSpawnRateMul', 'effectiveWaveDuration', 'chance',
  'dist2', 'HIGH_DIFFICULTY_SPAWN_CONFIG', 'HIGH_DIFFICULTY_FIELD_SPAWN_PATTERNS', 'ENEMY_FIELD_SPAWN_PATTERNS',
  'DIRECTOR_BUDGET_CAP', 'BASE_MAX_ENEMIES', 'SCORE_RULES', 'ENDLESS_ENEMY_STAT_CAP', 'ENDLESS_ENEMY_SPEED_CAP',
  'ENDLESS_ACTION_COOLDOWN_MIN', 'ENDLESS_ARMOR_PER_50_WAVES', 'ENDLESS_EVASION_PER_50_WAVES', 'ENEMY_ARMOR_MAX',
  'ENDLESS_SPAWN_PACE_CAP', 'WORLD_TREE_THREAT_RATE_MULTIPLIER', 'MAX_WAVE', 'UNLOCK_STEPS', 'isUnlocked',
];
const DIRECTOR_STUBS = `
function metaOnWaveStart(){} function resolveTimedContractAtWaveEnd(){} function applyEndlessWaveClearScaling(){}
function maybeSpawnTimedContractTarget(){} function unlock(){} function assignSpecialAbilities(){} function attachEnemyToNightmareSquad(){}
function showMessage(text,seconds=1.5){if(game)game.messageUntil=game.t+seconds;}
var audio={wave(){}};
var viewW=390,viewH=844,selectedDifficulty="normal";`;

/** Runs `code` in the context of `sandbox` (a contextified object from evaluateCuts). */
function inContext(sandbox, code, filename) {
  vm.runInContext(code, sandbox, { filename, timeout: 20000 });
}

function installMath(sandbox) {
  sandbox.__sin = glibcSin;
  sandbox.__cos = glibcCos;
  inContext(sandbox, 'Math.sin=__sin;Math.cos=__cos;', 'math-patch.js');
}

let directorCode = null;
/** The text of the director's functions that evaluateNewGame's context does not have yet (cut once: every cut scans the 2 MB source). */
function directorCuts(sandbox) {
  if (directorCode === null) {
    const missing = DIRECTOR_NAMES.filter((n) => !(n in sandbox));
    const cuts = cutNames(original().text, missing);
    directorCode = `${DIRECTOR_STUBS}\n${cuts.sort((a, b) => a.start - b.start).map((c) => c.text).join(';\n')};`;
  }
  return directorCode;
}

/** A seeded game of the original newGame (catalyst, normal, standard) with the director's functions added to its context. */
export function directorGame(seed) {
  const { sandbox, game } = evaluateNewGame({ character: 'catalyst', mode: 'normal', difficulty: 'normal', seed });
  installMath(sandbox);
  inContext(sandbox, directorCuts(sandbox), 'director-cuts.js');
  return { sandbox, game };
}

const f = (x) => hex64(x);
const names = (list) => (list.length ? list.join(',') : '-');

// ---------------------------------------------------------------------------------------------------
// plans: createEnemyFieldSpawnPlan
// ---------------------------------------------------------------------------------------------------
const PLAYERS = [
  { name: 'center_still', x: 13000, y: 13000, vx: 0, vy: 0 },
  { name: 'center_slow', x: 13000.5, y: 12999.25, vx: 10, vy: -12 },
  { name: 'center_fast', x: 12345.678, y: 14321.987, vx: 150.25, vy: -90.5 },
  { name: 'center_fast_neg_zero', x: 13000, y: 13000, vx: -0, vy: 100 },
  { name: 'corner_nw', x: 40, y: 50, vx: -120, vy: -120 },
  { name: 'corner_se', x: 25990, y: 25980, vx: 0, vy: 0 },
  { name: 'edge_west', x: 30, y: 13000, vx: 0, vy: 0 },
  { name: 'edge_north_moving', x: 9000, y: 28, vx: 100, vy: 0 },
];

function setPlayer(game, p) {
  game.player.x = p.x; game.player.y = p.y; game.player.vx = p.vx; game.player.vy = p.vy;
}

function buildPlans() {
  const rows = [];
  for (const seed of [11, 424242]) {
    for (const wave of [1, 2, 3, 4, 6, 7, 8]) {
      for (const p of PLAYERS) {
        for (let repeat = 0; repeat < 2; repeat++) {
          const { sandbox, game } = directorGame(seed);
          game.wave = wave;
          setPlayer(game, p);
          sandbox.setGameSeed(seed + repeat);
          const plan = sandbox.createEnemyFieldSpawnPlan({ batchSize: 4 });
          rows.push(row(['i', seed + repeat], ['i', wave], ['s', p.name], ['i', sandbox.gameRandomDraws], ['s', plan.pattern], ['f', plan.baseAngle], ['f', plan.radius],
            ['f', plan.cx], ['f', plan.cy], ['f', plan.minRadius], ['f', plan.maxRadius], ['f', plan.minDistance], ['i', plan.batchSize]));
        }
      }
    }
  }
  return rows;
}

// ---------------------------------------------------------------------------------------------------
// points: enemyFieldSpawnPoint for the four formations of waves 1-6
// ---------------------------------------------------------------------------------------------------
const FORMATIONS = ['scatter', 'arc', 'pincer', 'line'];

function buildPoints() {
  const rows = [];
  for (const seed of [5, 99]) {
    for (const p of PLAYERS) {
      for (const pattern of FORMATIONS) {
        const { sandbox, game } = directorGame(seed);
        game.wave = 3;
        setPlayer(game, p);
        sandbox.setGameSeed(seed);
        const plan = sandbox.createEnemyFieldSpawnPlan({ batchSize: 4 });
        plan.pattern = pattern; // the formation is forced; the plan's other values (and its draws) are the game's
        const planDraws = sandbox.gameRandomDraws;
        for (let index = 0; index < 4; index++) {
          const before = sandbox.gameRandomDraws;
          const pt = sandbox.enemyFieldSpawnPoint(plan, index, 28, 24);
          rows.push(row(['i', seed], ['s', p.name], ['s', pattern], ['i', index], ['i', planDraws], ['i', before], ['i', sandbox.gameRandomDraws],
            ['f', pt.x], ['f', pt.y], ['f', pt.distance]));
        }
      }
    }
  }
  return rows;
}

// ---------------------------------------------------------------------------------------------------
// safe_points: safePointAround and safeEnemySpawnPoint, including the fallbacks that no reference trace reaches
// ---------------------------------------------------------------------------------------------------
function buildSafePoints() {
  const cases = [];
  // safePointAround(cx, cy, minRadius, maxRadius, pad, minDistance, attempts)
  const around = [
    { cx: 13000, cy: 13000, minR: 613.28, maxR: 803.28, pad: 28, minD: 441.5616, attempts: 16 },
    { cx: 60, cy: 60, minR: 613.28, maxR: 803.28, pad: 28, minD: 441.5616, attempts: 16 },
    { cx: 60, cy: 60, minR: 613.28, maxR: 803.28, pad: 28, minD: 700, attempts: 8 }, // most attempts fall short
    { cx: 13000, cy: 13000, minR: 100, maxR: 200, pad: 28, minD: 5000, attempts: 16 }, // no attempt can reach: the fallback ring
    { cx: 100, cy: 25900, minR: 100, maxR: 200, pad: 28, minD: 5000, attempts: 5 },
    { cx: 25999, cy: 13000, minR: 613.28, maxR: 803.28, pad: 28, minD: 441.5616, attempts: 8 },
    { cx: 13000, cy: 13000, minR: -50, maxR: -10, pad: 28, minD: -3, attempts: 4 }, // negative radii are clamped to 0
    { cx: 13000, cy: 13000, minR: 300, maxR: 100, pad: 28, minD: 0, attempts: 3 }, // maxRadius below minRadius
    { cx: -50, cy: 30000, minR: 10, maxR: 20, pad: 28, minD: 10, attempts: 2 }, // the centre itself is off the map
  ];
  const rows = [];
  for (const seed of [3, 4]) {
    for (const [i, c] of around.entries()) {
      const { sandbox } = directorGame(seed);
      sandbox.setGameSeed(seed * 100 + i);
      const r = sandbox.safePointAround(c.cx, c.cy, c.minR, c.maxR, c.pad, c.minD, c.attempts);
      rows.push(row(['s', 'around'], ['i', seed * 100 + i], ['i', i], ['i', sandbox.gameRandomDraws], ['f', r.x], ['f', r.y], ['f', r.distance]));
      cases.push(c);
    }
  }
  // safeEnemySpawnPoint(p, minRadius, maxRadius, pad, minDistance, bodyRadius)
  const enemy = [
    { px: 13000, py: 13000, minR: 613.28, maxR: 803.28, pad: 28, minD: 441.5616, body: 24 },
    { px: 40, py: 50, minR: 613.28, maxR: 803.28, pad: 28, minD: 441.5616, body: 24 },
    { px: 13000, py: 13000, minR: 100, maxR: 200, pad: 28, minD: 5000, body: 24 }, // nothing is far enough: the walk over radii and angles finds nothing, then safePointAround
    { px: 13000, py: 13000, minR: 100, maxR: 400, pad: 28, minD: 380, body: 24 }, // few attempts succeed
    { px: 25990, py: 25980, minR: 613.28, maxR: 803.28, pad: 28, minD: 441.5616, body: 28 },
    { px: 13000, py: 40, minR: 613.28, maxR: 803.28, pad: 28, minD: 3000, body: 24 },
  ];
  for (const seed of [3, 4]) {
    for (const [i, c] of enemy.entries()) {
      const { sandbox } = directorGame(seed);
      sandbox.setGameSeed(seed * 100 + i);
      const r = sandbox.safeEnemySpawnPoint({ x: c.px, y: c.py }, c.minR, c.maxR, c.pad, c.minD, c.body);
      rows.push(row(['s', 'enemy'], ['i', seed * 100 + i], ['i', i], ['i', sandbox.gameRandomDraws], ['f', r.x], ['f', r.y], ['f', r.distance]));
      cases.push(c);
    }
  }
  return {
    columns: ['kind:s(around|enemy)', 'seed:i', 'case:i', 'draws:i', 'x:f', 'y:f', 'distance:f'],
    around: around.map((c) => ({ cx: f(c.cx), cy: f(c.cy), minR: f(c.minR), maxR: f(c.maxR), pad: f(c.pad), minD: f(c.minD), attempts: c.attempts })),
    enemy: enemy.map((c) => ({ px: f(c.px), py: f(c.py), minR: f(c.minR), maxR: f(c.maxR), pad: f(c.pad), minD: f(c.minD), body: f(c.body) })),
    rows,
  };
}

// ---------------------------------------------------------------------------------------------------
// spawn_enemy: the enemy object that spawnEnemy builds
// ---------------------------------------------------------------------------------------------------
const ENEMY_NUMBERS = ['x', 'y', 'vx', 'vy', 'r', 'hp', 'speed', 'damage', 'xp', 'armor', 'evasion', 'projectileSpeedMul', 'actionCooldownMul',
  'abilityCooldownMul', 'baseMaxHp', 'maxHp', 'maxShield', 'shootCd', 'aiTimer', 'abilityCd', 'aiSeed', 'thinkCd', 'facing', 'animPhase', 'tacticCd',
  'dotNumberTimer'];
/** Numbers that spawnEnemy sets to the same value for every enemy of the M1 kinds; the generator checks that, and the file lists them once. */
const ENEMY_CONSTANTS = ['flash', 'telegraph', 'attackAnim', 'attackAnimMax', 'fuse', 'dashX', 'dashY', 'tacticPulse', 'dotNumberFire', 'dotNumberPoison',
  'lastDamagedAt', 'seedGrowthMult'];
const constantsSeen = new Map();
/** The own keys of the enemy objects, in the game's order (all spawned swarms and assassins have the same list), and those of status / specialState. */
const keySets = { enemy: null, status: null, specialState: null };
function checkKeys(e) {
  const sets = { enemy: Object.keys(e).join(','), status: Object.keys(e.status).join(','), specialState: Object.keys(e.specialState).join(',') };
  for (const [k, v] of Object.entries(sets)) {
    if (keySets[k] === null) keySets[k] = v;
    else if (keySets[k] !== v) throw new Error(`the own keys of enemy ${k} differ between enemies: ${keySets[k]} vs ${v}`);
  }
}
function checkConstants(e) {
  checkKeys(e);
  for (const k of ENEMY_CONSTANTS) {
    const bits = hex64(e[k] === undefined ? NaN : e[k]);
    if (!constantsSeen.has(k)) constantsSeen.set(k, bits);
    else if (constantsSeen.get(k) !== bits) throw new Error(`enemy.${k} is not constant (${constantsSeen.get(k)} vs ${bits})`);
  }
}

function enemyRow(e) {
  checkConstants(e);
  return [
    ['i', e.id], ['s', e.kind], ['i', e.spawnWave], ['i', e.strafeDir], ['s', e.aiState], ['i', Object.keys(e).length],
    ...ENEMY_NUMBERS.map((k) => ['f', e[k] === undefined ? NaN : e[k]]),
  ];
}

function buildSpawnEnemy() {
  const rows = [];
  for (const seed of [21]) {
    for (const wave of [1, 2, 3, 4]) {
      for (const kind of ['swarm', 'assassin']) {
        for (const p of [PLAYERS[0], PLAYERS[2], PLAYERS[4]]) {
          const { sandbox, game } = directorGame(seed);
          game.wave = wave;
          setPlayer(game, p);
          sandbox.setGameSeed(seed);
          const plan = sandbox.createEnemyFieldSpawnPlan({ batchSize: 4 });
          const planDraws = sandbox.gameRandomDraws;
          const spawnedAt = [];
          for (let i = 0; i < 4; i++) {
            const before = sandbox.gameRandomDraws;
            const ok = sandbox.spawnEnemy(kind, { spawnPlan: plan, spawnIndex: i });
            if (!ok) throw new Error('spawnEnemy refused');
            const e = game.enemies[game.enemies.length - 1];
            spawnedAt.push(row(['i', seed], ['i', wave], ['s', p.name], ['s', plan.pattern], ['i', i], ['i', planDraws], ['i', before], ['i', sandbox.gameRandomDraws],
              ['i', game.nextEnemyId], ['i', game.enemiesVersion || 0], ...enemyRow(e)));
          }
          rows.push(...spawnedAt);
        }
      }
    }
  }
  return {
    columns: ['seed:i', 'wave:i', 'player:s', 'pattern:s', 'index:i', 'plan_draws:i', 'draws_before:i', 'draws_after:i', 'next_enemy_id:i', 'enemies_version:i',
      'id:i', 'kind:s', 'spawn_wave:i', 'strafe_dir:i', 'ai_state:s', 'own_key_count:i', ...ENEMY_NUMBERS.map((k) => `${k}:f`)],
    rows,
  };
}

// ---------------------------------------------------------------------------------------------------
// picks: the kind picks of the director, with the real counts of the list
// ---------------------------------------------------------------------------------------------------
function buildPicks() {
  const scenarios = [];
  const configs = [
    { name: 'wave1_swarm_only', seed: 1, wave: 1, assassins: 0, swarms: 0 },
    { name: 'wave3_theme', seed: 424242, wave: 3, assassins: 0, swarms: 0 },
    { name: 'wave3_theme_seed2', seed: 24681357, wave: 3, assassins: 0, swarms: 0 },
    { name: 'wave4_theme', seed: 7, wave: 4, assassins: 0, swarms: 0 },
    { name: 'wave3_assassin_cap', seed: 8, wave: 3, assassins: 15, swarms: 3 },
    { name: 'wave3_assassin_at_cap', seed: 9, wave: 3, assassins: 16, swarms: 3 },
  ];
  for (const c of configs) {
    const { sandbox, game } = directorGame(c.seed);
    game.wave = c.wave;
    sandbox.prepareEnemyWaveTheme(c.wave);
    // a theme whose featured kind is the assassin (when the seed's roll did not make it so): the other branch of the share rule
    if (c.name.endsWith('_cap')) {
      game.waveSpawnTheme.featuredKind = 'assassin';
      game.waveSpawnTheme.baseKind = 'assassin';
    }
    for (let i = 0; i < c.assassins; i++) game.enemies.push({ kind: 'assassin', id: 1000 + i });
    for (let i = 0; i < c.swarms; i++) game.enemies.push({ kind: 'swarm', id: 2000 + i });
    const picks = [];
    const themeAtStart = game.waveSpawnTheme;
    const drawsAtStart = sandbox.gameRandomDraws;
    for (let i = 0; i < 40; i++) {
      const before = sandbox.gameRandomDraws;
      const kind = sandbox.pickWaveDirectedEnemyKind();
      const picked = kind === null ? '-' : kind;
      picks.push(row(['i', before], ['i', sandbox.gameRandomDraws], ['s', picked]));
      if (kind) {
        game.enemies.push({ kind, id: 3000 + i });
        sandbox.registerDirectorEnemySpawn(kind);
      }
    }
    scenarios.push({
      name: c.name, seed: c.seed, wave: c.wave, assassins: c.assassins, swarms: c.swarms,
      theme_featured: themeAtStart.featuredKind, draws_at_start: drawsAtStart,
      picks,
      final_theme_counts: names(Object.entries(game.waveSpawnTheme.counts).map(([k, v]) => `${k}=${v}`)),
      final_total_spawned: game.waveSpawnTheme.totalSpawned,
      final_recent_mixed: names(game.waveSpawnTheme.recentMixed),
    });
  }
  return { columns: ['draws_before:i', 'draws_after:i', 'kind:s'], scenarios };
}

// ---------------------------------------------------------------------------------------------------
// waves: updateWave stepped, with the real director, wave advance and theme
// ---------------------------------------------------------------------------------------------------
const WAVE_SCENARIOS = [
  { name: 'w1_walk_circle', seed: 424242, steps: 600, wave: 1, player: 'circle' },
  { name: 'w1_idle', seed: 24681357, steps: 400, wave: 1, player: 'idle' },
  { name: 'w3_assassins', seed: 424242, steps: 500, wave: 3, budget: 6, player: 'circle' },
  { name: 'w3_assassin_theme', seed: 99, steps: 500, wave: 3, budget: 6, theme: 'assassin', player: 'zigzag' },
  { name: 'w2_to_w4', seed: 5150, steps: 400, wave: 2, waveClock: 1.5, player: 'zigzag', clockResetAt: [{ step: 150, waveClock: 1.5 }] },
  { name: 'w3_corner_nw', seed: 31337, steps: 400, wave: 3, budget: 5, player: 'fixed', at: { x: 60, y: 60, vx: 0, vy: 0 } },
  { name: 'w4_corner_se', seed: 777, steps: 400, wave: 4, budget: 5, player: 'fixed', at: { x: 25960, y: 25950, vx: -130, vy: -130 } },
  { name: 'w3_edge_west_pincer', seed: 2026, steps: 400, wave: 3, budget: 5, player: 'fixed', at: { x: 30, y: 13000, vx: 0, vy: 90 } },
  { name: 'w3_crowded_to_the_cap', seed: 12, steps: 200, wave: 3, budget: 18, player: 'circle', fill: { swarm: 92, assassin: 5 } },
  { name: 'w3_assassin_cap', seed: 14, steps: 300, wave: 3, budget: 18, theme: 'assassin', player: 'circle', fill: { assassin: 15, swarm: 6 } },
  { name: 'w1_full_list', seed: 13, steps: 100, wave: 1, budget: 18, player: 'idle', fill: { swarm: 99 } },
];

function playerAt(script, step, at) {
  switch (script) {
    case 'idle': return { x: 13000, y: 13000, vx: 0, vy: 0 };
    case 'fixed': return at;
    case 'circle': {
      const a = step * 0.01;
      const moving = Math.floor(step / 90) % 3 !== 2; // stands still every third 1.5 s
      return { x: 13000 + 400 * Math.sin(a), y: 13000 + 400 * Math.cos(a), vx: moving ? 180 * Math.cos(a) : 0, vy: moving ? -180 * Math.sin(a) : 0 };
    }
    case 'zigzag': {
      const k = Math.floor(step / 7);
      const dir = [[1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]][k % 8];
      return { x: 13000 + 3 * step * dir[0], y: 13000 + 3 * step * dir[1], vx: 180 * dir[0] * 0.7, vy: 180 * dir[1] * 0.7 };
    }
    default: throw new Error(`unknown player script ${script}`);
  }
}

function themeFlat(game) {
  const t = game.waveSpawnTheme;
  if (!t) return [['i', 0], ['s', '-'], ['s', '-'], ['b', false], ['f', 0], ['i', 0], ['s', '-'], ['s', '-']];
  return [['i', t.wave], ['s', t.baseKind], ['s', t.featuredKind], ['b', t.changed], ['f', t.changeChance], ['i', t.totalSpawned],
    ['s', names(Object.entries(t.counts).map(([k, v]) => `${k}=${v}`))], ['s', names(t.recentMixed)]];
}

function waveRow(sandbox, game, step) {
  return row(['i', step], ['i', sandbox.gameRandomDraws], ['i', game.wave], ['f', game.waveClock], ['f', game.directorClock], ['f', game.spawnBudget],
    ['i', game.nextEnemyId], ['i', game.enemies.length], ['i', game.enemiesVersion || 0], ['s', game.pendingDirectorEnemyKind ? game.pendingDirectorEnemyKind : '-'],
    ['f', game.waveFeaturedChangeChance], ['i', game.enemyAiTier], ['f', game.enemyAiSkill], ['f', game.rawScore], ['i', game.scoredWaves.size],
    ['s', names(Array.from(game.scoredWaves))], ...themeFlat(game), ['s', names(game.featuredEnemyHistory)]);
}

/** Debug aid (GOLDEN_COVERAGE=1): counts the calls of the functions whose paths the scenarios are meant to reach. Does not change the output. */
function countCalls(sandbox) {
  inContext(sandbox, `var __calls={};["safePointAround","safeEnemySpawnPoint","enemyFieldSpawnPoint","spawnEnemy","advanceWave","pickBalancedMixedEnemyKind","pickWaveDirectedEnemyKind","spawnDirectorEnemyBatch"].forEach((n)=>{const o=globalThis[n];globalThis[n]=function(...a){__calls[n]=(__calls[n]||0)+1;return o.apply(this,a);};});`, 'count-calls.js');
  return () => JSON.stringify(sandbox.__calls);
}

function buildWaves() {
  const out = [];
  for (const sc of WAVE_SCENARIOS) {
    const { sandbox, game } = directorGame(sc.seed);
    const calls = process.env.GOLDEN_COVERAGE ? countCalls(sandbox) : null;
    if (sc.wave !== 1) {
      game.wave = sc.wave;
      sandbox.prepareEnemyWaveTheme(sc.wave);
    }
    if (sc.theme) { game.waveSpawnTheme.featuredKind = sc.theme; game.waveSpawnTheme.baseKind = sc.theme; }
    if (sc.waveClock !== undefined) game.waveClock = sc.waveClock;
    if (sc.budget !== undefined) game.spawnBudget = sc.budget;
    const fillKinds = [];
    if (sc.fill) {
      let id = 5000;
      for (const [kind, n] of Object.entries(sc.fill)) {
        for (let i = 0; i < n; i++) { game.enemies.push({ kind, id: id++ }); fillKinds.push(kind); }
      }
    }
    const players = [];
    const draws = [];
    const rows = [];
    const spawned = [];
    const resets = new Map((sc.clockResetAt || []).map((r) => [r.step, r.waveClock]));
    let known = game.enemies.length;
    for (let step = 1; step <= sc.steps; step++) {
      if (resets.has(step)) game.waveClock = resets.get(step);
      const p = playerAt(sc.player, step, sc.at);
      setPlayer(game, p);
      players.push(p.x, p.y, p.vx, p.vy);
      game.t += DT;
      const wavesBefore = game.wave;
      const versionBefore = game.enemiesVersion || 0;
      sandbox.updateWave(DT);
      draws.push(sandbox.gameRandomDraws);
      for (; known < game.enemies.length; known++) {
        const e = game.enemies[known];
        spawned.push(row(['i', step], ...enemyRow(e)));
      }
      if (game.wave !== wavesBefore || (game.enemiesVersion || 0) !== versionBefore || step % 25 === 0 || step === sc.steps) rows.push(waveRow(sandbox, game, step));
    }
    if (calls) console.error(`coverage ${sc.name}: ${calls()}`);
    out.push({
      name: sc.name, seed: sc.seed, steps: sc.steps, wave: sc.wave, wave_clock: sc.waveClock ?? null, spawn_budget: sc.budget ?? null,
      fill: fillKinds.length ? Object.fromEntries(Object.entries(sc.fill)) : null,
      wave_clock_resets: (sc.clockResetAt || []).map((r) => [r.step, f(r.waveClock)]),
      theme: sc.theme ?? null,
      player_script: sc.player,
      player_at: sc.player === 'fixed' ? [f(sc.at.x), f(sc.at.y), f(sc.at.vx), f(sc.at.vy)] : (sc.player === 'idle' ? [f(13000), f(13000), f(0), f(0)] : null),
      players: sc.player === 'circle' || sc.player === 'zigzag' ? encodeF64(players) : null,
      draws: encodeI32(draws),
      rows,
      spawned,
    });
  }
  return {
    row_columns: ['step:i', 'draws:i', 'wave:i', 'wave_clock:f', 'director_clock:f', 'spawn_budget:f', 'next_enemy_id:i', 'enemies:i', 'enemies_version:i',
      'pending_kind:s', 'featured_change_chance:f', 'ai_tier:i', 'ai_skill:f', 'raw_score:f', 'scored_waves:i', 'scored_wave_list:s',
      'theme_wave:i', 'theme_base:s', 'theme_featured:s', 'theme_changed:b', 'theme_change_chance:f', 'theme_total:i', 'theme_counts:s', 'theme_recent:s',
      'history:s'],
    spawned_columns: ['step:i', 'id:i', 'kind:s', 'spawn_wave:i', 'strafe_dir:i', 'ai_state:s', 'own_key_count:i', ...ENEMY_NUMBERS.map((k) => `${k}:f`)],
    scenarios: out,
  };
}

// ---------------------------------------------------------------------------------------------------
// cleanup: cleanupDeadEnemies / killEnemy
// ---------------------------------------------------------------------------------------------------
const CLEANUP_NAMES = [
  'cleanupDeadEnemies', 'killEnemy', 'spawnXp', 'pushXpOrb', 'enemyXpDropMultiplier', 'awardEnemyScore', 'rawEnemyScore',
  'abilitiesActive', 'SCORE_RULES', 'rand', 'setGameSeed', 'makeSeededRandom', 'clamp',
];
const CLEANUP_STUBS = `
function archivistReleaseRecordForDeath(){} function findGroveAt(){return null;} function spreadSuperconductOnDeath(){} function spreadDeepErosionOnDeath(){}
function berserkerOnKill(){} function mikoActive(){return false;} function abilityOnKill(){} function spawnBossDefeatFx(){} function spawnEliteDefeatFx(){}
function burst(){} function detachEnemyFromSquad(){} function spawnLootDrop(){}
var audio={kill(){}};`;

let cleanupCode = null;
function cleanupSandbox(seed, maxOrbs) {
  if (cleanupCode === null) {
    const cuts = cutNames(original().text, CLEANUP_NAMES, { impureNames: ['setGameSeed'] });
    cleanupCode = `${CLEANUP_STUBS}\n${cuts.sort((a, b) => a.start - b.start).map((c) => c.text).join(';\n')};`;
  }
  const sandbox = {};
  const code = `var game=null,gameRandom=null,gameRandomDraws=0,gameRandomSeed=null,MAX_XP_ORBS=${maxOrbs};\n${cleanupCode}`;
  const context = vm.createContext(sandbox, { codeGeneration: { strings: false, wasm: false } });
  vm.runInContext('Math.random=function(){throw new Error("Math.random");};', context);
  vm.runInContext(code, context, { filename: 'cleanup-cuts.js', timeout: 20000 });
  sandbox.setGameSeed(seed);
  return sandbox;
}

function buildCleanup() {
  const scenarios = [];
  for (const sc of [
    { name: 'few', seed: 1, count: 12, dead: 0.3, maxOrbs: 480 },
    { name: 'many', seed: 2, count: 60, dead: 0.45, maxOrbs: 480 },
    { name: 'all_dead', seed: 3, count: 9, dead: 1.1, maxOrbs: 480 },
    { name: 'orb_cap_merge', seed: 4, count: 40, dead: 0.8, maxOrbs: 5 },
    { name: 'hp_values', seed: 5, count: 14, dead: 0.5, maxOrbs: 480, odd: true },
  ]) {
    const sandbox = cleanupSandbox(sc.seed, sc.maxOrbs);
    const rng = makeRng(sc.seed * 7919);
    const enemies = [];
    for (let i = 0; i < sc.count; i++) {
      const dead = rng() < sc.dead;
      const e = {
        id: i + 1, kind: i % 3 === 0 ? 'assassin' : 'swarm', x: 12000 + rng() * 800, y: 12000 + rng() * 800,
        hp: dead ? -rng() * 5 : 1 + rng() * 30, xp: i % 3 === 0 ? 16 : 8, spawnWave: 1 + (i % 4),
      };
      if (sc.odd && i === 2) e.hp = 0; // exactly 0 is dead
      if (sc.odd && i === 3) e.hp = NaN; // NaN is not dead
      if (sc.odd && i === 4) e.hp = -0;
      if (sc.odd && i === 5) { e.xp = 31; e.hp = -1; } // 3 orbs
      if (sc.odd && i === 6) { e.xp = 100 / 1.1; e.hp = -1; } // 8 orbs of 6 px
      enemies.push(e);
    }
    sandbox.game = {
      enemies, hazards: [], xpOrbs: [], xpMergeCursor: 0, kills: 0, rawScore: 0, ended: false, enemiesVersion: 0, wave: 2,
      contracts: {}, arenaWave: 0, specials: null, timedContract: null, squads: new Map(),
    };
    const input = enemies.map((e) => row(['i', e.id], ['s', e.kind], ['f', e.x], ['f', e.y], ['f', e.hp], ['f', e.xp], ['i', e.spawnWave]));
    sandbox.cleanupDeadEnemies();
    const game = sandbox.game;
    scenarios.push({
      name: sc.name, seed: sc.seed, max_orbs: sc.maxOrbs, input,
      draws: sandbox.gameRandomDraws, kills: game.kills, raw_score: f(game.rawScore), enemies_version: game.enemiesVersion, merge_cursor: game.xpMergeCursor,
      ids: names(game.enemies.map((e) => e.id)),
      orbs: game.xpOrbs.map((o) => row(['f', o.x], ['f', o.y], ['f', o.value], ['f', o.r])),
    });
  }
  return { input_columns: ['id:i', 'kind:s', 'x:f', 'y:f', 'hp:f', 'xp:f', 'spawn_wave:i'], orb_columns: ['x:f', 'y:f', 'value:f', 'r:f'], scenarios };
}

// ---------------------------------------------------------------------------------------------------
// grid: the enemy spatial grid and its queries
// ---------------------------------------------------------------------------------------------------
const GRID_NAMES = [
  'rebuildEnemySeparationGrid', 'rebuildEnemySeparationGridBasic', 'enemySeparationGridKey', 'queryEnemiesCircleBroad', 'queryEnemiesAabb',
  'nearestEnemy', 'clamp', 'dist2', 'MAP_W', 'MAP_H', 'ENEMY_SEPARATION_GRID_SIZE', 'ENEMY_SEPARATION_GRID_STRIDE', 'ENEMY_GRID_MAX_CX', 'ENEMY_GRID_MAX_CY',
  'ENEMY_NEAREST_SCRATCH',
];

let gridCode = null;
function gridSandbox() {
  if (gridCode === null) {
    const cuts = cutNames(original().text, GRID_NAMES);
    gridCode = `var game=null;\n${cuts.sort((a, b) => a.start - b.start).map((c) => c.text).join(';\n')};`;
  }
  const sandbox = {};
  const context = vm.createContext(sandbox, { codeGeneration: { strings: false, wasm: false } });
  vm.runInContext('Math.random=function(){throw new Error("Math.random");};', context);
  vm.runInContext(gridCode, context, { filename: 'grid-cuts.js' });
  return sandbox;
}

function buildGrid() {
  const scenarios = [];
  for (const sc of [
    { name: 'basic_dense', seed: 1, count: 70, projectiles: 0, spread: 700 },
    { name: 'basic_sparse', seed: 2, count: 30, projectiles: 10, spread: 6000 },
    { name: 'cells_and_cache_dense', seed: 3, count: 90, projectiles: 80, spread: 800 },
    { name: 'cells_sparse', seed: 4, count: 40, projectiles: 64, spread: 9000 },
    { name: 'edges', seed: 5, count: 50, projectiles: 0, spread: 300, edges: true },
    { name: 'hazards_select_cells', seed: 6, count: 60, projectiles: 0, hazards: 12, spread: 1500 },
  ]) {
    const sandbox = gridSandbox();
    const rng = makeRng(sc.seed * 104729);
    const enemies = [];
    for (let i = 0; i < sc.count; i++) {
      let x = 12500 + (rng() - 0.5) * sc.spread;
      let y = 12500 + (rng() - 0.5) * sc.spread;
      if (sc.edges) {
        const k = i % 5;
        if (k === 0) { x = 12 + rng() * 40; } else if (k === 1) { y = 12 + rng() * 40; } else if (k === 2) { x = 25988 - rng() * 40; } else if (k === 3) { y = 25988 - rng() * 40; }
      }
      enemies.push({ id: i + 1, x, y, hp: rng() < 0.1 ? -1 : 5 + rng() * 20 });
    }
    sandbox.game = {
      enemies, projectiles: Array.from({ length: sc.projectiles }, () => ({})), hazards: Array.from({ length: sc.hazards ?? 0 }, () => ({})),
    };
    const stages = [];
    const record = (label) => {
      const queries = [];
      const qrng = makeRng(sc.seed * 31 + stages.length);
      for (let q = 0; q < 16; q++) {
        const cx = 12500 + (qrng() - 0.5) * (q < 12 ? sc.spread * 1.2 : 30000);
        const cy = 12500 + (qrng() - 0.5) * (q < 12 ? sc.spread * 1.2 : 30000);
        const r = [30, 96, 200, 450, 1000, 5000][q % 6];
        const margin = q % 3;
        const out = [];
        sandbox.queryEnemiesCircleBroad(cx, cy, r, out, margin);
        const aabb = [];
        sandbox.queryEnemiesAabb(cx - r, cy - r * 0.5, cx + r * 1.5, cy + r, aabb, margin);
        const nearest = sandbox.nearestEnemy(cx, cy, r);
        queries.push(row(['f', cx], ['f', cy], ['f', r], ['i', margin], ['s', names(out.map((e) => e.id))], ['s', names(aabb.map((e) => e.id))], ['i', nearest ? nearest.id : 0]));
      }
      stages.push({ label, size: sandbox.game.enemySeparationGrid ? sandbox.game.enemySeparationGrid.size : 0, queries });
    };
    // no grid yet: the plain list order
    record('before_the_first_rebuild');
    sandbox.rebuildEnemySeparationGrid();
    record('after_rebuild');
    // enemies move, some die, but the grid is not rebuilt: stale buckets with live positions, hp checked again by the query
    for (const e of enemies) {
      if (e.id % 4 === 0) { e.x += 150; e.y -= 90; }
      if (e.id % 7 === 0) e.hp = 0;
    }
    record('stale_after_moves_and_deaths');
    sandbox.rebuildEnemySeparationGrid();
    record('after_second_rebuild');
    // an enemy is removed from the middle (swap-pop) and one is added
    const gone = enemies.splice(3, 1);
    if (gone.length) enemies.push(enemies.pop());
    enemies.push({ id: 1000, x: 12500, y: 12500, hp: 10 });
    sandbox.rebuildEnemySeparationGrid();
    record('after_swap_and_spawn');
    scenarios.push({
      name: sc.name, seed: sc.seed, count: sc.count, projectiles: sc.projectiles, hazards: sc.hazards ?? 0,
      input: buildGridInput(sc),
      stages,
    });
  }
  return { query_columns: ['cx:f', 'cy:f', 'r:f', 'cell_margin:i', 'circle_ids:s', 'aabb_ids:s', 'nearest_id:i'], enemy_columns: ['id:i', 'x:f', 'y:f', 'hp:f'], scenarios };
}

/** The initial enemy list of a grid scenario, regenerated (the sandbox mutated the originals). */
function buildGridInput(sc) {
  const rng = makeRng(sc.seed * 104729);
  const rows = [];
  for (let i = 0; i < sc.count; i++) {
    let x = 12500 + (rng() - 0.5) * sc.spread;
    let y = 12500 + (rng() - 0.5) * sc.spread;
    if (sc.edges) {
      const k = i % 5;
      if (k === 0) { x = 12 + rng() * 40; } else if (k === 1) { y = 12 + rng() * 40; } else if (k === 2) { x = 25988 - rng() * 40; } else if (k === 3) { y = 25988 - rng() * 40; }
    }
    rows.push(row(['i', i + 1], ['f', x], ['f', y], ['f', rng() < 0.1 ? -1 : 5 + rng() * 20]));
  }
  return rows;
}

// ---------------------------------------------------------------------------------------------------
export function generate(_extract) {
  const src = original();
  constantsSeen.clear();
  keySets.enemy = keySets.status = keySets.specialState = null;
  const plans = buildPlans();
  const points = buildPoints();
  const safePoints = buildSafePoints();
  const spawnEnemy = buildSpawnEnemy();
  const picks = buildPicks();
  const waves = buildWaves();
  const cleanup = buildCleanup();
  const grid = buildGrid();
  return {
    format: 1,
    generated_by: 'tools/golden/defs_enemies.mjs',
    source: 'webview-fg4/tests/fixtures/original.html',
    source_sha256: src.sha256,
    provenance: 'see the header of tools/golden/defs_enemies.mjs: real functions per section, the named stubs, sin/cos from tools/golden/_glibc_sin.mjs',
    dt: f(DT),
    enemy_numbers: ENEMY_NUMBERS,
    enemy_constants: Object.fromEntries(constantsSeen),
    enemy_keys: keySets.enemy.split(','),
    status_keys: keySets.status.split(','),
    special_state_keys: keySets.specialState.split(','),
    players: PLAYERS.map((p) => ({ name: p.name, x: f(p.x), y: f(p.y), vx: f(p.vx), vy: f(p.vy) })),
    plans: { columns: ['seed:i', 'wave:i', 'player:s', 'draws:i', 'pattern:s', 'base_angle:f', 'radius:f', 'cx:f', 'cy:f', 'min_radius:f', 'max_radius:f', 'min_distance:f', 'batch_size:i'], rows: plans },
    points: {
      columns: ['seed:i', 'player:s', 'pattern:s', 'index:i', 'plan_draws:i', 'draws_before:i', 'draws_after:i', 'x:f', 'y:f', 'distance:f'],
      rows: points,
    },
    safe_points: safePoints,
    spawn_enemy: spawnEnemy,
    picks,
    waves,
    cleanup,
    grid,
  };
}
