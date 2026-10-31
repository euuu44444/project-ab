// Golden vectors for the S3 formulas (topic "formulas" -> godot/tests/golden/formulas.json). Every expected value is
// produced by running the ORIGINAL function, cut out of original.html by name, in a node:vm context with an empty
// sandbox (tools/lib/js_source.mjs); nothing is typed by hand. The Godot side is tests/test_formulas.gd.
//
// What is real and what is stubbed, per section (the same statement sits in `provenance` of the output):
//   enemy_spec    real: enemySpec, currentDifficulty, currentDifficultyKey, DIFFICULTY_CONFIG, ENDLESS_* caps, ENEMY_ARMOR_MAX.
//   xp            real: gainXp, collectXp, XP_CURVE, DIFFICULTY_CONFIG, anomalyFactorActive, currentDifficulty. Stubbed: audio.xp /
//                 audio.levelUp (no-ops); `state` is "menu", so the trailing openNextPendingChoice() of gainXp is not reached
//                 (it is the hud/pending-choice system, step S6/S8). collectXp's archivist and anomaly-factor branches are not
//                 reachable for the catalyst without factors (their functions are left undefined: reaching them throws).
//   weapon        real: weaponDamage, weaponInterval, weaponRawInterval, effectivePlayerAttackSpeed, abilityWeaponSpeedMul,
//                 catalystHasteMul, finalCooldownMul, ... Stubbed: `game` is analyst A's catalyst stub (game.specials is a plain
//                 object with rank 0 for cat_haste), because makeSpecialsState needs SPECIAL_ABILITIES, which is filled by statements.
//   waves         real: isEliteWave, isBossWave, isSpecialWave, enemyArchetypeUnlockWave, progressionFeaturedEnemyKind,
//                 prepareEnemyWaveTheme, pickChangedFeaturedEnemyKind, setGameSeed + makeSeededRandom (the draw counter).
//   input_vector  real: inputVector.
//   camera        real: followPlayerWithCamera.
import { encodeF64, hex64, makeRng } from './_codec.mjs';
import { columns, original, row, sandboxWith, token } from './_defs_vm.mjs';
import { evaluateNewGame } from './_defs_vm.mjs';

export const name = 'formulas';

const KINDS = ['swarm', 'artillery', 'tank', 'support', 'controller', 'assassin', 'bomber', 'elite', 'boss', 'unknown_kind'];
const NUMERIC_SPEC_KEYS = ['r', 'hp', 'speed', 'damage', 'xp', 'armor', 'evasion', 'shoot', 'shield',
  'projectileSpeedMul', 'actionCooldownMul', 'abilityCooldownMul'];

// ---------------------------------------------------------------------------------------------------
// enemySpec
// ---------------------------------------------------------------------------------------------------
function buildEnemySpec() {
  const sb = sandboxWith([
    'enemySpec', 'currentDifficulty', 'currentDifficultyKey', 'DIFFICULTY_CONFIG', 'ENDLESS_ENEMY_STAT_CAP',
    'ENDLESS_ENEMY_SPEED_CAP', 'ENDLESS_ACTION_COOLDOWN_MIN', 'ENDLESS_ARMOR_PER_50_WAVES', 'ENDLESS_EVASION_PER_50_WAVES',
    'ENEMY_ARMOR_MAX',
  ], { prelude: 'var game=null,selectedDifficulty="normal";' });

  const baseWaves = [...Array.from({ length: 40 }, (_, i) => i + 1), 50, 51, 60, 100, 101];
  // 1 and 10: no milestone yet; 49-51, 99-101 and 149-151: the first three milestone boundaries (milestones 0|1, 1|2, 2|3)
  const MILESTONE_WAVES = [1, 10, 49, 50, 51, 99, 100, 101, 149, 150, 151];
  const scenarios = [
    { name: 'normal', mode: 'normal', difficulty: 'normal', statMult: 1, speedMult: 1, contract: 1, waves: baseWaves },
    ...['easy', 'hard', 'nightmare'].map((difficulty) => ({
      name: difficulty, mode: 'normal', difficulty, statMult: 1, speedMult: 1, contract: 1, waves: ([1, 2, 5, 10, 15, 30, 31, 60]),
    })),
    // endless: multipliers apply (capped by the ENDLESS_* constants); the armor/evasion milestone is floor(max(0, wave - 1) / 50), so it
    // steps at waves 51, 101 and 151: the waves on both sides of each boundary are listed (a boundary off by one wave is caught)
    { name: 'endless_x1', mode: 'endless', difficulty: 'normal', statMult: 1, speedMult: 1, contract: 1, waves: MILESTONE_WAVES },
    { name: 'endless_x2_5', mode: 'endless', difficulty: 'normal', statMult: 2.5, speedMult: 1.2, contract: 1, waves: MILESTONE_WAVES },
    { name: 'endless_x12', mode: 'endless', difficulty: 'nightmare', statMult: 12, speedMult: 2, contract: 1, waves: MILESTONE_WAVES },
    // the multipliers are ignored outside endless mode
    { name: 'normal_ignores_endless_mults', mode: 'normal', difficulty: 'normal', statMult: 2.5, speedMult: 1.2, contract: 1, waves: ([1, 10]) },
    // contract multiplier (max(1, x)): 1.3 applies, 0.5 does not
    { name: 'contract_1_3', mode: 'normal', difficulty: 'normal', statMult: 1, speedMult: 1, contract: 1.3, waves: ([1, 10, 30]) },
    { name: 'contract_0_5', mode: 'normal', difficulty: 'normal', statMult: 1, speedMult: 1, contract: 0.5, waves: ([1, 10]) },
    { name: 'endless_and_contract', mode: 'endless', difficulty: 'hard', statMult: 3, speedMult: 1.1, contract: 1.6, waves: ([1, 10, 49, 50, 51]) },
  ];

  const out = [];
  for (const sc of scenarios) {
    sb.game = {
      mode: sc.mode, difficulty: sc.difficulty, enemyStatMult: sc.statMult, enemySpeedMult: sc.speedMult, contractEnemyStatMul: sc.contract,
    };
    const rows = [];
    for (const kind of KINDS) {
      for (const wave of sc.waves) {
        const s = sb.enemySpec(kind, wave);
        const present = NUMERIC_SPEC_KEYS.filter((k) => s[k] !== undefined);
        const keys = Object.keys(s);
        const unexpected = keys.filter((k) => !NUMERIC_SPEC_KEYS.includes(k) && !['kind', 'color', 'elite', 'boss'].includes(k));
        if (unexpected.length) throw new Error(`enemySpec returned unexpected keys: ${unexpected.join(',')}`);
        for (const k of present) if (typeof s[k] !== 'number') throw new Error(`enemySpec.${k} is not a number`);
        const mask = present.reduce((m, k) => m | (1 << NUMERIC_SPEC_KEYS.indexOf(k)), 0);
        const flags = (s.elite === true ? 1 : 0) | (s.boss === true ? 2 : 0);
        rows.push([
          token('s', kind), token('i', wave), token('s', s.kind), token('s', s.color), token('i', flags), token('i', mask),
          ...present.map((k) => hex64(s[k])),
        ].join(' '));
      }
    }
    out.push({
      name: sc.name, mode: sc.mode, difficulty: sc.difficulty, enemyStatMult: hex64(sc.statMult), enemySpeedMult: hex64(sc.speedMult),
      contractEnemyStatMul: hex64(sc.contract), rows,
    });
  }
  sb.game = null;
  return {
    columns: columns('kind_in:s', 'wave:i', 'kind_out:s', 'color:s', 'flags:i(1=elite,2=boss)', 'mask:i(bit n = numeric_keys[n] present)', 'values:f...(present keys in order)'),
    numeric_keys: NUMERIC_SPEC_KEYS,
    scenarios: out,
  };
}

// ---------------------------------------------------------------------------------------------------
// XP curve: newGame's initial values + gainXp / collectXp
// ---------------------------------------------------------------------------------------------------
function xpSandbox() {
  return sandboxWith([
    'gainXp', 'collectXp', 'XP_CURVE', 'DIFFICULTY_CONFIG', 'anomalyFactorActive', 'currentDifficulty', 'currentDifficultyKey',
  ], {
    prelude: 'var game=null,selectedDifficulty="normal",state="menu";var audio={xp(){},levelUp(){}};',
  });
}

function xpState(sb, game) {
  const p = game.player;
  return row(['i', p.level], ['f', p.xp], ['f', p.xpBaseNext], ['f', p.xpNext], ['i', game.pendingLevelUps], ['i', game.pendingLevelNumbers.length],
    ['i', game.pendingLevelNumbers.length ? game.pendingLevelNumbers[game.pendingLevelNumbers.length - 1] : 0]);
}

function buildXp() {
  const sb = xpSandbox();
  const fresh = (difficulty = 'normal') => {
    const { game } = evaluateNewGame({ character: 'catalyst', mode: 'normal', difficulty });
    return game;
  };
  const initial = (() => {
    const game = fresh();
    return { xpBaseNext: hex64(game.player.xpBaseNext), xpNext: hex64(game.player.xpNext), level: game.player.level, xp: hex64(game.player.xp) };
  })();

  // 1. the requirement of every level: feed exactly xpNext, so each call is one level-up with nothing left over
  const levels = [];
  {
    const game = fresh();
    sb.game = game;
    levels.push(xpState(sb, game));
    for (let i = 1; i < 220; i++) {
      sb.gainXp(game.player.xpNext);
      levels.push(xpState(sb, game));
    }
  }

  // 2. scripted gains (fractional carry, several levels in one call, huge gains, zero)
  const scripted = (script) => {
    const game = fresh();
    sb.game = game;
    const rows = [xpState(sb, game)];
    for (const v of script.gains) {
      sb.gainXp(v);
      rows.push(xpState(sb, game));
    }
    return { name: script.name, gains: script.gains.map(hex64), rows };
  };
  const orb = 8 * 1.5;
  const sequences = [
    { name: 'orbs_of_8_catalyst', gains: Array.from({ length: 40 }, () => orb) },
    { name: 'fractions', gains: [0.1, 0.2, 0.3, 50.4, 0.0000001, 1 / 3, 2 / 3, 24.6, 51, 75, 103] },
    { name: 'multi_level', gains: [600, 5000, 123456.789, 1e7] },
    { name: 'zero_and_tiny', gains: [0, 0, 5e-324, 50.99999999999999, 1e-9, 51] },
    { name: 'around_thresholds', gains: [51, 74.99999999999999, 0.00000000000001, 103, 136, 175, 222] },
  ].map(scripted);

  // 3. collectXp: xpMul (1.5) * difficulty.xp * 1, for every difficulty
  const collect = ['easy', 'normal', 'hard', 'nightmare'].map((difficulty) => {
    const game = fresh(difficulty);
    sb.game = game;
    const values = [8, 14, 16, 17, 21, 23, 24, 95, 500, 0.3, 1234.5];
    const rows = [xpState(sb, game)];
    for (const v of values) {
      sb.collectXp(v);
      rows.push(xpState(sb, game));
    }
    return { difficulty, values: values.map(hex64), rows };
  });
  sb.game = null;
  return {
    columns: columns('level:i', 'xp:f', 'xpBaseNext:f', 'xpNext:f', 'pendingLevelUps:i', 'pendingLevelNumbers_len:i', 'pendingLevelNumbers_last:i'),
    initial, levels, sequences, collect,
  };
}

// ---------------------------------------------------------------------------------------------------
// weaponDamage / weaponInterval
// ---------------------------------------------------------------------------------------------------
function buildWeapon() {
  const sb = sandboxWith([
    'WEAPONS', 'weaponDamage', 'SAFE_ATTACK_INTERVAL', 'weaponRawInterval', 'weaponInterval', 'FINAL_BONUS_STEP', 'finalBonusStacks',
    'finalCooldownMul', 'effectivePlayerAttackSpeed', 'berserkerAttackSpeedMul', 'berserkerFrenzy', 'berserkerActive', 'BERSERKER_CONFIG',
    'abilityGlobalAttackSpeedMul', 'abilityWeaponSpeedMul', 'abilitiesActive', 'currentAbilityList', 'abilityListFor', 'EMPTY_ABILITY_LIST',
    'abilityRank', 'catalystHasteMul', 'clamp', 'sanitizeBerserkerNumber', 'BERSERKER_EPSILON',
  ], { prelude: 'var game=null;' });
  const ids = Object.keys(sb.WEAPONS);
  const levels = [...Array.from({ length: 12 }, (_, i) => i + 1), 20, 30, 100];

  const damage = [];
  for (const id of ids) for (const level of levels) damage.push(row(['s', id], ['i', level], ['f', sb.weaponDamage({ id, level })]));

  const gameStub = (attackSpeed, cooldownStacks) => ({
    mode: 'normal',
    difficulty: 'normal',
    contractEnemyStatMul: 1,
    enemyStatMult: 1,
    enemySpeedMult: 1,
    char: { id: 'catalyst' },
    player: { attackSpeed },
    specials: {
      abilityList: [{ id: 'cat_haste' }], ranks: { cat_haste: 0 }, finalBonus: { damage: 0, area: 0, cooldown: cooldownStacks }, runtime: {},
    },
    berserker: null,
    metaRun: {},
  });
  const m1Ids = ['catalytic_ring', 'pulse', 'blades', 'wand'];
  const scenarios = [
    { name: 'default', attackSpeed: 1, cooldownStacks: 0, ids, levels: levels.filter((l) => l <= 12 || l === 20 || l === 100) },
    { name: 'attack_speed_1_3', attackSpeed: 1.3, cooldownStacks: 0, ids: m1Ids, levels: [1, 2, 3, 4, 5, 6, 7, 8] },
    { name: 'cooldown_stacks_3', attackSpeed: 1, cooldownStacks: 3, ids: m1Ids, levels: [1, 2, 3, 4, 5, 6, 7, 8] },
    { name: 'cooldown_stacks_60_floor', attackSpeed: 1, cooldownStacks: 60, ids: m1Ids, levels: [1, 5] },
    { name: 'attack_speed_0_01_clamped', attackSpeed: 0.01, cooldownStacks: 0, ids: m1Ids, levels: [1, 5] },
    { name: 'attack_speed_50_clamped', attackSpeed: 50, cooldownStacks: 0, ids: m1Ids, levels: [1, 5] },
  ].map((sc) => {
    sb.game = gameStub(sc.attackSpeed, sc.cooldownStacks);
    const rows = [];
    for (const id of sc.ids) {
      for (const level of sc.levels) {
        const w = { id, level, shotSeq: 0, elements: [] };
        rows.push(row(['s', id], ['i', level], ['f', sb.weaponInterval(w)], ['f', sb.weaponRawInterval(w)]));
      }
    }
    return { name: sc.name, attackSpeed: hex64(sc.attackSpeed), cooldownStacks: sc.cooldownStacks, rows };
  });
  sb.game = null;
  return {
    damage_columns: columns('id:s', 'level:i', 'damage:f'),
    damage,
    interval_columns: columns('id:s', 'level:i', 'interval:f', 'raw_interval:f'),
    interval_scenarios: scenarios,
    note: 'game.specials is a plain stub (rank 0 for cat_haste, finalBonus.cooldown = cooldownStacks); see the header of tools/golden/defs_formulas.mjs',
  };
}

// ---------------------------------------------------------------------------------------------------
// Wave predicates, unlock waves, featured kinds, and the wave theme (prepareEnemyWaveTheme with the seeded rng)
// ---------------------------------------------------------------------------------------------------
function buildWaves() {
  const sb = sandboxWith([
    'isStandardEliteWave', 'isStandardBossWave', 'isEndlessEliteWave', 'isEndlessBossWave', 'isEliteWave', 'isBossWave', 'isSpecialWave',
    'enemyArchetypeUnlockWave', 'progressionFeaturedEnemyKind', 'anomalyFactorActive', 'ENEMY_ARCHETYPES', 'ENEMY_KIND_ORDER',
  ], { prelude: 'var game=null;function __emptySet(){return new Set();}' });
  const predicates = {};
  for (const mode of ['normal', 'endless']) {
    sb.game = { mode, metaRun: { factorSet: sb.__emptySet() } };
    const rows = [];
    for (let wave = 0; wave <= 60; wave++) {
      rows.push(row(['i', wave], ['b', sb.isEliteWave(wave)], ['b', sb.isBossWave(wave)], ['b', sb.isSpecialWave(wave)],
        ['s', sb.progressionFeaturedEnemyKind(wave)]));
    }
    predicates[mode] = rows;
  }
  const unlock = [...Object.keys(sb.ENEMY_ARCHETYPES), 'elite', 'boss', 'unknown_kind'].map((kind) => row(['s', kind], ['f', sb.enemyArchetypeUnlockWave(kind)]));
  sb.game = null;

  // prepareEnemyWaveTheme with the original's seeded generator: draws and results
  const theme = sandboxWith([
    'prepareEnemyWaveTheme', 'pickChangedFeaturedEnemyKind', 'isEliteWave', 'isBossWave', 'isSpecialWave', 'isStandardEliteWave',
    'isStandardBossWave', 'isEndlessEliteWave', 'isEndlessBossWave', 'enemyArchetypeUnlockWave', 'progressionFeaturedEnemyKind',
    'anomalyFactorActive', 'ENEMY_ARCHETYPES', 'ENEMY_KIND_ORDER', 'FEATURED_WAVE_CONFIG', 'clamp', 'makeSeededRandom', 'setGameSeed',
  ], {
    // setGameSeed names Math.random in its seedless branch, which is never taken here (the seed is always given)
    impureNames: ['setGameSeed'],
    prelude: 'var game=null,gameRandom=null,gameRandomDraws=0,gameRandomSeed=null;function __emptySet(){return new Set();}',
  });
  return { predicates_columns: columns('wave:i', 'elite:b', 'boss:b', 'special:b', 'featured_kind:s'), predicates, unlock_columns: columns('kind:s', 'wave:f'), unlock, theme: buildThemeRuns(theme) };
}

function buildThemeRuns(sb) {
  const runs = [];
  for (const seed of [424242, 24681357, 7]) {
    for (const chance of [0.05, 0.9, 1]) {
      sb.setGameSeed(seed);
      sb.game = {
        wave: 1, mode: 'normal', metaRun: { factorSet: sb.__emptySet() }, waveFeaturedChangeChance: chance, featuredEnemyHistory: [],
        pendingDirectorEnemyKind: 'stale', pendingDirectorComposition: { stale: true }, waveSpawnTheme: null,
      };
      const rows = [];
      for (let wave = 1; wave <= 30; wave++) {
        const before = sb.gameRandomDraws;
        const result = sb.prepareEnemyWaveTheme(wave);
        const t = sb.game.waveSpawnTheme;
        const history = sb.game.featuredEnemyHistory.join(',') || '-';
        if (t === null) {
          rows.push(row(['i', wave], ['i', sb.gameRandomDraws - before], ['b', false], ['s', '-'], ['s', '-'], ['b', false], ['f', 0], ['s', history]));
        } else {
          if (result !== t) throw new Error('prepareEnemyWaveTheme returned another object than game.waveSpawnTheme');
          rows.push(row(['i', wave], ['i', sb.gameRandomDraws - before], ['b', true], ['s', t.baseKind], ['s', t.featuredKind], ['b', t.changed],
            ['f', t.changeChance], ['s', history]));
        }
      }
      runs.push({ seed, waveFeaturedChangeChance: hex64(chance), rows, total_draws: sb.gameRandomDraws });
    }
  }
  return {
    columns: columns('wave:i', 'draws:i', 'has_theme:b', 'base_kind:s', 'featured_kind:s', 'changed:b', 'change_chance:f', 'history:s(comma list)'),
    note: 'game.featuredEnemyHistory and waveFeaturedChangeChance persist across the waves of one run; the changeChance of a wave is the value at that time (this golden never changes it between waves)',
    runs,
  };
}

// ---------------------------------------------------------------------------------------------------
// inputVector and followPlayerWithCamera
// ---------------------------------------------------------------------------------------------------
const KEY_NAMES = ['KeyA', 'ArrowLeft', 'KeyD', 'ArrowRight', 'KeyW', 'ArrowUp', 'KeyS', 'ArrowDown'];

function buildInputVector() {
  const sb = sandboxWith(['inputVector'], {
    prelude: 'var input={keys:new Set(),moveX:0,moveY:0};function __setInput(keys,mx,my){input.keys=new Set(keys);input.moveX=mx;input.moveY=my;}',
  });
  const call = (keys, mx, my) => {
    sb.__setInput(keys, mx, my);
    const v = sb.inputVector();
    return [v.x, v.y];
  };
  // every subset of the 8 key names with the stick at rest ...
  const subsets = [];
  for (let mask = 0; mask < 256; mask++) {
    const keys = KEY_NAMES.filter((_, i) => mask & (1 << i));
    const [x, y] = call(keys, 0, 0);
    subsets.push(row(['s', keys.join(',') || '-'], ['f', x], ['f', y]));
  }
  // ... and the 16 logical key combinations (A/D/W/S) with a grid of stick positions, including |stick| > 1 on a diagonal
  const sticks = [[0, 0], [1, 0], [0, -1], [0.6, -0.8], [-0.3, 0.4], [1, 1], [-1, -1], [0.123456789, -0.987654321], [0.5, 0.5], [0.7071067811865476, 0.7071067811865476], [1e-9, 0]];
  const combos = [];
  for (let mask = 0; mask < 16; mask++) {
    const keys = ['KeyA', 'KeyD', 'KeyW', 'KeyS'].filter((_, i) => mask & (1 << i));
    for (const [mx, my] of sticks) {
      const [x, y] = call(keys, mx, my);
      combos.push(row(['s', keys.join(',') || '-'], ['f', mx], ['f', my], ['f', x], ['f', y]));
    }
  }
  return {
    subset_columns: columns('keys:s(comma list, - = none)', 'x:f', 'y:f'),
    subsets,
    combo_columns: columns('keys:s', 'moveX:f', 'moveY:f', 'x:f', 'y:f'),
    combos,
  };
}

function buildCamera() {
  const sb = sandboxWith(['followPlayerWithCamera'], { prelude: 'var game=null;' });
  const rng = makeRng(20261019);
  const scripts = [
    { name: 'static_offset', cam: [13000, 13000], player: () => [13100, 12950], dts: Array(90).fill(1 / 60) },
    { name: 'walking_player', cam: [13000, 13000], player: (i) => [13000 + i * 3, 13000 - i * 1.7], dts: Array(120).fill(1 / 60) },
    { name: 'dt_variants', cam: [100.5, 200.25], player: (i) => [100.5 + 50 * Math.sin(i), 200.25 + 40 * Math.cos(i)],
      dts: [1 / 60, 1 / 30, 1 / 120, 0, 1e-9, 0.125, 0.2, 1 / 61, 1 / 59, 0.05, 1 / 60, 1 / 60] },
    { name: 'random_walk', cam: [9000, 5000], player: () => [9000 + rng() * 300, 5000 + rng() * 300], dts: Array(100).fill(1 / 60) },
  ].map((script) => {
    sb.game = { camera: { x: script.cam[0], y: script.cam[1] }, player: { x: 0, y: 0 } };
    const rows = [];
    script.dts.forEach((dt, i) => {
      const [px, py] = script.player(i);
      sb.game.player.x = px;
      sb.game.player.y = py;
      sb.followPlayerWithCamera(dt);
      rows.push(row(['f', dt], ['f', px], ['f', py], ['f', sb.game.camera.x], ['f', sb.game.camera.y]));
    });
    return { name: script.name, cam_x: hex64(script.cam[0]), cam_y: hex64(script.cam[1]), rows };
  });
  sb.game = null;
  return { columns: columns('dt:f', 'player_x:f', 'player_y:f', 'camera_x:f', 'camera_y:f'), scripts };
}

export function generate(_extract) {
  const src = original();
  return {
    format: 1,
    generated_by: 'tools/golden/defs_formulas.mjs',
    source: 'webview-fg4/tests/fixtures/original.html',
    source_sha256: src.sha256,
    encoding: 'doubles are 16 hex digits of the IEEE-754 bits (tools/golden/_codec.mjs); table rows are space separated tokens, see the columns arrays',
    enemy_spec: buildEnemySpec(),
    xp: buildXp(),
    weapon: buildWeapon(),
    waves: buildWaves(),
    input_vector: buildInputVector(),
    camera: buildCamera(),
  };
}

// keep the unused helper import honest for tools that import this module for its building blocks
export { encodeF64 };
