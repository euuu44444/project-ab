#!/usr/bin/env node
// Checks the constants of godot/sim/js_compat.gd (the bit-exact JsMath) against the upstream sources they come from.
//
//   node tools/check_js_compat_consts.mjs          verify; prints "check OK ..." and exits 0, else lists every problem and exits 1
//
// The constants of JsMath are written in the .gd file as `integer / 2^k` expressions (exact, and immune to the engine's
// float-literal parser) and pinned by a second table, CONST_BITS, inside the same file. Both come out of one hand
// transcription, so a mistake made consistently in the expression and in CONST_BITS would pass the Godot test
// (test_js_math.gd::test_constants_match_their_bit_patterns). This script closes that gap. It holds the constants a
// third time, as the literals of the upstream C sources (hex floats of glibc usncs.h; the decimal literals of glibc s_sin.c and of
// V8's src/base/ieee754.cc together with the hex words quoted in their comments; the high-word thresholds), converts them with the
// correctly rounded Number() of this JavaScript engine (what a C compiler does with a decimal literal), and requires that
//
//   1. the expression of every `const NAME: float = ...` of js_compat.gd, evaluated in IEEE double arithmetic (JavaScript
//      and GDScript evaluate `a / b / c` left to right with the same operations),
//   2. the entry of that constant in CONST_BITS, and
//   3. the upstream literal
//
// have the same bit pattern, and that no constant is missing from any of the three. For the two big tables it compares
// SINCOSTAB_BITS and TOVERP with the copies in tools/golden/_glibc_sin.mjs (the transcription behind the golden sin/cos
// vectors, which tools/verify_golden_chromium.mjs checks against the real Math.sin / Math.cos of Chromium).
//
// Sources of the upstream literals: V8 14.1.146.11 (the Chromium 141 of the reference traces): third_party/glibc/sysdeps/
// ieee754/dbl-64/{usncs.h,s_sin.c,branred.h} and src/base/ieee754.cc (fdlibm e_exp.c, e_log.c, s_atan.c, e_atan2.c).
// Needs Node 22 or newer (standard library only). Run by tools/check_generated.sh.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const GD_FILE = path.join(REPO_ROOT, 'godot/sim/js_compat.gd');
const GLIBC_JS = path.join(REPO_ROOT, 'tools/golden/_glibc_sin.mjs');

const dv = new DataView(new ArrayBuffer(8));
const bitsOf = (x) => { dv.setFloat64(0, x); return dv.getBigUint64(0); };
const hex16 = (b) => b.toString(16).padStart(16, '0');
const fromWords = (hi, lo) => { dv.setUint32(0, hi); dv.setUint32(4, lo); return dv.getFloat64(0); };
const fromBits = (hex) => { dv.setBigUint64(0, BigInt('0x' + hex)); return dv.getFloat64(0); };
const pow2 = (k) => fromBits(hex16(BigInt(k + 1023) << 52n)); // normal range only (|k| < 1023), checked below
function hexFloat(text) { // [-]0x1.ABCp-3, exact
  const m = /^(-?)0x([0-9a-f]+)\.?([0-9a-f]*)p([+-]?\d+)$/i.exec(text);
  if (!m) throw new Error(`bad hex float ${text}`);
  const mant = BigInt('0x' + m[2] + m[3]);
  if (BigInt(Number(mant)) !== mant) throw new Error(`mantissa too wide ${text}`);
  const v = Number(mant) * pow2(Number(m[4]) - 4 * m[3].length);
  return m[1] ? -v : v;
}

// --- the upstream literals -------------------------------------------------------------------------------------------
// H(text): a C hex float. D(text, bits): a decimal literal and the bits quoted in the comment next to it (when there is one).
// W(hi, lo): the high and low word of a double (a threshold or a value given as two words). P(k): 2^k.
const H = (text) => ({ value: hexFloat(text), source: text });
const D = (text, bits) => ({ value: Number(text), source: bits ? `${text} (comment ${bits})` : text, bits });
const W = (hi, lo) => ({ value: fromWords(hi, lo), source: `words 0x${hi.toString(16)} 0x${lo.toString(16)}` });
const P = (k) => ({ value: pow2(k), source: `2^${k}` });

const UPSTREAM = {
  P2_60: P(60),
  // glibc usncs.h
  G_S1: H('-0x1.5555555555555p-3'), G_S2: H('0x1.1111111110ECEp-7'), G_S3: H('-0x1.A01A019DB08B8p-13'),
  G_S4: H('0x1.71DE27B9A7ED9p-19'), G_S5: H('-0x1.ADDFFC2FCDF59p-26'), G_BIG: H('0x1.8000000000000p45'),
  G_HP0: H('0x1.921FB54442D18p0'), G_HP1: H('0x1.1A62633145C07p-54'), G_MP1: H('0x1.921FB58000000p0'),
  G_MP2: H('-0x1.DDE973C000000p-27'), G_PP3: H('-0x1.CB3B398000000p-55'), G_PP4: H('-0x1.d747f23e32ed7p-83'),
  G_HPINV: H('0x1.45F306DC9C883p-1'), G_TOINT: H('0x1.8000000000000p52'),
  // glibc s_sin.c
  G_SN3: D('-1.66666666666664880952546298448555E-01'), G_SN5: D('8.33333214285722277379541354343671E-03'),
  G_CS2: D('4.99999999999999999999950396842453E-01'), G_CS4: D('-4.16666666666664434524222570944589E-02'),
  G_CS6: D('1.38888874007937613028114285595617E-03'),
  // glibc branred.h (mynumber {hi, lo}); its mp1/mp2/hp0/hp1 are not those of usncs.h
  BR_T576: W(0x63f00000, 0), BR_TM600: W(0x1a700000, 0), BR_TM24: W(0x3e700000, 0), BR_BIG: W(0x43380000, 0),
  BR_BIG1: W(0x43580000, 0), BR_HP0: W(0x3FF921FB, 0x54442D18), BR_HP1: W(0x3C91A626, 0x33145C07),
  BR_MP1: W(0x3FF921FB, 0x58000000), BR_MP2: W(0xBE4DDE97, 0x40000000), BR_SPLIT: D('134217729'),
  // fdlibm s_atan.c (V8 src/base/ieee754.cc): atanhi, atanlo, aT
  AT_HI0: D('4.63647609000806093515e-01', '3FDDAC670561BB4F'), AT_HI1: D('7.85398163397448278999e-01', '3FE921FB54442D18'),
  AT_HI2: D('9.82793723247329054082e-01', '3FEF730BD281F69B'), AT_HI3: D('1.57079632679489655800e+00', '3FF921FB54442D18'),
  AT_LO0: D('2.26987774529616870924e-17', '3C7A2B7F222F65E2'), AT_LO1: D('3.06161699786838301793e-17', '3C81A62633145C07'),
  AT_LO2: D('1.39033110312309984516e-17', '3C7007887AF0CBBD'), AT_LO3: D('6.12323399573676603587e-17', '3C91A62633145C07'),
  AT_T0: D('3.33333333333329318027e-01', '3FD555555555550D'), AT_T1: D('-1.99999999998764832476e-01', 'BFC999999998EBC4'),
  AT_T2: D('1.42857142725034663711e-01', '3FC24924920083FF'), AT_T3: D('-1.11111104054623557880e-01', 'BFBC71C6FE231671'),
  AT_T4: D('9.09088713343650656196e-02', '3FB745CDC54C206E'), AT_T5: D('-7.69187620504482999495e-02', 'BFB3B0F2AF749A6D'),
  AT_T6: D('6.66107313738753120669e-02', '3FB10D66A0D03D51'), AT_T7: D('-5.83357013379057348645e-02', 'BFADDE2D52DEFD9A'),
  AT_T8: D('4.97687799461593236017e-02', '3FA97B4B24760DEB'), AT_T9: D('-3.65315727442169155270e-02', 'BFA2B4442C6A6C2F'),
  AT_T10: D('1.62858201153657823623e-02', '3F90AD3AE322DA11'),
  // fdlibm e_atan2.c
  A2_PI_O_4: D('7.8539816339744827900E-01', '3FE921FB54442D18'), A2_PI_O_2: D('1.5707963267948965580E+00', '3FF921FB54442D18'),
  A2_PI: D('3.1415926535897931160E+00', '400921FB54442D18'), A2_PI_LO: D('1.2246467991473531772E-16', '3CA1A62633145C07'),
  A2_TINY: D('1.0e-300'),
  // fdlibm e_exp.c
  EX_O_THRESHOLD: D('7.09782712893383973096e+02', '40862E42FEFA39EF'), EX_U_THRESHOLD: D('-7.45133219101941108420e+02', 'C0874910D52D3051'),
  EX_LN2HI: D('6.93147180369123816490e-01', '3FE62E42FEE00000'), EX_LN2LO: D('1.90821492927058770002e-10', '3DEA39EF35793C76'),
  EX_INVLN2: D('1.44269504088896338700e+00', '3FF71547652B82FE'),
  EX_P1: D('1.66666666666666019037e-01', '3FC555555555553E'), EX_P2: D('-2.77777777770155933842e-03', 'BF66C16C16BEBD93'),
  EX_P3: D('6.61375632143793436117e-05', '3F11566AAF25DE2C'), EX_P4: D('-1.65339022054652515390e-06', 'BEBBBD41C5D26BF1'),
  EX_P5: D('4.13813679705723846039e-08', '3E66376972BEA4D0'), EX_E: D('2.718281828459045', '4005BF0A8B145769'),
  EX_TWOM1000: D('9.33263618503218878990e-302', '0170000000000000'), EX_TWO1023: D('8.988465674311579539e307', '7FE0000000000000'),
  // fdlibm e_log.c
  LG_TWO54: D('1.80143985094819840000e+16', '4350000000000000'),
  LG_1: D('6.666666666666735130e-01', '3FE5555555555593'), LG_2: D('3.999999999940941908e-01', '3FD999999997FA04'),
  LG_3: D('2.857142874366239149e-01', '3FD2492494229359'), LG_4: D('2.222219843214978396e-01', '3FCC71C51D8E78AF'),
  LG_5: D('1.818357216161805012e-01', '3FC7466496CB03DE'), LG_6: D('1.531383769920937332e-01', '3FC39A09D078C69F'),
  LG_7: D('1.479819860511658591e-01', '3FC2F112DF3E5244'),
  LG_THIRD: D('0.33333333333333333'),
  // high-word thresholds: the C code compares the high word of |x|; |x| < (double with that high word and low word 0) is the same test
  EX_TH_HALF_LN2: W(0x3FD62E43, 0), EX_TH_1_5_LN2: W(0x3FF0A2B2, 0), EX_TH_2M28: W(0x3E300000, 0), EX_TH_BIG: W(0x40862E42, 0),
  G_TH_2M26: W(0x3e500000, 0), G_TH_2M27: W(0x3e400000, 0), G_TH_0855: W(0x3feb6000, 0), G_TH_2426: W(0x400368fd, 0),
  G_TH_REDUCE: W(0x419921fb, 0),
  AT_TH_2P66: W(0x44100000, 0), AT_TH_07: W(0x3fdc0000, 0), AT_TH_2M27: W(0x3e400000, 0), AT_TH_11: W(0x3ff30000, 0),
  AT_TH_06: W(0x3fe60000, 0), AT_TH_24: W(0x40038000, 0),
  // powers of two used by the fast path of atan2
  TWO_59: P(59), TWO_M59: P(-59), TWO_900: P(900), TWO_M900: P(-900),
};
// pow2() above only handles the normal range of exponents it is given here; the largest used is 900.

// --- the .gd file ------------------------------------------------------------------------------------------------------
const problems = [];
const problem = (text) => problems.push(text);

const gd = fs.readFileSync(GD_FILE, 'utf8');

// every `const NAME: float = EXPRESSION  # comment` line, in order; the expression may use constants defined before it
const gdConsts = [];
const values = new Map();
for (const line of gd.split('\n')) {
  const m = /^const ([A-Z][A-Z0-9_]*): float = (.+?)(?:\s+#.*)?$/.exec(line);
  if (!m) continue;
  const [, name, expr] = m;
  if (!/^[-0-9.*/ A-Z_]+$/.test(expr)) { problem(`${name}: the expression "${expr}" uses something other than numbers, * and /`); continue; }
  const js = expr.replace(/[A-Z][A-Z0-9_]*/g, (id) => {
    if (!values.has(id)) throw new Error(`${name}: ${id} is used before it is defined`);
    return `(${values.get(id)})`;
  });
  const value = vm.runInNewContext(js, Object.create(null), { timeout: 1000 });
  if (typeof value !== 'number') throw new Error(`${name}: the expression did not give a number`);
  values.set(name, value);
  gdConsts.push({ name, value });
}

// CONST_BITS: [NAME, signed int64]
const tableBlock = /const CONST_BITS: Array = \[\n([\s\S]*?)\n\]/.exec(gd);
if (!tableBlock) throw new Error('CONST_BITS not found in js_compat.gd');
const constBits = new Map();
for (const m of tableBlock[1].matchAll(/^\s*\[([A-Z][A-Z0-9_]*), (-?\d+)\],?$/gm)) {
  if (constBits.has(m[1])) problem(`${m[1]}: listed twice in CONST_BITS`);
  constBits.set(m[1], BigInt.asUintN(64, BigInt(m[2])));
}

// --- 1. names ------------------------------------------------------------------------------------------------------------
const gdNames = new Set(gdConsts.map((c) => c.name));
for (const name of gdNames) {
  if (!(name in UPSTREAM)) problem(`${name}: a constant of js_compat.gd without an upstream literal in tools/check_js_compat_consts.mjs`);
  if (name !== 'P2_60' && !constBits.has(name)) problem(`${name}: not listed in CONST_BITS`);
}
for (const name of Object.keys(UPSTREAM)) if (!gdNames.has(name)) problem(`${name}: an upstream literal for a constant that js_compat.gd no longer has`);
for (const name of constBits.keys()) if (!gdNames.has(name)) problem(`${name}: listed in CONST_BITS but not a constant of js_compat.gd`);

// --- 2. bits -------------------------------------------------------------------------------------------------------------
let compared = 0;
for (const { name, value } of gdConsts) {
  const up = UPSTREAM[name];
  if (!up) continue;
  const exprBits = bitsOf(value);
  const upBits = bitsOf(up.value);
  compared++;
  if (exprBits !== upBits) problem(`${name}: the expression gives ${hex16(exprBits)} but the upstream literal ${up.source} is ${hex16(upBits)}`);
  if (up.bits && up.bits.toLowerCase() !== hex16(upBits)) problem(`${name}: the decimal literal ${up.source} is ${hex16(upBits)}, not the bits quoted next to it`);
  const tableBits = constBits.get(name);
  if (tableBits !== undefined && tableBits !== upBits) problem(`${name}: CONST_BITS has ${hex16(tableBits)} but the upstream literal ${up.source} is ${hex16(upBits)}`);
}

// --- 3. the big tables ---------------------------------------------------------------------------------------------------
const glibc = fs.readFileSync(GLIBC_JS, 'utf8');
const gdTab = /const SINCOSTAB_BITS: Array = \[([\s\S]*?)\n\]/.exec(gd);
const jsTab = /const SINCOSTAB_BITS = \[([\s\S]*?)\n\];/.exec(glibc);
if (!gdTab || !jsTab) throw new Error('SINCOSTAB_BITS not found');
const gdSin = [...gdTab[1].matchAll(/-?\d+/g)].map((m) => BigInt.asUintN(64, BigInt(m[0])));
const jsSin = [...jsTab[1].matchAll(/'([0-9a-f]{16})'/g)].map((m) => BigInt('0x' + m[1]));
if (gdSin.length !== 440) problem(`SINCOSTAB_BITS of js_compat.gd has ${gdSin.length} entries, not 440`);
if (jsSin.length !== 440) problem(`SINCOSTAB_BITS of _glibc_sin.mjs has ${jsSin.length} entries, not 440`);
for (let i = 0; i < Math.min(gdSin.length, jsSin.length); i++) {
  if (gdSin[i] !== jsSin[i]) problem(`SINCOSTAB_BITS[${i}]: js_compat.gd has ${hex16(gdSin[i])}, _glibc_sin.mjs has ${hex16(jsSin[i])}`);
}
const gdTo = /static var TOVERP: PackedFloat64Array = PackedFloat64Array\(\[([^\]]*)\]\)/.exec(gd);
const jsTo = /const TOVERP = \[([^\]]*)\]/.exec(glibc);
if (!gdTo || !jsTo) throw new Error('TOVERP not found');
const toList = (text) => [...text.matchAll(/\d+/g)].map((m) => Number(m[0]));
const gdToverp = toList(gdTo[1]);
const jsToverp = toList(jsTo[1]);
if (gdToverp.length !== 75) problem(`TOVERP of js_compat.gd has ${gdToverp.length} entries, not 75`);
if (jsToverp.length !== gdToverp.length) problem(`TOVERP has ${gdToverp.length} entries in js_compat.gd and ${jsToverp.length} in _glibc_sin.mjs`);
for (let i = 0; i < Math.min(gdToverp.length, jsToverp.length); i++) {
  if (gdToverp[i] !== jsToverp[i]) problem(`TOVERP[${i}]: js_compat.gd has ${gdToverp[i]}, _glibc_sin.mjs has ${jsToverp[i]}`);
  if (!(gdToverp[i] >= 0 && gdToverp[i] < 2 ** 24)) problem(`TOVERP[${i}] = ${gdToverp[i]} is not a 24-bit digit`);
}

if (problems.length > 0) {
  for (const p of problems) console.error(`js_compat constants: ${p}`);
  console.error(`js_compat constants: ${problems.length} problem(s)`);
  process.exit(1);
}
console.log(`check OK: ${compared} constants of js_compat.gd = their CONST_BITS entries = the upstream literals; SINCOSTAB_BITS (${gdSin.length}) and TOVERP (${gdToverp.length}) = tools/golden/_glibc_sin.mjs`);
