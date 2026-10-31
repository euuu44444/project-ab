#include "swarm_native.h"

#include "build_info.h"
#include "fp_probe.h"

using namespace godot;

namespace swarm {

void SwarmNative::_bind_methods() {
	ClassDB::bind_static_method("SwarmNative", D_METHOD("version"), &SwarmNative::version);
	ClassDB::bind_static_method("SwarmNative", D_METHOD("fp_contract_probe", "a", "b", "c"), &SwarmNative::fp_contract_probe);
	ClassDB::bind_static_method("SwarmNative", D_METHOD("add_int64", "a", "b"), &SwarmNative::add_int64);
}

String SwarmNative::version() {
	return build_info();
}

double SwarmNative::fp_contract_probe(double p_a, double p_b, double p_c) {
	return swarm_fp_probe_mul_add(p_a, p_b, p_c);
}

int64_t SwarmNative::add_int64(int64_t p_a, int64_t p_b) {
	return static_cast<int64_t>(static_cast<uint64_t>(p_a) + static_cast<uint64_t>(p_b));
}

} // namespace swarm
