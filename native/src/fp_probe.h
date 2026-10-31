#ifndef SWARM_FP_PROBE_H
#define SWARM_FP_PROBE_H

// Kept free of Godot headers on purpose: tools/build_native.sh compiles this file by itself (once with
// and once without FMA contraction) to prove that its disassembly check can fail.
extern "C" {

// a * b + c as two IEEE operations (multiply, round, add, round). A fused multiply-add rounds once,
// so the result differs for the inputs documented in fp_probe.cpp. Never inlined, so that the
// function body stays visible in the object file.
double swarm_fp_probe_mul_add(double a, double b, double c);
}

#endif // SWARM_FP_PROBE_H
