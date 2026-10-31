#include "fp_probe.h"

// Probe inputs (see also godot/tests/test_native_extension.gd):
//   a = b = 1 + 2^-30 (bits 0x3FF0000000400000), c = -(1 + 2^-29) (bits 0xBFF0000000800000)
// The exact product is 1 + 2^-29 + 2^-60. It needs 61 bits; a double keeps 53.
//   unfused: the product is rounded to 1 + 2^-29, the sum with c is exactly +0.0 (bits 0x0000000000000000)
//   fused (FMA): the product is kept exact and the sum is 2^-60 (bits 0x3C30000000000000)
// build_native.sh also checks that the compiled body holds no fused instruction (fmadd, fmsub,
// fnmadd, fnmsub, fmla, fmls on arm64; vfma, vfms, vfnma, vfnms on arm32; vfmadd... on x86-64).
extern "C" __attribute__((noinline)) double swarm_fp_probe_mul_add(double a, double b, double c) {
	return a * b + c;
}
