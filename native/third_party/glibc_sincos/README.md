# libswarm_glibc_sincos: sin and cos from glibc (LGPL-2.1 or later)

`swarm_glibc::sin` and `swarm_glibc::cos` give the same numbers as `Math.sin` and `Math.cos` of Chromium 141 on every
platform, bit for bit. Chromium's V8 14.1 computes them with the sin/cos routines of glibc (IBM Accurate Mathematical
Library, `s_sin.c`); the simulation of this game has to reproduce them exactly (docs/godot-port-design.md section 5.2).

This directory is built on its own, with the compiler flags of the rest of `native/` (`-ffp-contract=off -fno-fast-math -O2`,
checked by `native/SConstruct`), into the static library `libswarm_glibc_sincos.a`. The extension library
`libswarm_native.<platform>.<target>.<arch>.so` and the test program `swarm_sim_tests` link that archive. Nothing in this
directory includes a Godot header (`tools/check_native_sources.py` checks it).

**License: GNU Lesser General Public License, version 2.1 or (at your option) any later version.** The text is in
`LICENSE` (an exact copy of `third_party/glibc/LICENSE` of V8 14.1.146.11; `tools/check_native_sources.py` checks its SHA-256).
The rest of `native/` does not carry this license; see `native/THIRD_PARTY_NOTICES.md`.

## Where the code comes from

| | |
| --- | --- |
| Upstream | glibc, `sysdeps/ieee754/dbl-64/` (https://www.gnu.org/software/libc/) |
| Copy used | V8 14.1.146.11 (the V8 of Chromium 141, tag `14.1.146.11` of https://chromium.googlesource.com/v8/v8), directory `third_party/glibc/` |
| glibc revision | `4e21c2075193e406a92c0d1cb091a7c804fda4d9` (`README.v8`); `METADATA` names version `985ff73ad29bc4cc4e15ce6d182ecd808b7b02d7`, last upgraded 2022-11-07 |
| Taken on | 2026-10-25 (URL form `https://chromium.googlesource.com/v8/v8/+/refs/tags/14.1.146.11/<path>?format=TEXT`, base64) |

The files (paths below `third_party/glibc/` of V8) and their SHA-256:

| File | Content used here | SHA-256 |
| --- | --- | --- |
| `LICENSE` | LGPL-2.1 text (copied as `LICENSE` here) | `b634ab5640e258563c536e658cad87080553df6f34f62269a21d554844e58bfe` |
| `README.v8`, `METADATA` | origin | `2876e977d794d5e8c5cb3a8416ac7ee9bcb9c9ec9f5eca814616ccfe49f176de`, `b87ba94e445c4c75d364a3913f2f84e528b4f0abe78c9ef1b1d91ef558b32ae2` |
| `src/sysdeps/ieee754/dbl-64/s_sin.c` | `glibc_sin`, `glibc_cos`, `do_sin`, `do_cos`, `reduce_sincos`, `do_sincos`; the constants `sn3` to `cs6` | `b05c66b322da8bde56fab4ef45bdb44c8e6178494648c89f1eb64272b749d4b4` |
| `.../branred.c` | `__branred` (reduction of large arguments) | `8a21104b079e3d5bc42bc903fdaf9d93bf6dc8b0e0e3030c1b3c8261bf6577c3` |
| `.../branred.h` | the table `toverp` and the constants `t576` to `mp2` | `7750d1665e454b94877020e0393f8b29e20d7ba51451a54f60a8ae2796354b9e` |
| `.../sincostab.c` | `__sincostab` (440 doubles) | `b0d85d1187a70beb14bf5b274c53706551e9ff29181c9a4a01dd019c8ccde2b7` |
| `.../usncs.h` | the constants `s1` to `hpinv`, `toint` (hex floats) | `c78fb520931e863618a60dc28206d5393f884ede9cbaffa3758b8dbc11553ee3` |
| `.../dla.h` | `CN` (= 2^27 + 1) | `8d94c1212d955c5536ddb8f64ed4d2b01f8b04957f81ebf1d17422e9d74d5cb2` |
| `.../mydefs.h` | `int4`, `mynumber` (not used here) | `41a661cdcb78709a3f3ca149b7a66ddccec62fffd4131ca727a959207e9c8891` |

The code in this directory is not a copy of these files. It is a C++17 transcription of the GDScript port in this repository,
`godot/sim/js_compat.gd` (`JsMath.sin`, `JsMath.cos`, `JsMath._branred` and the constants and tables they use), which was ported
from these files in step S3 and checked against 20,000 golden vectors from Chromium 141. `tools/check_js_compat_consts.mjs`
checks every constant and both tables against the upstream literals and against the GDScript port.

## Files

| File | Content |
| --- | --- |
| `glibc_sincos.h` | the interface: `swarm_glibc::sin(double)`, `swarm_glibc::cos(double)`, and the declarations of the tables |
| `sincos.cpp` | `sin`, `cos`, `branred` and the constants `G_*` and `BR_*` (derived from `s_sin.c`, `branred.c`, `branred.h`, `usncs.h`, `dla.h`) |
| `sincos_tables.cpp` | `SINCOSTAB_BITS` (440 IEEE-754 bit patterns) and `TOVERP` (75 digits of 2/pi in base 2^24) (derived from `sincostab.c`, `branred.h`) |
| `LICENSE` | LGPL-2.1 |

Each derived file starts with the copyright notice and the license notice of the upstream files, word for word, followed by a
notice that the file was changed, with the date (LGPL-2.1 section 2(b)).

## Changes against upstream

1. The C code was ported to GDScript (S3, `godot/sim/js_compat.gd`) and that was transcribed to C++17 (C2). The namespace is
   `swarm_glibc`; only `sin` and `cos` (V8's `glibc_sin`, `glibc_cos`) are visible from outside, the rest is in an anonymous
   namespace.
2. `do_sin`, `do_cos`, `reduce_sincos` and `do_sincos` are written out inside `sin` and `cos`.
3. The comparisons of the high word of the argument (`k < 0x3feb6000` and so on) are comparisons of `|x|` with the double that
   has that high word and a zero low word (`G_TH_*`): the same test.
4. `SINCOS_TABLE_LOOKUP` finds its index as `(uint32_t)(ur * 128) << 2`, where `ur = (big + |x|) - big`, instead of reading
   the low word of `big + |x|`: the same number, without looking at the bits of a double.
5. The tables are kept as IEEE-754 bit patterns (`uint64_t`) and read with `memcpy`. `mynumber` (a union used for type punning,
   which depends on the byte order) is not used. The constants are hex float literals with the names of the GDScript port
   (`G_S1`, `BR_T576`, ...); the decimal literals of `s_sin.c` are written as the hex float of the same double.
6. The glibc-internal machinery is gone: the empty definitions of `attribute_hidden`, `SECTION` and `__always_inline` and the
   `<errno.h>` include of V8's copy. (The setting of the rounding mode, the forcing of underflow and the setting of `errno` of
   full glibc are not in V8's copy either; none of them is here.) The rounding mode must be round-to-nearest, which
   `swarm::sim::fp_environment_ok` checks at run time.
7. `copysign (sn + cor, xold)` is `|sn + cor|` with a sign test on the argument, and `x / x` for a NaN or infinite argument is
   a quiet NaN (the result of `x / x`, without the payload of the argument).
8. `__branred` returns the quadrant (`n mod 4`) and gives the reduced argument through two pointers (`*a`, `*aa`) instead of
   the C array `r[]` and the union members; the local arrays are plain `double[6]`.

## Static linking and the LGPL (read this before distributing)

The extension library `libswarm_native.*.so` contains this code, linked from the static library `libswarm_glibc_sincos.a`. The
test program contains it too, but is never distributed.

- **Fact (LGPL-2.1 section 6):** whoever distributes a work that links the library statically must allow the user to modify the
  library and relink: for example by supplying the object files of the rest of the work ("the complete machine-readable work
  that uses the Library, as object code and/or source code"), the source of this directory with the changes used, a copy of
  `LICENSE`, and prominent notice that the library is used and covered by the license (sections 6 and 6a).
- **Decision (user, 2026-10-24):** the distribution policy (for example a switch to a shared library, which section 6b allows
  without supplying objects) is made in step S9. Until then no APK for distribution is built; the debug APKs of the build
  scripts are for development only.
- To relink with a modified library: replace the files here, run `tools/build_native.sh`, which rebuilds
  `libswarm_glibc_sincos.a` and relinks the extension. The objects of the rest of the extension are in the build directory
  (`$SWARM_CACHE_DIR/native-build/<configuration>/swarm_native/*.os`).
