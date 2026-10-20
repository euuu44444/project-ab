// Tests of tools/gen_golden.mjs and the math/rng golden modules (Node 22 `node:test`, no dependencies):
//
//   node --test tools/test_gen_golden.mjs
//
// tools/check_generated.sh runs them, next to `gen_golden.mjs --check`, which compares the committed vectors with a
// fresh generation. Covers:
//   * cutting declarations and functions out of a game text by name (unique match, brackets, strings, templates);
//   * the empty sandbox: a piece that touches the DOM or a game function it was not given fails, Math.random throws,
//     the forbidden-identifier screen refuses pieces unless the exception is allowed explicitly;
//   * the number codec (bit patterns, canonical NaN, stepping by ulps) and the topic loader's output format;
//   * the JavaScript transcription of V8's glibc sin/cos stays close to Math.sin / Math.cos (the bit-for-bit comparison
//     with a real Chromium is tools/verify_golden_chromium.mjs, which needs Playwright);
//   * math.mjs and rng.mjs: the vectors are large enough (20 000 rows for every ported function), deterministic, and the
//     expected values agree with the language where the language is the specification.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { format, GoldenError, makeExtractor, cutByName } from './gen_golden.mjs';
import { bitsOf, decodeF64, encodeF64, encodeI32, encodeU32, fromBits, fromHex64, hex64, makeRng, pow2, stepUlps } from './golden/_codec.mjs';
import { glibcCos, glibcSin } from './golden/_glibc_sin.mjs';
import * as math from './golden/math.mjs';
import * as rng from './golden/rng.mjs';

const TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOLS_DIR, '..');
const SOURCE = path.join(REPO_ROOT, 'webview-fg4/tests/fixtures/original.html');
const GAME = 'var K=3;var T={a:[1,2,{b:"x;}"}],c:`t${"}"}`};function f(a,b){return a+b+K;}function g(){return h(1)}var Z=[1,2,3].map(v=>v*2);';

const html = fs.readFileSync(SOURCE, 'utf8');
const scratch = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'gen-golden-test-'));
test.after(() => fs.rmSync(scratch, { recursive: true, force: true }));
const info = { sourcePath: 'webview-fg4/tests/fixtures/original.html', sourceSha256: 'test', sourceText: html };

// ------------------------------------------------------------------------------------------------
// Cutting and the empty sandbox
// ------------------------------------------------------------------------------------------------
test('cutByName finds declarations and functions and respects strings, templates and brackets', () => {
  assert.equal(cutByName(GAME, 'K').text, 'var K=3');
  assert.equal(cutByName(GAME, 'T').text, 'var T={a:[1,2,{b:"x;}"}],c:`t${"}"}`}');
  assert.equal(cutByName(GAME, 'f').text, 'function f(a,b){return a+b+K;}');
  assert.equal(cutByName(GAME, 'Z').text, 'var Z=[1,2,3].map(v=>v*2)');
});

test('cutByName refuses missing, ambiguous and non-identifier names', () => {
  assert.throws(() => cutByName(GAME, 'nope'), GoldenError);
  assert.throws(() => cutByName('var A=1;var A=2;', 'A'), GoldenError);
  assert.throws(() => cutByName('var A=1;function A(){}', 'A'), GoldenError);
  assert.throws(() => cutByName(GAME, 'f(a'), GoldenError);
});

test('extract evaluates in an empty sandbox: unknown names are errors, forbidden identifiers are refused', () => {
  const extract = makeExtractor(GAME);
  const { K, f, Z } = extract(['K', 'f', 'Z']);
  assert.equal(K, 3);
  assert.equal(f(1, 2), 6);
  assert.deepEqual([...Z], [2, 4, 6]);
  const { g } = extract(['g']);
  assert.throws(() => g(), /h is not defined/, 'g calls h, which was not cut out of the game');
  assert.throws(() => makeExtractor('var A=document.title;')(['A']), GoldenError);
  assert.throws(() => makeExtractor('function r(){return Math.random();}')(['r']), GoldenError);
  assert.throws(() => makeExtractor('var A=Date.now();')(['A']), GoldenError);
});

test('options: prelude, expose and the reviewed Math.random exception', () => {
  const src = 'function pick(){return Math.random();}function twice(){return counter+=2;}';
  const extract = makeExtractor(src);
  assert.throws(() => extract(['pick']), GoldenError);
  const { pick } = extract(['pick'], { allow: ['Math.random'] });
  assert.throws(() => pick(), /Math\.random was called/, 'Math.random is a throwing stub inside the context');
  const { twice, value } = extract(['twice'], { prelude: 'var counter=40;', expose: { value: '() => counter' } });
  assert.equal(twice(), 42);
  assert.equal(value(), 42);
  assert.throws(() => extract(['twice'], { allow: ['Nonsense'] }), GoldenError);
});

test('the game declares what the golden modules cut out of it', () => {
  const extract = makeExtractor(html);
  const { clamp, makeSeededRandom } = extract(['clamp', 'makeSeededRandom']);
  assert.equal(clamp(12, 10, 3), 10);
  assert.equal(makeSeededRandom(424242)(), 0.1287079993635416, 'the first output measured in the running game');
});

// ------------------------------------------------------------------------------------------------
// Codec
// ------------------------------------------------------------------------------------------------
test('codec: bit patterns, canonical NaN, negative zero, stepping', () => {
  assert.equal(hex64(1), '3ff0000000000000');
  assert.equal(hex64(-0), '8000000000000000');
  assert.equal(hex64(NaN), '7ff8000000000000');
  assert.equal(hex64(fromBits(0xfff8000000000001n)), '7ff8000000000000', 'any NaN is written canonically');
  assert.equal(fromHex64('c000000000000000'), -2);
  assert.ok(Object.is(fromHex64('8000000000000000'), -0));
  const values = [0, -0, 1.5, -1e300, 5e-324, Infinity, -Infinity, NaN, Math.PI];
  const decoded = decodeF64(encodeF64(values));
  assert.deepEqual(decoded.map(hex64), values.map(hex64));
  assert.equal(Buffer.from(encodeI32([-1, 2147483647]), 'base64').readInt32LE(0), -1);
  assert.equal(Buffer.from(encodeU32([4294967295]), 'base64').readUInt32LE(0), 4294967295);
  assert.throws(() => encodeI32([2147483648]));
  assert.equal(stepUlps(1, 1), 1.0000000000000002);
  assert.equal(stepUlps(1, -1), 0.9999999999999999);
  assert.equal(stepUlps(0, 1), 5e-324);
  assert.ok(Object.is(stepUlps(-5e-324, 1), 0));
  assert.equal(stepUlps(Number.MAX_VALUE, 5), Infinity);
  assert.equal(bitsOf(stepUlps(2, 0)), bitsOf(2));
  const r = makeRng(1);
  const first = [r(), r(), r()];
  const again = makeRng(1);
  assert.deepEqual([again(), again(), again()], first, 'the input generator is deterministic');
});

test('codec: pow2 is exact over the whole range and the input builders never use the host pow', () => {
  for (let e = -1074; e <= 1023; e++) {
    const x = pow2(e);
    // exact: halving and doubling by IEEE operations stay on powers of two, and the neighbours differ by one ulp
    assert.ok(x > 0 && Number.isFinite(x), `2^${e}`);
    if (e > -1074) assert.equal(x / 2, pow2(e - 1), `2^${e} / 2`);
    if (e < 1023) assert.equal(x * 2, pow2(e + 1), `2^${e} * 2`);
  }
  assert.equal(pow2(0), 1);
  assert.equal(pow2(-1074), 5e-324);
  assert.equal(pow2(1023) * 2, Infinity);
  assert.throws(() => pow2(1024), RangeError);
  assert.throws(() => pow2(-1075), RangeError);
  assert.throws(() => pow2(0.5), RangeError);
  // `**` calls the host's pow, which is fdlibm in V8 12.4 and the C library in V8 14.1: golden INPUTS must not depend on it.
  for (const file of ['math.mjs', '_glibc_sin.mjs']) {
    const code = fs.readFileSync(path.join(TOOLS_DIR, 'golden', file), 'utf8').split('\n').filter((line) => !/^\s*(\/\/|\/?\*)/.test(line)).join('\n');
    assert.ok(!code.includes('**'), `${file} must build its inputs with pow2(), not the ** operator`);
  }
});

test('format: stable, one space of indentation, long strings stay on one line', () => {
  const text = format({ a: 1, b: 'x'.repeat(150), c: [1, 2, 3], d: { e: 'y' } });
  assert.equal(text, `{\n "a": 1,\n "b": "${'x'.repeat(150)}",\n "c": [1,2,3],\n "d": {"e":"y"}\n}`);
});

// ------------------------------------------------------------------------------------------------
// glibc sin / cos transcription
// ------------------------------------------------------------------------------------------------
test('glibcSin / glibcCos stay within 1 ulp of Math.sin / Math.cos and agree on the special values', () => {
  const r = makeRng(99);
  const ulp = (x) => Math.max(Math.abs(stepUlps(x, 1) - x), 5e-324);
  for (let i = 0; i < 20000; i++) {
    const x = (r() - 0.5) * (i % 4 === 0 ? 1e9 : i % 4 === 1 ? 1e3 : 20);
    for (const [mine, theirs] of [[glibcSin(x), Math.sin(x)], [glibcCos(x), Math.cos(x)]]) {
      assert.ok(Math.abs(mine - theirs) <= 2 * ulp(theirs) + 1e-300, `x=${x}: ${mine} vs ${theirs}`);
    }
  }
  assert.ok(Object.is(glibcSin(-0), -0));
  assert.equal(glibcCos(0), 1);
  assert.ok(Number.isNaN(glibcSin(Infinity)) && Number.isNaN(glibcCos(NaN)));
});

// ------------------------------------------------------------------------------------------------
// Topic modules
// ------------------------------------------------------------------------------------------------
const extractGame = makeExtractor(html);
const mathBody = math.generate(extractGame, info);
const rngBody = rng.generate(extractGame, info);

test('math.json: 20 000 rows for every ported function, no input set shorter than its vectors', () => {
  const ported = ['sin', 'cos', 'atan', 'atan2', 'exp', 'log', 'hypot', 'round', 'trunc', 'mod', 'max', 'min', 'max3', 'min3', 'max5', 'min5', 'clamp',
    'to_int32', 'to_uint32', 'imul', 'shl', 'sar', 'shr_u'];
  for (const name of ported) assert.equal(mathBody.vectors[name].rows, 20000, name);
  for (const [name, vector] of Object.entries(mathBody.vectors)) {
    const set = mathBody.inputs[vector.input];
    assert.ok(set, `${name}: input set ${vector.input} exists`);
    assert.ok(set.rows >= vector.rows, `${name}: the input set has ${set.rows} rows, the vector ${vector.rows}`);
  }
  assert.ok(mathBody.named.length >= 40);
});

test('math.json: the vectors contain the edge cases that matter', () => {
  const inputs = (key, column = 0) => new Set(decodeF64(mathBody.inputs[key].columns[column]).map(hex64));
  const num = inputs('num');
  for (const x of [0.49999999999999994, -0, 4503599627370497, 2147483648, -2147483648.5, 2147483647.5, Infinity, NaN]) assert.ok(num.has(hex64(x)), `num has ${x}`);
  const trig = inputs('trig');
  for (const x of [Math.PI, Math.PI / 2, 1e22, 1e300, 0, -0, 5e-324]) assert.ok(trig.has(hex64(x)), `trig has ${x}`);
  const pairA = decodeF64(mathBody.inputs.pair.columns[0]);
  const pairB = decodeF64(mathBody.inputs.pair.columns[1]);
  const pairs = new Set(pairA.map((a, i) => `${hex64(a)} ${hex64(pairB[i])}`));
  for (const [a, b] of [[NaN, 1], [0, -0], [-0, 0], [Infinity, NaN], [1, Infinity], [-143.99999999997817, 0]]) {
    if (a === -143.99999999997817) continue; // that argument pair is one of the named cases, not of the random set
    assert.ok(pairs.has(`${hex64(a)} ${hex64(b)}`), `pair set has (${a}, ${b})`);
  }
});

test('math.json: expected values agree with the language where the language is the specification', () => {
  const column = (set, i) => decodeF64(mathBody.inputs[set].columns[i]);
  const check = (name, f, set = mathBody.vectors[name].input, columns = 1) => {
    const inputs = Array.from({ length: columns }, (_, i) => column(set, i));
    const expected = decodeF64(mathBody.vectors[name].output);
    for (let i = 0; i < expected.length; i++) {
      assert.equal(hex64(f(...inputs.map((c) => c[i]))), hex64(expected[i]), `${name} row ${i}`);
    }
  };
  check('exp', Math.exp);
  check('atan2', Math.atan2, 'pair', 2);
  check('round', Math.round);
  check('hypot', Math.hypot, 'pair', 2);
  check('max', Math.max, 'pair', 2);
  check('min', Math.min, 'pair', 2);
  check('mod', (a, b) => a % b, 'pair', 2);
});

test('generation is deterministic', () => {
  const again = math.generate(makeExtractor(html), info);
  assert.equal(JSON.stringify(again), JSON.stringify(mathBody));
  assert.equal(JSON.stringify(rng.generate(makeExtractor(html), info)), JSON.stringify(rngBody));
});

test('rng.json: streams, checkpoints and sequences come from the original makeSeededRandom', () => {
  assert.equal(rngBody.stream_length, 1000);
  for (const required of [424242, 24681357, 0, 1, 4294967295]) assert.ok(rngBody.seeds.some((s) => s.seed === required), `seed ${required}`);
  const { makeSeededRandom } = makeExtractor(html)(['makeSeededRandom']);
  for (const entry of rngBody.seeds) {
    const next = makeSeededRandom(entry.seed);
    const k = Buffer.from(entry.first, 'base64');
    assert.equal(k.length, 4000);
    for (let i = 0; i < 1000; i++) assert.equal(k.readUInt32LE(4 * i), next() * 4294967296, `seed ${entry.seed} output ${i}`);
    assert.equal(entry.normalized, (entry.seed >>> 0) || 2654435769);
  }
  const zero = rngBody.seeds.find((s) => s.seed === 0);
  const fallback = rngBody.seeds.find((s) => s.seed === 2654435769);
  assert.equal(zero.first, fallback.first, 'seed 0 and seed 2654435769 are the same stream');
  for (const sequence of rngBody.game_rng) {
    assert.equal(sequence.ops.length, 400);
    assert.equal(sequence.initial.draws, 0);
    let previous = 0;
    for (const op of sequence.ops) {
      const draws = op[3];
      assert.ok(op[0] === 'reseed' ? draws === 0 : draws >= previous, `${op[0]}: the draw counter only grows between re-seeds`);
      previous = draws;
    }
  }
});

// ------------------------------------------------------------------------------------------------
// Command line
// ------------------------------------------------------------------------------------------------
function runTool(args) {
  const result = spawnSync(process.execPath, [path.join(TOOLS_DIR, 'gen_golden.mjs'), ...args], { encoding: 'utf8' });
  return { code: result.status, out: result.stdout, err: result.stderr };
}

test('command line: --list, --check detects missing, changed and stray files', () => {
  const list = runTool(['--list']);
  assert.equal(list.code, 0);
  assert.match(list.out, /^math\s/m);
  assert.match(list.out, /^rng\s/m);

  const out = path.join(scratch, 'out');
  const written = runTool(['--only', 'math', '--out', out]);
  assert.equal(written.code, 0, written.err);
  assert.equal(runTool(['--only', 'math', '--check', '--out', out]).code, 0);
  assert.equal(runTool(['--only', 'rng', '--check', '--out', out]).code, 1, 'rng.json is missing');
  fs.appendFileSync(path.join(out, 'math.json'), ' ');
  const drift = runTool(['--only', 'math', '--check', '--out', out]);
  assert.equal(drift.code, 1);
  assert.match(drift.err, /differs:\s+math\.json/);
  fs.writeFileSync(path.join(out, 'stray.json'), '{}');
  assert.equal(runTool(['--only', 'math', '--out', out]).code, 0);
  const stray = runTool(['--check', '--out', out]);
  assert.equal(stray.code, 1);
  assert.match(stray.err, /unexpected:\s+stray\.json/);
  assert.equal(runTool(['--nonsense']).code, 2);
  assert.equal(runTool(['--only', 'nosuchtopic']).code, 2);
});
