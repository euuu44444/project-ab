extends "res://tests/test_case.gd"
## The C++ extension (native/, library swarm_native) loads in the headless editor and behaves as the
## C1 contract says (docs/godot-port-design.md section 5.5): build identity, deterministic IEEE
## floating point (no fused multiply-add), exact int64 arithmetic.
## Whether the descriptor and the library files exist is checked by test_native_files.gd.

const DESCRIPTOR_PATH: String = "res://swarm_native.gdextension"
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
	assert_true(text.contains("fp flags: "), "lists the floating-point flags: %s" % text)
	assert_true(text.contains("-ffp-contract=off"), "FMA contraction is off: %s" % text)
	assert_true(text.contains("-O2"), "optimization level -O2: %s" % text)
	for forbidden: String in ["-ffast-math", "-Ofast", "-funsafe-math-optimizations", "-ffinite-math-only", "-fassociative-math"]:
		assert_false(text.contains(forbidden), "no %s: %s" % [forbidden, text])


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
