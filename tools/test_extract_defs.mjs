// Tests of tools/extract_defs.mjs and of the S3 golden modules tools/golden/defs_*.mjs (Node 22 `node:test`, no dependencies):
//
//   node --test tools/test_extract_defs.mjs
//
// tools/check_generated.sh runs them next to `extract_defs.mjs --check` and `gen_golden.mjs --check`, which compare the committed
// files with a fresh generation. Covers:
//   * extract_defs: every constant that the simulation needs is listed exactly once; the output is deterministic; the numbers
//     JSON cannot hold (Infinity) and the ones Godot's parser reads one ulp off (1/15) are written as markers; both pointer
//     variants are recorded; `--check` exits 1 for a changed, missing or stray file and 2 when the game text is not what the
//     tool expects;
//   * the golden modules: each exports {name, generate}; they are deterministic; and their numbers agree with values that were
//     measured independently in a real Chromium running the original game (analyst A's runtime probes: the enemy stats, the XP
//     curve, the weapon damage and interval, and the first two frames of a diagonal walk), so a cut-out function that quietly
//     computed something else would be caught here;
//   * the golden file of the simulation scripts states what it stubbed out, and a stubbed function is never also a real one.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { GROUPS, POINTER_DEPENDENT, extractDefs, fileText } from './extract_defs.mjs';
import { fromHex64, hex64 } from './golden/_codec.mjs';
import * as bits from './golden/defs_bits.mjs';
import * as formulas from './golden/defs_formulas.mjs';
import * as newGame from './golden/defs_new_game.mjs';
import * as simScripts from './golden/defs_sim_scripts.mjs';

const TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOLS_DIR, '..');
const TOOL = path.join(TOOLS_DIR, 'extract_defs.mjs');
const SOURCE = path.join(REPO_ROOT, 'webview-fg4/tests/fixtures/original.html');
const DEFS_DIR = path.join(REPO_ROOT, 'godot/sim/defs');
const html = fs.readFileSync(SOURCE, 'utf8');
const scratch = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'extract-defs-test-'));
test.after(() => fs.rmSync(scratch, { recursive: true, force: true }));

function runTool(args) {
  const result = spawnSync(process.execPath, [TOOL, ...args], { encoding: 'utf8' });
  return { code: result.status, out: result.stdout, err: result.stderr };
}

// ------------------------------------------------------------------------------------------------
// extract_defs
// ------------------------------------------------------------------------------------------------
test('every constant is listed once and the pointer-dependent ones are separate', () => {
  const plain = Object.values(GROUPS).flat();
  const pointer = Object.values(POINTER_DEPENDENT).flat();
  assert.equal(new Set([...plain, ...pointer]).size, plain.length + pointer.length, 'no constant appears twice');
  assert.deepEqual(Object.keys(GROUPS), ['characters.json', 'weapons.json', 'enemies.json', 'rules.json', 'limits.json']);
  assert.ok(plain.length + pointer.length >= 77, `the tables the port reads are all there (${plain.length + pointer.length})`);
  for (const must of ['CHARACTERS', 'WEAPONS', 'ENEMY_ARCHETYPES', 'DIFFICULTY_CONFIG', 'XP_CURVE', 'MAP_W', 'FIXED_DT', 'MOVE_STICK_MAX', 'BERSERKER_CONFIG']) {
    assert.ok(plain.includes(must), `${must} is extracted`);
  }
});

test('the committed files are what the tool writes now, byte for byte', () => {
  const { files } = extractDefs();
  for (const [name, data] of files) {
    assert.equal(fs.readFileSync(path.join(DEFS_DIR, name), 'utf8'), fileText(data), `${name} is up to date`);
  }
  assert.deepEqual(fs.readdirSync(DEFS_DIR).sort(), [...files.keys()].sort(), 'no other file in godot/sim/defs');
});

test('the extraction is deterministic and records the SHA-256 of the game', () => {
  const first = extractDefs();
  const second = extractDefs();
  for (const [name, data] of first.files) assert.equal(fileText(data), fileText(second.files.get(name)), name);
  assert.match(first.sourceSha256, /^[0-9a-f]{64}$/);
  for (const data of first.files.values()) assert.equal(data.source_sha256, first.sourceSha256);
});

test('values: the numbers that the analysis measured in Chromium', () => {
  const { files } = extractDefs();
  const v = (file) => files.get(file).values;
  assert.equal(v('characters.json').CHARACTERS.length, 10);
  const catalyst = v('characters.json').CHARACTERS[0];
  assert.equal(catalyst.id, 'catalyst');
  assert.equal(catalyst.hp, 100);
  assert.equal(catalyst.speed, 180);
  assert.equal(catalyst.directDamageMul, 0.85);
  assert.equal(catalyst.reactionDamageMul, 0.8);
  assert.equal(v('characters.json').SIGNATURE_WEAPON_BY_CHARACTER.catalyst, 'catalytic_ring');
  assert.equal(Object.keys(v('weapons.json').WEAPONS).length, 24);
  assert.deepEqual(v('rules.json').XP_CURVE, { initialRequirement: 60, growthMultiplier: 1.18, flatGrowth: 18, requirementMultiplier: 0.85 });
  assert.equal(v('limits.json').MAP_W, 26000);
  assert.equal(v('limits.json').BASE_MAX_ENEMIES, 100);
  assert.equal(v('rules.json').FIXED_DT, 1 / 60);
  assert.equal(v('rules.json').WAVE_DURATION, 36);
  assert.equal(v('rules.json').DAY_CYCLE_SECONDS, 144);
  assert.equal(v('enemies.json').DIRECTOR_BUDGET_CAP, 18);
  assert.deepEqual(Array.from(v('enemies.json').ENEMY_KIND_ORDER), ['swarm', 'assassin', 'tank', 'artillery', 'bomber', 'support', 'controller']);
  assert.equal(v('rules.json').DIFFICULTY_CONFIG.normal.predictionMax, Infinity);
});

test('both pointer variants are recorded; the simulation reads the coarse one', () => {
  const { files } = extractDefs();
  const limits = files.get('limits.json');
  assert.deepEqual(limits.pointer.coarse, {
    MAX_PROJECTILES: 520, MAX_XP_ORBS: 480, MAX_ENEMY_PROJECTILES: 420, HUD_UPDATE_INTERVAL: 1 / 15, WORLD_CHUNK_CACHE_MIN: 32, WORLD_CHUNK_CACHE_MAX: 80,
  });
  assert.deepEqual(limits.pointer.fine, {
    MAX_PROJECTILES: 900, MAX_XP_ORBS: 900, MAX_ENEMY_PROJECTILES: 720, HUD_UPDATE_INTERVAL: 1 / 24, WORLD_CHUNK_CACHE_MIN: 48, WORLD_CHUNK_CACHE_MAX: 160,
  });
});

test('JSON text: Infinity and long decimals travel as markers, short decimals as plain numbers', () => {
  const rules = fs.readFileSync(path.join(DEFS_DIR, 'rules.json'), 'utf8');
  assert.match(rules, /"predictionMax": \{"\$num": "Infinity"\}/);
  assert.doesNotMatch(rules, /\bInfinity\b(?!")/, 'a bare Infinity would be invalid JSON');
  assert.match(rules, /"FIXED_DT": \{"\$num": "f64:3f91111111111111"\}/, '1/60 has 16 digits: it travels as its bits');
  const limits = fs.readFileSync(path.join(DEFS_DIR, 'limits.json'), 'utf8');
  assert.match(limits, /"HUD_UPDATE_INTERVAL": \{"\$num": "f64:3fb1111111111111"\}/);
  assert.equal(fromHex64('3fb1111111111111'), 1 / 15);
  assert.match(rules, /"enemyHp": 0\.75,/, 'a short decimal stays a number');
  for (const text of [rules, limits]) JSON.parse(text);
});

test('command line: --check passes on the committed files and exits 1 on a changed, missing or stray file', () => {
  assert.equal(runTool(['--check']).code, 0);
  const dir = path.join(scratch, 'check-out');
  assert.equal(runTool(['--out', dir]).code, 0, 'writing into a fresh directory');
  assert.equal(runTool(['--check', '--out', dir]).code, 0);
  for (const name of fs.readdirSync(dir)) {
    assert.equal(fs.readFileSync(path.join(dir, name), 'utf8'), fs.readFileSync(path.join(DEFS_DIR, name), 'utf8'), `${name} equals the committed file`);
  }
  const limits = path.join(dir, 'limits.json');
  const original = fs.readFileSync(limits, 'utf8');
  fs.writeFileSync(limits, original.replace('"MAP_W": 26000', '"MAP_W": 26001'));
  const changed = runTool(['--check', '--out', dir]);
  assert.equal(changed.code, 1);
  assert.match(changed.err, /differs from a fresh extraction: limits\.json/);
  fs.writeFileSync(limits, original);
  fs.rmSync(path.join(dir, 'weapons.json'));
  const missing = runTool(['--check', '--out', dir]);
  assert.equal(missing.code, 1);
  assert.match(missing.err, /missing: weapons\.json/);
  assert.equal(runTool(['--out', dir]).code, 0, 'rewriting restores it');
  fs.writeFileSync(path.join(dir, 'stray.json'), '{}');
  const stray = runTool(['--check', '--out', dir]);
  assert.equal(stray.code, 1);
  assert.match(stray.err, /unexpected file.*stray\.json/);
});

test('the tool refuses a game text that is not what it expects (exit code 2)', () => {
  const run = (name, modify) => {
    const dir = path.join(scratch, name);
    fs.mkdirSync(dir, { recursive: true });
    const source = path.join(dir, 'game.html');
    fs.writeFileSync(source, modify(html));
    return runTool(['--source', source, '--out', path.join(dir, 'out')]);
  };
  const missing = run('missing', (text) => text.replace('var XP_CURVE=', 'var XP_CURVE_RENAMED='));
  assert.equal(missing.code, 2);
  assert.match(missing.err, /XP_CURVE/);
  const duplicate = run('duplicate', (text) => `${text}\n<script>var MAP_W=1;</script>`);
  assert.equal(duplicate.code, 2);
  assert.match(duplicate.err, /MAP_W/);
  const impure = run('impure', (text) => text.replace(/var MAX_WAVE=\d+/, 'var MAX_WAVE=document.title.length'));
  assert.equal(impure.code, 2);
  assert.match(impure.err, /MAX_WAVE/);
  const unknownKind = run('pointer-form', (text) => text.replace(/var MAX_PROJECTILES=IS_COARSE_POINTER\?(\d+):(\d+)/, 'var MAX_PROJECTILES=Math.max(1,$1)'));
  assert.equal(unknownKind.code, 2);
  assert.match(unknownKind.err, /MAX_PROJECTILES/);
  assert.equal(runTool(['--no-such-option']).code, 2);
});

// ------------------------------------------------------------------------------------------------
// The golden modules
// ------------------------------------------------------------------------------------------------
const MODULES = [bits, formulas, newGame, simScripts];

test('each golden module exports a topic name and generate(); the names are the committed files', () => {
  assert.deepEqual(MODULES.map((m) => m.name), ['defs_bits', 'formulas', 'new_game', 'sim_scripts']);
  for (const m of MODULES) {
    assert.equal(typeof m.generate, 'function');
    assert.ok(fs.existsSync(path.join(REPO_ROOT, 'godot/tests/golden', `${m.name}.json`)), `${m.name}.json is committed`);
  }
});

test('the modules are deterministic', () => {
  for (const m of MODULES) {
    assert.equal(JSON.stringify(m.generate()), JSON.stringify(m.generate()), `${m.name} twice`);
  }
});

const rowOf = (rows, startsWith) => {
  const row = rows.find((r) => r.startsWith(startsWith));
  assert.ok(row, `a row starting with "${startsWith}"`);
  return row.split(' ');
};

test('enemySpec: values measured in Chromium (analyst A) and the size of the table', () => {
  const spec = formulas.generate().enemy_spec;
  const keys = spec.numeric_keys;
  const normal = spec.scenarios.find((s) => s.name === 'normal');
  assert.equal(normal.rows.length, 10 * 45, '10 kinds (one unknown) x 45 waves');
  assert.ok(spec.scenarios.reduce((n, s) => n + s.rows.length, 0) > 900);
  const valueOf = (row, key) => {
    const mask = Number(row[5]);
    assert.ok(mask & (1 << keys.indexOf(key)), `${key} is present`);
    let index = 6;
    for (let k = 0; k < keys.indexOf(key); k++) if (mask & (1 << k)) index++;
    return fromHex64(row[index]);
  };
  const swarm1 = rowOf(normal.rows, 'swarm 1 ');
  assert.equal(valueOf(swarm1, 'hp'), 28);
  assert.equal(valueOf(swarm1, 'speed'), 72);
  assert.equal(valueOf(swarm1, 'damage'), 9.34);
  assert.equal(valueOf(swarm1, 'armor'), 0.03);
  assert.equal(valueOf(swarm1, 'evasion'), 0.02);
  assert.equal(valueOf(swarm1, 'actionCooldownMul'), 1);
  const assassin4 = rowOf(normal.rows, 'assassin 4 ');
  assert.equal(valueOf(assassin4, 'hp'), 44.97500000000001);
  assert.equal(valueOf(assassin4, 'speed'), 90.87);
  // an unknown kind is a swarm
  assert.equal(rowOf(normal.rows, 'unknown_kind 1 ')[2], 'swarm');
});

test('XP curve: the sequence measured in Chromium (level, xpBaseNext, xpNext)', () => {
  const xp = formulas.generate().xp;
  const expected = [[1, 60, 51], [2, 88, 75], [3, 121, 103], [4, 160, 136], [5, 206, 175], [6, 261, 222], [7, 325, 276], [8, 401, 341],
    [9, 491, 417], [10, 597, 507], [11, 722, 614], [12, 869, 739], [13, 1043, 887]];
  assert.ok(xp.levels.length >= 60, 'at least the first 60 levels');
  expected.forEach(([level, base, next], i) => {
    const t = xp.levels[i].split(' ');
    assert.equal(Number(t[0]), level);
    assert.equal(fromHex64(t[2]), base);
    assert.equal(fromHex64(t[3]), next);
  });
  assert.equal(fromHex64(xp.initial.xpNext), 51);
  assert.equal(fromHex64(xp.initial.xpBaseNext), 60);
});

test('weapons: catalytic ring damage and interval measured in Chromium', () => {
  const weapon = formulas.generate().weapon;
  const damage = (id, level) => fromHex64(rowOf(weapon.damage, `${id} ${level} `)[2]);
  assert.equal(damage('catalytic_ring', 1), 24);
  assert.equal(damage('catalytic_ring', 2), 27.599999999999998);
  assert.equal(damage('catalytic_ring', 3), 31.200000000000003);
  assert.equal(damage('catalytic_ring', 8), 49.199999999999996);
  const defaults = weapon.interval_scenarios.find((s) => s.name === 'default');
  const interval = (level) => fromHex64(rowOf(defaults.rows, `catalytic_ring ${level} `)[2]);
  assert.equal(interval(1), 0.84);
  assert.equal(interval(2), 0.7777777777777777);
  assert.equal(interval(3), 0.7241379310344828);
});

test('movement: the first two frames of a diagonal walk equal what Chromium showed', () => {
  const golden = simScripts.generate();
  const column = Object.fromEntries(golden.columns.map((c, i) => [c.split(':')[1], i]));
  const script = golden.scripts.find((s) => s.name === 'stick_diag');
  const read = (step) => {
    const t = script.rows.find((r) => r.startsWith(`${step} `)).split(' ');
    return (name) => fromHex64(t[column[name]]);
  };
  const f1 = read(1);
  assert.equal(f1('x'), 13001.8);
  assert.equal(f1('y'), 12997.6);
  assert.equal(f1('vx'), 107.99999999995634);
  assert.equal(f1('vy'), -143.99999999997817);
  assert.equal(f1('ax'), 1400);
  assert.equal(f1('ay'), -1400);
  assert.equal(f1('walkPhase'), 0.1939393939393873);
  assert.equal(f1('lastFacing'), -0.9272952180017334, 'V8 atan2: the last digit differs from the C library (…335)');
  assert.equal(f1('camX'), 13000.24);
  assert.equal(f1('camY'), 12999.68);
  const f2 = read(2);
  assert.equal(f2('x'), 13003.599999999999);
  assert.equal(f2('y'), 12995.2);
  assert.equal(f2('ax'), 0);
  assert.equal(f2('ay'), 0);
  assert.equal(f2('camX'), 13000.688);
  assert.equal(f2('camY'), 12999.082666666667);
});

test('newGame: one draw with seed 424242 and the cooldown measured in Chromium', () => {
  const golden = newGame.generate();
  const seeded = golden.seeded.find((s) => s.seed === 424242);
  assert.equal(seeded.draws, 1);
  assert.equal(fromHex64(seeded.weapon.cooldown.f64), 0.03861239980906248);
  assert.equal(seeded.theme.featuredKind, 'swarm');
  assert.equal(seeded.theme.changed, false);
  assert.deepEqual(golden.seeded.map((s) => s.draws), Array(8).fill(1), 'the same on every seed');
  assert.equal(hex64(0.1287079993635416 * 0.3), seeded.weapon.cooldown.f64, 'rand(0, 0.3) of the first output 0.1287079993635416');
  assert.deepEqual(Object.values(golden.system_lists).map((list) => list.length), [5, 43, 5]);
  const baseline = golden.cases.baseline;
  assert.equal(baseline.player.xpNext, 51);
  assert.equal(baseline.player.xpBaseNext, 60);
  assert.equal(baseline.player.hp, 100);
  assert.equal(baseline.camera.x, 13000);
  assert.equal(baseline.weaponSlotMax, 6);
});

test('sim_scripts states what it stubbed out, and nothing that it ran for real is also stubbed', () => {
  const golden = simScripts.generate();
  const real = new Set(golden.real_functions);
  for (const name of golden.stubbed_noop) assert.ok(!real.has(name), `${name} is stubbed and real`);
  for (const mustBeReal of ['update', 'runSystems', 'updatePlayerMovement', 'followPlayerWithCamera', 'inputVector', 'updateDayCycle', 'advanceFrameClock']) {
    assert.ok(real.has(mustBeReal), `${mustBeReal} is run for real`);
  }
  for (const mustBeStubbed of ['updateWave', 'updateEnemies', 'updateWeapons', 'updateProjectiles', 'updateXp']) {
    assert.ok(golden.stubbed_noop.includes(mustBeStubbed), `${mustBeStubbed} is stubbed (steps S5/S6)`);
  }
  assert.deepEqual(golden.custom_stubs, ['clearTransientInput', 'endRun']);
  assert.equal(golden.scripts.length, 13);
  assert.ok(golden.scripts.some((s) => s.name === 'knock_out'), 'the knock-out sequence is covered');
  const knockOut = golden.scripts.find((s) => s.name === 'knock_out');
  assert.ok(knockOut.rows.at(-1).split(' ')[1] === 'ended', 'the knock-out run ends');
});

test('defs_bits lists every non-integer number of the definition files with its bit pattern', () => {
  const golden = bits.generate();
  assert.ok(golden.entries.length > 150, `many non-integer numbers (${golden.entries.length})`);
  const rules = JSON.parse(fs.readFileSync(path.join(DEFS_DIR, 'rules.json'), 'utf8'));
  const entry = golden.entries.find((e) => e.startsWith('rules.json:values.XP_CURVE.growthMultiplier '));
  assert.ok(entry, 'XP_CURVE.growthMultiplier is listed');
  assert.equal(fromHex64(entry.split(' ')[1]), 1.18);
  assert.equal(rules.values.XP_CURVE.growthMultiplier, 1.18);
  assert.ok(golden.entries.some((e) => e.startsWith('rules.json:values.FIXED_DT ')), 'FIXED_DT is listed');
});
