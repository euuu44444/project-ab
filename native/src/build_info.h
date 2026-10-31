#ifndef SWARM_BUILD_INFO_H
#define SWARM_BUILD_INFO_H

#include <godot_cpp/variant/string.hpp>

namespace swarm {

// One line that identifies this binary: library version, godot-cpp pin, API version, target,
// compiler and the floating-point flags it was built with.
godot::String build_info();

} // namespace swarm

#endif // SWARM_BUILD_INFO_H
