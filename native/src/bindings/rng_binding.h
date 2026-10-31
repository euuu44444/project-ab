#ifndef SWARM_RNG_BINDING_H
#define SWARM_RNG_BINDING_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

#include "sim/fx_rng.h"
#include "sim/game_rng.h"
#include "sim/seeded_rng.h"

namespace swarm {

// Godot bindings of the random number generators of native/src/sim (the C++ versions of the GDScript classes
// SeededRng, GameRng and FxRng). GDExtension classes cannot take arguments in new(): a generator starts from its
// default seed (SwarmSeededRng and SwarmGameRng: 0, which means 2654435769; SwarmFxRng: 0x9E3779B9) and set_seed()
// sets the seed. Values travel as Variant FLOAT (a double) and INT (an int64); nothing is computed here.

class SwarmSeededRng : public godot::RefCounted {
	GDCLASS(SwarmSeededRng, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	void set_seed(int64_t p_seed);
	int64_t next_u32();
	double next_float();
	// `seed>>>0||2654435769` for a JavaScript number.
	static int64_t normalize_seed(double p_js_seed);
	// The generator state as a signed int32 (property `state`).
	int64_t get_state() const;
	void set_state(int64_t p_state);

private:
	sim::SeededRng rng_;
};

class SwarmGameRng : public godot::RefCounted {
	GDCLASS(SwarmGameRng, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	void set_seed(int64_t p_seed);
	double random();
	double rand(double p_a, double p_b);
	// Both bounds inclusive; |a| and |b| must be at most 2^31, otherwise an error is reported and 0 returned.
	int64_t randi(int64_t p_a, int64_t p_b);
	bool chance(double p_p);
	int64_t index(int64_t p_length);
	// Shuffles the array in place and returns it; draws size - 1 times.
	godot::Array shuffle(godot::Array p_items);
	// Properties `draws` and `seed_value` (read only).
	int64_t get_draws() const;
	int64_t get_seed_value() const;

private:
	sim::GameRng rng_;
};

class SwarmFxRng : public godot::RefCounted {
	GDCLASS(SwarmFxRng, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	void set_seed(int64_t p_seed);
	double random();
	double rand_fx(double p_a, double p_b);
	// Both bounds inclusive; |a| and |b| must be at most 2^31, otherwise an error is reported and 0 returned.
	int64_t randi_fx(int64_t p_a, int64_t p_b);
	bool chance_fx(double p_p);

private:
	sim::FxRng rng_;
};

} // namespace swarm

#endif // SWARM_RNG_BINDING_H
