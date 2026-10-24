// Shared helpers of the golden-vector modules (tools/golden/*.mjs). Files whose name starts with "_" are
// helpers: tools/gen_golden.mjs does not load them as golden modules.
//
// Encoding of numbers in the committed JSON files (see the Godot side: res://tests/golden_codec.gd):
//   * JSON numbers must not carry doubles. Godot's JSON parser and GDScript float literals are not correctly rounded
//     (measured: 16% of the shortest JavaScript doubles come back 1 ulp or more off), and JSON cannot hold NaN, Infinity or
//     -0 at all. Every double therefore travels as its IEEE-754 bit pattern: either 16 lowercase hex digits (a single
//     value) or, for arrays, as the base64 of the little-endian bytes (8 per double).
//   * NaN is written with the canonical bit pattern 0x7ff8000000000000, so the output does not depend on the
//     payload bits that an engine happens to produce. Tests treat any NaN as equal to any NaN.
//   * 32-bit integers are base64 of little-endian int32 / uint32 arrays.
import crypto from 'node:crypto';

const dv = new DataView(new ArrayBuffer(8));
export const CANONICAL_NAN_BITS = 0x7ff8000000000000n;

export function bitsOf(x) {
  if (Number.isNaN(x)) return CANONICAL_NAN_BITS;
  dv.setFloat64(0, x);
  return dv.getBigUint64(0);
}

export function fromBits(bits) {
  dv.setBigUint64(0, BigInt.asUintN(64, BigInt(bits)));
  return dv.getFloat64(0);
}

/** 16 lowercase hex digits of the bit pattern (NaN canonical). */
export function hex64(x) {
  return bitsOf(x).toString(16).padStart(16, '0');
}

export function fromHex64(hex) {
  if (!/^[0-9a-f]{16}$/.test(hex)) throw new Error(`not a 16-digit hex bit pattern: ${hex}`);
  return fromBits(BigInt(`0x${hex}`));
}

/** Double whose high 32 bits are `hi` and low 32 bits `lo` (the fdlibm / glibc way of writing thresholds). */
export function fromWords(hi, lo = 0) {
  dv.setUint32(0, hi >>> 0);
  dv.setUint32(4, lo >>> 0);
  return dv.getFloat64(0);
}

/**
 * 2^e for an integer e in [-1074, 1023], built from the bit pattern. The generators use this instead of `2 ** e` and never
 * `10 ** e`: the `**` operator calls the host's pow (fdlibm in V8 12.4, the C library's pow in V8 14.1), so an input set
 * built with it could differ between Node versions and report drift that is no drift.
 */
export function pow2(e) {
  if (!Number.isInteger(e) || e < -1074 || e > 1023) throw new RangeError(`pow2: exponent out of range: ${e}`);
  return e >= -1022 ? fromBits(BigInt(e + 1023) << 52n) : fromBits(1n << BigInt(e + 1074));
}

/**
 * The double `n` representable values away from x (n may be negative), counting through zero: -0 and +0 share one
 * position, so stepping from -MIN_VALUE by +1 gives zero (+0) and by +2 gives +MIN_VALUE. n = 0 returns x itself.
 * Infinity and NaN are returned unchanged; stepping past the largest finite value saturates at +-Infinity.
 */
export function stepUlps(x, n) {
  if (!Number.isFinite(x) || n === 0) return x;
  const bits = bitsOf(x);
  const negative = (bits >> 63n) === 1n;
  let ordinal = negative ? -(bits & 0x7fffffffffffffffn) : bits;
  ordinal += BigInt(n);
  const limit = 0x7ff0000000000000n;
  if (ordinal > limit) ordinal = limit;
  if (ordinal < -limit) ordinal = -limit;
  if (ordinal >= 0n) return fromBits(ordinal);
  return fromBits((-ordinal) | 0x8000000000000000n);
}

/** Base64 of the little-endian IEEE-754 binary64 values. */
export function encodeF64(values) {
  const buffer = Buffer.alloc(8 * values.length);
  for (let i = 0; i < values.length; i++) buffer.writeBigUInt64LE(bitsOf(values[i]), 8 * i);
  return buffer.toString('base64');
}

export function encodeI32(values) {
  const buffer = Buffer.alloc(4 * values.length);
  for (let i = 0; i < values.length; i++) {
    if (!Number.isInteger(values[i]) || values[i] < -2147483648 || values[i] > 2147483647) throw new Error(`not an int32: ${values[i]}`);
    buffer.writeInt32LE(values[i], 4 * i);
  }
  return buffer.toString('base64');
}

export function encodeU32(values) {
  const buffer = Buffer.alloc(4 * values.length);
  for (let i = 0; i < values.length; i++) {
    if (!Number.isInteger(values[i]) || values[i] < 0 || values[i] > 4294967295) throw new Error(`not a uint32: ${values[i]}`);
    buffer.writeUInt32LE(values[i], 4 * i);
  }
  return buffer.toString('base64');
}

export function decodeF64(base64) {
  const buffer = Buffer.from(base64, 'base64');
  if (buffer.length % 8 !== 0) throw new Error('f64 array of bad length');
  const out = new Array(buffer.length / 8);
  for (let i = 0; i < out.length; i++) out[i] = fromBits(buffer.readBigUInt64LE(8 * i));
  return out;
}

export const sha256Hex = (data) => crypto.createHash('sha256').update(data).digest('hex');

/**
 * Deterministic generator of the test INPUTS (not of the game's random numbers): 32-bit mulberry32 with a fixed seed.
 * Returns a function that yields doubles in [0, 1) with 32 random bits.
 */
export function makeRng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
