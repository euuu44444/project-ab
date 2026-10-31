#!/usr/bin/env node
// Self-test of tools/compare_trace.mjs and tools/lib/trace_io.mjs on small synthetic traces (no browser, no Godot):
//   node --test tools/test_compare_trace.mjs        exit 0 when every check passes (the style of tools/test_gen_golden.mjs)
import assert from 'node:assert/strict';
import test, { after } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { run } from './compare_trace.mjs';
import { fileURLToPath } from 'node:url';
import { doubleToHex, hexToDouble, readTrace, writeTrace, firstEffects, TRACE_FORMAT } from './lib/trace_io.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'compare-trace-test-'));
const check = (name, fn) => test(name, fn);
after(() => fs.rmSync(dir, { recursive: true, force: true }));

const F = doubleToHex;
const header = (producer, extraFields = {}) => ({
  format: TRACE_FORMAT, producer, seed: 1, input_script: { name: 'unit' },
  slots: { intro: ['a'], main: ['wave/progress', 'enemy/update'], ko: [] },
  fields: { player: ['x:f', 'y:f', 'level:i'], camera: ['x:f'], wave: ['t:f'], enemy: ['id:i', 'kind:s', 'x:f', ...(extraFields.enemy || [])], projectile: [], xp_orb: [] },
  count_fields: ['enemies', 'projectiles', 'xp_orbs', 'particles', 'enemy_projectiles', 'hazards'],
});
function step(n, { x = n, enemies = [], draws = n, slots = {} } = {}) {
  return {
    n, input: { moveX: F(0), moveY: F(0), keys: [] }, state: 'playing', draws, slot_draws: slots, outside_draws: 0,
    player: [F(x), F(2 * n), 1], camera: [F(x / 2)], wave: [F(n / 60)],
    counts: { enemies: enemies.length, projectiles: 0, xp_orbs: 0, particles: 0, enemy_projectiles: 0, hazards: 0 },
    enemies, projectiles: [], xp_orbs: [],
  };
}
const enemy = (id, x) => [id, 'swarm', F(x)];
function make(name, producer, steps, h = header(producer)) {
  const file = path.join(dir, name);
  writeTrace(file, h, steps.map((s) => JSON.stringify(s)).join('\n'));
  return file;
}
const base = (n) => Array.from({ length: n }, (_, i) => step(i + 1, { enemies: [enemy(1, 10 + i), enemy(2, 20)] }));
const cmp = (a, b, ...args) => run([a, b, ...args]);

check('double <-> hex round trip, -0, NaN, subnormal, infinity', () => {
  for (const x of [0, -0, 1, -1, 0.1, 1 / 60, 5e-324, 1.7976931348623157e308, Infinity, -Infinity, Math.PI]) {
    assert.ok(Object.is(hexToDouble(F(x)), x), `round trip of ${x}`);
  }
  assert.equal(F(NaN), '7ff8000000000000');
  assert.equal(F(-0), '8000000000000000');
  assert.equal(F(1), '3ff0000000000000');
  assert.throws(() => hexToDouble('3ff0'), /16-digit/);
});

const ref = make('ref.jsonl.gz', 'original-chromium', base(10));

check('identical traces are the same (exit 0), also gzip against plain text', () => {
  const plain = make('same.jsonl', 'godot-port', base(10));
  assert.equal(readTrace(plain).steps.length, 10);
  const r = cmp(ref, plain);
  assert.equal(r.code, 0, r.text);
  assert.match(r.text, /RESULT: SAME/);
});

check('a float that differs: first step, field, both values as double and hex, the delta (exit 1)', () => {
  const steps = base(10); steps[4].player[0] = F(5 + 2 ** -40); steps[7].player[1] = F(0);
  const r = cmp(ref, make('p1.jsonl', 'godot-port', steps));
  assert.equal(r.code, 1);
  assert.match(r.text, /player, first at step 5, field x/);
  assert.ok(r.text.includes(F(5)) && r.text.includes(F(5 + 2 ** -40)), 'both bit patterns are printed');
  assert.match(r.text, /reference: 5 \(/);
  assert.match(r.text, /port - reference = 9\.094947017729282e-13, 1024 ulp/);
  assert.match(r.text, /every diverging field, with its first step: x@5 y@8/);
});

check('--until stops before the divergence, --from starts after it', () => {
  const steps = base(10); steps[4].player[0] = F(99);
  const p = make('p2.jsonl', 'godot-port', steps);
  assert.equal(cmp(ref, p, '--until', '4').code, 0);
  assert.equal(cmp(ref, p, '--until', '5').code, 1);
  assert.equal(cmp(ref, p, '--from', '6').code, 0);
});

check('--fields and --ignore select groups and single fields', () => {
  const steps = base(10); steps[2].camera[0] = F(-1);
  const p = make('p3.jsonl', 'godot-port', steps);
  assert.equal(cmp(ref, p, '--fields', 'player,wave').code, 0);
  assert.equal(cmp(ref, p, '--fields', 'camera').code, 1);
  assert.equal(cmp(ref, p, '--fields', 'camera.x').code, 1);
  assert.equal(cmp(ref, p, '--ignore', 'camera').code, 0);
  assert.equal(cmp(ref, p, '--ignore', 'camera.x').code, 0);
  assert.equal(cmp(ref, p, '--fields', 'player.x,player.y').code, 0);
});

check('a selector without such a field is a usage error naming the field', () => {
  assert.throws(() => cmp(ref, ref, '--fields', 'player.nothing'), /no field "nothing" in group player/);
  assert.throws(() => cmp(ref, ref, '--fields', 'nothing'), /unknown group/);
  assert.throws(() => cmp(ref, ref, '--fields', 'player', '--ignore', 'player'), /no field is selected/);
  assert.throws(() => run([ref]), /two trace files/);
  assert.throws(() => cmp(ref, ref, '--bogus'), /unknown option/);
});

check('entity lists: a different length, a different field, ids in the report', () => {
  const steps = base(10); steps[5].enemies.pop(); steps[5].counts.enemies = 1;
  let r = cmp(ref, make('p4.jsonl', 'godot-port', steps), '--fields', 'enemies');
  assert.equal(r.code, 1);
  assert.match(r.text, /enemies, first at step 6, field length/);
  assert.match(r.text, /ids reference \[1,2\] port \[1\]/);
  const moved = base(10); moved[2].enemies[1][2] = F(21);
  r = cmp(ref, make('p5.jsonl', 'godot-port', moved), '--fields', 'enemies');
  assert.match(r.text, /first at step 3, field \[1\] \(id 2\)\.x/);
  r = cmp(ref, make('p5b.jsonl', 'godot-port', steps), '--fields', 'counts');
  assert.match(r.text, /counts, first at step 6, field enemies/);
});

check('draws and the per-slot draws, with the slot name', () => {
  const steps = base(10); steps[3].draws = 99; steps[3].slot_draws = { 'main:1': 3 };
  const r = cmp(ref, make('p6.jsonl', 'godot-port', steps));
  assert.equal(r.code, 1);
  assert.match(r.text, /draws, first at step 4, field draws/);
  assert.match(r.text, /slot_draws, first at step 4, field main:1/);
  assert.match(r.text, /slot enemy\/update/);
  assert.equal(cmp(ref, make('p6b.jsonl', 'godot-port', steps), '--fields', 'player').code, 0);
});

check('state and input are compared', () => {
  const steps = base(10); steps[1].state = 'ended'; steps[2].input.keys = ['KeyA']; steps[3].input.moveX = F(0.5);
  const r = cmp(ref, make('p7.jsonl', 'godot-port', steps), '--fields', 'state,input');
  assert.match(r.text, /state, first at step 2/);
  assert.match(r.text, /input, first at step 3, field keys/);
  assert.match(r.text, /every diverging field, with its first step: keys@3 moveX@4/);
});

check('the port may carry fewer fields (unported): compared on the common ones', () => {
  const portHeader = header('godot-port'); portHeader.fields.player = ['x:f', 'y:f'];
  const steps = base(10).map((s) => ({ ...s, player: s.player.slice(0, 2) }));
  const p = make('p8.jsonl', 'godot-port', steps, portHeader);
  const r = cmp(ref, p);
  assert.equal(r.code, 0, r.text);
  assert.match(r.text, /not carried by the port, not compared: player: level/);
  assert.throws(() => cmp(ref, p, '--fields', 'player.level'), /no field "level"/);
  // fields of another order are matched by name
  const reordered = header('godot-port'); reordered.fields.player = ['y:f', 'x:f', 'level:i'];
  const q = make('p9.jsonl', 'godot-port', base(10).map((s) => ({ ...s, player: [s.player[1], s.player[0], s.player[2]] })), reordered);
  assert.equal(cmp(ref, q).code, 0);
});

check('a tolerance accepts small float differences, bit-exact does not', () => {
  const steps = base(10); steps[0].player[0] = F(1 + 1e-12);
  const p = make('p10.jsonl', 'godot-port', steps);
  assert.equal(cmp(ref, p).code, 1);
  assert.equal(cmp(ref, p, '--tolerance', '1e-9').code, 0);
  assert.equal(cmp(ref, p, '--tolerance', '1e-15').code, 1);
});

check('traces of different length differ unless --until limits the comparison to steps both have', () => {
  const shorter = make('p11.jsonl', 'godot-port', base(8));
  const r = cmp(ref, shorter);
  assert.equal(r.code, 1);
  assert.match(r.text, /steps, first at step 9, field count/);
  assert.equal(cmp(ref, shorter, '--until', '8').code, 0);
  assert.equal(cmp(ref, shorter, '--until', '5').code, 0);
  // the length check does not depend on what is selected
  assert.equal(cmp(ref, shorter, '--fields', 'player').code, 1);
});

check('--until beyond the end of the shorter trace is a divergence, not a silent shorter comparison', () => {
  const shorter = make('p11b.jsonl', 'godot-port', base(8));
  for (const fields of [[], ['--fields', 'player'], ['--fields', 'player.x,camera']]) {
    const r = cmp(ref, shorter, '--until', '20', ...fields);
    assert.equal(r.code, 1, `--until 20 against 8 steps ${fields.join(' ')}\n${r.text}`);
    assert.match(r.text, /steps, first at step 9, field count/);
    assert.match(r.text, /--until 20 asks for steps 9\.\.20, which the port trace does not have \(reference 10 steps, port 8 steps\)/);
    assert.match(r.text, /RESULT: DIFFERENT/);
  }
  assert.equal(cmp(ref, shorter, '--until', '9').code, 1, 'one step too many');
  // the reference may be the short one, too
  assert.match(cmp(shorter, ref, '--until', '20').text, /which the reference trace does not have \(reference 8 steps, port 10 steps\)/);
  // --ignore steps drops the different-length check only; an explicit --until that cannot be met still fails
  assert.equal(cmp(ref, shorter, '--ignore', 'steps').code, 0);
  assert.equal(cmp(ref, shorter, '--ignore', 'steps', '--until', '20').code, 1);
  const json = JSON.parse(cmp(ref, shorter, '--until', '20', '--fields', 'player', '--json').text);
  assert.equal(json.diverged, 1);
  assert.equal(json.groups.steps.first.step, 9);
});

check('an empty port trace or an empty range never passes', () => {
  const emptyHeader = header('godot-port');
  const empty = make('empty.jsonl', 'godot-port', [], emptyHeader);
  assert.equal(readTrace(empty).steps.length, 0);
  for (const args of [['--until', '585', '--fields', 'player'], ['--fields', 'player'], ['--until', '585'], ['--ignore', 'steps', '--fields', 'player'], []]) {
    const r = cmp(ref, empty, ...args);
    assert.equal(r.code, 1, `empty port trace with ${args.join(' ')}\n${r.text}`);
    assert.match(r.text, /steps, first at step 1, field count/);
  }
  assert.match(cmp(ref, empty, '--fields', 'player').text, /no step is compared: steps 1\.\.0/);
  assert.throws(() => cmp(ref, empty, '--until', '0'), /--from 1 is after --until 0/);
  // two empty traces compare nothing, which is not a pass either
  assert.equal(cmp(empty, empty, '--fields', 'player').code, 1);
  assert.equal(cmp(empty, empty, '--ignore', 'steps', '--fields', 'player,steps').code, 1);
  // --from past the end of both traces
  const eight = make('eight.jsonl', 'godot-port', base(8));
  const r = cmp(eight, eight, '--from', '9');
  assert.equal(r.code, 1);
  assert.match(r.text, /no step is compared: steps 9\.\.8/);
  assert.equal(cmp(eight, eight, '--from', '8').code, 0, 'the last step alone is a valid range');
  assert.throws(() => cmp(ref, ref, '--from', '6', '--until', '4'), /--from 6 is after --until 4/);
});

check('selecting a field of an entity list also compares the list length; particles are effects-only', () => {
  const extra = base(10); extra[3].enemies.push(enemy(3, 30)); extra[3].counts.enemies = 3;
  const p = make('p12.jsonl', 'godot-port', extra);
  for (const fields of ['enemies.x', 'enemies.kind,enemies.id', 'enemies']) {
    const r = cmp(ref, p, '--fields', fields);
    assert.equal(r.code, 1, fields);
    assert.match(r.text, /enemies, first at step 4, field length/);
  }
  assert.equal(cmp(ref, p, '--fields', 'enemies.x', '--ignore', 'enemies.length').code, 0, 'an explicit --ignore enemies.length is respected');
  assert.equal(cmp(ref, p, '--fields', 'enemies.x', '--ignore', 'enemies.x').code, 1, 'ignoring the field leaves the length check');
  // counts.particles: effects only
  const fx = base(10); fx[5].counts.particles = 7;
  const q = make('p13.jsonl', 'godot-port', fx);
  assert.equal(cmp(ref, q).code, 0, 'the default selection leaves the particle count out');
  assert.equal(cmp(ref, q, '--fields', 'counts').code, 0, 'so does the counts group selector');
  const named = cmp(ref, q, '--fields', 'counts.particles');
  assert.equal(named.code, 1);
  assert.match(named.text, /counts, first at step 6, field particles/);
  // the other counts are compared by default
  const wrong = base(10); wrong[5].counts.projectiles = 1;
  assert.equal(cmp(ref, make('p14.jsonl', 'godot-port', wrong)).code, 1);
});

check('NaN equals NaN, +0 does not equal -0, --json is parseable', () => {
  const a = base(3); a[1].player[0] = F(NaN);
  const b = base(3); b[1].player[0] = '7ff8000000000001'; // another NaN payload
  const fa = make('n1.jsonl', 'original-chromium', a); const fb = make('n2.jsonl', 'godot-port', b);
  assert.equal(cmp(fa, fb).code, 0);
  const c = base(3); c[0].player[0] = F(0); const d = base(3); d[0].player[0] = F(-0);
  const r = cmp(make('z1.jsonl', 'original-chromium', c), make('z2.jsonl', 'godot-port', d), '--fields', 'player.x');
  assert.equal(r.code, 1);
  assert.match(r.text, /differs only in the sign of zero/);
  const json = JSON.parse(cmp(fa, fb, '--json').text);
  assert.equal(json.diverged, 0);
});

check('wrong format and missing files are errors', () => {
  const bad = path.join(dir, 'bad.jsonl'); fs.writeFileSync(bad, '{"format":"other"}\n');
  assert.throws(() => cmp(bad, ref), /format is "other"/);
  assert.throws(() => cmp(path.join(dir, 'nope'), ref), /ENOENT/);
});

check('the boundaries in the header of every committed reference trace equal firstEffects() (the Godot test checks the other implementation)', () => {
  const referenceDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'godot', 'tests', 'reference');
  const files = fs.readdirSync(referenceDir).filter((f) => f.endsWith('.jsonl.gz')).sort();
  assert.ok(files.length >= 7, `6 standard traces and a long run are committed (found ${files.length})`);
  for (const file of files) {
    const trace = readTrace(path.join(referenceDir, file));
    assert.deepEqual(trace.header.boundaries, firstEffects(trace), file);
    assert.deepEqual(trace.header.stats.never_defined, [], `${file}: no field was always undefined`);
  }
});
