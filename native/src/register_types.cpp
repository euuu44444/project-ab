#include "register_types.h"

#include "swarm_native.h"

#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_swarm_native_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(swarm::SwarmNative);
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
