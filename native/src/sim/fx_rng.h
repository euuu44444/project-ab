#ifndef SWARM_SIM_FX_RNG_H
#define SWARM_SIM_FX_RNG_H

// The effects generator: fxRandom() / randFx / randiFx / chanceFx of the original (all Math.random there): the C++
// version of godot/sim/fx_rng.gd (FxRng).
//
// # port: fxRandom, randFx, randiFx, chanceFx
//   function fxRandom(){return Math.random();}   function randFx(a,b){return a+fxRandom()*(b-a);}
//   function randiFx(a,b){return Math.floor(randFx(a,b+1));}   function chanceFx(p){return fxRandom()<p;}
//
// Effects (particles, bursts) must never influence the simulation, so they use their own generator, separate from
// GameRng: drawing from it never changes GameRng::draws(). The original is not deterministic here (Math.random); this
// port is seedable so that headless runs and tests are reproducible. The stream is NOT the original's (there is none).

#include <cmath>
#include <cstdint>

#include "fp_env.h"
#include "seeded_rng.h"

namespace swarm::sim {

class FxRng {
public:
	static constexpr int64_t kDefaultSeed = 0x9E3779B9;

	explicit FxRng(int64_t seed = kDefaultSeed) :
			rng_(seed) {}

	void set_seed(int64_t seed) {
		rng_.set_seed(seed);
	}

	// fxRandom(): a float in [0, 1).
	double random() {
		return rng_.next_float();
	}

	// randFx: a + fxRandom() * (b - a).
	double rand_fx(double a, double b) {
		return a + rng_.next_float() * (b - a);
	}

	// randiFx: Math.floor(randFx(a, b + 1)); both bounds inclusive. Precondition as GameRng::randi: |a|, |b| <= 2^31.
	int64_t randi_fx(int64_t a, int64_t b) {
#ifdef DEBUG_ENABLED
		if (!(a >= -kRandiBound && a <= kRandiBound && b >= -kRandiBound && b <= kRandiBound)) {
			precondition_failed("FxRng::randi_fx: |a| and |b| must be at most 2^31");
		}
#endif
		return static_cast<int64_t>(std::floor(static_cast<double>(a) + rng_.next_float() * (static_cast<double>(b + 1) - static_cast<double>(a))));
	}

	// chanceFx: fxRandom() < p.
	bool chance_fx(double p) {
		return rng_.next_float() < p;
	}

private:
	static constexpr int64_t kRandiBound = 2147483648;

	SeededRng rng_;
};

} // namespace swarm::sim

#endif // SWARM_SIM_FX_RNG_H
