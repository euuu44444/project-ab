# Third-party code in native/

The C++ code of the extension (`native/src`, `native/tests`) is this project's own, except for the parts listed here. The
GDExtension library `libswarm_native.*.so` contains all three of them; godot-cpp (MIT) is linked in as well (see
`tools/setup_cpp.sh` for its pinned commit and its license file, `LICENSE.md` in the godot-cpp checkout).

## 1. glibc: sin and cos (LGPL-2.1 or later)

- Where: `native/third_party/glibc_sincos/`, built as the static library `libswarm_glibc_sincos.a`, linked into
  `libswarm_native.*.so`. Details, the changes against upstream and the upstream files with their SHA-256: `README.md` there.
- Origin: glibc `sysdeps/ieee754/dbl-64/` (IBM Accurate Mathematical Library, Copyright (C) 2001-2022 Free Software
  Foundation, Inc.) as copied into V8 14.1.146.11, `third_party/glibc/`.
- License: GNU Lesser General Public License 2.1 or later, `native/third_party/glibc_sincos/LICENSE`.
- What it means for distribution: the library is linked statically. LGPL-2.1 section 6 then asks for the user's right to
  modify the library and relink (for instance by supplying the object files of the rest of the work and the source of this
  library), a copy of the license and a prominent notice. **No APK for distribution is built until step S9 decides the policy**
  (a shared library is one of the options). The decision of 2026-10-24 is recorded in docs/godot-port-design.md section 5.5.

## 2. fdlibm: atan, atan2, exp, log (Sun Microsystems notice; V8 BSD-3-Clause)

- Where: `native/src/sim/fdlibm.cpp` (the functions `atan`, `atan2`, `exp`, `log` and their constants).
- Origin: fdlibm (http://www.netlib.org/fdlibm) as adapted in V8 14.1.146.11, `src/base/ieee754.cc`. The file keeps the notice of
  Sun Microsystems ("Permission to use, copy, modify, and distribute this software is freely granted, provided that this notice
  is preserved.") and the V8 notice ("Copyright 2016 the V8 project authors"), word for word, at its start.
- License of the V8 part: BSD-3-Clause, `native/LICENSES/V8-BSD-3-Clause.txt` (an exact copy of V8's `LICENSE`; the library
  does not display it at run time, the file travels with the source).

## 3. V8: hypot, round (BSD-3-Clause)

- Where: `native/src/sim/js_math.cpp` (`hypot`, `round`; `max`, `min` and the 32-bit integer functions follow the
  semantics of V8 and of ECMAScript, not its code).
- Origin: algorithms of V8 14.1 (Torque `FastMathHypot`, CodeStubAssembler `Float64Round`), written for this project through
  the GDScript port `godot/sim/js_compat.gd`.
- License: BSD-3-Clause, `native/LICENSES/V8-BSD-3-Clause.txt`.

## Not covered here

`godot/sim/js_compat.gd` (the GDScript version of all of the above, which the combat simulation still uses until step C3) does not carry
these notices yet. It is replaced by the C++ version in C3 (decision of 2026-10-25), and the missing notices are recorded as a known issue
in verification/godot/c2/.
