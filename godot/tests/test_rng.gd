extends "res://tests/test_case.gd"
## SeededRng, GameRng and FxRng against res://tests/golden/rng.json (design section 9.1).
##
## The golden file is generated from the original game: makeSeededRandom, setGameSeed, rand, randi, chance and shuffle are cut
## out of original.html and run in an empty node:vm context (tools/golden/rng.mjs). It holds, per seed, the first 1000 outputs of
## the generator (as the integer k with value = k / 2^32), checkpoints further into the stream, the normalisation of unusual
## seeds, and scripted sequences of the gameRandom helpers with the draw counter after every call.

const CHECKPOINT_FULL_LENGTH_SEED: int = 424242


func _golden() -> Dictionary:
	return GoldenCodec.load_json("rng")


func test_first_1000_outputs_of_every_seed_match_the_original() -> void:
	var golden: Dictionary = _golden()
	var length: int = int(golden["stream_length"])
	assert_eq(length, 1000)
	var seeds: Array = golden["seeds"]
	assert_true(seeds.size() >= 8, "at least the eight seeds of the design are covered")
	var seen: Dictionary = {}
	for entry: Dictionary in seeds:
		var seed: int = int(entry["seed"])
		seen[seed] = true
		var expected: PackedInt64Array = GoldenCodec.decode_u32(entry["first"])
		assert_eq(expected.size(), length, "seed %d: vector length" % seed)
		var rng: SeededRng = SeededRng.new(seed)
		var floats: SeededRng = SeededRng.new(seed)
		var bad: int = 0
		for i: int in range(length):
			var k: int = rng.next_u32()
			var f: float = floats.next_float()
			var ok: bool = k == expected[i] and GoldenCodec.same_double(f, float(expected[i]) / 4294967296.0)
			if not ok:
				bad += 1
				if bad <= 3:
					fail("seed %d output %d: expected k=%d got k=%d (float %s)" % [seed, i, expected[i], k, str(f)])
		assert_eq(bad, 0, "seed %d: outputs that differ" % seed)
	# The seeds that the task and the reference traces name.
	for required: int in [424242, 24681357, 0, 1, 0xFFFFFFFF]:
		assert_true(seen.has(required), "seed %d is in the golden file" % required)


func test_later_outputs_match_the_checkpoints() -> void:
	# The stream is continued to the checkpoints recorded from the original (outputs number 10000 and 100000, and for one
	# seed number 1000000), which catches a drift of the state that the first 1000 values would not show.
	var golden: Dictionary = _golden()
	for entry: Dictionary in golden["seeds"]:
		var seed: int = int(entry["seed"])
		var checkpoints: Dictionary = entry["checkpoints"]
		var last: int = 99999
		if checkpoints.has("999999"):
			assert_eq(seed, CHECKPOINT_FULL_LENGTH_SEED, "only the first reference seed has the long checkpoint")
			last = 999999
		var rng: SeededRng = SeededRng.new(seed)
		var k: int = 0
		for i: int in range(last + 1):
			k = rng.next_u32()
			var key: String = str(i)
			if checkpoints.has(key):
				assert_eq(k, int(checkpoints[key]), "seed %d output %d" % [seed, i])
		assert_true(checkpoints.has(str(last)), "seed %d: checkpoint %d exists" % [seed, last])


func test_seed_normalisation_follows_seed_ushr_0_or_default() -> void:
	# `seed>>>0||2654435769`: negative, fractional, NaN, huge and infinite seeds, as the original treats them.
	var golden: Dictionary = _golden()
	var cases: Array = golden["normalization"]
	assert_true(cases.size() >= 10)
	for entry: Dictionary in cases:
		var input: float = GoldenCodec.from_hex(entry["input"])
		var normalized: int = SeededRng.normalize_seed(input)
		assert_eq(normalized, int(entry["normalized"]), "normalize_seed(%s)" % str(input))
		var rng: SeededRng = SeededRng.new(normalized)
		var first: Array = entry["first"]
		for i: int in range(first.size()):
			assert_eq(rng.next_u32(), int(first[i]), "seed %s, output %d" % [str(input), i])


func test_equal_streams_for_seeds_that_normalise_alike() -> void:
	# 0, 2654435769 and 4294967296 are the same seed for the original (and so are -1 and 4294967295).
	var a: SeededRng = SeededRng.new(0)
	var b: SeededRng = SeededRng.new(2654435769)
	var c: SeededRng = SeededRng.new(4294967296)
	var d: SeededRng = SeededRng.new(-1)
	var e: SeededRng = SeededRng.new(4294967295)
	for i: int in range(50):
		var k: int = a.next_u32()
		assert_eq(b.next_u32(), k)
		assert_eq(c.next_u32(), k)
		assert_eq(d.next_u32(), e.next_u32())


func test_state_can_be_saved_and_restored() -> void:
	var rng: SeededRng = SeededRng.new(24681357)
	for i: int in range(37):
		rng.next_u32()
	var saved: int = rng.state
	var expected: PackedInt64Array = PackedInt64Array()
	for i: int in range(20):
		expected.append(rng.next_u32())
	var other: SeededRng = SeededRng.new(1)
	other.state = saved
	for i: int in range(20):
		assert_eq(other.next_u32(), expected[i], "output %d after restoring the state" % i)
	other.set_seed(24681357)
	var fresh: SeededRng = SeededRng.new(24681357)
	assert_eq(other.next_u32(), fresh.next_u32(), "set_seed restarts the stream")


func _replay_game_rng_sequence(sequence: Dictionary) -> int:
	var seed: int = int(sequence["seed"])
	var game: GameRng = GameRng.new(12345)  # deliberately another seed first: set_seed must start the stream over
	game.random()
	game.set_seed(seed)
	var initial: Dictionary = sequence["initial"]
	assert_eq(game.draws, int(initial["draws"]), "seed %d: draws right after set_seed" % seed)
	assert_eq(game.seed_value, int(initial["seed_value"]), "seed %d: gameRandomSeed" % seed)
	var bad: int = 0
	var index: int = 0
	var ops: Array = sequence["ops"]
	for op: Array in ops:
		var name: String = op[0]
		var args: Array = op[1]
		var expected: Variant = op[2]
		var expected_draws: int = int(op[3])
		var ok: bool = true
		var got_text: String = ""
		match name:
			"random":
				var r: float = game.random()
				ok = GoldenCodec.same_double(r, GoldenCodec.from_hex(expected))
				got_text = str(r)
			"rand":
				var r: float = game.rand(GoldenCodec.from_hex(args[0]), GoldenCodec.from_hex(args[1]))
				ok = GoldenCodec.same_double(r, GoldenCodec.from_hex(expected))
				got_text = str(r)
			"randi":
				var r: int = game.randi(int(args[0]), int(args[1]))
				ok = r == int(expected)
				got_text = str(r)
			"chance":
				var r: bool = game.chance(GoldenCodec.from_hex(args[0]))
				ok = r == (expected as bool)
				got_text = str(r)
			"shuffle":
				var items: Array = []
				for j: int in range(int(args[0])):
					items.append(j)
				game.shuffle(items)
				var want: Array = expected
				ok = items.size() == want.size()
				for j: int in range(mini(items.size(), want.size())):
					if (items[j] as int) != int(want[j]):
						ok = false
				got_text = str(items)
			"index":
				var r: int = game.index(int(args[0]))
				ok = r == int(expected)
				got_text = str(r)
			"reseed":
				game.set_seed(int(args[0]))
				ok = game.seed_value == int(expected)
				got_text = str(game.seed_value)
			_:
				fail("unknown operation %s" % name)
		if game.draws != expected_draws:
			ok = false
			got_text += " (draws %d, expected %d)" % [game.draws, expected_draws]
		if not ok:
			bad += 1
			if bad <= 5:
				fail("seed %d op %d %s%s: expected %s but got %s" % [seed, index, name, str(args), str(expected), got_text])
		index += 1
	return bad


func test_game_rng_helpers_and_draw_counter_match_the_original() -> void:
	var golden: Dictionary = _golden()
	var sequences: Array = golden["game_rng"]
	assert_true(sequences.size() >= 5)
	var total_bad: int = 0
	for sequence: Dictionary in sequences:
		total_bad += _replay_game_rng_sequence(sequence)
	assert_eq(total_bad, 0, "operations that differ from the original")


func test_every_helper_draws_as_often_as_in_the_original() -> void:
	# The counts are those of the original (verified by the replay above); stated here so that a failure names the helper.
	var game: GameRng = GameRng.new(424242)
	assert_eq(game.draws, 0)
	game.random()
	assert_eq(game.draws, 1)
	game.rand(0.0, 1.0)
	assert_eq(game.draws, 2)
	game.randi(1, 6)
	assert_eq(game.draws, 3)
	game.chance(0.0)
	assert_eq(game.draws, 4, "chance draws even when the probability is 0")
	game.chance(1.0)
	assert_eq(game.draws, 5)
	game.index(4)
	assert_eq(game.draws, 6)
	game.shuffle([])
	game.shuffle([1])
	assert_eq(game.draws, 6, "shuffle of 0 or 1 elements draws nothing")
	game.shuffle([1, 2, 3, 4, 5])
	assert_eq(game.draws, 10, "shuffle draws length - 1 times")
	game.set_seed(424242)
	assert_eq(game.draws, 0, "set_seed resets the counter")


func test_game_rng_and_seeded_rng_give_the_same_stream() -> void:
	var game: GameRng = GameRng.new(424242)
	var plain: SeededRng = SeededRng.new(424242)
	for i: int in range(100):
		assert_eq(GoldenCodec.same_double(game.random(), plain.next_float()), true, "draw %d" % i)
	assert_eq(game.draws, 100)


func test_fx_rng_is_separate_and_seedable() -> void:
	var game_a: GameRng = GameRng.new(424242)
	var game_b: GameRng = GameRng.new(424242)
	var fx: FxRng = FxRng.new(777)
	for i: int in range(200):
		var a: float = game_a.random()
		# Effects drawn between the simulation's draws must not change them.
		fx.random()
		fx.rand_fx(-3.0, 3.0)
		fx.randi_fx(1, 6)
		fx.chance_fx(0.5)
		var b: float = game_b.random()
		assert_eq(GoldenCodec.same_double(a, b), true, "simulation draw %d unchanged by effect draws" % i)
	assert_eq(game_a.draws, 200)
	assert_eq(game_b.draws, 200, "FxRng never touches GameRng.draws")
	var fx_a: FxRng = FxRng.new(5)
	var fx_b: FxRng = FxRng.new(5)
	var fx_c: FxRng = FxRng.new(6)
	var differs: bool = false
	for i: int in range(50):
		var x: float = fx_a.random()
		assert_eq(GoldenCodec.same_double(x, fx_b.random()), true, "same seed, same effect stream")
		assert_true(x >= 0.0 and x < 1.0)
		if not GoldenCodec.same_double(x, fx_c.random()):
			differs = true
		var r: int = fx_a.randi_fx(2, 4)
		fx_b.randi_fx(2, 4)
		assert_true(r >= 2 and r <= 4, "randi_fx stays within its inclusive bounds")
		var f: float = fx_a.rand_fx(10.0, 20.0)
		fx_b.rand_fx(10.0, 20.0)
		assert_true(f >= 10.0 and f < 20.0)
	assert_true(differs, "another seed gives another stream")


# ---------------------------------------------------------------------------------------------------
# Microbenchmark (prints draws per second; there is no pass/fail threshold)
# ---------------------------------------------------------------------------------------------------

func test_benchmark_prints_draws_per_second() -> void:
	var calls: int = 200000
	var rng: SeededRng = SeededRng.new(424242)
	var game: GameRng = GameRng.new(424242)
	var fx: FxRng = FxRng.new(1)
	var acc: float = 0.0
	var k_sum: int = 0
	var t: int = Time.get_ticks_usec()
	for i: int in range(calls):
		acc += float(i)
	var loop_us: int = Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	for i: int in range(calls):
		k_sum += rng.next_u32()
	_report("SeededRng.next_u32", t, loop_us, calls)
	t = Time.get_ticks_usec()
	for i: int in range(calls):
		acc += rng.next_float()
	_report("SeededRng.next_float", t, loop_us, calls)
	t = Time.get_ticks_usec()
	for i: int in range(calls):
		acc += game.random()
	_report("GameRng.random", t, loop_us, calls)
	t = Time.get_ticks_usec()
	for i: int in range(calls):
		acc += game.rand(-5.0, 5.0)
	_report("GameRng.rand", t, loop_us, calls)
	t = Time.get_ticks_usec()
	for i: int in range(calls):
		if game.chance(0.5):
			k_sum += 1
	_report("GameRng.chance", t, loop_us, calls)
	t = Time.get_ticks_usec()
	for i: int in range(calls):
		k_sum += game.index(4)
	_report("GameRng.index", t, loop_us, calls)
	t = Time.get_ticks_usec()
	for i: int in range(calls):
		acc += fx.random()
	_report("FxRng.random", t, loop_us, calls)
	print("BENCH  checksum %s %d (keeps the loops from being optimised away)" % [str(acc), k_sum])
	assert_eq(game.draws, 4 * calls, "the benchmark drew from GameRng four times per round (random, rand, chance, index)")
	assert_true(is_finite(acc), "the benchmark checksum is finite")


func _report(label: String, started_us: int, baseline_us: int, calls: int) -> void:
	var elapsed: float = float(Time.get_ticks_usec() - started_us - baseline_us)
	var per_call_ns: float = maxf(elapsed, 1.0) * 1000.0 / float(calls)
	print("BENCH  %-26s %7.0f ns/call  %6.2f M calls/s" % [label, per_call_ns, 1000.0 / per_call_ns])
