#ifndef SWARM_SIM_SEEDED_RNG_H
#define SWARM_SIM_SEEDED_RNG_H

// Port of the game's makeSeededRandom(seed) (a mulberry32 variant), bit for bit: the C++ version of
// godot/sim/rng.gd (SeededRng).
//
// # port: makeSeededRandom
//   function makeSeededRandom(seed){let a=seed>>>0||2654435769;return function(){a|=0;a=a+1831565813|0;
//     let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296;};}
//
// Every output is exactly k / 2^32 for an integer k in [0, 2^32), so next_u32() gives the exact k and next_float()
// is k / 4294967296.0 (a division by a power of two: exact in 64-bit floats).
//
// Integer arithmetic. JavaScript keeps `a` and `t` as int32 values. Here the state and all intermediate values are
// uint32_t, which wraps modulo 2^32 (signed overflow would be undefined); `a + 1831565813 | 0`, Math.imul and the
// XORs only depend on the bit patterns, and `x >>> n` is a plain shift of the unsigned value. The conversion to
// int32_t happens in state() only.

#include <cstdint>

#include "bits.h"
#include "js_math.h"

namespace swarm::sim {

class SeededRng {
public:
	// The seed that replaces 0: `seed>>>0||2654435769`.
	static constexpr uint32_t kDefaultSeed = 2654435769u;

	// `seed` follows `seed>>>0||2654435769`: it is reduced modulo 2^32 and 0 is replaced by 2654435769.
	explicit SeededRng(int64_t seed = 0) :
			a_(normalize_seed(static_cast<double>(seed))) {}

	// `seed>>>0||2654435769` for a JavaScript number: truncate toward zero, wrap modulo 2^32 (NaN and the infinities
	// give 0), and replace 0 by 2654435769. Result in [1, 2^32).
	static uint32_t normalize_seed(double js_seed) {
		uint32_t n = js::to_uint32(js_seed);
		return n != 0 ? n : kDefaultSeed;
	}

	// Re-seeds the stream like makeSeededRandom(seed) does (the state restarts).
	void set_seed(int64_t seed) {
		a_ = normalize_seed(static_cast<double>(seed));
	}

	// The next output as the integer k in [0, 2^32): the value of makeSeededRandom's function is k / 4294967296.
	uint32_t next_u32() {
		a_ = a_ + 1831565813u;
		uint32_t a = a_;
		// t = Math.imul(a ^ a >>> 15, 1 | a)
		uint32_t x = a ^ (a >> 15);
		uint32_t t = x * (1u | a);
		// t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t
		uint32_t y = t ^ (t >> 7);
		uint32_t m = y * (61u | t);
		t = (t + m) ^ t;
		// ((t ^ t >>> 14) >>> 0)
		return t ^ (t >> 14);
	}

	// The function returned by makeSeededRandom: a float in [0, 1).
	double next_float() {
		return static_cast<double>(next_u32()) / 4294967296.0;
	}

	// The generator state `a` as a signed int32. Readable and writable, e.g. to snapshot a stream.
	int32_t state() const {
		return as_int32(a_);
	}

	void set_state(int32_t state) {
		a_ = static_cast<uint32_t>(state);
	}

private:
	uint32_t a_;
};

} // namespace swarm::sim

#endif // SWARM_SIM_SEEDED_RNG_H
