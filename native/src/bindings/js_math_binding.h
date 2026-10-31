#ifndef SWARM_JS_MATH_BINDING_H
#define SWARM_JS_MATH_BINDING_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace swarm {

// Godot binding of swarm::sim::js (native/src/sim/js_math.h): the C++ version of the GDScript class JsMath, as static
// methods of SwarmJsMath (a class named JsMath would collide with the GDScript class_name). Values travel as Variant
// FLOAT (a 64-bit double) and INT (an int64); nothing is computed here, the arguments are converted and passed on.
// The method names and the argument and result types are those of JsMath; to_bits returns the signed int64 of the
// bit pattern. pow is the one function that is not bit-exact (see js_math.h).
class SwarmJsMath : public godot::RefCounted {
	GDCLASS(SwarmJsMath, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	static double sin(double p_x);
	static double cos(double p_x);
	static double atan(double p_x);
	static double atan2(double p_y, double p_x);
	static double exp(double p_x);
	static double log(double p_x);
	static double hypot(double p_x, double p_y);
	static double js_round(double p_x);
	static double trunc(double p_x);
	static double js_mod(double p_a, double p_b);
	static double js_max(double p_a, double p_b);
	static double js_min(double p_a, double p_b);
	static double max3(double p_a, double p_b, double p_c);
	static double min3(double p_a, double p_b, double p_c);
	static double max5(double p_a, double p_b, double p_c, double p_d, double p_e);
	static double min5(double p_a, double p_b, double p_c, double p_d, double p_e);
	static double max_n(const godot::PackedFloat64Array &p_values);
	static double min_n(const godot::PackedFloat64Array &p_values);
	static double clamp(double p_v, double p_lo, double p_hi);
	static double sqrt(double p_x);
	static double floor(double p_x);
	static double ceil(double p_x);
	static double abs(double p_x);
	static double pow(double p_x, double p_y);
	static int64_t to_int32(double p_x);
	static int64_t to_uint32(double p_x);
	static int64_t i32(int64_t p_v);
	static int64_t imul(int64_t p_a, int64_t p_b);
	static int64_t shl(int64_t p_a, int64_t p_n);
	static int64_t sar(int64_t p_a, int64_t p_n);
	static int64_t shr_u(int64_t p_a, int64_t p_n);
	static int64_t to_bits(double p_x);
	static double from_bits(int64_t p_bits);
	static double neg_zero();

	// swarm::sim::fp_environment_ok: round-to-nearest and no flush-to-zero in the current thread.
	static bool fp_environment_ok();
	// What is wrong with the floating-point environment, or "" when fp_environment_ok() is true.
	static godot::String fp_environment_reason();
};

} // namespace swarm

#endif // SWARM_JS_MATH_BINDING_H
