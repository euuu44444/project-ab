extends "res://tests/test_case.gd"
## Guards the project settings and the Android export preset decided in
## docs/godot-port-design.md (sections 1, 3, 6.1, 10).

const PRESETS_PATH: String = "res://export_presets.cfg"
const PROJECT_PATH: String = "res://project.godot"
const ANDROID_PACKAGE: String = "com.elementalswarm.engine"


func test_engine_version_is_4_7() -> void:
	var info: Dictionary = Engine.get_version_info()
	assert_eq(info["major"], 4, "engine major version")
	assert_eq(info["minor"], 7, "engine minor version")
	assert_eq(info["status"], "stable", "engine release status")


func test_application_identity() -> void:
	assert_eq(_setting("application/config/name"), "Elemental Swarm Engine")
	assert_eq(_setting("application/run/main_scene"), "res://main.tscn")
	assert_eq(_setting("application/config/icon"), "res://icon.svg")
	var features: PackedStringArray = _setting("application/config/features")
	assert_true(features.has("4.7"), "features has 4.7: %s" % [features])
	assert_true(features.has("GL Compatibility"), "features has GL Compatibility: %s" % [features])
	assert_true(FileAccess.file_exists("res://main.tscn"), "main scene file exists")
	assert_true(FileAccess.file_exists("res://icon.svg"), "icon file exists")


func test_renderer_is_compatibility_everywhere() -> void:
	assert_eq(_setting("rendering/renderer/rendering_method"), "gl_compatibility")
	assert_eq(_setting("rendering/renderer/rendering_method.mobile"), "gl_compatibility")
	# Without this the Android exporter reports the project configuration as invalid
	# on a desktop host, because only ETC2/ASTC textures can be used on Android.
	assert_eq(_setting("rendering/textures/vram_compression/import_etc2_astc"), true)


func test_fixed_step_is_60hz_without_engine_interpolation() -> void:
	assert_eq(_setting("physics/common/physics_ticks_per_second"), 60)
	assert_eq(_setting("physics/common/max_physics_steps_per_frame"), 5)
	# Interpolation is done by our own render layer via
	# Engine.get_physics_interpolation_fraction(); the engine's own stays off.
	assert_eq(_setting("physics/common/physics_interpolation", false), false)
	# Godot's own jitter fix would skew the interpolation fraction and the tick scheduling away
	# from a pure fixed-step accumulator; it has to be off when interpolation is custom.
	assert_eq(_setting("physics/common/physics_jitter_fix"), 0.0)
	assert_eq(Engine.physics_jitter_fix, 0.0)
	assert_eq(Engine.physics_ticks_per_second, 60)
	assert_eq(Engine.max_physics_steps_per_frame, 5)


func test_gdscript_is_statically_typed() -> void:
	# Design section 5.1: every GDScript declaration carries a type. 2 = error, so an untyped
	# declaration fails the headless run and the export instead of being a silent warning.
	assert_eq(_setting("debug/gdscript/warnings/untyped_declaration"), 2)


func test_stretch_and_viewport() -> void:
	assert_eq(_setting("display/window/stretch/mode"), "canvas_items")
	assert_eq(_setting("display/window/stretch/aspect"), "expand")
	assert_eq(_setting("display/window/size/viewport_width"), 390)
	assert_eq(_setting("display/window/size/viewport_height"), 390)
	assert_eq(_setting("display/window/size/window_width_override"), 390)
	assert_eq(_setting("display/window/size/window_height_override"), 844)


func test_orientation_follows_the_sensor() -> void:
	# DisplayServer.SCREEN_SENSOR: portrait and landscape, both directions.
	assert_eq(_setting("display/window/handheld/orientation"), DisplayServer.SCREEN_SENSOR)
	assert_eq(DisplayServer.SCREEN_SENSOR, 6)


func test_pixel_art_filtering_and_screen_on() -> void:
	# 0 = Nearest in the project setting's enum (1 = Linear is the default).
	assert_eq(_setting("rendering/textures/canvas_textures/default_texture_filter"), 0)
	assert_eq(_setting("display/window/energy_saving/keep_screen_on"), true)


func test_project_file_is_config_version_5() -> void:
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(PROJECT_PATH), OK, "project.godot parses as a ConfigFile")
	assert_eq(config.get_value("", "config_version", 0), 5)
	assert_eq(
		config.get_value("rendering", "renderer/rendering_method.mobile", ""),
		"gl_compatibility",
		"mobile renderer override as written in project.godot",
	)


func test_android_preset_identity() -> void:
	var config: ConfigFile = _load_presets()
	if config == null:
		return
	assert_eq(config.get_value("preset.0", "name", ""), "Android")
	assert_eq(config.get_value("preset.0", "platform", ""), "Android")
	assert_eq(config.get_value("runnable_presets", "Android", ""), "Android", "Android preset is runnable")
	assert_eq(
		config.get_value("preset.0", "export_path", ""),
		"../export/ElementalSwarm_engine_s1_debug.apk",
		"resolved against the project directory, i.e. <repo>/export/",
	)
	assert_false(config.has_section("preset.1"), "exactly one preset")


func test_android_preset_options() -> void:
	var config: ConfigFile = _load_presets()
	if config == null:
		return
	var s: String = "preset.0.options"
	assert_eq(config.get_value(s, "package/unique_name", ""), ANDROID_PACKAGE)
	assert_eq(config.get_value(s, "package/name", ""), "Elemental Swarm Engine")
	assert_eq(config.get_value(s, "version/code", 0), 1)
	assert_eq(config.get_value(s, "version/name", ""), "0.1.0-s1")
	assert_eq(config.get_value(s, "gradle_build/use_gradle_build", true), false)
	assert_eq(config.get_value(s, "screen/immersive_mode", false), true)
	assert_eq(config.get_value(s, "architectures/arm64-v8a", false), true)
	assert_eq(config.get_value(s, "architectures/armeabi-v7a", false), true)
	assert_eq(config.get_value(s, "architectures/x86", true), false)
	assert_eq(config.get_value(s, "architectures/x86_64", true), false)


func test_android_preset_requests_no_permissions() -> void:
	var config: ConfigFile = _load_presets()
	if config == null:
		return
	var s: String = "preset.0.options"
	var checked: int = 0
	for key: String in config.get_section_keys(s):
		if not key.begins_with("permissions/"):
			continue
		checked += 1
		if key == "permissions/custom_permissions":
			var custom: PackedStringArray = config.get_value(s, key, PackedStringArray())
			assert_true(custom.is_empty(), "no custom permissions")
		else:
			assert_eq(config.get_value(s, key), false, key)
	assert_true(checked > 100, "the full permission list is spelled out (%d keys)" % checked)
	assert_eq(config.get_value(s, "permissions/internet", true), false, "no INTERNET permission")


func test_export_presets_hold_no_secrets() -> void:
	var config: ConfigFile = _load_presets()
	if config == null:
		return
	for section: String in config.get_sections():
		for key: String in config.get_section_keys(section):
			var lowered: String = key.to_lower()
			if lowered.begins_with("keystore/") or lowered.contains("password"):
				fail("%s [%s] must not be stored in export_presets.cfg" % [key, section])
	assert_true(true, "scanned all sections")


func _setting(setting_name: String, default_value: Variant = null) -> Variant:
	if default_value == null:
		if not ProjectSettings.has_setting(setting_name):
			fail("project setting is missing: %s" % setting_name)
			return null
		return ProjectSettings.get_setting(setting_name)
	return ProjectSettings.get_setting(setting_name, default_value)


func _load_presets() -> ConfigFile:
	var config: ConfigFile = ConfigFile.new()
	var err: Error = config.load(PRESETS_PATH)
	if err != OK:
		fail("cannot load %s (error %d)" % [PRESETS_PATH, err])
		return null
	return config
