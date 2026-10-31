#ifndef SWARM_SIM_GAME_RNG_H
#define SWARM_SIM_GAME_RNG_H

// The game's gameRandom() with its draw counter and the helpers built on it (rand, randi, chance, shuffle, the index
// idiom): the C++ version of godot/sim/game_rng.gd (GameRng).
//
// # port: setGameSeed, rand, randi, chance, shuffle (original.html)
//   function setGameSeed(seed){gameRandomSeed=seed==null?null:seed>>>0;gameRandomDraws=0;const base=seed==null?Math.random:makeSeededRandom(seed>>>0);
//     gameRandom=()=>{gameRandomDraws++;return base();};}
//   function rand(a,b){return a+gameRandom()*(b-a);}   function randi(a,b){return Math.floor(rand(a,b+1));}
//   function chance(p){return gameRandom()<p;}
//   function shuffle(a){for(let i=a.length-1;i>0;i--){const j=gameRandom()*(i+1)|0;[a[i],a[j]]=[a[j],a[i]];}return a;}
//
// The ORDER and the NUMBER of draws are what the reference traces compare (gameRandomDraws), so every helper draws
// exactly as often as its JavaScript original: rand, randi, chance and index() draw once, shuffle() draws once per
// swap position (n - 1 times), random() draws once. Arguments are evaluated before the draw, as in JavaScript.
//
// The null-seed path of setGameSeed (an unseeded Math.random) does not exist here: the simulation always runs from a
// seed. Effects that the original draws from Math.random (fxRandom) use FxRng, a separate generator that never
// changes draws().

#include <cstddef>
#include <cstdint>
#include <cmath>
#include <utility>

#include "fp_env.h"
#include "js_math.h"
#include "seeded_rng.h"

namespace swarm::sim {

class GameRng {
public:
	// `seed` can be any int64; like setGameSeed it is reduced with `seed>>>0` (and 0 means the same stream as 2654435769).
	explicit GameRng(int64_t seed = 0) {
		set_seed(seed);
	}

	// # port: setGameSeed (seeded path). Restarts the stream and the draw counter.
	void set_seed(int64_t seed) {
		seed_value_ = js::to_uint32(static_cast<double>(seed));
		draws_ = 0;
		rng_.set_seed(seed);
	}

	// The number of gameRandom() calls since the last set_seed (gameRandomDraws).
	int64_t draws() const {
		return draws_;
	}

	// The seed as the game keeps it (`seed>>>0`, gameRandomSeed).
	uint32_t seed_value() const {
		return seed_value_;
	}

	// gameRandom(): a float in [0, 1); counts one draw.
	double random() {
		draws_ += 1;
		return rng_.next_float();
	}

	// # port: rand. a + gameRandom() * (b - a); one draw.
	double rand(double a, double b) {
		draws_ += 1;
		return a + rng_.next_float() * (b - a);
	}

	// # port: randi. Math.floor(rand(a, b + 1)); one draw. The bounds are integers; both are inclusive.
	// Precondition: |a| and |b| are at most 2^31 (then b + 1 cannot overflow and the result, which lies between a and
	// b + 1, fits an int64). A debug build checks it; the Godot bindings validate it before calling.
	int64_t randi(int64_t a, int64_t b) {
#ifdef DEBUG_ENABLED
		if (!(a >= -kRandiBound && a <= kRandiBound && b >= -kRandiBound && b <= kRandiBound)) {
			precondition_failed("GameRng::randi: |a| and |b| must be at most 2^31");
		}
#endif
		draws_ += 1;
		return static_cast<int64_t>(std::floor(static_cast<double>(a) + rng_.next_float() * (static_cast<double>(b + 1) - static_cast<double>(a))));
	}

	// # port: chance. gameRandom() < p; one draw, also for p <= 0, p >= 1 and NaN.
	bool chance(double p) {
		draws_ += 1;
		return rng_.next_float() < p;
	}

	// The idiom `gameRandom() * length | 0` (for example `pool[gameRandom() * pool.length | 0]`): an index in [0, length)
	// for a length of at least 1 (the JavaScript idiom gives 0 for length 0 and a negative number for a negative one).
	// One draw.
	int32_t index(int64_t length) {
		draws_ += 1;
		return js::to_int32(rng_.next_float() * static_cast<double>(length));
	}

	// # port: shuffle. Fisher-Yates in place from the end, like the original. Draws n - 1 times (not at all for 0 or
	// 1 elements).
	template <typename T>
	void shuffle(T *items, size_t n) {
		if (n < 2) {
			return;
		}
		for (size_t i = n - 1; i > 0; --i) {
			draws_ += 1;
			// in [0, i], so the conversion is the same as `| 0`
			size_t j = static_cast<size_t>(rng_.next_float() * static_cast<double>(i + 1));
			if (j != i) { // a swap with itself changes nothing (and a self-move could clear a Godot Variant)
				std::swap(items[i], items[j]);
			}
		}
	}

private:
	static constexpr int64_t kRandiBound = 2147483648;

	int64_t draws_ = 0;
	uint32_t seed_value_ = 0;
	SeededRng rng_;
};

} // namespace swarm::sim

#endif // SWARM_SIM_GAME_RNG_H
