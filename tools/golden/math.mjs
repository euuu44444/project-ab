// Golden vectors for godot/sim/js_compat.gd (class JsMath): the JavaScript numerics that the original game relies on
// (Math.sin/cos/atan/atan2/exp/log/hypot/round/trunc/max/min/pow, %, |0, >>>0, Math.imul, shifts, clamp).
//
// Reference. The port is checked against Chromium 141 (V8 14.1.146.11), the browser that records the reference
// traces (design section 9.2). The expected values come from JavaScript, in two ways:
//   * atan, atan2, exp, log, hypot, round, trunc, floor, ceil, sqrt, abs, max, min, %, |0, >>>0, Math.imul, <<, >>, >>>:
//     the Math function or operator of the Node that runs this generator. V8 12.4 (Node 22) and V8 14.1 (Chromium 141)
//     give identical bits for all of them (fdlibm ports in src/base/ieee754.cc, IEEE operations, Torque/CSA builtins),
//     measured on 200 000 or more inputs per function. CANARIES below catch a Node whose Math differs.
//   * sin and cos: Node 22 is built with gcc and uses fdlibm, which differs from Chromium (clang build, glibc s_sin.c
//     via V8's use_libm_trig_functions) in the last bit for 3% of the inputs. They are computed by
//     tools/golden/_glibc_sin.mjs, a JavaScript transcription of V8's copy of glibc s_sin.c / branred.c.
//   * clamp: the game's own function, cut out of original.html (like every golden value that can be).
// tools/verify_golden_chromium.mjs runs every vector of the committed math.json through the real Math of a Chromium
// (Playwright) and fails on any bit that differs. It needs Playwright and is therefore not part of tools/check_generated.sh.
//
// Inputs are fixed by the generator (deterministic pseudo-random numbers plus hand-built edge cases: thresholds of the
// algorithms +-20 ulp, multiples of pi/2 and pi/4 +-20 ulp, 0.5 boundaries, 2^52, int32 limits, +-0, +-Infinity, NaN).
// Everything is stored as bit patterns (see _codec.mjs).
import { glibcCos, glibcSin } from './_glibc_sin.mjs';
import { encodeF64, encodeI32, encodeU32, fromWords, hex64, makeRng, pow2, stepUlps } from './_codec.mjs';
import { CANARIES } from './_canaries.mjs';

export const name = 'math';

const N = 20000; // samples per ported function
const N_TUPLES = N; // rows of the 3 and 5 argument sets (also 20 000: every ported function gets the full count)
const N_BUILTIN = 2048; // samples of the functions that Godot already implements exactly (sqrt, floor, ceil, abs)

const PI = Math.PI;
const SPECIALS = [0, -0, 1, -1, 2, -2, 3, 5, -5, 0.5, -0.5, Infinity, -Infinity, NaN, Number.MIN_VALUE, -Number.MIN_VALUE,
  Number.MAX_VALUE, -Number.MAX_VALUE, 1e-300, -1e-300, 1e300, 2.2250738585072014e-308];

// ---------------------------------------------------------------------------------------------------
// Input sets
// ---------------------------------------------------------------------------------------------------
function builder(seed, size) {
  const rng = makeRng(seed);
  const values = [];
  return {
    rng,
    values,
    uniform: (lo, hi) => lo + rng() * (hi - lo),
    push: (...xs) => { for (const x of xs) values.push(x); },
    /** sign * mantissa in [1, 2) * 2^e, e an integer in [eLo, eHi] */
    wide: (eLo, eHi) => (rng() < 0.5 ? -1 : 1) * (1 + rng()) * pow2(eLo + Math.floor(rng() * (eHi - eLo + 1))),
    size,
    finish() {
      if (values.length > size) throw new Error(`edge cases (${values.length}) exceed the set size (${size})`);
      return values;
    },
  };
}

/** All nearby values of each base: base +- 0..20 ulp steps (both signs of the base). */
function aroundThresholds(b, bases, steps = [-20, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13, 20], withNegative = true) {
  for (const base of bases) for (const d of steps) {
    b.push(stepUlps(base, d));
    if (withNegative) b.push(-stepUlps(base, d));
  }
}

function trigInputs() {
  const b = builder(0x7a1b0001, N);
  b.push(...SPECIALS);
  // thresholds of s_sin.c / s_cos.c: 2^-26, 2^-27, 0.855469, 2.426265, 105414350
  aroundThresholds(b, [fromWords(0x3e500000), fromWords(0x3e400000), fromWords(0x3feb6000), fromWords(0x400368fd), fromWords(0x419921fb)],
    Array.from({ length: 41 }, (_, i) => i - 20));
  // multiples of pi/2 and pi/4 +- a few ulp: where the argument reduction cancels
  for (let k = -64; k <= 64; k++) {
    for (const base of [k * PI / 2, k * PI / 4]) aroundThresholds(b, [base], [-20, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13, 20], false);
  }
  // large arguments (branred) and the exact powers of two and ten
  for (let e = 27; e <= 1023; e += 12) b.push(pow2(e), -pow2(e), stepUlps(pow2(e), 1), 1.5 * pow2(e));
  for (const e of [9, 15, 22, 100, 200, 300]) b.push(Number(`1e${e}`), -Number(`1e${e}`));
  b.push(1e9, 105414357, 1e10, 4294967296, pow2(53), -pow2(53));
  // the ranges the game produces
  for (let i = 0; i < 4000; i++) b.push(b.uniform(-10, 10));
  for (let i = 0; i < 2000; i++) b.push(b.uniform(0, 2 * PI));
  for (let i = 0; i < 2000; i++) b.push(b.uniform(-30000, 30000));
  for (let i = 0; i < 1000; i++) b.push(b.uniform(-1e6, 1e6));
  for (let i = 0; i < 500; i++) b.push(b.wide(-60, -20));
  for (let i = 0; i < 500; i++) b.push(b.wide(-1074, -60));
  for (let i = 0; i < 1500; i++) b.push(b.wide(27, 200));
  for (let i = 0; i < 500; i++) b.push(b.wide(200, 1023));
  while (b.values.length < N) b.push(b.uniform(-100, 100));
  return b.finish();
}

function atanInputs() {
  const b = builder(0x7a1b0002, N);
  b.push(...SPECIALS);
  // fdlibm atan branch thresholds: 7/16, 11/16, 19/16, 39/16, 2^66, 2^-27
  aroundThresholds(b, [fromWords(0x3fdc0000), fromWords(0x3fe60000), fromWords(0x3ff30000), fromWords(0x40038000), fromWords(0x44100000), fromWords(0x3e400000)]);
  for (let i = 0; i < 6000; i++) b.push(b.uniform(-50, 50));
  for (let i = 0; i < 5000; i++) b.push(b.wide(-70, 80));
  for (let i = 0; i < 2000; i++) b.push(b.uniform(-3, 3));
  while (b.values.length < N) b.push(b.uniform(-1000, 1000));
  return b.finish();
}

function expInputs() {
  const b = builder(0x7a1b0003, N);
  const ln2 = Math.LN2;
  b.push(...SPECIALS, 1, -1, pow2(-28), -pow2(-28), pow2(-29));
  // fdlibm exp thresholds: 0.5 ln2, 1.5 ln2, 2^-28, 709.78 (overflow), -745.13 (underflow), 0x40862e42
  aroundThresholds(b, [fromWords(0x3fd62e43), fromWords(0x3ff0a2b2), fromWords(0x3e300000), fromWords(0x40862e42), 709.782712893384, 745.1332191019411]);
  for (let k = -1080; k <= 1030; k += 5) b.push(k * ln2, stepUlps(k * ln2, 1), stepUlps(k * ln2, -1), (k + 0.5) * ln2);
  for (let i = 0; i < 2000; i++) b.push(b.uniform(-1, 0));
  for (let i = 0; i < 2000; i++) b.push(b.uniform(-5, 0));
  for (let i = 0; i < 3000; i++) b.push(b.uniform(-30, 30));
  for (let i = 0; i < 3000; i++) b.push(b.uniform(-750, 720));
  for (let i = 0; i < 1000; i++) b.push(b.wide(-60, -26));
  while (b.values.length < N) b.push(b.uniform(-50, 50));
  return b.finish();
}

function logInputs() {
  const b = builder(0x7a1b0004, N);
  b.push(...SPECIALS, 1, Math.E, 0.5, 10, pow2(-1022), pow2(-1023), pow2(1023));
  // fdlibm log reduces x to [sqrt(2)/2, sqrt(2)]; 0x95F64 and 0x6147A, 0x6B851 are the mantissa thresholds
  aroundThresholds(b, [1, Math.SQRT2, Math.SQRT1_2, 2, 0.5, fromWords(0x3ff6a09e, 0x667f3bcd), fromWords(0x3ff00000, 0)], undefined, false);
  for (let i = 0; i < 3000; i++) b.push(stepUlps(1, Math.floor(b.uniform(-3000, 3000))));
  for (let i = 0; i < 4000; i++) b.push(b.uniform(0, 4));
  for (let i = 0; i < 3000; i++) b.push(b.uniform(0, 1e6));
  for (let i = 0; i < 3000; i++) b.push(Math.abs(b.wide(-1074, 1023)));
  for (let i = 0; i < 500; i++) b.push(-Math.abs(b.wide(-30, 30)));
  while (b.values.length < N) b.push(b.uniform(0, 100));
  return b.finish();
}

/** Two-argument sets: atan2(y, x), hypot(a, b), a % b, Math.max(a, b), Math.min(a, b) all read the pairs (a, b). */
function pairInputs() {
  const b = builder(0x7a1b0005, N);
  const A = [];
  const B = [];
  const add = (a, c) => { A.push(a); B.push(c); };
  for (const a of SPECIALS) for (const c of SPECIALS) add(a, c);
  for (let i = 0; i < 3000; i++) add(b.uniform(-1000, 1000), b.uniform(-1000, 1000));
  for (let i = 0; i < 1500; i++) add(b.uniform(-300, 300), b.uniform(-300, 300));
  for (let i = 0; i < 1500; i++) add(b.uniform(-26000, 26000), b.uniform(-26000, 26000));
  for (let i = 0; i < 1500; i++) add(b.wide(-1074, 1023), b.wide(-1074, 1023));
  for (let i = 0; i < 1200; i++) { const e = Math.floor(b.uniform(-900, 900)); add(b.wide(e, e + 30), b.wide(e, e + 30)); }
  // atan2: |y/x| near 2^59 and 2^-59, where fdlibm switches to a closed form; x = +-1
  for (let i = 0; i < 1200; i++) {
    const x = b.uniform(-100, 100) || 1;
    const scale = [pow2(59), pow2(-59), pow2(60), pow2(-60), pow2(58), pow2(-58)][i % 6];
    add(stepUlps(x * scale, Math.floor(b.uniform(-3, 4))), x);
  }
  for (let i = 0; i < 200; i++) add(b.uniform(-100, 100), i % 2 === 0 ? 1 : -1);
  // equal and adjacent values (max, min, hypot, atan2)
  for (let i = 0; i < 300; i++) { const v = b.wide(-40, 40); add(v, v); add(v, -v); }
  for (let i = 0; i < 600; i++) { const v = b.wide(-40, 40); add(v, stepUlps(v, 1 + (i % 3))); }
  // zeros against values
  for (let i = 0; i < 200; i++) { const v = b.uniform(-50, 50); add(i % 2 === 0 ? 0 : -0, v); add(v, i % 2 === 0 ? -0 : 0); }
  // remainders: fractions, integers, exact multiples (sign of a zero result), walkPhase % 1e4, (dayPhase + ...) % 1
  for (let i = 0; i < 1500; i++) add(b.uniform(-1e5, 1e5), b.wide(-10, 13)); // divisors from about 0.001 to 16000, both signs
  for (let i = 0; i < 800; i++) add(Math.floor(b.uniform(-1000, 1000)), Math.floor(b.uniform(-20, 20)));
  for (let i = 0; i < 300; i++) { const d = Math.floor(b.uniform(1, 30)) * (i % 2 === 0 ? 1 : -1); add(d * Math.floor(b.uniform(-50, 50)), d); }
  for (let i = 0; i < 200; i++) add(b.uniform(0, 20000), 1e4);
  for (let i = 0; i < 200; i++) add(b.uniform(0, 2), 1);
  if (A.length > N) throw new Error(`pair edge cases (${A.length}) exceed ${N}`);
  while (A.length < N) add(b.uniform(-100, 100), b.uniform(-100, 100));
  return { a: A, b: B };
}

/** One-argument integer-ish set: round, trunc, floor, ceil, sqrt, abs, ToInt32, ToUint32. */
function numInputs() {
  const b = builder(0x7a1b0006, N);
  b.push(...SPECIALS, 0.49999999999999994, -0.49999999999999994, 0.5000000000000001, -0.5000000000000001, 4503599627370497, 4503599627370495.5,
    -4503599627370497, 9007199254740991, 9007199254740993, 4294967295.5, -4294967296.5, 2147483647.5, -2147483648.5);
  // k + 0.5 and its neighbours, where rounding goes up or down
  for (let k = -200; k <= 200; k++) aroundThresholds(b, [k + 0.5], [-2, -1, 0, 1, 2], false);
  // 32-bit limits and powers of two, with fractions
  for (const base of [2147483648, 4294967296, pow2(53), pow2(52), pow2(63), pow2(64), pow2(31) - 1, pow2(32) - 1]) {
    aroundThresholds(b, [base], [-3, -2, -1, 0, 1, 2, 3]);
    b.push(base + 0.5, -base - 0.5, base - 0.5);
  }
  for (let e = 0; e <= 1023; e += 9) b.push(pow2(e), -pow2(e), pow2(e) + 1, 3 * pow2(e));
  for (let i = 0; i < 3000; i++) b.push(b.uniform(-1000, 1000));
  for (let i = 0; i < 2500; i++) b.push(b.uniform(-1.5, 1.5));
  for (let i = 0; i < 2500; i++) b.push(b.uniform(-8589934592, 8589934592));
  for (let i = 0; i < 1500; i++) b.push(Math.floor(b.uniform(-4294967296, 8589934592)));
  for (let i = 0; i < 1500; i++) b.push(b.wide(0, 1023));
  for (let i = 0; i < 700; i++) b.push(b.wide(-1074, -1));
  while (b.values.length < N) b.push(b.uniform(-100000, 100000));
  return b.finish();
}

/** Integer-valued pairs for Math.imul (any integer a double holds exactly: int32, uint32 and beyond). */
function imulInputs() {
  const b = builder(0x7a1b0007, N);
  const A = [];
  const B = [];
  const add = (a, c) => { A.push(a); B.push(c); };
  const limits = [0, 1, -1, 2, -2, 65535, 65536, -65536, 2147483647, -2147483648, 2147483646, -2147483647, 4294967295, 4294967296, 2654435769, 1831565813,
    61, 1 << 15, 3, 7, 4294967294, pow2(53) - 1, -(pow2(53) - 1), pow2(40), -pow2(40) - 1];
  for (const a of limits) for (const c of limits) add(a, c);
  const int32 = () => Math.floor(b.uniform(-2147483648, 2147483648));
  const uint32 = () => Math.floor(b.uniform(0, 4294967296));
  const wideInt = () => Math.floor(b.uniform(-pow2(53), pow2(53)));
  for (let i = 0; i < 6000; i++) add(int32(), int32());
  for (let i = 0; i < 5000; i++) add(uint32(), uint32());
  for (let i = 0; i < 3000; i++) add(wideInt(), wideInt());
  for (let i = 0; i < 2000; i++) add(int32(), Math.floor(b.uniform(-100, 100)));
  if (A.length > N) throw new Error(`imul edge cases (${A.length}) exceed ${N}`);
  while (A.length < N) add(int32(), uint32());
  return { a: A, b: B };
}

/** Shift sets: a (an int32 or uint32 value as JavaScript holds it) and a shift count n, including counts above 31 and negative ones. */
function shiftInputs() {
  const b = builder(0x7a1b0008, N);
  const A = [];
  const C = [];
  const add = (a, n) => { A.push(a); C.push(n); };
  for (const a of [0, 1, -1, 2147483647, -2147483648, 4294967295, 2147483648, 255, -255, 123456789, -123456789]) for (let n = -33; n <= 70; n++) add(a, n);
  while (A.length < N) {
    const r = b.rng();
    const a = r < 0.5 ? Math.floor(b.uniform(-2147483648, 2147483648)) : Math.floor(b.uniform(0, 4294967296));
    add(a, Math.floor(b.uniform(-5, 70)));
  }
  return { a: A, n: C };
}

/** Five-column rows built from the pair set (so they contain NaN, +-0, infinities, equal values) for the 3 and 5 argument max/min and clamp. */
function tupleInputs(pairs) {
  const rng = makeRng(0x7a1b0009);
  const pool = [...pairs.a, ...pairs.b];
  const columns = [[], [], [], [], []];
  for (let i = 0; i < N_TUPLES; i++) for (let c = 0; c < 5; c++) columns[c].push(pool[Math.floor(rng() * pool.length)]);
  return columns;
}

/** Arguments of Math.pow whose result is fixed by IEEE 754 / the ECMAScript special cases (no last-bit libm differences possible). */
function powInputs() {
  const bases = [0, -0, 1, -1, 2, -2, 0.5, -0.5, 3, -3, 10, 4, 9, 16, 1.5, 0.25, Infinity, -Infinity, NaN, 1e300, -1e300, 5e-324, 7];
  const exponents = [0, -0, 1, 2, 0.5, NaN, Infinity, -Infinity];
  const A = [];
  const B = [];
  for (const x of bases) for (const y of exponents) { A.push(x); B.push(y); }
  for (let k = -30; k <= 30; k++) { A.push(2); B.push(k); A.push(-2); B.push(k); A.push(0.5); B.push(k); }
  for (let k = -20; k <= 20; k++) { A.push(4); B.push(k); A.push(1); B.push(k); A.push(-1); B.push(k); }
  return { a: A, b: B };
}

// ---------------------------------------------------------------------------------------------------
// Reference functions
// ---------------------------------------------------------------------------------------------------
const toInt32 = (x) => x | 0;
const toUint32 = (x) => x >>> 0;

function checkCanaries() {
  const reference = { exp: Math.exp, atan2: Math.atan2, atan: Math.atan, log: Math.log, hypot: Math.hypot };
  for (const [fn, args, expected] of CANARIES) {
    if (expected === null) continue;
    const got = hex64(reference[fn](...args));
    if (got !== expected) {
      throw new Error(`this Node's Math.${fn}(${args.join(', ')}) = ${got}, Chromium 141 gives ${expected}: the golden vectors would not describe Chromium (use Node 22)`);
    }
  }
}

export function generate(extract, info) {
  checkCanaries();

  // The game's own clamp(v,a,b) = Math.max(a,Math.min(b,v)).
  const { clamp } = extract(['clamp']);

  const inputs = {};
  const vectors = {};
  const addInput = (key, columns, type = 'f64') => {
    const length = columns[0].length;
    for (const c of columns) if (c.length !== length) throw new Error(`input set ${key}: columns differ in length`);
    inputs[key] = { type, rows: length, columns: columns.map((c) => (type === 'f64' ? encodeF64(c) : type === 'i32' ? encodeI32(c) : encodeU32(c))) };
  };
  const addVector = (fn, input, outputType, results, note, rows = results.length) => {
    const encoded = outputType === 'f64' ? encodeF64(results) : outputType === 'i32' ? encodeI32(results) : encodeU32(results);
    vectors[fn] = { input, rows, output_type: outputType, output: encoded, ...(note ? { note } : {}) };
  };
  const map1 = (column, f, limit = column.length) => column.slice(0, limit).map((x) => f(x));
  const map2 = (a, c, f, limit = a.length) => a.slice(0, limit).map((x, i) => f(x, c[i]));

  const trig = trigInputs();
  addInput('trig', [trig]);
  addVector('sin', 'trig', 'f64', map1(trig, glibcSin), 'Chromium 141: glibc s_sin.c (tools/golden/_glibc_sin.mjs)');
  addVector('cos', 'trig', 'f64', map1(trig, glibcCos), 'Chromium 141: glibc s_sin.c (tools/golden/_glibc_sin.mjs)');

  const atanIn = atanInputs();
  addInput('atan', [atanIn]);
  addVector('atan', 'atan', 'f64', map1(atanIn, Math.atan), 'Math.atan');

  const expIn = expInputs();
  addInput('exp', [expIn]);
  addVector('exp', 'exp', 'f64', map1(expIn, Math.exp), 'Math.exp');

  const logIn = logInputs();
  addInput('log', [logIn]);
  addVector('log', 'log', 'f64', map1(logIn, Math.log), 'Math.log');

  const pairs = pairInputs();
  addInput('pair', [pairs.a, pairs.b]);
  addVector('atan2', 'pair', 'f64', map2(pairs.a, pairs.b, Math.atan2), 'Math.atan2(a, b): a is y, b is x');
  addVector('hypot', 'pair', 'f64', map2(pairs.a, pairs.b, Math.hypot), 'Math.hypot(a, b)');
  addVector('mod', 'pair', 'f64', map2(pairs.a, pairs.b, (a, c) => a % c), 'a % b');
  addVector('max', 'pair', 'f64', map2(pairs.a, pairs.b, Math.max), 'Math.max(a, b)');
  addVector('min', 'pair', 'f64', map2(pairs.a, pairs.b, Math.min), 'Math.min(a, b)');

  const num = numInputs();
  addInput('num', [num]);
  addVector('round', 'num', 'f64', map1(num, Math.round), 'Math.round');
  addVector('trunc', 'num', 'f64', map1(num, Math.trunc), 'Math.trunc');
  addVector('to_int32', 'num', 'i32', map1(num, toInt32), 'x | 0');
  addVector('to_uint32', 'num', 'u32', map1(num, toUint32), 'x >>> 0');
  // Godot implements these exactly (IEEE 754); a short vector pins that down on every platform the tests run on.
  addVector('floor', 'num', 'f64', map1(num, Math.floor, N_BUILTIN), 'Math.floor (first rows of the set)', N_BUILTIN);
  addVector('ceil', 'num', 'f64', map1(num, Math.ceil, N_BUILTIN), 'Math.ceil (first rows of the set)', N_BUILTIN);
  addVector('sqrt', 'num', 'f64', map1(num, Math.sqrt, N_BUILTIN), 'Math.sqrt (first rows of the set)', N_BUILTIN);
  addVector('abs', 'num', 'f64', map1(num, Math.abs, N_BUILTIN), 'Math.abs (first rows of the set)', N_BUILTIN);

  const imul = imulInputs();
  addInput('imul', [imul.a, imul.b]);
  addVector('imul', 'imul', 'i32', map2(imul.a, imul.b, Math.imul), 'Math.imul(a, b); the inputs are integers of any size a double holds');

  const shifts = shiftInputs();
  addInput('shift', [shifts.a, shifts.n]);
  addVector('shl', 'shift', 'i32', map2(shifts.a, shifts.n, (a, n) => a << n), 'a << n');
  addVector('sar', 'shift', 'i32', map2(shifts.a, shifts.n, (a, n) => a >> n), 'a >> n');
  addVector('shr_u', 'shift', 'u32', map2(shifts.a, shifts.n, (a, n) => a >>> n), 'a >>> n');

  const tuples = tupleInputs(pairs);
  addInput('tuple', tuples);
  const rows = tuples[0].length;
  const row = (i) => tuples.map((c) => c[i]);
  addVector('max3', 'tuple', 'f64', Array.from({ length: rows }, (_, i) => Math.max(...row(i).slice(0, 3))), 'Math.max(c0, c1, c2)');
  addVector('min3', 'tuple', 'f64', Array.from({ length: rows }, (_, i) => Math.min(...row(i).slice(0, 3))), 'Math.min(c0, c1, c2)');
  addVector('max5', 'tuple', 'f64', Array.from({ length: rows }, (_, i) => Math.max(...row(i))), 'Math.max(c0, c1, c2, c3, c4)');
  addVector('min5', 'tuple', 'f64', Array.from({ length: rows }, (_, i) => Math.min(...row(i))), 'Math.min(c0, c1, c2, c3, c4)');
  addVector('clamp', 'tuple', 'f64', Array.from({ length: rows }, (_, i) => clamp(tuples[0][i], tuples[1][i], tuples[2][i])), 'the game\'s clamp(v, lo, hi) with (v, lo, hi) = (c0, c1, c2)');

  const pow = powInputs();
  addInput('pow', [pow.a, pow.b]);
  addVector('pow', 'pow', 'f64', map2(pow.a, pow.b, Math.pow), 'Math.pow(a, b) restricted to arguments whose result is fixed by IEEE 754 or the ECMAScript special cases');

  return {
    format: 'elemental-swarm-golden-math/1',
    generated_by: 'tools/gen_golden.mjs (tools/golden/math.mjs)',
    reference: 'Chromium 141.0.7390.37, V8 14.1.146.11 (see the header of tools/golden/math.mjs for how each value is obtained)',
    source: info.sourcePath,
    encoding: 'columns: base64 of little-endian arrays: f64 = IEEE-754 binary64 bit patterns (NaN canonical 0x7ff8000000000000), i32/u32 = 32-bit integers',
    inputs,
    vectors,
    named: namedCases(clamp),
  };
}

/**
 * Hand-picked cases that document the pitfalls of the straightforward GDScript translation. The expected values are
 * computed here (JavaScript), not typed: [label, function, [argument bit patterns], result bit pattern].
 */
function namedCases(clamp) {
  const cases = [];
  const add = (label, fn, args, f) => cases.push([label, fn, args.map(hex64), hex64(f(...args))]);
  add('round(0.49999999999999994) is 0, floor(x+0.5) would give 1', 'round', [0.49999999999999994], Math.round);
  add('round(-0.3) keeps the sign of zero', 'round', [-0.3], Math.round);
  add('round(-2.5) rounds toward +Infinity', 'round', [-2.5], Math.round);
  add('round(2.5)', 'round', [2.5], Math.round);
  add('round(4503599627370497) is odd and above 2^52', 'round', [4503599627370497], Math.round);
  add('round(NaN)', 'round', [NaN], Math.round);
  add('max(NaN, 1) is NaN (Godot maxf gives 1)', 'max', [NaN, 1], Math.max);
  add('max(1, NaN) is NaN', 'max', [1, NaN], Math.max);
  add('min(0, -0) is -0', 'min', [0, -0], Math.min);
  add('max(-0, 0) is +0', 'max', [-0, 0], Math.max);
  add('clamp(12, 10, 3) is 10 (lo wins when lo > hi; Godot clampf gives 3)', 'clamp', [12, 10, 3], clamp);
  add('clamp(NaN, 0, 1) is NaN', 'clamp', [NaN, 0, 1], clamp);
  add('clamp(-0, 0, 1) is +0 (max(0, min(1, -0)))', 'clamp', [-0, 0, 1], clamp);
  add('mod(-7.5, 2) takes the sign of the dividend', 'mod', [-7.5, 2], (a, b) => a % b);
  add('mod(-6, 3) is -0', 'mod', [-6, 3], (a, b) => a % b);
  add('mod(5, 0) is NaN', 'mod', [5, 0], (a, b) => a % b);
  add('mod(5, Infinity) is 5', 'mod', [5, Infinity], (a, b) => a % b);
  add('hypot(3, 4) is exactly 5', 'hypot', [3, 4], Math.hypot);
  add('hypot(Infinity, NaN) is Infinity', 'hypot', [Infinity, NaN], Math.hypot);
  add('hypot(1e200, 1e200) does not overflow', 'hypot', [1e200, 1e200], Math.hypot);
  add('hypot(1e-200, 1e-200) does not underflow', 'hypot', [1e-200, 1e-200], Math.hypot);
  add('atan2(-143.99999999997817, 107.99999999995634): the last bit differs in libm (Godot builtin ...335, V8 ...334)', 'atan2', [-143.99999999997817, 107.99999999995634], Math.atan2);
  add('atan2(0, -0) is pi', 'atan2', [0, -0], Math.atan2);
  add('atan2(-0, -0) is -pi', 'atan2', [-0, -0], Math.atan2);
  add('atan2(0, 0) is 0', 'atan2', [0, 0], Math.atan2);
  add('atan2(Infinity, -Infinity)', 'atan2', [Infinity, -Infinity], Math.atan2);
  add('exp(-Infinity) is 0', 'exp', [-Infinity], Math.exp);
  add('exp(709.8) overflows to Infinity', 'exp', [709.8], Math.exp);
  add('exp(-0.55 * (1 / 60)): a damping factor of the enemy steering', 'exp', [-0.55 * (1 / 60)], Math.exp);
  add('sin(Math.PI) is not 0', 'sin', [Math.PI], glibcSin);
  add('cos(Math.PI / 2) is not 0', 'cos', [Math.PI / 2], glibcCos);
  add('sin(1e22)', 'sin', [1e22], glibcSin);
  add('cos(1e300)', 'cos', [1e300], glibcCos);
  add('sin(-0) is -0', 'sin', [-0], glibcSin);
  add('to_int32(2147483648) wraps to -2147483648', 'to_int32', [2147483648], toInt32Pair);
  add('to_int32(-2147483649.9) truncates before wrapping', 'to_int32', [-2147483649.9], toInt32Pair);
  add('to_int32(NaN) is 0', 'to_int32', [NaN], toInt32Pair);
  add('to_int32(1e300) is 0', 'to_int32', [1e300], toInt32Pair);
  add('to_uint32(-1) is 4294967295', 'to_uint32', [-1], (x) => x >>> 0);
  add('to_uint32(4294967296.5) is 0', 'to_uint32', [4294967296.5], (x) => x >>> 0);
  add('imul(4294967295, 2): the arguments are converted with ToInt32 first', 'imul', [4294967295, 2], Math.imul);
  add('imul(-2147483648, -1) wraps', 'imul', [-2147483648, -1], Math.imul);
  add('imul(2654435769, 1831565813)', 'imul', [2654435769, 1831565813], Math.imul);
  add('pow(1, Infinity) is NaN in JavaScript (C pow gives 1)', 'pow', [1, Infinity], Math.pow);
  add('pow(-1, -Infinity) is NaN in JavaScript', 'pow', [-1, -Infinity], Math.pow);
  add('pow(NaN, 0) is 1', 'pow', [NaN, 0], Math.pow);
  add('pow(-0, 0.5) is +0', 'pow', [-0, 0.5], Math.pow);
  add('pow(-Infinity, 0.5) is Infinity', 'pow', [-Infinity, 0.5], Math.pow);
  return cases;
}

/** Math.imul-like int32 result as a double, so it travels through hex64. */
function toInt32Pair(x) {
  return x | 0;
}

