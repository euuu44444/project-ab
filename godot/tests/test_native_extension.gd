extends "res://tests/test_case.gd"
## The C++ extension (native/, library swarm_native) loads in the headless editor and behaves as the
## C1 contract says (docs/godot-port-design.md section 5.5): build identity, deterministic IEEE
## floating point (no fused multiply-add), exact int64 arithmetic. Step C2 adds the classes SwarmJsMath, SwarmSeededRng,
## SwarmGameRng and SwarmFxRng (their results are checked against the golden vectors by test_js_math.gd and test_rng.gd; here:
## that they are registered, what they expose, and that the floating-point environment is the one the simulation needs).
## Whether the descriptor and the library files exist is checked by test_native_files.gd.

const DESCRIPTOR_PATH: String = "res://swarm_native.gdextension"
const NATIVE_VERSION: String = "0.2.0-c2"
const SWARM_CLASSES: PackedStringArray = ["SwarmJsMath", "SwarmSeededRng", "SwarmGameRng", "SwarmFxRng"]
## The methods each C2 class has (verification/godot/c2/spec.md sections 7.2 and 7.3), and the properties.
const SWARM_METHODS: Dictionary = {
	"SwarmJsMath": [
		"sin", "cos", "atan", "atan2", "exp", "log", "hypot", "js_round", "trunc", "js_mod", "js_max", "js_min", "max3", "min3",
		"max5", "min5", "max_n", "min_n", "clamp", "sqrt", "floor", "ceil", "abs", "pow", "to_int32", "to_uint32", "i32", "imul",
		"shl", "sar", "shr_u", "to_bits", "from_bits", "neg_zero", "fp_environment_ok", "fp_environment_reason",
	],
	"SwarmSeededRng": ["set_seed", "next_u32", "next_float", "normalize_seed", "get_state", "set_state"],
	"SwarmGameRng": ["set_seed", "random", "rand", "randi", "chance", "index", "shuffle", "get_draws", "get_seed_value"],
	"SwarmFxRng": ["set_seed", "random", "rand_fx", "randi_fx", "chance_fx"],
}
const SWARM_PROPERTIES: Dictionary = {
	"SwarmJsMath": [],
	"SwarmSeededRng": ["state"],
	"SwarmGameRng": ["draws", "seed_value"],
	"SwarmFxRng": [],
}
const INT64_MAX: int = 9223372036854775807
const INT64_MIN: int = -9223372036854775807 - 1

# Probe inputs, see native/src/fp_probe.cpp: a = b = 1 + 2^-30, c = -(1 + 2^-29).
const PROBE_A_BITS: int = 0x3FF0000000400000
const PROBE_C_NEGATED_BITS: int = 0x3FF0000000800000
const FUSED_RESULT_BITS: int = 0x3C30000000000000 # 2^-60: what one fused multiply-add gives
const UNFUSED_RESULT_BITS: int = 0 # +0.0: what multiply, round, add, round gives


func test_extension_is_loaded_in_the_headless_editor() -> void:
	assert_true(GDExtensionManager.is_extension_loaded(DESCRIPTOR_PATH), "swarm_native.gdextension is loaded")
	assert_true(GDExtensionManager.get_loaded_extensions().has(DESCRIPTOR_PATH), "listed among the loaded extensions")
	assert_eq(GDExtensionManager.load_extension(DESCRIPTOR_PATH), GDExtensionManager.LOAD_STATUS_ALREADY_LOADED,
			"loading it again reports that it is already loaded")
	assert_true(ClassDB.class_exists("SwarmNative"), "class SwarmNative is registered")
	assert_true(ClassDB.can_instantiate("SwarmNative"), "SwarmNative can be instantiated")
	assert_eq(ClassDB.get_parent_class("SwarmNative"), &"RefCounted", "SwarmNative extends RefCounted")
	var instance: Variant = ClassDB.instantiate("SwarmNative")
	assert_true(instance is RefCounted, "an instance is a RefCounted")


func test_version_identifies_the_build() -> void:
	var text: String = SwarmNative.version()
	assert_true(text.begins_with("swarm_native "), "starts with the library name: %s" % text)
	var pin: RegEx = RegEx.create_from_string("godot-cpp ([0-9a-f]{40}) \\((\\d{4}-\\d{2}-\\d{2})\\) api (\\d+\\.\\d+)")
	var found: RegExMatch = pin.search(text)
	assert_true(found != null, "names the godot-cpp commit, its date and the api version: %s" % text)
	if found != null:
		assert_eq(found.get_string(3), "4.7", "api_version")
		var pinned: String = OS.get_environment("SWARM_GODOT_CPP_COMMIT")
		if not pinned.is_empty(): # exported by tools/lib/cpp_toolchain.sh when run through run_godot_tests.sh
			assert_eq(found.get_string(1), pinned, "the commit in the binary is the pinned one")
	assert_true(text.contains(".template_debug.") or text.contains(".template_release."), "names the build target: %s" % text)
	assert_true(text.contains("linux.") and text.contains(".x86_64"), "this run uses the linux x86_64 library: %s" % text)
	assert_true(text.contains(NATIVE_VERSION), "names the library version %s: %s" % [NATIVE_VERSION, text])
	assert_true(text.contains("fp flags: "), "lists the floating-point flags: %s" % text)
	assert_true(text.contains("-ffp-contract=off"), "FMA contraction is off: %s" % text)
	assert_true(text.contains("-O2"), "optimization level -O2: %s" % text)
	for forbidden: String in ["-ffast-math", "-Ofast", "-funsafe-math-optimizations", "-ffinite-math-only", "-fassociative-math"]:
		assert_false(text.contains(forbidden), "no %s: %s" % [forbidden, text])


func test_c2_classes_are_registered_and_are_ref_counted() -> void:
	for swarm_class: String in SWARM_CLASSES:
		assert_true(ClassDB.class_exists(swarm_class), "class %s is registered" % swarm_class)
		assert_true(ClassDB.can_instantiate(swarm_class), "%s can be instantiated" % swarm_class)
		assert_eq(ClassDB.get_parent_class(swarm_class), &"RefCounted", "%s extends RefCounted" % swarm_class)
		var instance: Variant = ClassDB.instantiate(swarm_class)
		assert_true(instance is RefCounted, "an instance of %s is a RefCounted" % swarm_class)


func test_c2_classes_expose_the_documented_methods_and_properties() -> void:
	for swarm_class: String in SWARM_CLASSES:
		for method: String in (SWARM_METHODS[swarm_class] as Array):
			assert_true(ClassDB.class_has_method(swarm_class, method, true), "%s has the method %s" % [swarm_class, method])
		var properties: PackedStringArray = PackedStringArray()
		for info: Dictionary in ClassDB.class_get_property_list(swarm_class, true):
			properties.append(info["name"] as String)
		for property: String in (SWARM_PROPERTIES[swarm_class] as Array):
			assert_true(properties.has(property), "%s has the property %s" % [swarm_class, property])


func test_floating_point_environment_is_suitable() -> void:
	# Round to nearest, subnormal numbers kept (design section 11, rule 5): what the simulation needs. The debug library also checks
	# this when it loads and reports an engine error otherwise, which would fail the run of the tests.
	assert_true(SwarmJsMath.fp_environment_ok(), "the floating-point environment: %s" % SwarmJsMath.fp_environment_reason())
	assert_eq(SwarmJsMath.fp_environment_reason(), "", "no reason is given when the environment is fine")
	# The engine's own arithmetic in the same thread agrees: 2^-1074 is not flushed, DBL_MIN / 2 is a subnormal number.
	var tiny: float = SwarmJsMath.from_bits(1)
	assert_true(tiny > 0.0, "the smallest subnormal number is not zero")
	assert_true(tiny * 1.0 > 0.0 and SwarmJsMath.from_bits(0x0010000000000000) * 0.5 > 0.0, "subnormal inputs and results are kept")


func test_default_seeds_of_the_generators() -> void:
	var game: SwarmGameRng = SwarmGameRng.new()
	assert_eq(game.draws, 0, "a new SwarmGameRng has drawn nothing")
	assert_eq(game.seed_value, 0, "the default seed of SwarmGameRng is 0")
	var seeded: SwarmSeededRng = SwarmSeededRng.new()
	var zero: SwarmSeededRng = SwarmSeededRng.new()
	zero.set_seed(0)
	assert_eq(seeded.next_u32(), zero.next_u32(), "the default seed of SwarmSeededRng is 0")
	# SwarmFxRng starts from 0x9E3779B9 (= 2654435769, the value 0 is replaced by).
	var fx: SwarmFxRng = SwarmFxRng.new()
	var reference: SwarmSeededRng = SwarmSeededRng.new()
	reference.set_seed(0x9E3779B9)
	assert_eq(fx.random(), reference.next_float(), "the default seed of SwarmFxRng is 0x9E3779B9")


## a * b + c computed as two IEEE operations: the product is rounded to 1 + 2^-29 first, so the sum is
## exactly +0.0. A fused multiply-add keeps the exact product and gives 2^-60 instead.
func test_fp_contract_probe_returns_the_unfused_result() -> void:
	var a: float = _from_bits(PROBE_A_BITS)
	var c: float = -_from_bits(PROBE_C_NEGATED_BITS)
	assert_eq(_bits(a), PROBE_A_BITS, "input a is 1 + 2^-30 exactly")
	assert_eq(_bits(_from_bits(FUSED_RESULT_BITS)), FUSED_RESULT_BITS, "bit helper round trip")
	var result: float = SwarmNative.fp_contract_probe(a, a, c)
	assert_eq(typeof(result), TYPE_FLOAT, "returns a float")
	assert_eq(_bits(result), UNFUSED_RESULT_BITS, "unfused result is +0.0 (bits 0x0), got bits %x" % _bits(result))
	assert_true(_bits(result) != FUSED_RESULT_BITS, "not the fused result 2^-60")
	# GDScript evaluates the multiplication and the addition as two separate operations.
	assert_eq(_bits(a * a + c), UNFUSED_RESULT_BITS, "GDScript reference agrees")


## Many inputs, many of them with heavy cancellation (c close to -a*b), where fused and unfused results differ:
## the native result must always have the bits of the two-operation evaluation.
func test_fp_contract_probe_matches_separate_operations_on_many_inputs() -> void:
	var state: int = 0x2545F4914F6CDD1D
	var mismatches: int = 0
	var cancelling: int = 0
	for i: int in 20000:
		state = (state * 6364136223846793005 + 1442695040888963407) # 64-bit LCG, wraps
		var a: float = 1.0 + float((state >> 11) & 0x1FFFFFFFFFFFFF) * 1.1102230246251565e-16 * 2.0
		state = (state * 6364136223846793005 + 1442695040888963407)
		var b: float = 1.0 + float((state >> 11) & 0x1FFFFFFFFFFFFF) * 1.1102230246251565e-16 * 2.0
		var product: float = a * b
		state = (state * 6364136223846793005 + 1442695040888963407)
		var c: float = -product if (i % 2 == 0) else -product * (1.0 + float((state >> 40) & 0xFFFF) * 1e-12)
		var expected: float = a * b + c
		var got: float = SwarmNative.fp_contract_probe(a, b, c)
		if _bits(got) != _bits(expected):
			mismatches += 1
		if absf(got) < 1e-12:
			cancelling += 1
	assert_eq(mismatches, 0, "results that differ from separate multiply and add")
	assert_true(cancelling > 5000, "the inputs do exercise cancellation (%d of 20000)" % cancelling)


func test_add_int64_edge_cases() -> void:
	assert_eq(SwarmNative.add_int64(0, 0), 0)
	assert_eq(SwarmNative.add_int64(1, 2), 3)
	assert_eq(SwarmNative.add_int64(-1, 1), 0)
	assert_eq(SwarmNative.add_int64(-5, -7), -12)
	assert_eq(SwarmNative.add_int64(4294967296, 4294967296), 8589934592, "beyond 32 bits")
	assert_eq(SwarmNative.add_int64(INT64_MAX, 0), INT64_MAX)
	assert_eq(SwarmNative.add_int64(INT64_MIN, 0), INT64_MIN)
	assert_eq(SwarmNative.add_int64(INT64_MAX, INT64_MIN), -1)
	assert_eq(SwarmNative.add_int64(INT64_MAX - 1, 1), INT64_MAX)
	assert_eq(SwarmNative.add_int64(INT64_MIN + 1, -1), INT64_MIN)
	# Two's complement wrap-around, never undefined behaviour.
	assert_eq(SwarmNative.add_int64(INT64_MAX, 1), INT64_MIN, "INT64_MAX + 1 wraps")
	assert_eq(SwarmNative.add_int64(INT64_MIN, -1), INT64_MAX, "INT64_MIN - 1 wraps")
	assert_eq(SwarmNative.add_int64(INT64_MAX, INT64_MAX), -2, "INT64_MAX + INT64_MAX wraps")
	assert_eq(SwarmNative.add_int64(INT64_MIN, INT64_MIN), 0, "INT64_MIN + INT64_MIN wraps")
	assert_eq(typeof(SwarmNative.add_int64(1, 1)), TYPE_INT, "returns an int")
	assert_eq(SwarmNative.add_int64(2, 3), 2 + 3, "agrees with GDScript on ordinary values")


func _bits(value: float) -> int:
	var buffer: PackedByteArray = PackedByteArray()
	buffer.resize(8)
	buffer.encode_double(0, value)
	return buffer.decode_s64(0)


func _from_bits(bits: int) -> float:
	var buffer: PackedByteArray = PackedByteArray()
	buffer.resize(8)
	buffer.encode_s64(0, bits)
	return buffer.decode_double(0)
