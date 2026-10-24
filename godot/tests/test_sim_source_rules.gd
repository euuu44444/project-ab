extends "res://tests/test_case.gd"
## Source rules of the simulation (design sections 2 and 5): everything under res://sim/ except js_compat.gd itself must reach
## the JavaScript numerics through JsMath and the random numbers through GameRng / FxRng, never through the engine's own functions.
##
## Why: the reference traces compare doubles bit for bit with V8. The engine's sin / cos / atan2 / exp / log / pow differ from V8
## in the last bit (measured: tools/golden/math.mjs, verify_golden_chromium.mjs), round() is not Math.round, fmod / max / min /
## clamp have other NaN and -0 rules, Vector2 and friends hold float32, and a Node, the clock or the input state would make the
## simulation depend on the scene tree. The golden tests only notice such a call when a value happens to differ, so this test
## reads the sources and fails on the call itself.
##
## Allowed on purpose (exact in IEEE-754 double and identical to the JavaScript function on every input): sqrt, floor, floorf,
## ceil, ceilf, abs, absf, is_nan, is_inf, is_finite, and the integer helpers mini, maxi, clampi, absi.

const SIM_DIR: String = "res://sim"
## The compatibility layer is the one file allowed to call the engine (it wraps sqrt and pow, and implements the rest).
const EXEMPT_FILE: String = "js_compat.gd"
## A call of one of these names that is not a method (no "." or word character before it) and not a definition ("func ").
const FORBIDDEN_CALLS: String = (
	"sin|cos|tan|asin|acos|atan|atan2|sinh|cosh|tanh|asinh|acosh|atanh|exp|exp2|log|pow|round|roundf|roundi|snapped|snappedf|"
	+ "snappedi|fmod|fposmod|posmod|maxf|minf|max|min|clamp|clampf|sign|signf|lerp|lerpf|lerp_angle|inverse_lerp|remap|"
	+ "move_toward|smoothstep|randf|randf_range|randi|randi_range|randomize|rand_from_seed|deg_to_rad|rad_to_deg|hypot"
)
const FORBIDDEN_TYPES: String = "Vector[234]i?|Rect2i?|Transform[23]D|Basis|Quaternion|Color|Plane|AABB|Projection"
const FORBIDDEN_SINGLETONS: String = "Time|OS|Input|Engine|DisplayServer|RenderingServer"
const FORBIDDEN_BASES: String = "Node\\w*|Control|CanvasItem|Object|Resource|Window"


func test_the_simulation_sources_follow_the_numerics_rules() -> void:
	var files: PackedStringArray = PackedStringArray()
	_find_scripts(SIM_DIR, files)
	assert_true(files.size() >= 30, "found the sim scripts (got %d)" % files.size())
	assert_true(files.has(SIM_DIR.path_join("js_compat.gd")), "js_compat.gd is among them")
	assert_true(files.has(SIM_DIR.path_join("systems/player_movement_system.gd")), "the systems folder is walked")
	for path: String in files:
		if path.get_file() == EXEMPT_FILE:
			continue
		for violation: String in scan_source(FileAccess.get_file_as_string(path)):
			fail("%s: %s" % [path, violation])


func test_every_sim_class_is_a_ref_counted_object_without_scene_tree() -> void:
	# The simulation must run headless without a scene tree: its classes extend RefCounted (or another sim class).
	var files: PackedStringArray = PackedStringArray()
	_find_scripts(SIM_DIR, files)
	var extends_re: RegEx = RegEx.create_from_string("(?m)^extends\\s+(\\w+)")
	var allowed: PackedStringArray = PackedStringArray(["RefCounted", "SimSystem"])
	for path: String in files:
		var found: RegExMatch = extends_re.search(FileAccess.get_file_as_string(path))
		if found == null:
			fail("%s has no extends line" % path)
			continue
		assert_true(allowed.has(found.get_string(1)), "%s extends %s" % [path, found.get_string(1)])


func test_the_scanner_finds_what_it_must_and_nothing_else() -> void:
	var bad: PackedStringArray = [
		"var a: float = sin(x)", "var a: float = cos (x)", "var a: float = atan2(y, x)", "var a: float = atan(x)",
		"var a: float = exp(-x)", "var a: float = log(x)", "var a: float = pow(x, 2.0)", "var a: float = x ** 2.0",
		"var a: float = round(x)", "var a: float = roundf(x)", "var a: int = roundi(x)", "var a: float = snappedf(x, 1.0)",
		"var a: float = fmod(x, y)", "var a: float = posmod(x, y)", "var a: float = maxf(x, y)", "var a: float = minf(x, y)",
		"var a: float = max(x, y)", "var a: float = min(x, y)", "var a: float = clamp(x, 0.0, 1.0)",
		"var a: float = clampf(x, 0.0, 1.0)", "var a: float = lerp(x, y, 0.5)", "var a: float = lerpf(x, y, 0.5)",
		"var a: float = signf(x)", "var a: float = randf()", "var a: int = randi()", "var a: float = randf_range(0.0, 1.0)",
		"var a: float = deg_to_rad(x)", "var a: float = x + sin(y) + 1.0", "return(sin(x))", "if x and cos(y) > 0.0:",
		"var v: Vector2 = Vector2(1.0, 2.0)", "var c: Color = Color.RED", "var t: float = Time.get_ticks_msec()",
		"var t: bool = Input.is_key_pressed(KEY_A)", "var t: int = Engine.get_frames_drawn()", "var o: int = OS.get_ticks_msec()",
		"extends Node2D", "extends Node",
	]
	for line: String in bad:
		assert_eq(scan_source(line).size(), 1, "the scanner must flag: %s" % line)
	var good: PackedStringArray = [
		"var a: float = JsMath.sin(x)", "var a: float = JsMath.atan2(y, x)", "var a: float = JsMath.clamp(x, 0.0, 1.0)",
		"var a: float = JsMath.js_round(x)", "var a: float = JsMath.hypot(x, y)", "var a: float = sqrt(x)",
		"var a: float = floorf(x)", "var a: float = ceilf(x)", "var a: float = absf(x)", "var a: int = maxi(x, y)",
		"var a: int = mini(x, y)", "var a: int = clampi(x, 0, 3)", "var a: bool = is_nan(x)", "var a: bool = is_finite(x)",
		"func randi(a: int, b: int) -> int:", "func rand(a: float, b: float) -> float:", "return rng.randi(0, 3)",
		"var a: float = game.rng.rand(0.0, 1.0)", "var s: String = \"sin(x) and Vector2 and max(a, b)\"",
		"# var a: float = sin(x)", "var a: float = 1.0  # sin(x), Vector2, round(x)", "## round(x) is not Math.round",
		"var a: float = x * y", "var a: float = x * -y", "var round_count: int = 0", "var x: float = last_facing", "extends RefCounted",
		"extends SimSystem", "var a: float = _log_scale(x)", "var a: float = state.max_hp", "var a: float = self.min(1.0)",
	]
	for line: String in good:
		assert_eq(scan_source(line).size(), 0, "the scanner must accept: %s" % line)
	# Line numbers are those of the source, also behind comment and string lines.
	var report: PackedStringArray = scan_source("var a: int = 1\n# a comment\nvar s: String = \"x\"\nvar b: float = sin(a)\n")
	assert_eq(report.size(), 1, "one violation in the multi-line source")
	assert_true(report.size() == 1 and report[0].begins_with("line 4:"), "reported at line 4: %s" % [report])


## Returns one entry per line of `text` that breaks a rule, as "line N: <the line, trimmed>". Comments and the contents of
## string literals are ignored.
func scan_source(text: String) -> PackedStringArray:
	var calls_re: RegEx = RegEx.create_from_string("(?<![\\w.])(?<!func )(?:" + FORBIDDEN_CALLS + ")\\s*\\(")
	var power_re: RegEx = RegEx.create_from_string("\\*\\*")
	var types_re: RegEx = RegEx.create_from_string("\\b(?:" + FORBIDDEN_TYPES + ")\\b")
	var singleton_re: RegEx = RegEx.create_from_string("\\b(?:" + FORBIDDEN_SINGLETONS + ")\\s*\\.")
	var base_re: RegEx = RegEx.create_from_string("^\\s*extends\\s+(?:" + FORBIDDEN_BASES + ")\\b")
	var found: PackedStringArray = PackedStringArray()
	var lines: PackedStringArray = text.split("\n")
	for i: int in lines.size():
		var code: String = _blank_comments_and_strings(lines[i])
		if (calls_re.search(code) != null or power_re.search(code) != null or types_re.search(code) != null
				or singleton_re.search(code) != null or base_re.search(code) != null):
			found.append("line %d: %s" % [i + 1, lines[i].strip_edges()])
	return found


## The line without its comment and with every string literal replaced by spaces.
func _blank_comments_and_strings(line: String) -> String:
	var result: String = ""
	var quote: String = ""
	var i: int = 0
	while i < line.length():
		var c: String = line[i]
		if quote.is_empty():
			if c == "#":
				break
			if c == "\"" or c == "'":
				quote = c
				result += " "
			else:
				result += c
		elif c == "\\":
			i += 1
			result += "  "
		elif c == quote:
			quote = ""
			result += " "
		else:
			result += " "
		i += 1
	return result


func _find_scripts(dir_path: String, found: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		fail("cannot open %s" % dir_path)
		return
	for sub: String in dir.get_directories():
		if not sub.begins_with("."):
			_find_scripts(dir_path.path_join(sub), found)
	for file_name: String in dir.get_files():
		if file_name.ends_with(".gd"):
			found.append(dir_path.path_join(file_name))
