/*
 * IBM Accurate Mathematical Library
 * written by International Business Machines Corp.
 * Copyright (C) 2001-2022 Free Software Foundation, Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU  Lesser General Public License
 * along with this program; if not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Modified 2026-10-25 (LGPL-2.1 section 2(b)). This is NOT the glibc file. It is a C++17 transcription of the
 * GDScript port godot/sim/js_compat.gd of this repository (JsMath.sin, JsMath.cos, JsMath._branred and the constants
 * G_* and BR_*), which was ported from glibc sysdeps/ieee754/dbl-64/s_sin.c, branred.c, branred.h, usncs.h and dla.h
 * (the copies in V8 14.1.146.11, third_party/glibc, glibc commit 4e21c2075193e406a92c0d1cb091a7c804fda4d9). The same
 * copyright notice and license (without the "written by" line) are carried by branred.c, branred.h, usncs.h, dla.h
 * and sincostab.c. The changes against upstream are listed in README.md of this directory.
 *
 * What the code computes: Math.sin and Math.cos of Chromium (V8 calls glibc's s_sin.c), bit for bit. Only IEEE-754
 * additions, subtractions, multiplications and comparisons are used, so with -ffp-contract=off (no fused
 * multiply-add) and round-to-nearest the results are the same on every platform.
 */

#include "glibc_sincos.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

namespace swarm_glibc {

namespace {

constexpr double kInfinity = std::numeric_limits<double>::infinity();

// Bit access by memcpy (glibc's mynumber union is not used).
inline uint64_t to_bits(double x) {
	uint64_t bits;
	std::memcpy(&bits, &x, sizeof bits);
	return bits;
}

inline double from_bits(uint64_t bits) {
	double x;
	std::memcpy(&x, &bits, sizeof x);
	return x;
}

// High 32 bits of x (glibc: u.i[HIGH_HALF]).
inline uint32_t high_word(double x) {
	return static_cast<uint32_t>(to_bits(x) >> 32);
}

// SINCOSTAB[i], an entry of __sincostab (sincos_tables.cpp keeps the bit patterns).
inline double sincostab(uint32_t i) {
	return from_bits(SINCOSTAB_BITS[i]);
}

// glibc usncs.h (sin / cos)
constexpr double G_S1 = -0x1.5555555555555p-3;
constexpr double G_S2 = 0x1.1111111110ECEp-7;
constexpr double G_S3 = -0x1.A01A019DB08B8p-13;
constexpr double G_S4 = 0x1.71DE27B9A7ED9p-19;
constexpr double G_S5 = -0x1.ADDFFC2FCDF59p-26;
constexpr double G_BIG = 0x1.8000000000000p45;
constexpr double G_HP0 = 0x1.921FB54442D18p0;
constexpr double G_HP1 = 0x1.1A62633145C07p-54;
constexpr double G_MP1 = 0x1.921FB58000000p0;
constexpr double G_MP2 = -0x1.DDE973C000000p-27;
constexpr double G_PP3 = -0x1.CB3B398000000p-55;
constexpr double G_PP4 = -0x1.D747F23E32ED7p-83;
constexpr double G_HPINV = 0x1.45F306DC9C883p-1;
constexpr double G_TOINT = 0x1.8000000000000p52;

// glibc s_sin.c
constexpr double G_SN3 = -0x1.5555555555515p-3;  // -1.66666666666664880952546298448555E-01
constexpr double G_SN5 = 0x1.11110E829872Fp-7;  // 8.33333214285722277379541354343671E-03
constexpr double G_CS2 = 0x1.0000000000000p-1;  // 4.99999999999999999999950396842453E-01
constexpr double G_CS4 = -0x1.5555555555535p-5;  // -4.16666666666664434524222570944589E-02
constexpr double G_CS6 = 0x1.6C16BEDD9E239p-10;  // 1.38888874007937613028114285595617E-03

// glibc branred.h (range reduction for |x| >= 105414350; its mp1/mp2/hp0/hp1 are not those of usncs.h)
constexpr double BR_T576 = 0x1.0000000000000p576;  // mynumber {0x63f00000, 0}: 2^576
constexpr double BR_TM600 = 0x1.0000000000000p-600;  // mynumber {0x1a700000, 0}: 2^-600
constexpr double BR_TM24 = 0x1.0000000000000p-24;  // mynumber {0x3e700000, 0}: 2^-24
constexpr double BR_BIG = 0x1.8000000000000p52;  // mynumber {0x43380000, 0}: 6755399441055744
constexpr double BR_BIG1 = 0x1.8000000000000p54;  // mynumber {0x43580000, 0}: 27021597764222976
constexpr double BR_HP0 = 0x1.921FB54442D18p0;  // mynumber {0x3FF921FB, 0x54442D18}
constexpr double BR_HP1 = 0x1.1A62633145C07p-54;  // mynumber {0x3C91A626, 0x33145C07}
constexpr double BR_MP1 = 0x1.921FB58000000p0;  // mynumber {0x3FF921FB, 0x58000000}
constexpr double BR_MP2 = -0x1.DDE9740000000p-27;  // mynumber {0xBE4DDE97, 0x40000000}
constexpr double BR_SPLIT = 0x1.0000002000000p27;  // 2^27 + 1

// Thresholds: the C code compares the HIGH WORD of |x|; |x| < D (D the double with that high word and low word 0) is the same test
constexpr double G_TH_2M26 = 0x1.0000000000000p-26;  // sin: 2^-26 (high word 0x3e500000)
constexpr double G_TH_2M27 = 0x1.0000000000000p-27;  // cos: 2^-27 (high word 0x3e400000)
constexpr double G_TH_0855 = 0x1.B600000000000p-1;  // sin/cos: 0.855469 (high word 0x3feb6000)
constexpr double G_TH_2426 = 0x1.368FD00000000p1;  // sin/cos: 2.426265 (high word 0x400368fd)
constexpr double G_TH_REDUCE = 0x1.921FB00000000p26;  // sin/cos: 105414350 (end of the Cody-Waite reduction) (high word 0x419921fb)

// glibc __branred: reduces |x| >= 105414350 modulo pi/2 using 2/pi in base 2^24. Returns the quadrant (0..3) and
// leaves the reduced argument in *a_out + *da_out. Not used by the simulation (angles stay small) but part of Math.sin.
uint32_t branred(double x, double *a_out, double *da_out) {
	double xs = x * BR_TM600;
	double t = xs * BR_SPLIT;
	double x1 = t - (t - xs);
	double x2 = xs - x1;
	double r[6] = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
	double res[6] = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }; // b1, bb1, sum1, b2, bb2, sum2
	for (int part = 0; part < 2; ++part) {
		double xp = part == 0 ? x1 : x2;
		double sum = 0.0;
		// The biased exponent of xp is at most 2047; k stays below 67, so TOVERP[k + 5] is inside the 75 entries.
		int32_t k = static_cast<int32_t>((high_word(xp) >> 20) & 2047u);
		k = (k - 450) / 24; // truncates toward zero, like the original
		if (k < 0) {
			k = 0;
		}
		double gor = from_bits(to_bits(BR_T576) - (static_cast<uint64_t>(k * 24) << 52));
		for (int i = 0; i < 6; ++i) {
			r[i] = xp * TOVERP[k + i] * gor;
			gor *= BR_TM24;
		}
		for (int i = 0; i < 3; ++i) {
			double s0 = (r[i] + BR_BIG) - BR_BIG;
			sum += s0;
			r[i] -= s0;
		}
		t = 0.0;
		for (int i = 0; i < 6; ++i) {
			t += r[5 - i];
		}
		double bb = (((((r[0] - t) + r[1]) + r[2]) + r[3]) + r[4]) + r[5];
		double s = (t + BR_BIG) - BR_BIG;
		sum += s;
		t -= s;
		double b = t + bb;
		bb = (t - b) + bb;
		s = (sum + BR_BIG1) - BR_BIG1;
		sum -= s;
		res[part * 3] = b;
		res[part * 3 + 1] = bb;
		res[part * 3 + 2] = sum;
	}
	double b1 = res[0];
	double bb1 = res[1];
	double b2 = res[3];
	double bb2 = res[4];
	double sumt = res[2] + res[5];
	double bt = b1 + b2;
	double bbt = std::fabs(b1) > std::fabs(b2) ? (b1 - bt) + b2 : (b2 - bt) + b1;
	if (bt > 0.5) {
		bt -= 1.0;
		sumt += 1.0;
	} else if (bt < -0.5) {
		bt += 1.0;
		sumt -= 1.0;
	}
	double s2 = bt + (bbt + bb1 + bb2);
	double t3 = ((bt - s2) + bbt) + (bb1 + bb2);
	double bs = s2 * BR_SPLIT;
	double t1 = bs - (bs - s2);
	double t2 = s2 - t1;
	double b3 = s2 * BR_HP0;
	double bb3 = (((t1 * BR_MP1 - b3) + t1 * BR_MP2) + t2 * BR_MP1) + (t2 * BR_MP2 + s2 * BR_HP1 + t3 * BR_HP0);
	double s3 = b3 + bb3;
	double t4 = (b3 - s3) + bb3;
	*a_out = s3;
	*da_out = t4;
	// sumt is a small integer here (the sums were reduced to [-2, 2] above), so the conversion is in range.
	return static_cast<uint32_t>(static_cast<int32_t>(sumt)) & 3u;
}

} // namespace

// do_sin / do_cos / do_sincos / reduce_sincos are written out inside sin and cos (function calls cost more than the
// arithmetic); the structure is: reduce to a + da with |a| < pi/4 and a quadrant n, then evaluate sin or cos of (a, da)
// by a Taylor polynomial or by a table lookup at a multiple of 1/128.

double sin(double x) {
	double ax = std::fabs(x);
	double a;
	double da;
	uint32_t n = 0;
	bool mid = false;
	if (ax < G_TH_0855) {
		if (ax < G_TH_2M26) {
			return x;
		}
		a = x;
		da = 0.0;
	} else if (ax < G_TH_2426) {
		a = G_HP0 - ax;
		da = G_HP1;
		n = 1;
		mid = true;
	} else if (ax < G_TH_REDUCE) {
		double t0 = x * G_HPINV + G_TOINT;
		double xn = t0 - G_TOINT;
		double y0 = (x - xn * G_MP1) - xn * G_MP2;
		n = static_cast<uint32_t>(static_cast<int32_t>(xn)) & 3u; // |xn| < 6.7e7: in range
		double t1 = xn * G_PP3;
		double t2 = y0 - t1;
		double db = (y0 - t2) - t1;
		t1 = xn * G_PP4;
		a = t2 - t1;
		db += (t2 - a) - t1;
		da = db;
	} else if (ax < kInfinity) {
		n = branred(x, &a, &da);
	} else {
		return std::numeric_limits<double>::quiet_NaN();
	}
	double r;
	if ((n & 1u) == 0) {
		if (std::fabs(a) < 0.126) {
			double xx0 = a * a;
			double poly = (((G_S5 * xx0 + G_S4) * xx0 + G_S3) * xx0 + G_S2) * xx0 + G_S1;
			r = a + ((poly * a - 0.5 * da) * xx0 + da);
		} else {
			double d = a <= 0.0 ? -da : da;
			double aa = std::fabs(a);
			double ur = (G_BIG + aa) - G_BIG;
			double xr = aa - ur;
			double xx = xr * xr;
			double s = xr + (d + xr * xx * (G_SN3 + xx * G_SN5));
			double c = xr * d + xx * (G_CS2 + xx * (G_CS4 + xx * G_CS6));
			uint32_t k = static_cast<uint32_t>(ur * 128.0) << 2; // 0 <= ur <= 0.86: in range
			double sn = sincostab(k);
			double cs = sincostab(k + 2);
			double cor = (sincostab(k + 1) + s * sincostab(k + 3) - sn * c) + cs * s;
			r = std::fabs(sn + cor);
			if (a < 0.0) {
				r = -r;
			}
		}
	} else {
		double d2 = a < 0.0 ? -da : da;
		double aa2 = std::fabs(a);
		double ur2 = (G_BIG + aa2) - G_BIG;
		double xr2 = aa2 - ur2 + d2;
		double xx2 = xr2 * xr2;
		double s2 = xr2 + xr2 * xx2 * (G_SN3 + xx2 * G_SN5);
		double c2 = xx2 * (G_CS2 + xx2 * (G_CS4 + xx2 * G_CS6));
		uint32_t k2 = static_cast<uint32_t>(ur2 * 128.0) << 2;
		double sn2 = sincostab(k2);
		double cs2 = sincostab(k2 + 2);
		double cor2 = (sincostab(k2 + 3) - s2 * sincostab(k2 + 1) - cs2 * c2) - sn2 * s2;
		r = cs2 + cor2;
	}
	if (mid) {
		r = std::fabs(r);
		return x < 0.0 ? -r : r;
	}
	return (n & 2u) != 0 ? -r : r;
}

double cos(double x) {
	double ax = std::fabs(x);
	double a;
	double da;
	uint32_t n = 1;
	if (ax < G_TH_0855) {
		if (ax < G_TH_2M27) {
			return 1.0;
		}
		a = x;
		da = 0.0;
	} else if (ax < G_TH_2426) {
		double y = G_HP0 - ax;
		a = y + G_HP1;
		da = (y - a) + G_HP1;
		n = 0;
	} else if (ax < G_TH_REDUCE) {
		double t0 = x * G_HPINV + G_TOINT;
		double xn = t0 - G_TOINT;
		double y0 = (x - xn * G_MP1) - xn * G_MP2;
		n = (static_cast<uint32_t>(static_cast<int32_t>(xn)) + 1u) & 3u; // |xn| < 6.7e7: in range
		double t1 = xn * G_PP3;
		double t2 = y0 - t1;
		double db = (y0 - t2) - t1;
		t1 = xn * G_PP4;
		a = t2 - t1;
		db += (t2 - a) - t1;
		da = db;
	} else if (ax < kInfinity) {
		n = (branred(x, &a, &da) + 1u) & 3u;
	} else {
		return std::numeric_limits<double>::quiet_NaN();
	}
	double r;
	if ((n & 1u) == 0) {
		if (std::fabs(a) < 0.126) {
			double xx0 = a * a;
			double poly = (((G_S5 * xx0 + G_S4) * xx0 + G_S3) * xx0 + G_S2) * xx0 + G_S1;
			r = a + ((poly * a - 0.5 * da) * xx0 + da);
		} else {
			double d = a <= 0.0 ? -da : da;
			double aa = std::fabs(a);
			double ur = (G_BIG + aa) - G_BIG;
			double xr = aa - ur;
			double xx = xr * xr;
			double s = xr + (d + xr * xx * (G_SN3 + xx * G_SN5));
			double c = xr * d + xx * (G_CS2 + xx * (G_CS4 + xx * G_CS6));
			uint32_t k = static_cast<uint32_t>(ur * 128.0) << 2;
			double sn = sincostab(k);
			double cs = sincostab(k + 2);
			double cor = (sincostab(k + 1) + s * sincostab(k + 3) - sn * c) + cs * s;
			r = std::fabs(sn + cor);
			if (a < 0.0) {
				r = -r;
			}
		}
	} else {
		double d2 = a < 0.0 ? -da : da;
		double aa2 = std::fabs(a);
		double ur2 = (G_BIG + aa2) - G_BIG;
		double xr2 = aa2 - ur2 + d2;
		double xx2 = xr2 * xr2;
		double s2 = xr2 + xr2 * xx2 * (G_SN3 + xx2 * G_SN5);
		double c2 = xx2 * (G_CS2 + xx2 * (G_CS4 + xx2 * G_CS6));
		uint32_t k2 = static_cast<uint32_t>(ur2 * 128.0) << 2;
		double sn2 = sincostab(k2);
		double cs2 = sincostab(k2 + 2);
		double cor2 = (sincostab(k2 + 3) - s2 * sincostab(k2 + 1) - cs2 * c2) - sn2 * s2;
		r = cs2 + cor2;
	}
	return (n & 2u) != 0 ? -r : r;
}

} // namespace swarm_glibc
