extends "res://tests/test_case.gd"
## JsMath (res://sim/js_compat.gd) against the golden vectors of res://tests/golden/math.json (design section 9.1).
##
## Every vector holds at least 20 000 inputs per ported function (edge cases around the thresholds of the algorithms,
## multiples of pi/2, 0.5 boundaries, int32 limits, +-0, +-Infinity, NaN, plus pseudo-random numbers in the ranges the game
## produces). The expected values come from the original game's JavaScript semantics (tools/golden/math.mjs, checked against
## Chromium 141 by tools/verify_golden_chromium.mjs). Results are compared by bit pattern: -0 differs from +0, any NaN equals any NaN.

const MAX_REPORTED: int = 5
## Every ported function is checked on at least this many golden rows (the thin wrappers over exact builtins and pow need fewer).
const PORTED_MIN_ROWS: int = 20000
const WRAPPER_MIN_ROWS: int = 2048
const BENCH_CALLS: int = 200000
## Net times below this per call are reported as "below the resolution" (the loop cost is subtracted and its jitter is about this size).
const BENCH_RESOLUTION_NS: float = 10.0


func _vector(vector_name: String) -> Dictionary:
	var golden: Dictionary = GoldenCodec.load_json("math")
	return (golden["vectors"] as Dictionary)[vector_name]


## Runs `f` over every row of the vector and compares with the expected column. `f` takes the first n floats of each row
## (n = its number of parameters; the sets for the 3 and 5 argument functions have five columns).
func _check(vector_name: String, f: Callable, min_rows: int = PORTED_MIN_ROWS) -> void:
	var golden: Dictionary = GoldenCodec.load_json("math")
	var vector: Dictionary = (golden["vectors"] as Dictionary)[vector_name]
	var columns: Array[PackedFloat64Array] = GoldenCodec.input_columns(golden, vector_name)
	var rows: int = int(vector["rows"])
	var output_type: String = vector["output_type"]
	var expected_f64: PackedFloat64Array = PackedFloat64Array()
	var expected_int: PackedInt64Array = PackedInt64Array()
	if output_type == "f64":
		expected_f64 = GoldenCodec.decode_f64(vector["output"])
	elif output_type == "u32":
		expected_int = GoldenCodec.decode_u32(vector["output"])
	else:
		for v: int in GoldenCodec.decode_i32(vector["output"]):
			expected_int.append(v)
	assert_true(rows >= min_rows, "%s: the vector has only %d rows" % [vector_name, rows])
	var arity: int = f.get_argument_count()
	assert_true(arity >= 1 and arity <= columns.size(), "%s: the function takes %d arguments, the input set has %d columns" % [vector_name, arity, columns.size()])
	arity = clampi(arity, 1, columns.size())
	assert_eq(columns[0].size() >= rows, true, "%s: input column shorter than the vector" % vector_name)
	var bad: int = 0
	var args: Array = []
	args.resize(arity)
	for i: int in range(rows):
		for c: int in range(arity):
			args[c] = columns[c][i]
		var got: Variant = f.callv(args)
		var ok: bool
		var got_text: String
		var expected_text: String
		if output_type == "f64":
			ok = GoldenCodec.same_double(got as float, expected_f64[i])
			got_text = "%s (%s)" % [GoldenCodec.hex_of(got as float), str(got)]
			expected_text = "%s (%s)" % [GoldenCodec.hex_of(expected_f64[i]), str(expected_f64[i])]
		else:
			ok = (got as int) == expected_int[i]
			got_text = str(got)
			expected_text = str(expected_int[i])
		if not ok:
			bad += 1
			if bad <= MAX_REPORTED:
				var arg_text: PackedStringArray = PackedStringArray()
				for a: Variant in args:
					arg_text.append("%s (%s)" % [GoldenCodec.hex_of(a as float), str(a)])
				fail("%s row %d: args [%s] expected %s but got %s" % [vector_name, i, ", ".join(arg_text), expected_text, got_text])
	assert_eq(bad, 0, "%s: %d of %d rows differ" % [vector_name, bad, rows])


# ---------------------------------------------------------------------------------------------------
# Ported functions
# ---------------------------------------------------------------------------------------------------

func test_constants_match_their_bit_patterns() -> void:
	# Every constant of js_compat.gd is written as integer / 2^k (exact); this guards against a mis-rounded literal.
	assert_eq(JsMath.self_check(), 0, "JsMath constants or tables differ from their recorded bit patterns")
	assert_eq(JsMath.SINCOSTAB.size(), 440)


func test_sin() -> void:
	_check("sin", JsMath.sin)


func test_cos() -> void:
	_check("cos", JsMath.cos)


func test_atan() -> void:
	_check("atan", JsMath.atan)


func test_atan2() -> void:
	_check("atan2", JsMath.atan2)


func test_exp() -> void:
	_check("exp", JsMath.exp)


func test_log() -> void:
	_check("log", JsMath.log)


func test_hypot() -> void:
	_check("hypot", JsMath.hypot)


func test_js_round() -> void:
	_check("round", JsMath.js_round)


func test_trunc() -> void:
	_check("trunc", JsMath.trunc)


func test_js_mod() -> void:
	_check("mod", JsMath.js_mod)


func test_js_max() -> void:
	_check("max", JsMath.js_max)


func test_js_min() -> void:
	_check("min", JsMath.js_min)


func test_max3_min3() -> void:
	_check("max3", JsMath.max3)
	_check("min3", JsMath.min3)


func test_max5_min5() -> void:
	_check("max5", JsMath.max5)
	_check("min5", JsMath.min5)


func test_max_n_min_n_agree_with_the_five_argument_vectors() -> void:
	_check("max5", func(a: float, b: float, c: float, d: float, e: float) -> float: return JsMath.max_n(PackedFloat64Array([a, b, c, d, e])))
	_check("min5", func(a: float, b: float, c: float, d: float, e: float) -> float: return JsMath.min_n(PackedFloat64Array([a, b, c, d, e])))
	assert_eq(JsMath.max_n(PackedFloat64Array()), -INF, "Math.max() is -Infinity")
	assert_eq(JsMath.min_n(PackedFloat64Array()), INF, "Math.min() is Infinity")


func test_clamp_is_the_games_clamp() -> void:
	# The expected values were produced by the game's own clamp(v,a,b), cut out of original.html.
	_check("clamp", JsMath.clamp)


func test_to_int32() -> void:
	_check("to_int32", func(x: float) -> int: return JsMath.to_int32(x))


func test_to_uint32() -> void:
	_check("to_uint32", func(x: float) -> int: return JsMath.to_uint32(x))


func test_imul() -> void:
	_check("imul", func(a: float, b: float) -> int: return JsMath.imul(int(a), int(b)))


func test_shifts() -> void:
	_check("shl", func(a: float, n: float) -> int: return JsMath.shl(int(a), int(n)))
	_check("sar", func(a: float, n: float) -> int: return JsMath.sar(int(a), int(n)))
	_check("shr_u", func(a: float, n: float) -> int: return JsMath.shr_u(int(a), int(n)))


func test_i32_wraps_to_the_int32_range() -> void:
	# JavaScript: (v | 0) for integer-valued v. The golden vectors cover the doubles; this covers ints beyond 2^53.
	var cases: Array = [0, 1, -1, 2147483647, 2147483648, -2147483648, -2147483649, 4294967295, 4294967296, 9223372036854775807, -9223372036854775807 - 1]
	var expected: Array = [0, 1, -1, 2147483647, -2147483648, -2147483648, 2147483647, -1, 0, -1, 0]
	for i: int in range(cases.size()):
		assert_eq(JsMath.i32(cases[i] as int), expected[i] as int, "i32(%s)" % str(cases[i]))


func test_pow_special_cases() -> void:
	# pow is not bit-guaranteed in general (see the header of js_compat.gd); the vector holds only arguments whose result
	# is fixed by IEEE 754 or by the ECMAScript special cases.
	_check("pow", JsMath.pow, 400)


# ---------------------------------------------------------------------------------------------------
# Functions that the engine implements exactly (thin wrappers)
# ---------------------------------------------------------------------------------------------------

func test_exact_wrappers_sqrt_floor_ceil_abs() -> void:
	_check("sqrt", JsMath.sqrt, WRAPPER_MIN_ROWS)
	_check("floor", JsMath.floor, WRAPPER_MIN_ROWS)
	_check("ceil", JsMath.ceil, WRAPPER_MIN_ROWS)
	_check("abs", JsMath.abs, WRAPPER_MIN_ROWS)


# ---------------------------------------------------------------------------------------------------
# Named pitfalls (expected values computed in JavaScript by the generator, not typed here)
# ---------------------------------------------------------------------------------------------------

func _call_named(fn: String, a: PackedFloat64Array) -> float:
	match fn:
		"sin":
			return JsMath.sin(a[0])
		"cos":
			return JsMath.cos(a[0])
		"round":
			return JsMath.js_round(a[0])
		"max":
			return JsMath.js_max(a[0], a[1])
		"min":
			return JsMath.js_min(a[0], a[1])
		"clamp":
			return JsMath.clamp(a[0], a[1], a[2])
		"mod":
			return JsMath.js_mod(a[0], a[1])
		"hypot":
			return JsMath.hypot(a[0], a[1])
		"atan2":
			return JsMath.atan2(a[0], a[1])
		"exp":
			return JsMath.exp(a[0])
		"to_int32":
			return float(JsMath.to_int32(a[0]))
		"to_uint32":
			return float(JsMath.to_uint32(a[0]))
		"imul":
			return float(JsMath.imul(int(a[0]), int(a[1])))
		"pow":
			return JsMath.pow(a[0], a[1])
	fail("named case: unknown function %s" % fn)
	return NAN


func test_named_pitfall_cases() -> void:
	var golden: Dictionary = GoldenCodec.load_json("math")
	var cases: Array = golden["named"]
	assert_true(cases.size() >= 40, "the generator provides the named cases")
	var bad: int = 0
	for entry: Array in cases:
		var label: String = entry[0]
		var fn: String = entry[1]
		var args: PackedFloat64Array = PackedFloat64Array()
		for hex: String in (entry[2] as Array):
			args.append(GoldenCodec.from_hex(hex))
		var expected: float = GoldenCodec.from_hex(entry[3])
		var got: float = _call_named(fn, args)
		if not GoldenCodec.same_double(got, expected):
			bad += 1
			fail("%s: expected %s (%s) but got %s (%s)" % [label, GoldenCodec.hex_of(expected), str(expected), GoldenCodec.hex_of(got), str(got)])
	assert_eq(bad, 0, "named cases that differ")


func test_bit_helpers_and_negative_zero() -> void:
	var z: float = JsMath.neg_zero()
	assert_eq(GoldenCodec.hex_of(z), "8000000000000000", "neg_zero() is -0")
	assert_eq(GoldenCodec.hex_of(0.0), "0000000000000000")
	assert_eq(JsMath.to_bits(1.0), 0x3FF0000000000000)
	assert_eq(JsMath.from_bits(0x3FF0000000000000), 1.0)
	assert_eq(JsMath.to_bits(-2.0), -4611686018427387904, "-2.0 is 0xC000000000000000 as a signed int64")
	for x: float in [0.1, -0.1, 1e300, 5e-324, 123456.789]:
		assert_eq(JsMath.from_bits(JsMath.to_bits(x)), x)


# ---------------------------------------------------------------------------------------------------
# Microbenchmark (prints calls per second; there is no pass/fail threshold)
# ---------------------------------------------------------------------------------------------------

func _report(label: String, started_us: int, baseline_us: int) -> void:
	var elapsed: float = float(Time.get_ticks_usec() - started_us - baseline_us)
	var per_call_ns: float = elapsed * 1000.0 / float(BENCH_CALLS)
	if per_call_ns < BENCH_RESOLUTION_NS:
		# The loop's own cost was subtracted: what is left is below what this method can measure (a number would be noise).
		print("BENCH  %-26s    < %d ns/call  (below the resolution of the loop-cost subtraction)" % [label, int(BENCH_RESOLUTION_NS)])
		return
	print("BENCH  %-26s %7.0f ns/call  %6.2f M calls/s" % [label, per_call_ns, 1000.0 / per_call_ns])


func test_benchmark_prints_calls_per_second() -> void:
	var golden: Dictionary = GoldenCodec.load_json("math")
	var angles: PackedFloat64Array = GoldenCodec.input_columns(golden, "sin")[0]
	var pairs: Array[PackedFloat64Array] = GoldenCodec.input_columns(golden, "atan2")
	var exps: PackedFloat64Array = GoldenCodec.input_columns(golden, "exp")[0]
	var nums: PackedFloat64Array = GoldenCodec.input_columns(golden, "round")[0]
	# Game-like inputs: angles within a few turns, coordinates, damping exponents.
	var xs: PackedFloat64Array = PackedFloat64Array()
	var ys: PackedFloat64Array = PackedFloat64Array()
	var es: PackedFloat64Array = PackedFloat64Array()
	xs.resize(BENCH_CALLS)
	ys.resize(BENCH_CALLS)
	es.resize(BENCH_CALLS)
	var rng: SeededRng = SeededRng.new(12345)
	for i: int in range(BENCH_CALLS):
		xs[i] = rng.next_float() * 20.0 - 10.0
		ys[i] = rng.next_float() * 600.0 - 300.0
		es[i] = -rng.next_float() * 0.6
	var acc: float = 0.0
	var t: int = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += xs[i]
	var loop_us: int = Time.get_ticks_usec() - t
	print("BENCH  (typed GDScript, headless; each line is net of the loop cost; a builtin call costs about 30 to 70 ns)")
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += sin(xs[i])
	_report("builtin sin", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.sin(xs[i])
	_report("JsMath.sin", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.cos(xs[i])
	_report("JsMath.cos", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += atan2(ys[i], xs[i])
	_report("builtin atan2", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.atan2(ys[i], xs[i])
	_report("JsMath.atan2", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.atan(xs[i])
	_report("JsMath.atan", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += exp(es[i])
	_report("builtin exp", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.exp(es[i])
	_report("JsMath.exp", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.log(absf(ys[i]) + 1.0)
	_report("JsMath.log", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.hypot(ys[i], xs[i])
	_report("JsMath.hypot", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.js_round(ys[i])
	_report("JsMath.js_round", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += float(JsMath.to_int32(ys[i]))
	_report("JsMath.to_int32", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.js_max(xs[i], ys[i])
	_report("JsMath.js_max", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.clamp(ys[i], -100.0, 100.0)
	_report("JsMath.clamp", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.js_min(xs[i], ys[i])
	_report("JsMath.js_min", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.max3(xs[i], ys[i], es[i])
	_report("JsMath.max3", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.min3(xs[i], ys[i], es[i])
	_report("JsMath.min3", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.max5(xs[i], ys[i], es[i], xs[i], ys[i])
	_report("JsMath.max5", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.min5(xs[i], ys[i], es[i], xs[i], ys[i])
	_report("JsMath.min5", t, loop_us)
	var five: PackedFloat64Array = PackedFloat64Array([1.0, 2.0, 3.0, 4.0, 5.0])
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		five[i % 5] = xs[i]
		acc += JsMath.max_n(five)
	_report("JsMath.max_n (5 values)", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		five[i % 5] = ys[i]
		acc += JsMath.min_n(five)
	_report("JsMath.min_n (5 values)", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.trunc(ys[i])
	_report("JsMath.trunc", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += float(JsMath.to_uint32(ys[i]))
	_report("JsMath.to_uint32", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.sqrt(absf(ys[i]))
	_report("JsMath.sqrt (wrapper)", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += sqrt(absf(ys[i]))
	_report("builtin sqrt", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.js_mod(ys[i], 1e4)
	_report("JsMath.js_mod", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		acc += JsMath.pow(absf(xs[i]), 0.7)
	_report("JsMath.pow", t, loop_us)
	t = Time.get_ticks_usec()
	var bits: int = 1
	for i: int in range(BENCH_CALLS):
		bits = JsMath.imul(bits + i, 1831565813)
	_report("JsMath.imul", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		bits += JsMath.i32(i * 40000)
	_report("JsMath.i32", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		bits += JsMath.shl(i, 7)
	_report("JsMath.shl", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		bits += JsMath.sar(i - 100000, 3)
	_report("JsMath.sar", t, loop_us)
	t = Time.get_ticks_usec()
	for i: int in range(BENCH_CALLS):
		bits += JsMath.shr_u(i - 100000, 3)
	_report("JsMath.shr_u", t, loop_us)
	print("BENCH  checksum %s %d (keeps the loops from being optimised away)" % [str(acc), bits])
	# The only assertions: the input sets were read and the loops produced finite numbers.
	assert_true(angles.size() == 20000 and pairs[0].size() == 20000 and exps.size() == 20000 and nums.size() == 20000, "golden input sets are complete")
	assert_true(is_finite(acc), "the benchmark checksum is finite")
