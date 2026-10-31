extends SceneTree
## Headless test runner.
##
##   godot --headless --path godot -s res://tests/run_tests.gd [-- <name-filter>]
##
## Discovers res://tests/test_*.gd (except the base class test_case.gd), runs every
## method named test_*, prints PASS/FAIL per test and a summary, and exits with 0
## only if every test passed. An optional user argument keeps only the test files
## whose name contains it.

const TEST_DIR: String = "res://tests"
const TEST_FILE_PREFIX: String = "test_"
const BASE_CLASS_FILE: String = "test_case.gd"
const TestCase = preload("res://tests/test_case.gd")


## Collects engine and script errors (push_error, runtime script errors, parse errors) so a test
## that dies half way, or a script that does not compile, fails the run instead of being missed.
class ErrorCollector extends Logger:
	var _mutex: Mutex = Mutex.new()
	var _messages: PackedStringArray = PackedStringArray()

	func _log_error(_function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var text: String = rationale if not rationale.is_empty() else code
		_mutex.lock()
		_messages.append("%s (%s:%d)" % [text, file, line])
		_mutex.unlock()

	## Returns the errors seen since the previous call and forgets them.
	func take() -> PackedStringArray:
		_mutex.lock()
		var taken: PackedStringArray = _messages
		_messages = PackedStringArray()
		_mutex.unlock()
		return taken


var _errors: ErrorCollector = ErrorCollector.new()
## Set only when _run_all reaches one of its returns. GDScript carries on after a runtime error in a
## callee, so without this flag a runner that died half way would exit with 0.
var _completed: bool = false


func _initialize() -> void:
	var filter: String = ""
	var user_args: PackedStringArray = OS.get_cmdline_user_args()
	if user_args.size() > 0:
		filter = user_args[0]
	# The root window enters the tree only after _initialize returns. Wait one frame so that tests
	# can add scenes to a running tree.
	await process_frame
	OS.add_logger(_errors)
	var exit_code: int = _run_all(filter)
	var stray: PackedStringArray = _errors.take()
	OS.remove_logger(_errors)
	if not _completed or not stray.is_empty():
		printerr("FAIL  the test run did not complete cleanly (runtime error in the runner itself)")
		for message: String in stray:
			printerr("        - %s" % message)
		printerr("RESULT: FAIL")
		exit_code = 1
	quit(exit_code)


func _run_all(filter: String) -> int:
	var files: PackedStringArray = _discover(filter)
	if files.is_empty():
		printerr("FAIL  no test files found in %s (filter: '%s')" % [TEST_DIR, filter])
		_completed = true
		return 1

	var passed: int = 0
	var failed: int = 0
	var assertions: int = 0
	print("Godot %s - running %d test file(s)" % [Engine.get_version_info()["string"], files.size()])

	for file_name: String in files:
		var path: String = TEST_DIR.path_join(file_name)
		_errors.take()
		var script: Script = load(path) as Script
		if script == null or not script.can_instantiate() or not _errors.take().is_empty():
			printerr("FAIL  %s: script failed to load or compile" % file_name)
			failed += 1
			continue
		if _init_needs_arguments(script):
			printerr("FAIL  %s: _init takes required arguments; test files are constructed without any" % file_name)
			failed += 1
			continue
		_errors.take()
		var instance: Variant = script.new()
		var construct_errors: PackedStringArray = _errors.take()
		if not construct_errors.is_empty():
			printerr("FAIL  %s: engine/script error while constructing" % file_name)
			for message: String in construct_errors:
				printerr("        - %s" % message)
			failed += 1
			continue
		if not (instance is TestCase):
			printerr("FAIL  %s: does not extend res://tests/test_case.gd" % file_name)
			failed += 1
			continue
		var test_case: TestCase = instance
		var methods: PackedStringArray = _test_methods(script)
		if methods.is_empty():
			printerr("FAIL  %s: no test_* methods" % file_name)
			failed += 1
			continue

		for method_name: String in methods:
			test_case.begin_test()
			_errors.take()
			test_case.call(method_name)
			var failures: PackedStringArray = test_case.take_failures()
			var count: int = test_case.assertion_count()
			assertions += count
			var raised: PackedStringArray = _errors.take()
			var label: String = "%s::%s" % [file_name, method_name]
			if not raised.is_empty():
				printerr("FAIL  %s: engine/script error while running" % label)
				for message: String in raised:
					printerr("        - %s" % message)
				for message: String in failures:
					printerr("        - %s" % message)
				failed += 1
			elif count == 0:
				printerr("FAIL  %s: no assertions executed" % label)
				failed += 1
			elif failures.is_empty():
				print("PASS  %s (%d assertions)" % [label, count])
				passed += 1
			else:
				printerr("FAIL  %s" % label)
				for message: String in failures:
					printerr("        - %s" % message)
				failed += 1

	var total: int = passed + failed
	print("Summary: %d/%d passed, %d failed, %d assertions" % [passed, total, failed, assertions])
	_completed = true
	if failed > 0:
		printerr("RESULT: FAIL")
		return 1
	print("RESULT: PASS")
	return 0


func _discover(filter: String) -> PackedStringArray:
	var found: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(TEST_DIR)
	if dir == null:
		return found
	for file_name: String in dir.get_files():
		if not (file_name.begins_with(TEST_FILE_PREFIX) and file_name.ends_with(".gd")):
			continue
		if file_name == BASE_CLASS_FILE:
			continue
		if not filter.is_empty() and not file_name.contains(filter):
			continue
		found.append(file_name)
	found.sort()
	return found


func _init_needs_arguments(script: Script) -> bool:
	for info: Dictionary in script.get_script_method_list():
		if info["name"] == "_init":
			var args: Array = info["args"]
			var defaults: Array = info["default_args"]
			return args.size() > defaults.size()
	return false


func _test_methods(script: Script) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for info: Dictionary in script.get_script_method_list():
		var method_name: String = info["name"]
		if method_name.begins_with("test_") and (info["args"] as Array).is_empty():
			names.append(method_name)
	names.sort()
	return names
