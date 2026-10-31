// The following is adapted from fdlibm (http://www.netlib.org/fdlibm).
//
// ====================================================
// Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
//
// Developed at SunSoft, a Sun Microsystems, Inc. business.
// Permission to use, copy, modify, and distribute this
// software is freely granted, provided that this notice
// is preserved.
// ====================================================
//
// The original source code covered by the above license above has been
// modified significantly by Google Inc.
// Copyright 2016 the V8 project authors. All rights reserved.
//
// Modified 2026-10-25. This is NOT the V8 file. It is a C++17 transcription of the GDScript port godot/sim/js_compat.gd of
// this repository (JsMath.atan, atan2, _atan2_general, exp, log and the constants AT_*, A2_*, EX_*, LG_*, TWO_*), which
// was ported from fdlibm s_atan.c, e_atan2.c, e_exp.c and e_log.c as they are in V8 14.1.146.11, src/base/ieee754.cc
// (sha256 1bf999809d4c4c1d31ad5ff3578d32614796f159e08b9e7782560d017721a0c2). The fast path of atan2 and the
// threshold comparisons on doubles instead of high words are changes made in the GDScript port. The V8 project's
// license (BSD-3-Clause) is in native/LICENSES/V8-BSD-3-Clause.txt; the notice of Sun Microsystems above applies as well.
//
// Bit-exact with Chromium 141: only IEEE-754 additions, subtractions, multiplications, divisions and comparisons are
// used, so with -ffp-contract=off the results are the same on every platform.

#include "js_math.h"

#include <cmath>
#include <cstdint>
#include <limits>

#include "bits.h"

namespace swarm::sim::js {

namespace {

constexpr double kInfinity = std::numeric_limits<double>::infinity();
constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();

// fdlibm s_atan.c (V8 src/base/ieee754.cc)
constexpr double AT_HI0 = 0x1.DAC670561BB4Fp-2;  // atanhi[0]
constexpr double AT_HI1 = 0x1.921FB54442D18p-1;  // atanhi[1]
constexpr double AT_HI2 = 0x1.F730BD281F69Bp-1;  // atanhi[2]
constexpr double AT_HI3 = 0x1.921FB54442D18p0;  // atanhi[3]
constexpr double AT_LO0 = 0x1.A2B7F222F65E2p-56;  // atanlo[0]
constexpr double AT_LO1 = 0x1.1A62633145C07p-55;  // atanlo[1]
constexpr double AT_LO2 = 0x1.007887AF0CBBDp-56;  // atanlo[2]
constexpr double AT_LO3 = 0x1.1A62633145C07p-54;  // atanlo[3]
constexpr double AT_T0 = 0x1.555555555550Dp-2;  // aT[0]
constexpr double AT_T1 = -0x1.999999998EBC4p-3;  // aT[1]
constexpr double AT_T2 = 0x1.24924920083FFp-3;  // aT[2]
constexpr double AT_T3 = -0x1.C71C6FE231671p-4;  // aT[3]
constexpr double AT_T4 = 0x1.745CDC54C206Ep-4;  // aT[4]
constexpr double AT_T5 = -0x1.3B0F2AF749A6Dp-4;  // aT[5]
constexpr double AT_T6 = 0x1.10D66A0D03D51p-4;  // aT[6]
constexpr double AT_T7 = -0x1.DDE2D52DEFD9Ap-5;  // aT[7]
constexpr double AT_T8 = 0x1.97B4B24760DEBp-5;  // aT[8]
constexpr double AT_T9 = -0x1.2B4442C6A6C2Fp-5;  // aT[9]
constexpr double AT_T10 = 0x1.0AD3AE322DA11p-6;  // aT[10]

// fdlibm e_atan2.c
constexpr double A2_PI_O_4 = 0x1.921FB54442D18p-1;  // pi_o_4
constexpr double A2_PI_O_2 = 0x1.921FB54442D18p0;  // pi_o_2
constexpr double A2_PI = 0x1.921FB54442D18p1;  // pi
constexpr double A2_PI_LO = 0x1.1A62633145C07p-53;  // pi_lo
constexpr double A2_TINY = 0x1.56E1FC2F8F359p-997;  // tiny = 1.0e-300

// fdlibm e_exp.c
constexpr double EX_O_THRESHOLD = 0x1.62E42FEFA39EFp9;  // o_threshold
constexpr double EX_U_THRESHOLD = -0x1.74910D52D3051p9;  // u_threshold
constexpr double EX_LN2HI = 0x1.62E42FEE00000p-1;  // ln2HI[0]
constexpr double EX_LN2LO = 0x1.A39EF35793C76p-33;  // ln2LO[0]
constexpr double EX_INVLN2 = 0x1.71547652B82FEp0;  // invln2
constexpr double EX_P1 = 0x1.555555555553Ep-3;  // P1
constexpr double EX_P2 = -0x1.6C16C16BEBD93p-9;  // P2
constexpr double EX_P3 = 0x1.1566AAF25DE2Cp-14;  // P3
constexpr double EX_P4 = -0x1.BBD41C5D26BF1p-20;  // P4
constexpr double EX_P5 = 0x1.6376972BEA4D0p-25;  // P5
constexpr double EX_E = 0x1.5BF0A8B145769p1;  // e = 2.718281828459045
constexpr double EX_TWOM1000 = 0x1.0000000000000p-1000;  // twom1000
constexpr double EX_TWO1023 = 0x1.0000000000000p1023;  // two1023

// fdlibm e_log.c
constexpr double LG_TWO54 = 0x1.0000000000000p54;  // two54 = 1.80143985094819840000e+16
constexpr double LG_1 = 0x1.5555555555593p-1;  // Lg1
constexpr double LG_2 = 0x1.999999997FA04p-2;  // Lg2
constexpr double LG_3 = 0x1.2492494229359p-2;  // Lg3
constexpr double LG_4 = 0x1.C71C51D8E78AFp-3;  // Lg4
constexpr double LG_5 = 0x1.7466496CB03DEp-3;  // Lg5
constexpr double LG_6 = 0x1.39A09D078C69Fp-3;  // Lg6
constexpr double LG_7 = 0x1.2F112DF3E5244p-3;  // Lg7
constexpr double LG_THIRD = 0x1.5555555555555p-2;  // 0.33333333333333333 (the literal of e_log.c, a C double)

// Thresholds: C code compares the HIGH WORD of |x|; |x| < D (D the double with that high word and low word 0) is the same test
constexpr double EX_TH_HALF_LN2 = 0x1.62E4300000000p-2;  // exp: 0.5 ln2 (high word 0x3fd62e43)
constexpr double EX_TH_1_5_LN2 = 0x1.0A2B200000000p0;  // exp: 1.5 ln2 (high word 0x3ff0a2b2)
constexpr double EX_TH_2M28 = 0x1.0000000000000p-28;  // exp: 2^-28 (high word 0x3e300000)
constexpr double EX_TH_BIG = 0x1.62E4200000000p9;  // exp: |x| >= 709.78 (high word 0x40862e42)
constexpr double AT_TH_2P66 = 0x1.0000000000000p66;  // atan: 2^66 (high word 0x44100000)
constexpr double AT_TH_07 = 0x1.C000000000000p-2;  // atan: 7/16 (high word 0x3fdc0000)
constexpr double AT_TH_2M27 = 0x1.0000000000000p-27;  // atan: 2^-27 (high word 0x3e400000)
constexpr double AT_TH_11 = 0x1.3000000000000p0;  // atan: 19/16 (high word 0x3ff30000)
constexpr double AT_TH_06 = 0x1.6000000000000p-1;  // atan: 11/16 (high word 0x3fe60000)
constexpr double AT_TH_24 = 0x1.3800000000000p1;  // atan: 39/16 (high word 0x40038000)

// Powers of two used by the fast path of atan2
constexpr double TWO_59 = 0x1.0000000000000p59;  // 2^59
constexpr double TWO_M59 = 0x1.0000000000000p-59;  // 2^-59
constexpr double TWO_900 = 0x1.0000000000000p900;  // 2^900
constexpr double TWO_M900 = 0x1.0000000000000p-900;  // 2^-900

// POW2.v[k + 1100] = 2^k for k in [-1100, 1100] (0 and infinity outside the range of a double). Every entry is built
// from exact doublings and halvings, so the table is a compile-time constant (no initialization order to care about).
struct Pow2Table {
	double v[2201];
};

constexpr Pow2Table make_pow2() {
	Pow2Table t = {};
	double p = 1.0;
	for (int k = 0; k <= 1023; ++k) {
		t.v[k + 1100] = p;
		if (k < 1023) {
			p *= 2.0;
		}
	}
	for (int k = 1024; k <= 1100; ++k) {
		t.v[k + 1100] = std::numeric_limits<double>::infinity();
	}
	double q = 1.0;
	for (int k = -1; k >= -1074; --k) {
		q *= 0.5; // exact down to 2^-1074, the smallest subnormal
		t.v[k + 1100] = q;
	}
	return t;
}

constexpr Pow2Table POW2 = make_pow2();

// fdlibm __ieee754_atan2, all cases.
double atan2_general(double y, double x) {
	if (std::isnan(x) || std::isnan(y)) {
		return x + y;
	}
	if (x == 1.0) {
		return atan(y);
	}
	bool yneg = y < 0.0 || (y == 0.0 && 1.0 / y < 0.0);
	bool xneg = x < 0.0 || (x == 0.0 && 1.0 / x < 0.0);
	uint32_t m = (yneg ? 1u : 0u) | (xneg ? 2u : 0u);
	if (y == 0.0) {
		if (m <= 1) {
			return y;
		}
		if (m == 2) {
			return A2_PI + A2_TINY;
		}
		return -A2_PI - A2_TINY;
	}
	if (x == 0.0) {
		return yneg ? -A2_PI_O_2 - A2_TINY : A2_PI_O_2 + A2_TINY;
	}
	double axx = std::fabs(x);
	double ayy = std::fabs(y);
	if (axx == kInfinity) {
		if (ayy == kInfinity) {
			if (m == 0) {
				return A2_PI_O_4 + A2_TINY;
			}
			if (m == 1) {
				return -A2_PI_O_4 - A2_TINY;
			}
			if (m == 2) {
				return 3.0 * A2_PI_O_4 + A2_TINY;
			}
			return -3.0 * A2_PI_O_4 - A2_TINY;
		}
		if (m == 0) {
			return 0.0;
		}
		if (m == 1) {
			return neg_zero();
		}
		if (m == 2) {
			return A2_PI + A2_TINY;
		}
		return -A2_PI - A2_TINY;
	}
	if (ayy == kInfinity) {
		return yneg ? -A2_PI_O_2 - A2_TINY : A2_PI_O_2 + A2_TINY;
	}
	// Both high words without the sign bit are at most 0x7FFFFFFF, so the difference fits an int32.
	int32_t k = arithmetic_shift_right(static_cast<int32_t>(high_word(y) & 0x7FFFFFFFu) - static_cast<int32_t>(high_word(x) & 0x7FFFFFFFu), 20);
	double z;
	if (k > 60) {
		z = A2_PI_O_2 + 0.5 * A2_PI_LO;
		m &= 1u;
	} else if (xneg && k < -60) {
		z = 0.0;
	} else {
		z = atan(std::fabs(y / x));
	}
	if (m == 0) {
		return z;
	}
	if (m == 1) {
		return -z;
	}
	if (m == 2) {
		return A2_PI - (z - A2_PI_LO);
	}
	return (z - A2_PI_LO) - A2_PI;
}

} // namespace

// Math.atan.
double atan(double x) {
	if (std::isnan(x)) {
		return x + x;
	}
	bool neg = x < 0.0;
	double ax = std::fabs(x);
	if (ax >= AT_TH_2P66) {
		return x > 0.0 ? AT_HI3 + AT_LO3 : -AT_HI3 - AT_LO3;
	}
	int32_t id;
	if (ax < AT_TH_07) {
		if (ax < AT_TH_2M27) {
			return x;
		}
		id = -1;
	} else {
		x = ax;
		if (ax < AT_TH_11) {
			if (ax < AT_TH_06) {
				id = 0;
				x = (2.0 * x - 1.0) / (2.0 + x);
			} else {
				id = 1;
				x = (x - 1.0) / (x + 1.0);
			}
		} else if (ax < AT_TH_24) {
			id = 2;
			x = (x - 1.5) / (1.0 + 1.5 * x);
		} else {
			id = 3;
			x = -1.0 / x;
		}
	}
	double z = x * x;
	double w = z * z;
	double s1 = z * (AT_T0 + w * (AT_T2 + w * (AT_T4 + w * (AT_T6 + w * (AT_T8 + w * AT_T10)))));
	double s2 = w * (AT_T1 + w * (AT_T3 + w * (AT_T5 + w * (AT_T7 + w * AT_T9))));
	if (id < 0) {
		return x - x * (s1 + s2);
	}
	double hi;
	double lo;
	if (id == 0) {
		hi = AT_HI0;
		lo = AT_LO0;
	} else if (id == 1) {
		hi = AT_HI1;
		lo = AT_LO1;
	} else if (id == 2) {
		hi = AT_HI2;
		lo = AT_LO2;
	} else {
		hi = AT_HI3;
		lo = AT_LO3;
	}
	z = hi - ((x * (s1 + s2) - lo) - x);
	return neg ? -z : z;
}

// Math.atan2(y, x). The common case (both arguments finite, normal, |y/x| between 2^-59 and 2^59, x != 1) is
// evaluated directly; everything else (zeros, infinities, NaN, huge ratios, x == 1) goes through atan2_general, the
// complete fdlibm routine.
double atan2(double y, double x) {
	double ax = std::fabs(x);
	double ay = std::fabs(y);
	if (ax > TWO_M900 && ax < TWO_900 && ay > TWO_M900 && ay < TWO_900 && ay < ax * TWO_59 && ay > ax * TWO_M59 && x != 1.0) {
		double t = ay / ax;
		double z;
		if (t < AT_TH_07) {
			if (t < AT_TH_2M27) {
				z = t;
			} else {
				double zz = t * t;
				double w = zz * zz;
				double s1 = zz * (AT_T0 + w * (AT_T2 + w * (AT_T4 + w * (AT_T6 + w * (AT_T8 + w * AT_T10)))));
				double s2 = w * (AT_T1 + w * (AT_T3 + w * (AT_T5 + w * (AT_T7 + w * AT_T9))));
				z = t - t * (s1 + s2);
			}
		} else {
			double hi;
			double lo;
			double u;
			if (t < AT_TH_11) {
				if (t < AT_TH_06) {
					hi = AT_HI0;
					lo = AT_LO0;
					u = (2.0 * t - 1.0) / (2.0 + t);
				} else {
					hi = AT_HI1;
					lo = AT_LO1;
					u = (t - 1.0) / (t + 1.0);
				}
			} else if (t < AT_TH_24) {
				hi = AT_HI2;
				lo = AT_LO2;
				u = (t - 1.5) / (1.0 + 1.5 * t);
			} else {
				hi = AT_HI3;
				lo = AT_LO3;
				u = -1.0 / t;
			}
			double zz2 = u * u;
			double w2 = zz2 * zz2;
			double s3 = zz2 * (AT_T0 + w2 * (AT_T2 + w2 * (AT_T4 + w2 * (AT_T6 + w2 * (AT_T8 + w2 * AT_T10)))));
			double s4 = w2 * (AT_T1 + w2 * (AT_T3 + w2 * (AT_T5 + w2 * (AT_T7 + w2 * AT_T9))));
			z = hi - ((u * (s3 + s4) - lo) - u);
		}
		if (x > 0.0) {
			return y < 0.0 ? -z : z;
		}
		if (y < 0.0) {
			return (z - A2_PI_LO) - A2_PI;
		}
		return A2_PI - (z - A2_PI_LO);
	}
	return atan2_general(y, x);
}

// Math.exp.
double exp(double x) {
	if (std::isnan(x)) {
		return x + x;
	}
	double ax = std::fabs(x);
	int32_t xsb = x < 0.0 ? 1 : 0;
	if (ax >= EX_TH_BIG) {
		if (ax == kInfinity) {
			return xsb == 0 ? x : 0.0;
		}
		if (x > EX_O_THRESHOLD) {
			return kInfinity;
		}
		if (x < EX_U_THRESHOLD) {
			return 0.0;
		}
	}
	double hi = 0.0;
	double lo = 0.0;
	int32_t k = 0;
	if (ax >= EX_TH_HALF_LN2) {
		if (ax < EX_TH_1_5_LN2) {
			if (x == 1.0) {
				return EX_E;
			}
			if (xsb == 0) {
				hi = x - EX_LN2HI;
				lo = EX_LN2LO;
				k = 1;
			} else {
				hi = x + EX_LN2HI;
				lo = -EX_LN2LO;
				k = -1;
			}
		} else {
			// |x| < 709.79 here, so the argument of the conversion is below 1026 in magnitude.
			k = static_cast<int32_t>(EX_INVLN2 * x + (xsb == 1 ? -0.5 : 0.5));
			double tk = static_cast<double>(k);
			hi = x - tk * EX_LN2HI;
			lo = tk * EX_LN2LO;
		}
		x = hi - lo;
	} else if (ax < EX_TH_2M28) {
		return 1.0 + x;
	}
	double t = x * x;
	double c = x - t * (EX_P1 + t * (EX_P2 + t * (EX_P3 + t * (EX_P4 + t * EX_P5))));
	if (k == 0) {
		return 1.0 - ((x * c) / (c - 2.0) - x);
	}
	double y = 1.0 - ((lo - (x * c) / (2.0 - c)) - hi);
	if (k >= -1021) {
		if (k == 1024) {
			return y * 2.0 * EX_TWO1023;
		}
		return y * POW2.v[k + 1100];
	}
	return y * POW2.v[k + 1000 + 1100] * EX_TWOM1000;
}

// Math.log.
double log(double x) {
	int32_t hx = as_int32(high_word(x));
	uint32_t lx = low_word(x);
	int32_t k = 0;
	if (hx < 0x00100000) {
		if (((static_cast<uint32_t>(hx) & 0x7FFFFFFFu) | lx) == 0) {
			return -kInfinity;
		}
		if (hx < 0) {
			return kNaN;
		}
		k -= 54;
		x *= LG_TWO54;
		hx = as_int32(high_word(x));
	}
	if (hx >= 0x7FF00000) {
		return x + x;
	}
	k += (hx >> 20) - 1023; // hx >= 0 here: negative arguments returned above
	hx &= 0x000FFFFF;
	int32_t i = (hx + 0x95F64) & 0x100000;
	x = with_high_word(x, static_cast<uint32_t>(hx | (i ^ 0x3FF00000)));
	k += i >> 20;
	double f = x - 1.0;
	double dk;
	if ((0x000FFFFF & (2 + hx)) < 3) {
		if (f == 0.0) {
			if (k == 0) {
				return 0.0;
			}
			dk = static_cast<double>(k);
			return dk * EX_LN2HI + dk * EX_LN2LO;
		}
		double r0 = f * f * (0.5 - LG_THIRD * f);
		if (k == 0) {
			return f - r0;
		}
		dk = static_cast<double>(k);
		return dk * EX_LN2HI - ((r0 - dk * EX_LN2LO) - f);
	}
	double s = f / (2.0 + f);
	dk = static_cast<double>(k);
	double z = s * s;
	int32_t i2 = hx - 0x6147A;
	double w = z * z;
	int32_t j = 0x6B851 - hx;
	double t1 = w * (LG_2 + w * (LG_4 + w * LG_6));
	double t2 = z * (LG_1 + w * (LG_3 + w * (LG_5 + w * LG_7)));
	i2 |= j;
	double r = t2 + t1;
	if (i2 > 0) {
		double hfsq = 0.5 * f * f;
		if (k == 0) {
			return f - (hfsq - s * (hfsq + r));
		}
		return dk * EX_LN2HI - ((hfsq - (s * (hfsq + r) + dk * EX_LN2LO)) - f);
	}
	if (k == 0) {
		return f - s * (f - r);
	}
	return dk * EX_LN2HI - ((s * (f - r) - dk * EX_LN2LO) - f);
}

} // namespace swarm::sim::js
