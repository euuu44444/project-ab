#include "js_math_binding.h"

#include "sim/fp_env.h"
#include "sim/js_math.h"

using namespace godot;

namespace swarm {

void SwarmJsMath::_bind_methods() {
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("sin", "x"), &SwarmJsMath::sin);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("cos", "x"), &SwarmJsMath::cos);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("atan", "x"), &SwarmJsMath::atan);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("atan2", "y", "x"), &SwarmJsMath::atan2);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("exp", "x"), &SwarmJsMath::exp);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("log", "x"), &SwarmJsMath::log);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("hypot", "x", "y"), &SwarmJsMath::hypot);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("js_round", "x"), &SwarmJsMath::js_round);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("trunc", "x"), &SwarmJsMath::trunc);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("js_mod", "a", "b"), &SwarmJsMath::js_mod);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("js_max", "a", "b"), &SwarmJsMath::js_max);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("js_min", "a", "b"), &SwarmJsMath::js_min);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("max3", "a", "b", "c"), &SwarmJsMath::max3);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("min3", "a", "b", "c"), &SwarmJsMath::min3);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("max5", "a", "b", "c", "d", "e"), &SwarmJsMath::max5);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("min5", "a", "b", "c", "d", "e"), &SwarmJsMath::min5);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("max_n", "values"), &SwarmJsMath::max_n);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("min_n", "values"), &SwarmJsMath::min_n);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("clamp", "v", "lo", "hi"), &SwarmJsMath::clamp);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("sqrt", "x"), &SwarmJsMath::sqrt);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("floor", "x"), &SwarmJsMath::floor);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("ceil", "x"), &SwarmJsMath::ceil);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("abs", "x"), &SwarmJsMath::abs);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("pow", "x", "y"), &SwarmJsMath::pow);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("to_int32", "x"), &SwarmJsMath::to_int32);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("to_uint32", "x"), &SwarmJsMath::to_uint32);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("i32", "v"), &SwarmJsMath::i32);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("imul", "a", "b"), &SwarmJsMath::imul);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("shl", "a", "n"), &SwarmJsMath::shl);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("sar", "a", "n"), &SwarmJsMath::sar);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("shr_u", "a", "n"), &SwarmJsMath::shr_u);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("to_bits", "x"), &SwarmJsMath::to_bits);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("from_bits", "bits"), &SwarmJsMath::from_bits);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("neg_zero"), &SwarmJsMath::neg_zero);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("fp_environment_ok"), &SwarmJsMath::fp_environment_ok);
	ClassDB::bind_static_method("SwarmJsMath", D_METHOD("fp_environment_reason"), &SwarmJsMath::fp_environment_reason);
}

double SwarmJsMath::sin(double p_x) {
	return sim::js::sin(p_x);
}

double SwarmJsMath::cos(double p_x) {
	return sim::js::cos(p_x);
}

double SwarmJsMath::atan(double p_x) {
	return sim::js::atan(p_x);
}

double SwarmJsMath::atan2(double p_y, double p_x) {
	return sim::js::atan2(p_y, p_x);
}

double SwarmJsMath::exp(double p_x) {
	return sim::js::exp(p_x);
}

double SwarmJsMath::log(double p_x) {
	return sim::js::log(p_x);
}

double SwarmJsMath::hypot(double p_x, double p_y) {
	return sim::js::hypot(p_x, p_y);
}

double SwarmJsMath::js_round(double p_x) {
	return sim::js::round(p_x);
}

double SwarmJsMath::trunc(double p_x) {
	return sim::js::trunc(p_x);
}

double SwarmJsMath::js_mod(double p_a, double p_b) {
	return sim::js::mod(p_a, p_b);
}

double SwarmJsMath::js_max(double p_a, double p_b) {
	return sim::js::max(p_a, p_b);
}

double SwarmJsMath::js_min(double p_a, double p_b) {
	return sim::js::min(p_a, p_b);
}

double SwarmJsMath::max3(double p_a, double p_b, double p_c) {
	return sim::js::max3(p_a, p_b, p_c);
}

double SwarmJsMath::min3(double p_a, double p_b, double p_c) {
	return sim::js::min3(p_a, p_b, p_c);
}

double SwarmJsMath::max5(double p_a, double p_b, double p_c, double p_d, double p_e) {
	return sim::js::max5(p_a, p_b, p_c, p_d, p_e);
}

double SwarmJsMath::min5(double p_a, double p_b, double p_c, double p_d, double p_e) {
	return sim::js::min5(p_a, p_b, p_c, p_d, p_e);
}

double SwarmJsMath::max_n(const PackedFloat64Array &p_values) {
	return sim::js::max_n(p_values.ptr(), static_cast<size_t>(p_values.size()));
}

double SwarmJsMath::min_n(const PackedFloat64Array &p_values) {
	return sim::js::min_n(p_values.ptr(), static_cast<size_t>(p_values.size()));
}

double SwarmJsMath::clamp(double p_v, double p_lo, double p_hi) {
	return sim::js::clamp(p_v, p_lo, p_hi);
}

double SwarmJsMath::sqrt(double p_x) {
	return sim::js::sqrt(p_x);
}

double SwarmJsMath::floor(double p_x) {
	return sim::js::floor(p_x);
}

double SwarmJsMath::ceil(double p_x) {
	return sim::js::ceil(p_x);
}

double SwarmJsMath::abs(double p_x) {
	return sim::js::abs(p_x);
}

double SwarmJsMath::pow(double p_x, double p_y) {
	return sim::js::pow(p_x, p_y);
}

int64_t SwarmJsMath::to_int32(double p_x) {
	return sim::js::to_int32(p_x);
}

int64_t SwarmJsMath::to_uint32(double p_x) {
	return sim::js::to_uint32(p_x);
}

int64_t SwarmJsMath::i32(int64_t p_v) {
	return sim::js::i32(p_v);
}

int64_t SwarmJsMath::imul(int64_t p_a, int64_t p_b) {
	return sim::js::imul(p_a, p_b);
}

int64_t SwarmJsMath::shl(int64_t p_a, int64_t p_n) {
	return sim::js::shl(p_a, p_n);
}

int64_t SwarmJsMath::sar(int64_t p_a, int64_t p_n) {
	return sim::js::sar(p_a, p_n);
}

int64_t SwarmJsMath::shr_u(int64_t p_a, int64_t p_n) {
	return sim::js::shr_u(p_a, p_n);
}

int64_t SwarmJsMath::to_bits(double p_x) {
	return static_cast<int64_t>(sim::js::to_bits(p_x)); // the same bit pattern as a signed int64
}

double SwarmJsMath::from_bits(int64_t p_bits) {
	return sim::js::from_bits(static_cast<uint64_t>(p_bits));
}

double SwarmJsMath::neg_zero() {
	return sim::js::neg_zero();
}

bool SwarmJsMath::fp_environment_ok() {
	return sim::fp_environment_ok(nullptr);
}

String SwarmJsMath::fp_environment_reason() {
	const char *reason = "";
	sim::fp_environment_ok(&reason);
	return String(reason);
}

} // namespace swarm
