#include "register_types.h"

#include "swarm_native.h"

#include "bindings/js_math_binding.h"
#include "bindings/rng_binding.h"
#include "sim/fp_env.h"

#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void initialize_swarm_native_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(swarm::SwarmNative);
	GDREGISTER_CLASS(swarm::SwarmJsMath);
	GDREGISTER_CLASS(swarm::SwarmSeededRng);
	GDREGISTER_CLASS(swarm::SwarmGameRng);
	GDREGISTER_CLASS(swarm::SwarmFxRng);
#ifdef DEBUG_ENABLED
	// godot-cpp defines DEBUG_ENABLED for template_debug builds only (see the compile commands in the flag-guard.txt
	// that native/SConstruct writes). The simulation needs round-to-nearest and no flush-to-zero
	// (docs/godot-port-design.md section 11); C3 repeats this check when a battle starts.
	const char *reason = "";
	if (!swarm::sim::fp_environment_ok(&reason)) {
		UtilityFunctions::push_error(String("swarm_native: the floating-point environment is not suitable for the simulation: ") + reason);
	}
#endif
}

void uninitialize_swarm_native_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

// Named by "entry_symbol" in godot/swarm_native.gdextension.
GDExtensionBool GDE_EXPORT swarm_native_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_swarm_native_module);
	init_obj.register_terminator(uninitialize_swarm_native_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
