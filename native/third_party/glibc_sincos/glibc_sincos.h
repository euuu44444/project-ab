// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Interface of libswarm_glibc_sincos, the static library that holds the glibc-derived sin and cos (LGPL-2.1 or
// later; see LICENSE and README.md in this directory). This header was written for this project; the code it
// declares (sincos.cpp, sincos_tables.cpp) is derived from glibc.
//
// Kept free of Godot headers on purpose: the library is built on its own and linked into the extension and into the
// C++ test program (tools/check_native_sources.py checks this).
#ifndef SWARM_GLIBC_SINCOS_H
#define SWARM_GLIBC_SINCOS_H

#include <cstdint>

namespace swarm_glibc {

// Math.sin(x) and Math.cos(x) of Chromium 141 (V8 14.1: glibc's s_sin.c), bit for bit, on every platform: only
// IEEE-754 additions, subtractions, multiplications and comparisons are used (build with -ffp-contract=off).
// NaN and the infinities give NaN. There is no shared state, so the functions are re-entrant.
double sin(double x);
double cos(double x);

// The tables (sincos_tables.cpp). Implementation detail, declared here so that the definitions and their users agree.
// SINCOSTAB_BITS: the 440 doubles of glibc's __sincostab as IEEE-754 bit patterns; TOVERP: 2/pi in base 2^24.
extern const uint64_t SINCOSTAB_BITS[440];
extern const double TOVERP[75];

} // namespace swarm_glibc

#endif // SWARM_GLIBC_SINCOS_H
