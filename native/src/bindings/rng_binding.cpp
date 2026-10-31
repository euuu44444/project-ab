#include "rng_binding.h"

#include <vector>

#include <godot_cpp/variant/utility_functions.hpp>

#include "sim/js_math.h"

using namespace godot;

namespace swarm {

namespace {

// randi / randi_fx need |a| and |b| <= 2^31 (see sim/game_rng.h). Scripts can pass any int, so the bindings check it
// here, in every build, and report instead of calling.
bool randi_bounds_ok(const char *p_method, int64_t p_a, int64_t p_b) {
	constexpr int64_t kBound = 2147483648;
	if (p_a >= -kBound && p_a <= kBound && p_b >= -kBound && p_b <= kBound) {
		return true;
	}
	UtilityFunctions::push_error(String(p_method) + ": |a| and |b| must be at most 2^31 (got " + String::num_int64(p_a) + ", " + String::num_int64(p_b) + ")");
	return false;
}

} // namespace

// ---- SwarmSeededRng -----------------------------------------------------------------------------------------------

void SwarmSeededRng::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &SwarmSeededRng::set_seed);
	ClassDB::bind_method(D_METHOD("next_u32"), &SwarmSeededRng::next_u32);
	ClassDB::bind_method(D_METHOD("next_float"), &SwarmSeededRng::next_float);
	ClassDB::bind_static_method("SwarmSeededRng", D_METHOD("normalize_seed", "js_seed"), &SwarmSeededRng::normalize_seed);
	ClassDB::bind_method(D_METHOD("get_state"), &SwarmSeededRng::get_state);
	ClassDB::bind_method(D_METHOD("set_state", "state"), &SwarmSeededRng::set_state);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "state"), "set_state", "get_state");
}

void SwarmSeededRng::set_seed(int64_t p_seed) {
	rng_.set_seed(p_seed);
}

int64_t SwarmSeededRng::next_u32() {
	return rng_.next_u32();
}

double SwarmSeededRng::next_float() {
	return rng_.next_float();
}

int64_t SwarmSeededRng::normalize_seed(double p_js_seed) {
	return sim::SeededRng::normalize_seed(p_js_seed);
}

int64_t SwarmSeededRng::get_state() const {
	return rng_.state();
}

void SwarmSeededRng::set_state(int64_t p_state) {
	rng_.set_state(sim::js::i32(p_state)); // the state is an int32, like a value read from `state`
}

// ---- SwarmGameRng -------------------------------------------------------------------------------------------------

void SwarmGameRng::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &SwarmGameRng::set_seed);
	ClassDB::bind_method(D_METHOD("random"), &SwarmGameRng::random);
	ClassDB::bind_method(D_METHOD("rand", "a", "b"), &SwarmGameRng::rand);
	ClassDB::bind_method(D_METHOD("randi", "a", "b"), &SwarmGameRng::randi);
	ClassDB::bind_method(D_METHOD("chance", "p"), &SwarmGameRng::chance);
	ClassDB::bind_method(D_METHOD("index", "length"), &SwarmGameRng::index);
	ClassDB::bind_method(D_METHOD("shuffle", "items"), &SwarmGameRng::shuffle);
	ClassDB::bind_method(D_METHOD("get_draws"), &SwarmGameRng::get_draws);
	ClassDB::bind_method(D_METHOD("get_seed_value"), &SwarmGameRng::get_seed_value);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "draws"), "", "get_draws");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "seed_value"), "", "get_seed_value");
}

void SwarmGameRng::set_seed(int64_t p_seed) {
	rng_.set_seed(p_seed);
}

double SwarmGameRng::random() {
	return rng_.random();
}

double SwarmGameRng::rand(double p_a, double p_b) {
	return rng_.rand(p_a, p_b);
}

int64_t SwarmGameRng::randi(int64_t p_a, int64_t p_b) {
	if (!randi_bounds_ok("SwarmGameRng.randi", p_a, p_b)) {
		return 0;
	}
	return rng_.randi(p_a, p_b);
}

bool SwarmGameRng::chance(double p_p) {
	return rng_.chance(p_p);
}

int64_t SwarmGameRng::index(int64_t p_length) {
	return rng_.index(p_length);
}

Array SwarmGameRng::shuffle(Array p_items) {
	// godot::Array has no contiguous access to its elements: the elements are copied (a Variant copy is cheap), shuffled
	// and written back, so that the array handed in is changed in place, as the GDScript GameRng.shuffle does.
	int64_t count = p_items.size();
	if (count >= 2) {
		std::vector<Variant> elements(static_cast<size_t>(count));
		for (int64_t i = 0; i < count; ++i) {
			elements[static_cast<size_t>(i)] = p_items[i];
		}
		rng_.shuffle(elements.data(), elements.size());
		for (int64_t i = 0; i < count; ++i) {
			p_items[i] = elements[static_cast<size_t>(i)];
		}
	}
	return p_items;
}

int64_t SwarmGameRng::get_draws() const {
	return rng_.draws();
}

int64_t SwarmGameRng::get_seed_value() const {
	return rng_.seed_value();
}

// ---- SwarmFxRng ---------------------------------------------------------------------------------------------------

void SwarmFxRng::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &SwarmFxRng::set_seed);
	ClassDB::bind_method(D_METHOD("random"), &SwarmFxRng::random);
	ClassDB::bind_method(D_METHOD("rand_fx", "a", "b"), &SwarmFxRng::rand_fx);
	ClassDB::bind_method(D_METHOD("randi_fx", "a", "b"), &SwarmFxRng::randi_fx);
	ClassDB::bind_method(D_METHOD("chance_fx", "p"), &SwarmFxRng::chance_fx);
}

void SwarmFxRng::set_seed(int64_t p_seed) {
	rng_.set_seed(p_seed);
}

double SwarmFxRng::random() {
	return rng_.random();
}

double SwarmFxRng::rand_fx(double p_a, double p_b) {
	return rng_.rand_fx(p_a, p_b);
}

int64_t SwarmFxRng::randi_fx(int64_t p_a, int64_t p_b) {
	if (!randi_bounds_ok("SwarmFxRng.randi_fx", p_a, p_b)) {
		return 0;
	}
	return rng_.randi_fx(p_a, p_b);
}

bool SwarmFxRng::chance_fx(double p_p) {
	return rng_.chance_fx(p_p);
}

} // namespace swarm
