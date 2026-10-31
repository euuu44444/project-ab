#include "fp_env.h"

#include <cfenv>
#include <cfloat>
#include <cstdio>
#include <cstdlib>

namespace swarm::sim {

bool fp_environment_ok(const char **reason) {
	const char *problem = "";
	if (std::fegetround() != FE_TONEAREST) {
		problem = "the rounding mode is not round-to-nearest";
	} else {
		// volatile: the compiler must not fold these products at compile time, where nothing is flushed.
		// 2^-1074 is the smallest subnormal: a flush-to-zero input (DAZ) turns the product into 0.
		// DBL_MIN * 0.5 = 2^-1023 is a subnormal result: flush-to-zero (FTZ) turns it into 0.
		volatile double smallest_subnormal = 0x1p-1074;
		volatile double one = 1.0;
		volatile double smallest_normal = DBL_MIN;
		volatile double half = 0.5;
		if (smallest_subnormal * one == 0.0) {
			problem = "subnormal inputs are treated as zero (denormals-are-zero)";
		} else if (smallest_normal * half == 0.0) {
			problem = "subnormal results are flushed to zero (flush-to-zero)";
		}
	}
	if (reason != nullptr) {
		*reason = problem;
	}
	return problem[0] == '\0';
}

[[noreturn]] void precondition_failed(const char *what) {
	std::fprintf(stderr, "swarm_native: precondition failed: %s\n", what);
	std::fflush(stderr);
	std::abort();
}

} // namespace swarm::sim
