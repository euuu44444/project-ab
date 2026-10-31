// Port of V8 14.1: Float64Round (CodeStubAssembler), Float64Max / Float64Min and FastMathHypot (Torque), written
// for this project from the GDScript port godot/sim/js_compat.gd. The V8 project's license (BSD-3-Clause) is in
// native/LICENSES/V8-BSD-3-Clause.txt. sin and cos call the glibc-derived library in native/third_party/glibc_sincos
// (LGPL-2.1 or later); atan, atan2, exp and log are in fdlibm.cpp.

#include "js_math.h"

#include <cmath>
#include <limits>

#include "glibc_sincos/glibc_sincos.h"

namespace swarm::sim::js {

namespace {

constexpr double kInfinity = std::numeric_limits<double>::infinity();
constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();

} // namespace

// Negative zero (the literal -0.0 would do in C++; the GDScript version needs a trick, this keeps the name).
double neg_zero() {
	return -0.0;
}

// ---- 32-bit integer semantics -------------------------------------------------------------------------------------
// JavaScript int32 values are int32_t, uint32 values uint32_t. The arithmetic is done in uint32_t (it wraps; signed
// overflow would be undefined) and the result is converted to int32_t once, at the end.

// Wraps any int64 to the int32 range: the low 32 bits.
int32_t i32(int64_t v) {
	return as_int32(static_cast<uint32_t>(static_cast<uint64_t>(v)));
}

// ECMAScript ToInt32 (x | 0): truncate toward zero, then wrap modulo 2^32. NaN and the infinities give 0.
int32_t to_int32(double x) {
	if (x >= -2147483648.0 && x <= 2147483647.0) {
		return static_cast<int32_t>(x); // truncates toward zero; in range by the test above
	}
	if (std::isnan(x) || std::isinf(x)) {
		return 0;
	}
	// |x| >= 2^31 (or just beyond the int32 range): fmod is exact and |fmod| < 2^32, so the int64 conversion is in
	// range; the wrap to 32 bits is the unsigned conversion.
	int64_t truncated = static_cast<int64_t>(std::fmod(x, 4294967296.0));
	return as_int32(static_cast<uint32_t>(static_cast<uint64_t>(truncated)));
}

// ECMAScript ToUint32 (x >>> 0).
uint32_t to_uint32(double x) {
	return static_cast<uint32_t>(to_int32(x));
}

// Math.imul(a, b). The low 32 bits of a product depend only on the low 32 bits of the factors, so the factors are
// wrapped first and multiplied as uint32_t.
int32_t imul(int64_t a, int64_t b) {
	return as_int32(static_cast<uint32_t>(a) * static_cast<uint32_t>(b));
}

// a << n of JavaScript (the count is taken modulo 32).
int32_t shl(int64_t a, int64_t n) {
	return as_int32(static_cast<uint32_t>(a) << (static_cast<uint32_t>(n) & 31u));
}

// a >> n of JavaScript (arithmetic shift of the int32 value; the count is taken modulo 32).
int32_t sar(int64_t a, int64_t n) {
	return arithmetic_shift_right(i32(a), static_cast<uint32_t>(n) & 31u);
}

// a >>> n of JavaScript (logical shift of the uint32 value; the count is taken modulo 32).
uint32_t shr_u(int64_t a, int64_t n) {
	return static_cast<uint32_t>(a) >> (static_cast<uint32_t>(n) & 31u);
}

// ---- Rounding, remainder, min / max / clamp ----------------------------------------------------------------------

// Math.round: ties go toward +Infinity, -0 and NaN are kept. V8's Float64Round: c = ceil(x); c - 0.5 <= x ? c : c - 1.
// (floor(x + 0.5) is wrong for 0.49999999999999994 and for odd values above 2^52; lround rounds ties away from zero.)
double round(double x) {
	double c = std::ceil(x);
	if (c - 0.5 <= x) {
		return c;
	}
	return c - 1.0;
}

// Math.trunc.
double trunc(double x) {
	return x < 0.0 ? std::ceil(x) : std::floor(x);
}

// a % b of JavaScript on numbers: the sign follows the dividend.
double mod(double a, double b) {
	return std::fmod(a, b);
}

// Math.max(a, b): NaN if either is NaN, and +0 beats -0.
double max(double a, double b) {
	if (a > b) {
		return a;
	}
	if (b > a) {
		return b;
	}
	if (a == b) {
		if (a == 0.0 && 1.0 / a < 0.0) {
			return b;
		}
		return a;
	}
	return kNaN;
}

// Math.min(a, b): NaN if either is NaN, and -0 beats +0.
double min(double a, double b) {
	if (a < b) {
		return a;
	}
	if (b < a) {
		return b;
	}
	if (a == b) {
		if (a == 0.0 && 1.0 / a > 0.0) {
			return b;
		}
		return a;
	}
	return kNaN;
}

double max3(double a, double b, double c) {
	return max(max(a, b), c);
}

double min3(double a, double b, double c) {
	return min(min(a, b), c);
}

double max5(double a, double b, double c, double d, double e) {
	return max(max(max(max(a, b), c), d), e);
}

double min5(double a, double b, double c, double d, double e) {
	return min(min(min(min(a, b), c), d), e);
}

// Math.max(...values): -Infinity for an empty array.
double max_n(const double *values, size_t count) {
	double r = -kInfinity;
	for (size_t i = 0; i < count; ++i) {
		r = max(r, values[i]);
	}
	return r;
}

// Math.min(...values): +Infinity for an empty array.
double min_n(const double *values, size_t count) {
	double r = kInfinity;
	for (size_t i = 0; i < count; ++i) {
		r = min(r, values[i]);
	}
	return r;
}

// The game's clamp(v, a, b) = Math.max(a, Math.min(b, v)). When lo > hi the result is lo, and NaN stays NaN.
double clamp(double v, double lo, double hi) {
	double m;
	if (v < hi) {
		m = v;
	} else if (hi < v) {
		m = hi;
	} else {
		m = min(hi, v);
	}
	if (m > lo) {
		return m;
	}
	if (lo > m) {
		return lo;
	}
	return max(lo, m);
}

// ---- IEEE-754 exact functions --------------------------------------------------------------------------------------

// Math.sqrt (correctly rounded by IEEE 754).
double sqrt(double x) {
	return std::sqrt(x);
}

// Math.floor (exact).
double floor(double x) {
	return std::floor(x);
}

// Math.ceil (exact).
double ceil(double x) {
	return std::ceil(x);
}

// Math.abs (exact).
double abs(double x) {
	return std::fabs(x);
}

// Math.hypot(x, y) with two arguments, V8 14.1 FastMathHypot: scale by the larger magnitude, then
// sqrt((a/m)^2 + (b/m)^2) * m. (sqrt(x*x + y*y) differs in the last bit for a third of all inputs.)
double hypot(double x, double y) {
	double a = std::fabs(x);
	double b = std::fabs(y);
	if (a == kInfinity || b == kInfinity) {
		return kInfinity;
	}
	if (std::isnan(a) || std::isnan(b)) {
		return kNaN;
	}
	double m = a > b ? a : b;
	if (m == 0.0) {
		return 0.0;
	}
	double ra = a / m;
	double rb = b / m;
	return std::sqrt(ra * ra + rb * rb) * m;
}

// ---- sin / cos -------------------------------------------------------------------------------------------------------

// Math.sin (bit-exact with Chromium 141).
double sin(double x) {
	return swarm_glibc::sin(x);
}

// Math.cos (bit-exact with Chromium 141).
double cos(double x) {
	return swarm_glibc::cos(x);
}

// ---- pow ---------------------------------------------------------------------------------------------------------------

// Math.pow (also x ** y). NOT bit-guaranteed: the JavaScript special cases are handled here, the general case calls the
// platform's pow (glibc, Bionic), which V8 14.1 itself also uses (std::pow) apart from these cases. x ** 2 is x * x as
// in V8. Port the ARM optimized-routines pow if a trace ever diverges here; the simulation of milestone 1 does not call it.
double pow(double x, double y) {
	if (std::isnan(y)) {
		return kNaN;
	}
	if (y == 0.0) {
		return 1.0;
	}
	if ((x == 1.0 || x == -1.0) && std::isinf(y)) {
		return kNaN;
	}
	if (y == 2.0) {
		return x * x;
	}
	if (y == 0.5) {
		return x == -kInfinity ? kInfinity : std::sqrt(x + 0.0);
	}
	return std::pow(x, y);
}

} // namespace swarm::sim::js
