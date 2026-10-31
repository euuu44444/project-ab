extends "res://tests/test_case.gd"
## The GDExtension descriptor (godot/swarm_native.gdextension) is well formed, and the Linux debug library
## it names (the one the headless editor loads) exists. Libraries are build output (godot/bin/, gitignored):
## tools/build_native.sh makes them, and tools/run_godot_tests.sh runs it first (host, template_debug). That
## the release and the Android libraries exist is checked by tools/build_android.sh, which builds them.
## This file does not use the SwarmNative class, so a missing library is reported here instead of as a
## script that fails to compile.

const DESCRIPTOR_PATH: String = "res://swarm_native.gdextension"
const LIBRARY_PREFIX: String = "res://bin/libswarm_native."
const EXPECTED_KEYS: PackedStringArray = [
	"linux.debug.x86_64", "linux.release.x86_64",
	"android.debug.arm64", "android.release.arm64", "android.debug.arm32", "android.release.arm32",
]


func test_descriptor_is_well_formed() -> void:
	assert_true(FileAccess.file_exists(DESCRIPTOR_PATH), "%s exists" % DESCRIPTOR_PATH)
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(DESCRIPTOR_PATH), OK, "the descriptor parses as a ConfigFile")
	assert_eq(config.get_value("configuration", "entry_symbol", ""), "swarm_native_library_init")
	assert_eq(config.get_value("configuration", "compatibility_minimum", ""), "4.7")
	var keys: PackedStringArray = config.get_section_keys("libraries")
	var sorted_keys: PackedStringArray = keys.duplicate()
	sorted_keys.sort()
	var expected: PackedStringArray = EXPECTED_KEYS.duplicate()
	expected.sort()
	assert_eq(sorted_keys, expected, "[libraries] has exactly the linux and android entries")
	for key: String in keys:
		var path: String = config.get_value("libraries", key, "")
		var target: PackedStringArray = key.split(".")
		var want: String = "%s%s.template_%s.%s.so" % [LIBRARY_PREFIX, target[0], "debug" if target[1] == "debug" else "release", target[2]]
		assert_eq(path, want, "library path of %s" % key)


func test_linux_debug_library_exists() -> void:
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(DESCRIPTOR_PATH), OK, "the descriptor parses")
	for key: String in ["linux.debug.x86_64"]:
		var path: String = config.get_value("libraries", key, "")
		assert_false(path.is_empty(), "%s is listed" % key)
		assert_true(FileAccess.file_exists(path), "%s exists (run tools/build_native.sh --host-only --debug-only)" % path)
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			fail("cannot open %s" % path)
			continue
		assert_true(file.get_length() > 100000, "%s is a real library (%d bytes)" % [path, file.get_length()])
		assert_eq(file.get_buffer(4), PackedByteArray([0x7F, 0x45, 0x4C, 0x46]), "%s starts with the ELF magic" % path)
