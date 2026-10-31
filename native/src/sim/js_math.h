#ifndef SWARM_SIM_JS_MATH_H
#define SWARM_SIM_JS_MATH_H

// JavaScript-compatible numerics for the simulation (docs/godot-port-design.md section 5.2): the C++ version of
// godot/sim/js_compat.gd (JsMath). Every function is a transcription of the GDScript function of the same name
// (js_round, js_mod, js_max and js_min lose their prefix; they live in namespace js), which in turn ports V8 14.1.
// native/src/sim is plain C++17 without Godot headers (tools/check_native_sources.py).
//
// The original game runs on V8 and the port has to reproduce its numbers bit for bit, because the random-number
// draws and every spawn depend on them. So:
//   * ported from V8, exact because only IEEE-754 additions, multiplications, divisions and comparisons are used
//     (built with -ffp-contract=off, so nothing is fused into an FMA):
//       sin, cos      glibc s_sin.c / branred.c as in V8's third_party/glibc (swarm_glibc::sin / cos, an LGPL library)
//       atan, atan2   fdlibm s_atan.c / e_atan2.c as in V8 src/base/ieee754.cc (fdlibm.cpp)
//       exp, log      fdlibm e_exp.c / e_log.c as in V8 src/base/ieee754.cc (fdlibm.cpp)
//       hypot         V8 Torque FastMathHypot (two arguments)
//       round         V8 CodeStubAssembler Float64Round (ceil based; keeps -0)
//       max, min, max3, min3, max5, min5, max_n, min_n, clamp   Float64Max / Float64Min (NaN wins, -0 < +0)
//       to_int32, to_uint32, i32, imul, shl, sar, shr_u   32-bit integer semantics
//   * IEEE-754 exact, so the C library is used: sqrt, floor, ceil, abs, trunc, mod (fmod).
//   * pow is NOT bit-guaranteed: it handles the JavaScript special cases and then calls std::pow. It is not used by
//     the simulation of milestone 1.
// Rules for simulation code: call these with the namespace (js::sin(x)); never the C library's sin, round, fmax, ...
// A double is converted to an integer only where the range is known, or through to_int32.

#include <cstddef>
#include <cstdint>

#include "bits.h"

namespace swarm::sim::js {

// Bit access (bits.h): JsMath.to_bits / from_bits (unsigned here), fdlibm GET_HIGH_WORD.
using sim::from_bits;
using sim::high_word;
using sim::to_bits;

// Negative zero.
double neg_zero();

// ---- 32-bit integer semantics -------------------------------------------------------------------------------------
// Wraps any int64 to the int32 range (the low 32 bits).
int32_t i32(int64_t v);
// ECMAScript ToInt32 (x | 0): truncate toward zero, then wrap modulo 2^32. NaN and the infinities give 0.
int32_t to_int32(double x);
// ECMAScript ToUint32 (x >>> 0).
uint32_t to_uint32(double x);
// Math.imul(a, b) for integer arguments (any int64: they are wrapped to int32 first).
int32_t imul(int64_t a, int64_t b);
// a << n, a >> n, a >>> n of JavaScript (the count is taken modulo 32).
int32_t shl(int64_t a, int64_t n);
int32_t sar(int64_t a, int64_t n);
uint32_t shr_u(int64_t a, int64_t n);

// ---- Rounding, remainder, min / max / clamp ----------------------------------------------------------------------
// Math.round: ties go toward +Infinity, -0 and NaN are kept (V8's Float64Round: c = ceil(x); c - 0.5 <= x ? c : c - 1).
double round(double x);
// Math.trunc.
double trunc(double x);
// a % b of JavaScript on numbers: the sign follows the dividend (fmod).
double mod(double a, double b);
// Math.max(a, b): NaN if either is NaN, and +0 beats -0. Math.min(a, b): NaN if either is NaN, and -0 beats +0.
double max(double a, double b);
double min(double a, double b);
double max3(double a, double b, double c);
double min3(double a, double b, double c);
double max5(double a, double b, double c, double d, double e);
double min5(double a, double b, double c, double d, double e);
// Math.max(...values): -Infinity for an empty array. Math.min(...values): +Infinity.
double max_n(const double *values, size_t count);
double min_n(const double *values, size_t count);
// The game's clamp(v, lo, hi) = Math.max(lo, Math.min(hi, v)). When lo > hi the result is lo, and NaN stays NaN.
double clamp(double v, double lo, double hi);

// ---- IEEE-754 exact functions --------------------------------------------------------------------------------------
double sqrt(double x);
double floor(double x);
double ceil(double x);
double abs(double x);
// Math.hypot(x, y) with two arguments, V8 14.1 FastMathHypot.
double hypot(double x, double y);

// ---- Transcendental functions (bit-exact with Chromium 141) -------------------------------------------------------
double sin(double x);
double cos(double x);
double atan(double x);
double atan2(double y, double x);
double exp(double x);
double log(double x);

// Math.pow (also x ** y). NOT bit-guaranteed, see above.
double pow(double x, double y);

} // namespace swarm::sim::js

#endif // SWARM_SIM_JS_MATH_H
