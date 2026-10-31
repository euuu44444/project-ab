#ifndef SWARM_SIM_FP_ENV_H
#define SWARM_SIM_FP_ENV_H

// Checks of the floating-point environment, and of preconditions in debug builds (docs/godot-port-design.md
// section 11, rule 5). The simulation needs IEEE-754 double arithmetic with round-to-nearest, subnormal numbers kept
// and no extended precision; the compiler flags (-ffp-contract=off, no fast-math) are checked at build time, the
// state of the processor is checked here at run time.

#include <cfloat>

// x87 extended precision (FLT_EVAL_METHOD 2) would double-round; 0 means every operation is done in its own type.
static_assert(FLT_EVAL_METHOD == 0, "the simulation needs FLT_EVAL_METHOD == 0 (no x87 extended precision)");

namespace swarm::sim {

// True if the current thread rounds to nearest and does not flush subnormal numbers to zero (neither as inputs nor as
// results). Otherwise false, and *reason (if reason is not null) names the problem as a string literal. When the
// answer is true, *reason is "".
bool fp_environment_ok(const char **reason);

// Called by a precondition check of a debug build (DEBUG_ENABLED, defined by godot-cpp for template_debug) that
// failed: prints `what` to stderr and aborts. Never called by a release build, and not reachable from scripts: the
// Godot bindings validate their arguments first.
[[noreturn]] void precondition_failed(const char *what);

} // namespace swarm::sim

#endif // SWARM_SIM_FP_ENV_H
