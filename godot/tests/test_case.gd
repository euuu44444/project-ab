extends RefCounted
## Minimal base class for headless tests (no third-party addon).
##
## A test file extends this script by path and defines methods named test_*.
## The runner (run_tests.gd) calls begin_test() / take_failures() around each
## method. Assertions record a message instead of aborting, so one test can
## report several problems.

var _assertion_count: int = 0
var _failures: PackedStringArray = PackedStringArray()


func begin_test() -> void:
	_assertion_count = 0
	_failures = PackedStringArray()


func assertion_count() -> int:
	return _assertion_count


func take_failures() -> PackedStringArray:
	return _failures


func assert_true(condition: bool, message: String = "") -> void:
	_assertion_count += 1
	if not condition:
		_failures.append("expected true. %s" % message)


func assert_false(condition: bool, message: String = "") -> void:
	_assertion_count += 1
	if condition:
		_failures.append("expected false. %s" % message)


## Strict equality: the Variant types must match as well as the values.
func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	_assertion_count += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		_failures.append("expected %s (%s) but got %s (%s). %s" % [
			var_to_str(expected), type_string(typeof(expected)),
			var_to_str(actual), type_string(typeof(actual)),
			message,
		])


func assert_almost_eq(actual: float, expected: float, tolerance: float = 1e-6, message: String = "") -> void:
	_assertion_count += 1
	if absf(actual - expected) > tolerance:
		_failures.append("expected %s +/- %s but got %s. %s" % [expected, tolerance, actual, message])


func fail(message: String) -> void:
	_assertion_count += 1
	_failures.append(message)
