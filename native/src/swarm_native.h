#ifndef SWARM_NATIVE_H
#define SWARM_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

namespace swarm {

// Entry point of the extension for GDScript: SwarmNative.version() and friends are static methods.
// Step C1 only proves the toolchain (loading, build identity, deterministic floating point); the
// combat simulation moves here in C2/C3 (docs/godot-port-design.md section 5.5).
class SwarmNative : public godot::RefCounted {
	GDCLASS(SwarmNative, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	// Build identity: library version, godot-cpp commit, API version, target, compiler, fp flags.
	static godot::String version();

	// a * b + c computed as two IEEE operations. See fp_probe.cpp for the inputs that tell fused
	// from unfused evaluation apart.
	static double fp_contract_probe(double p_a, double p_b, double p_c);

	// Two's complement addition of two int64 values; overflow wraps around (no undefined behavior).
	static int64_t add_int64(int64_t p_a, int64_t p_b);
};

} // namespace swarm

#endif // SWARM_NATIVE_H
