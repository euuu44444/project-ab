#include "build_info.h"

// Written by native/SConstruct into the build directory; the values come from the pinned toolchain.
#include "build_info.gen.h"

namespace swarm {

#define SWARM_STR_(x) #x
#define SWARM_STR(x) SWARM_STR_(x)

godot::String build_info() {
	const char *compiler =
#if defined(__clang__)
			"clang " SWARM_STR(__clang_major__) "." SWARM_STR(__clang_minor__) "." SWARM_STR(__clang_patchlevel__);
#elif defined(__GNUC__)
			"gcc " SWARM_STR(__GNUC__) "." SWARM_STR(__GNUC_MINOR__) "." SWARM_STR(__GNUC_PATCHLEVEL__);
#else
			"unknown compiler";
#endif
	return godot::String("swarm_native ") + SWARM_NATIVE_VERSION +
			" | godot-cpp " + SWARM_GODOT_CPP_COMMIT + " (" + SWARM_GODOT_CPP_COMMIT_DATE + ") api " + SWARM_GODOT_API_VERSION +
			" | " + SWARM_BUILD_PLATFORM + "." + SWARM_BUILD_TARGET + "." + SWARM_BUILD_ARCH +
			" | " + compiler +
			" | fp flags: " + SWARM_FP_FLAGS;
}

} // namespace swarm
