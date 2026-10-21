extends SceneTree
## Benchmark of Sim.step on deterministic stress states: the measurement that the decision of design section 5.5 waits for ("measure
## Sim.step, then decide between the bit-exact cost cuts, a GDExtension for the math, or builtins for the distributed build"). TEST-ONLY:
## it lives under godot/tests, which the Android export excludes (exclude_filter "tests/*"); the simulation does not know it.
##
## Run it with tools/bench_sim.sh (toolchain, the profiling build for the call counts, a stable header). By hand:
##
##   godot --headless --path godot -s res://tests/bench/bench_sim.gd -- [--mode=time|count|steps] [--steps=N] [--only=a,b,c]
##                                                                       [--counts=FILE] [--builtin=FILE] [--out=FILE]
##
##   --mode=time    (default) times Sim.step and every slot, measures the cost of one JsMath call, prints the report.
##   --mode=count   counts the JsMath calls of every step per function and per slot. It only means something in a PROFILING BUILD of the
##                  project, in which sim/js_compat.gd was rewritten by tools/lib/make_jsmath_profile.mjs so that sin, cos, atan, atan2,
##                  exp, log, hypot and pow bump the dictionary stored in Engine meta "swarm_bench_jsmath_counts". The production
##                  code has no counter; the counts are written to --out as JSON and the time run reads them back with --counts.
##   --mode=steps   only times Sim.step (the first pass of --mode=time) and writes the statistics to --out as JSON. Run in a copy of the
##                  project whose js_compat.gd forwards sin, cos, ... to the engine's builtins (make_jsmath_profile.mjs --builtin): the
##                  EXPERIMENT that shows what the bit-exact math costs; the time run reads it back with --builtin.
##   --steps=N      measured steps per scenario (default 600; at least 600 for the numbers of the report).
##   --only=a,b,c   scenarios to run.
##
## The scenarios (all: seed 424242, catalyst, normal difficulty, 390 x 844, coarse pointer, player hp 1e9 so that contact hits cannot end
## the run, wave clock held so that the wave does not change while measuring; the enemies are the real ones, made by
## EnemyDirector.create_enemy_field_spawn_plan + spawn_enemy, so they have the stats and AI state of a director spawn):
##   a  100 swarm enemies bunched near the player: spawned at the director's distance, then 1500 steps of the real AI against a player that
##      stands still. They end up in a blob around the player and hit it every 0.38 s: the worst case of the swarm AI (crowded separation
##      scans, steering, contact).
##   b  100 mixed swarm / assassin (every third enemy an assassin) spread at spawn distance: spawned as in (a); every 30 steps all of them
##      are placed again, so that every measured step has them 600 to 800 px away from the player (the cost of a full wave that has just
##      arrived: sparse grid, long walks, no contact).
##   c  30 enemies, a typical early wave: the same mix as (b), the enemy cap is lowered to 30 so that the director cannot add more, a player
##      that walks the 8 directions of the design 9.2 input script (60 steps each), 600 steps of warm-up so that they trail it.
## What is NOT in these states (steps S6 to S8 have not ported it yet): projectiles, XP orbs, weapons, hits (nothing dies), particles,
## pickup, HUD. The design 5.5 target scene (520 projectiles, 480 orbs) is therefore only partly measurable today; this harness is meant to
## be re-run when S6 lands. The timed numbers are of the headless editor binary (a debug build) on this machine, not of a phone.

const SEED: int = 424242
const DEFAULT_STEPS: int = 600
const PRE_STEPS: int = 60
const TOP_SLOTS: int = 8
const HUGE_HP: float = 1.0e9
const TARGET_MS: float = 4.0
const COUNT_META: String = "swarm_bench_jsmath_counts"
const FUNCS: PackedStringArray = ["sin", "cos", "atan", "atan2", "exp", "log", "hypot", "pow"]
const MICRO_CALLS: int = 100000
const MICRO_RUNS: int = 5
const DIR_STEPS: int = 60


class Scenario extends RefCounted:
	var id: String = ""
	var title: String = ""
	var count: int = 0
	## 0: swarm only; n: every n-th enemy is an assassin.
	var assassin_every: int = 0
	var wave: int = 1
	var cap: int = 100
	var player_moves: bool = false
	## 0: place the enemies once; n: place them again every n steps.
	var ring_window: int = 0
	var warmup_steps: int = 0
	var step_index: int = 0

	func _init(p_id: String, p_title: String, p_count: int, p_assassin_every: int, p_wave: int, p_cap: int, p_player_moves: bool,
			p_ring_window: int, p_warmup_steps: int) -> void:
		id = p_id
		title = p_title
		count = p_count
		assassin_every = p_assassin_every
		wave = p_wave
		cap = p_cap
		player_moves = p_player_moves
		ring_window = p_ring_window
		warmup_steps = p_warmup_steps


## Times one slot: the time inside run() of every step is collected in `acc_us` and moved to `samples` after the step.
class SlotTimer extends SimSystem:
	var inner: SimSystem = null
	var label: String = ""
	var acc_us: int = 0
	var samples: PackedFloat64Array = PackedFloat64Array()

	func _init(p_inner: SimSystem, p_label: String) -> void:
		super(p_inner.game, p_inner.original_function)
		inner = p_inner
		label = p_label

	func run(dt: float) -> void:
		var started: int = Time.get_ticks_usec()
		inner.run(dt)
		acc_us += Time.get_ticks_usec() - started

	func when() -> bool:
		return inner.when()

	func is_implemented() -> bool:
		return inner.is_implemented()


## Counts the JsMath calls that one slot makes: the difference of the shared counter dictionary around run().
class SlotCounter extends SimSystem:
	var inner: SimSystem = null
	var label: String = ""
	var counts: Dictionary = {}
	var names: PackedStringArray = PackedStringArray()
	var totals: PackedInt64Array = PackedInt64Array()
	var _before: PackedInt64Array = PackedInt64Array()

	func _init(p_inner: SimSystem, p_label: String, p_counts: Dictionary, p_names: PackedStringArray) -> void:
		super(p_inner.game, p_inner.original_function)
		inner = p_inner
		label = p_label
		counts = p_counts
		names = p_names
		totals.resize(names.size())
		_before.resize(names.size())

	func run(dt: float) -> void:
		for k: int in range(names.size()):
			_before[k] = int(counts.get(names[k], 0))
		inner.run(dt)
		for k: int in range(names.size()):
			totals[k] += int(counts.get(names[k], 0)) - _before[k]

	func when() -> bool:
		return inner.when()

	func is_implemented() -> bool:
		return inner.is_implemented()


var _sink: float = 0.0
var _xs: PackedFloat64Array = PackedFloat64Array()
var _ys: PackedFloat64Array = PackedFloat64Array()
var _zs: PackedFloat64Array = PackedFloat64Array()
var _ps: PackedFloat64Array = PackedFloat64Array()


func _initialize() -> void:
	var options: Dictionary = {"mode": "time", "steps": str(DEFAULT_STEPS), "only": "", "counts": "", "builtin": "", "out": ""}
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--") or not argument.contains("="):
			printerr("bench_sim: unknown argument %s" % argument)
			quit(2)
			return
		var key: String = argument.substr(2, argument.find("=") - 2)
		if not options.has(key):
			printerr("bench_sim: unknown option --%s" % key)
			quit(2)
			return
		options[key] = argument.substr(argument.find("=") + 1)
	var steps: int = int(options["steps"])
	if steps < 1:
		printerr("bench_sim: --steps must be positive")
		quit(2)
		return
	var wanted: PackedStringArray = PackedStringArray()
	if str(options["only"]) != "":
		wanted = str(options["only"]).split(",")
	var scenarios: Array[Scenario] = []
	for scn: Scenario in _scenarios():
		if wanted.is_empty() or wanted.has(scn.id):
			scenarios.append(scn)
	if scenarios.is_empty():
		printerr("bench_sim: no scenario selected")
		quit(2)
		return
	var code: int = 2
	match str(options["mode"]):
		"time":
			code = _run_time(scenarios, steps, str(options["counts"]), str(options["builtin"]))
		"count":
			code = _run_count(scenarios, steps, str(options["out"]))
		"steps":
			code = _run_steps(scenarios, steps, str(options["out"]))
		_:
			printerr("bench_sim: --mode must be time, count or steps")
	quit(code)


# --- scenarios ----------------------------------------------------------------------------------------------------------------

func _scenarios() -> Array[Scenario]:
	var list: Array[Scenario] = []
	list.append(Scenario.new("a", "100 swarm enemies bunched near the player", 100, 0, 3, 100, false, 0, 1500))
	list.append(Scenario.new("b", "100 mixed swarm/assassin at spawn distance", 100, 3, 3, 100, false, 30, 0))
	list.append(Scenario.new("c", "30 enemies, typical early wave (mixed, player walking)", 30, 3, 3, 30, true, 0, 600))
	return list


func _build(scn: Scenario) -> Sim:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = SEED
	var sim: Sim = Sim.new()
	if not sim.new_game(config):
		return null
	var game: GameState = sim.game
	game.player.hp = HUGE_HP
	game.player.max_hp = HUGE_HP
	var progress: WaveProgressSystem = WaveProgressSystem.new(game)
	while game.wave < scn.wave:
		progress.advance_wave()
	game.wave_clock = 1.0e6
	game.limits.base_max_enemies = scn.cap
	scn.step_index = 0
	_place(sim, scn)
	for i: int in range(scn.warmup_steps):
		_before_step(sim, scn)
		sim.step()
	return sim


## Replaces all enemies by `scn.count` fresh director spawns (batches of 4 around random points at the spawn distance of the director).
func _place(sim: Sim, scn: Scenario) -> void:
	var game: GameState = sim.game
	game.enemies.clear()
	game.enemies_version += 1
	var made: int = 0
	while made < scn.count:
		var plan: EnemySpawnPlan = EnemyDirector.create_enemy_field_spawn_plan(game, 4)
		for j: int in range(4):
			if made >= scn.count:
				break
			var kind: String = "swarm"
			if scn.assassin_every > 0 and made % scn.assassin_every == scn.assassin_every - 1:
				kind = "assassin"
			if not EnemyDirector.spawn_enemy(game, kind, plan, j):
				push_error("bench_sim: spawn_enemy refused enemy %d of scenario %s" % [made, scn.id])
				return
			made += 1


@warning_ignore("integer_division")
## What the host does before each step: the input, and for scenario b the new placement of the enemies at the start of a window.
func _before_step(sim: Sim, scn: Scenario) -> void:
	var game: GameState = sim.game
	if scn.player_moves:
		var direction: int = (scn.step_index / DIR_STEPS) % 8
		var input: SimInput = game.input
		input.key_right = direction == 0 or direction == 1 or direction == 7
		input.key_down = direction == 1 or direction == 2 or direction == 3
		input.key_left = direction == 3 or direction == 4 or direction == 5
		input.key_up = direction == 5 or direction == 6 or direction == 7
	if scn.ring_window > 0 and scn.step_index % scn.ring_window == 0:
		_place(sim, scn)
	scn.step_index += 1


# --- statistics ---------------------------------------------------------------------------------------------------------------

@warning_ignore("integer_division")
func _median_of_sorted(s: PackedFloat64Array) -> float:
	var n: int = s.size()
	if n == 0:
		return 0.0
	if n % 2 == 1:
		return s[n / 2]
	return (s[n / 2 - 1] + s[n / 2]) / 2.0


func _stats(samples_us: PackedFloat64Array) -> Dictionary:
	var s: PackedFloat64Array = samples_us.duplicate()
	s.sort()
	var n: int = s.size()
	var total: float = 0.0
	for v: float in s:
		total += v
	var p95_index: int = clampi(ceili(0.95 * float(n)) - 1, 0, maxi(n - 1, 0))
	return {
		"n": n,
		"median": _median_of_sorted(s),
		"p95": s[p95_index] if n > 0 else 0.0,
		"min": s[0] if n > 0 else 0.0,
		"max": s[n - 1] if n > 0 else 0.0,
		"mean": total / float(maxi(n, 1)),
	}


func _ms(us: float) -> String:
	return "%.3f" % (us / 1000.0)


## "min / median / max" of the enemies' distance to the player, in px.
func _distance_text(game: GameState) -> String:
	var d: PackedFloat64Array = PackedFloat64Array()
	for e: EnemyState in game.enemies:
		var dx: float = e.x - game.player.x
		var dy: float = e.y - game.player.y
		d.append(sqrt(dx * dx + dy * dy))
	if d.is_empty():
		return "no enemies"
	d.sort()
	return "%.0f / %.0f / %.0f px" % [d[0], _median_of_sorted(d), d[d.size() - 1]]


func _kinds_text(game: GameState) -> String:
	var swarm: int = 0
	var assassin: int = 0
	var other: int = 0
	for e: EnemyState in game.enemies:
		if e.kind == "swarm":
			swarm += 1
		elif e.kind == "assassin":
			assassin += 1
		else:
			other += 1
	return "%d enemies (swarm %d, assassin %d, other %d)" % [game.enemies.size(), swarm, assassin, other]


## A hash of the state that the timed steps lead to: the enemies' positions and the draw count. Equal in every run; the count run prints the same
## after the same steps, so the report can show that both runs saw the same game.
func _fingerprint(game: GameState) -> String:
	var h: int = 1469598103934665603
	for e: EnemyState in game.enemies:
		h = (h ^ JsMath.to_bits(e.x)) * 1099511628211
		h = (h ^ JsMath.to_bits(e.y)) * 1099511628211
	h = (h ^ game.rng.draws) * 1099511628211
	h = (h ^ JsMath.to_bits(game.player.x)) * 1099511628211
	h = (h ^ JsMath.to_bits(game.player.y)) * 1099511628211
	return "%016x" % (h & 0x7FFFFFFFFFFFFFFF)


# --- the time run --------------------------------------------------------------------------------------------------------------

## The unmeasured steps are done; times `steps` steps of Sim.step alone, nothing around it. Returns {samples (microseconds), hits (steps with a
## contact hit on the player)}.
func _pass_one(sim: Sim, scn: Scenario, steps: int) -> Dictionary:
	var game: GameState = sim.game
	var samples: PackedFloat64Array = PackedFloat64Array()
	samples.resize(steps)
	var hits: int = 0
	for i: int in range(steps):
		_before_step(sim, scn)
		var last_hit: float = game.player.last_hit
		var started: int = Time.get_ticks_usec()
		sim.step()
		samples[i] = float(Time.get_ticks_usec() - started)
		if game.player.last_hit != last_hit:
			hits += 1
	return {"samples": samples, "hits": hits}


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed
	return {}


func _run_time(scenarios: Array[Scenario], steps: int, counts_file: String, builtin_file: String) -> int:
	var counts: Dictionary = {}
	if counts_file != "":
		counts = _read_json(counts_file)
		if counts.is_empty():
			printerr("bench_sim: cannot read the call counts from %s" % counts_file)
			return 1
	var builtin: Dictionary = {}
	if builtin_file != "":
		builtin = _read_json(builtin_file)
		if builtin.is_empty():
			printerr("bench_sim: cannot read the builtin-math statistics from %s" % builtin_file)
			return 1
	print("bench_sim: Sim.step on deterministic stress states (design 5.5)")
	print("godot:     %s, debug build %s, headless" % [Engine.get_version_info()["string"], str(OS.is_debug_build())])
	print("cpu:       %s (%d logical cores)" % [OS.get_processor_name(), OS.get_processor_count()])
	print("seed:      %d, steps measured per scenario: %d (after %d unmeasured steps), step = %.9f s" % [SEED, steps, PRE_STEPS, Sim.FIXED_DT])
	print("note:      the numbers are of this machine and of the headless editor binary (a debug build), not of a phone or of the release template.")
	print("")
	var micro: Dictionary = _micro_bench()
	_print_micro(micro)
	var summary: Array = []
	for scn: Scenario in scenarios:
		summary.append(_time_scenario(scn, steps, micro, counts.get("scenarios", {}).get(scn.id, {}) as Dictionary))
	print("")
	print("SUMMARY: Sim.step, milliseconds (design 5.5 target: median <= %.3f ms for 100 enemies + 520 projectiles + 480 orbs; projectiles and orbs do not exist yet)" % TARGET_MS)
	print("  %-3s %-54s %8s %8s %8s %8s" % ["id", "scenario", "median", "p95", "max", "median/4ms"])
	for row: Dictionary in summary:
		print("  %-3s %-54s %8s %8s %8s %7.2fx" % [row["id"], row["title"], _ms(row["median"]), _ms(row["p95"]), _ms(row["max"]), row["median"] / 1000.0 / TARGET_MS])
	if not builtin.is_empty():
		print("")
		print("EXPERIMENT, what the bit-exact math costs: the same steps in a copy of the project whose JsMath.sin, cos, atan, atan2, exp, log, pow forward to the")
		print("engine's builtins and hypot to sqrt(x*x + y*y) (still called through JsMath; NOT bit-exact, the game drifts in the last bits; milliseconds):")
		print("  %-3s %-54s %17s %17s %8s" % ["id", "scenario", "JsMath median/p95", "builtin median/p95", "saved"])
		var scenario_stats: Dictionary = builtin.get("scenarios", {})
		for row: Dictionary in summary:
			var other: Dictionary = scenario_stats.get(row["id"], {})
			if other.is_empty():
				continue
			var saved: float = row["median"] - float(other["median"])
			print("  %-3s %-54s %8s /%8s %8s /%8s %7.1f%%" % [row["id"], row["title"], _ms(row["median"]), _ms(row["p95"]), _ms(float(other["median"])),
					_ms(float(other["p95"])), 100.0 * saved / row["median"]])
	return 0


func _time_scenario(scn: Scenario, steps: int, micro: Dictionary, counts: Dictionary) -> Dictionary:
	print("")
	print("=== scenario %s: %s" % [scn.id, scn.title])
	var sim: Sim = _build(scn)
	if sim == null:
		printerr("bench_sim: the game could not be created")
		return {"id": scn.id, "title": scn.title, "median": 0.0, "p95": 0.0, "max": 0.0}
	var game: GameState = sim.game
	print("state at the start: wave %d, %s" % [game.wave, _kinds_text(game)])
	print("                    distance to the player (min / median / max): %s" % _distance_text(game))
	if scn.warmup_steps > 0:
		print("                    after %d steps of warm-up" % scn.warmup_steps)
	for i: int in range(PRE_STEPS):
		_before_step(sim, scn)
		sim.step()
	# pass 1: Sim.step alone, nothing around it
	var draws_before: int = game.rng.draws
	var version_before: int = game.enemies_version
	var pass_one: Dictionary = _pass_one(sim, scn, steps)
	var samples: PackedFloat64Array = pass_one["samples"]
	var hits: int = pass_one["hits"]
	var fingerprint: String = _fingerprint(game)
	var stats: Dictionary = _stats(samples)
	print("")
	print("Sim.step over %d steps:  median %s ms   p95 %s ms   mean %s ms   min %s ms   max %s ms" % [
		steps, _ms(stats["median"]), _ms(stats["p95"]), _ms(stats["mean"]), _ms(stats["min"]), _ms(stats["max"])])
	print("state after the steps:   %s; distance to the player %s" % [_kinds_text(game), _distance_text(game)])
	print("                         contact hits on the player: %d, gameRandom draws: %d, enemies list changes: %d, fingerprint %s" % [
		hits, game.rng.draws - draws_before, game.enemies_version - version_before, fingerprint])
	# pass 2: the same game goes on with every slot wrapped in a timer
	var probes: Array[SlotTimer] = []
	for pair: Array in [["intro", sim.runner.intro], ["main", sim.runner.main]]:
		var list: Array[SystemSlot] = pair[1]
		for index: int in range(list.size()):
			var slot: SystemSlot = list[index]
			var probe: SlotTimer = SlotTimer.new(slot.system, "%s:%d %s" % [pair[0], index, slot.id])
			slot.system = probe
			probes.append(probe)
	var wrapped: PackedFloat64Array = PackedFloat64Array()
	wrapped.resize(steps)
	for i: int in range(steps):
		_before_step(sim, scn)
		var started: int = Time.get_ticks_usec()
		sim.step()
		wrapped[i] = float(Time.get_ticks_usec() - started)
		for probe: SlotTimer in probes:
			probe.samples.append(float(probe.acc_us))
			probe.acc_us = 0
	var wrapped_stats: Dictionary = _stats(wrapped)
	var rows: Array = []
	var sum_of_medians: float = 0.0
	for probe: SlotTimer in probes:
		var s: Dictionary = _stats(probe.samples)
		sum_of_medians += s["median"]
		rows.append({"label": probe.label, "median": s["median"], "p95": s["p95"], "max": s["max"]})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["median"] > b["median"])
	print("")
	print("per slot, %d more steps with every slot wrapped in a timer (the wrapped Sim.step: median %s ms, p95 %s ms):" % [
		steps, _ms(wrapped_stats["median"]), _ms(wrapped_stats["p95"])])
	print("  %-34s %9s %9s %9s %8s" % ["slot (the heaviest %d of %d)" % [TOP_SLOTS, rows.size()], "median ms", "p95 ms", "max ms", "% of step"])
	var shown: float = 0.0
	for k: int in range(mini(TOP_SLOTS, rows.size())):
		var row: Dictionary = rows[k]
		shown += row["median"]
		print("  %-34s %9s %9s %9s %7.1f%%" % [row["label"], _ms(row["median"]), _ms(row["p95"]), _ms(row["max"]), 100.0 * row["median"] / wrapped_stats["median"]])
	print("  %-34s %9s %9s %9s %7.1f%%" % ["the other %d slots together" % maxi(rows.size() - TOP_SLOTS, 0), _ms(sum_of_medians - shown), "", "", 100.0 * (sum_of_medians - shown) / wrapped_stats["median"]])
	print("  %-34s %9s   (sum of the slot medians; the rest of a step is the wrapper and Sim.step itself)" % ["all slots", _ms(sum_of_medians)])
	_print_rebuild(game)
	_print_steering_parts(game)
	if not counts.is_empty():
		_print_counts(counts, steps, micro, wrapped_stats["median"], stats["median"], fingerprint)
	return {"id": scn.id, "title": scn.title, "median": stats["median"], "p95": stats["p95"], "max": stats["max"]}


func _print_rebuild(game: GameState) -> void:
	var t: PackedFloat64Array = PackedFloat64Array()
	for i: int in range(100):
		var started: int = Time.get_ticks_usec()
		game.enemy_grid.rebuild(game.enemies)
		t.append(float(Time.get_ticks_usec() - started))
	var s: Dictionary = _stats(t)
	print("  EnemyGrid.rebuild alone, %d enemies: median %.0f us, p95 %.0f us (run by index/separation-1, enemy/update and index/separation-2: 3 per step)" % [
		game.enemies.size(), s["median"], s["p95"]])


## What the biggest slot is made of, by the two public functions of EnemySteering that enemy/update calls for every enemy, timed over all enemies on the
## final state (the enemies' x, y, velocity and facing are put back after each repeat). steer_enemy is called with the swarm's arguments
## (_move_basic_enemy), which is only an approximation for the assassins.
func _print_steering_parts(game: GameState) -> void:
	var steering: EnemySteering = EnemySteering.new(game)
	var p: PlayerState = game.player
	var saved: PackedFloat64Array = PackedFloat64Array()
	for e: EnemyState in game.enemies:
		saved.append_array(PackedFloat64Array([e.x, e.y, e.vx, e.vy, e.facing]))
	var scan_us: PackedFloat64Array = PackedFloat64Array()
	var steer_us: PackedFloat64Array = PackedFloat64Array()
	for rep: int in range(30):
		game.enemy_grid.rebuild(game.enemies)
		var started: int = Time.get_ticks_usec()
		for e: EnemyState in game.enemies:
			steering.enemy_separation_vector(e, 36.0)
		scan_us.append(float(Time.get_ticks_usec() - started))
		started = Time.get_ticks_usec()
		for e: EnemyState in game.enemies:
			steering.steer_enemy(e, p.x, p.y, e.speed, Sim.FIXED_DT, 0.62, 36.0, false, 1.05, 0.08)
		steer_us.append(float(Time.get_ticks_usec() - started))
		for k: int in range(game.enemies.size()):
			var e2: EnemyState = game.enemies[k]
			e2.x = saved[k * 5]
			e2.y = saved[k * 5 + 1]
			e2.vx = saved[k * 5 + 2]
			e2.vy = saved[k * 5 + 3]
			e2.facing = saved[k * 5 + 4]
	var scan: Dictionary = _stats(scan_us)
	var steer: Dictionary = _stats(steer_us)
	print("  inside enemy/update, timed alone over all %d enemies (EnemySteering, 30 repeats, swarm arguments):" % game.enemies.size())
	print("    enemy_separation_vector, the neighbour scan:        median %s ms (%.1f us per enemy)" % [_ms(scan["median"]), scan["median"] / float(maxi(game.enemies.size(), 1))])
	print("    steer_enemy, which includes that scan:              median %s ms (%.1f us per enemy)" % [_ms(steer["median"]), steer["median"] / float(maxi(game.enemies.size(), 1))])


func _print_counts(counts: Dictionary, steps: int, micro: Dictionary, wrapped_median: float, plain_median: float, fingerprint: String) -> void:
	var counted_steps: int = int(counts.get("steps", 0))
	if counted_steps <= 0:
		return
	var total: Dictionary = counts.get("total", {})
	print("")
	var same: String = "the counted steps are the timed steps (same fingerprint %s)" % fingerprint if str(counts.get("fingerprint", "")) == fingerprint \
			else "WARNING: the counted game differs from the timed game (fingerprint %s against %s)" % [str(counts.get("fingerprint", "")), fingerprint]
	print("JsMath calls per step, by function (profiling build, %d steps counted; %s):" % [counted_steps, same])
	print("  %-8s %12s %12s %12s %14s %14s" % ["function", "calls/step", "JsMath ns", "builtin ns", "JsMath us/step", "builtin us/step"])
	var calls_total: float = 0.0
	var js_us: float = 0.0
	var builtin_us: float = 0.0
	for name: String in FUNCS:
		var per_step: float = float(total.get(name, 0)) / float(counted_steps)
		var cost: Array = micro.get(name, [0.0, 0.0])
		calls_total += per_step
		js_us += per_step * cost[0] / 1000.0
		builtin_us += per_step * cost[1] / 1000.0
		print("  %-8s %12.1f %12.0f %12.0f %14.1f %14.1f" % [name, per_step, cost[0], cost[1], per_step * cost[0] / 1000.0, per_step * cost[1] / 1000.0])
	print("  %-8s %12.1f %12s %12s %14.1f %14.1f" % ["total", calls_total, "", "", js_us, builtin_us])
	print("  estimate: the JsMath calls above cost about %.2f ms of the %.3f ms step median (%.0f%%); with the engine builtins they would cost %.2f ms." % [
		js_us / 1000.0, plain_median / 1000.0, 100.0 * js_us / plain_median, builtin_us / 1000.0])
	print("            (calls x the per-call cost measured above: an estimate, not a measurement of the step; sqrt, floor, js_max and the other JsMath functions are not counted;")
	print("             the EXPERIMENT at the end of the report measures the same cost directly, with the step itself)")
	var slot_counts: Dictionary = counts.get("slots", {})
	var rows: Array = []
	for label: String in slot_counts.keys():
		var by_function: Dictionary = slot_counts[label]
		var slot_total: float = 0.0
		for name: String in FUNCS:
			slot_total += float(by_function.get(name, 0))
		if slot_total > 0.0:
			rows.append({"label": label, "by": by_function, "total": slot_total})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["total"] > b["total"])
	var header: String = "  %-34s" % "calls per step by slot"
	for name: String in FUNCS:
		header += " %8s" % name
	print(header)
	for row: Dictionary in rows:
		var line: String = "  %-34s" % row["label"]
		for name: String in FUNCS:
			line += " %8.1f" % (float(row["by"].get(name, 0)) / float(counted_steps))
		print(line)
	var outside: Dictionary = counts.get("outside_slots", {})
	var outside_total: float = 0.0
	for name: String in FUNCS:
		outside_total += float(outside.get(name, 0))
	print("  calls outside the slots (Sim.step itself): %.1f per step" % (outside_total / float(counted_steps)))


# --- the steps run (pass 1 only) -----------------------------------------------------------------------------------------------------

func _run_steps(scenarios: Array[Scenario], steps: int, out_file: String) -> int:
	if out_file == "":
		printerr("bench_sim: --mode=steps needs --out=FILE")
		return 2
	var result: Dictionary = {"steps": steps, "scenarios": {}}
	for scn: Scenario in scenarios:
		var sim: Sim = _build(scn)
		if sim == null:
			printerr("bench_sim: the game could not be created")
			return 1
		for i: int in range(PRE_STEPS):
			_before_step(sim, scn)
			sim.step()
		var pass_one: Dictionary = _pass_one(sim, scn, steps)
		var stats: Dictionary = _stats(pass_one["samples"])
		result["scenarios"][scn.id] = stats
		print("bench_sim steps: scenario %s, %d steps, median %s ms, p95 %s ms" % [scn.id, steps, _ms(stats["median"]), _ms(stats["p95"])])
	var file: FileAccess = FileAccess.open(out_file, FileAccess.WRITE)
	if file == null:
		printerr("bench_sim: cannot write %s" % out_file)
		return 1
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	return 0


# --- the count run ---------------------------------------------------------------------------------------------------------------

func _snapshot(counts: Dictionary) -> PackedInt64Array:
	var out: PackedInt64Array = PackedInt64Array()
	for name: String in FUNCS:
		out.append(int(counts.get(name, 0)))
	return out


func _run_count(scenarios: Array[Scenario], steps: int, out_file: String) -> int:
	if out_file == "":
		printerr("bench_sim: --mode=count needs --out=FILE")
		return 2
	var result: Dictionary = {"steps": steps, "scenarios": {}}
	for scn: Scenario in scenarios:
		var sim: Sim = _build(scn)
		if sim == null:
			printerr("bench_sim: the game could not be created")
			return 1
		for i: int in range(PRE_STEPS):
			_before_step(sim, scn)
			sim.step()
		var counts: Dictionary = {}
		for name: String in FUNCS:
			counts[name] = 0
		Engine.set_meta(COUNT_META, counts)
		var probes: Array[SlotCounter] = []
		for pair: Array in [["intro", sim.runner.intro], ["main", sim.runner.main]]:
			var list: Array[SystemSlot] = pair[1]
			for index: int in range(list.size()):
				var slot: SystemSlot = list[index]
				var probe: SlotCounter = SlotCounter.new(slot.system, "%s:%d %s" % [pair[0], index, slot.id], counts, FUNCS)
				slot.system = probe
				probes.append(probe)
		# only the calls made inside Sim.step count: the placement of the enemies in _before_step (scenario b) is the harness, not the game
		var step_totals: PackedInt64Array = PackedInt64Array()
		step_totals.resize(FUNCS.size())
		for i: int in range(steps):
			_before_step(sim, scn)
			var before: PackedInt64Array = _snapshot(counts)
			sim.step()
			var after: PackedInt64Array = _snapshot(counts)
			for k: int in range(FUNCS.size()):
				step_totals[k] += after[k] - before[k]
		var total: Dictionary = {}
		var outside: Dictionary = {}
		var slots: Dictionary = {}
		var any: int = 0
		for k: int in range(FUNCS.size()):
			total[FUNCS[k]] = step_totals[k]
			any += step_totals[k]
			outside[FUNCS[k]] = step_totals[k]
		for probe: SlotCounter in probes:
			var by_function: Dictionary = {}
			var slot_any: int = 0
			for k: int in range(FUNCS.size()):
				by_function[FUNCS[k]] = probe.totals[k]
				slot_any += probe.totals[k]
				outside[FUNCS[k]] = int(outside[FUNCS[k]]) - probe.totals[k]
			if slot_any > 0:
				slots[probe.label] = by_function
		Engine.remove_meta(COUNT_META)
		if any == 0:
			printerr("bench_sim: not a single JsMath call was counted; this is not a profiling build (tools/lib/make_jsmath_profile.mjs)")
			return 1
		result["scenarios"][scn.id] = {"total": total, "slots": slots, "outside_slots": outside, "steps": steps, "fingerprint": _fingerprint(sim.game)}
		print("bench_sim count: scenario %s, %d steps, %d JsMath calls counted, fingerprint %s" % [scn.id, steps, any, _fingerprint(sim.game)])
	# the report reads "steps" and "fingerprint" per scenario
	var file: FileAccess = FileAccess.open(out_file, FileAccess.WRITE)
	if file == null:
		printerr("bench_sim: cannot write %s" % out_file)
		return 1
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	return 0


# --- the cost of one JsMath call ---------------------------------------------------------------------------------------------------

func _args(low: float, high: float, seed_value: int) -> PackedFloat64Array:
	var out: PackedFloat64Array = PackedFloat64Array()
	var s: int = seed_value * 2862933555777941757 + 3037000493
	for i: int in range(1024):
		s = s * 6364136223846793005 + 1442695040888963407
		var u: float = float((s >> 11) & 0x1FFFFFFFFFFFFF) / 9007199254740992.0
		out.append(low + (high - low) * u)
	return out


func _time_loop(loop: Callable) -> float:
	var started: int = Time.get_ticks_usec()
	loop.call(MICRO_CALLS)
	return float(Time.get_ticks_usec() - started) * 1000.0 / float(MICRO_CALLS)


## Nanoseconds per call, the loop's own cost (baseline loop of the same arity) taken off; the median of MICRO_RUNS runs.
@warning_ignore("integer_division")
func _net_ns(loop: Callable, baseline: Callable) -> float:
	var net: PackedFloat64Array = PackedFloat64Array()
	for r: int in range(MICRO_RUNS):
		net.append(_time_loop(loop) - _time_loop(baseline))
	net.sort()
	return maxf(net[net.size() / 2], 0.0)


func _micro_bench() -> Dictionary:
	_xs = _args(-3.2, 3.2, 1)
	_ys = _args(-600.0, 600.0, 2)
	_zs = _args(-12.0, 0.0, 3)
	_ps = _args(0.001, 100.0, 4)
	_time_loop(_loop_base1)  # warm the code and the caches
	var table: Dictionary = {}
	table["sin"] = [_net_ns(_loop_js_sin, _loop_base1), _net_ns(_loop_b_sin, _loop_base1)]
	table["cos"] = [_net_ns(_loop_js_cos, _loop_base1), _net_ns(_loop_b_cos, _loop_base1)]
	table["atan"] = [_net_ns(_loop_js_atan, _loop_base1), _net_ns(_loop_b_atan, _loop_base1)]
	table["atan2"] = [_net_ns(_loop_js_atan2, _loop_base2), _net_ns(_loop_b_atan2, _loop_base2)]
	table["exp"] = [_net_ns(_loop_js_exp, _loop_base1), _net_ns(_loop_b_exp, _loop_base1)]
	table["log"] = [_net_ns(_loop_js_log, _loop_base1), _net_ns(_loop_b_log, _loop_base1)]
	table["hypot"] = [_net_ns(_loop_js_hypot, _loop_base2), _net_ns(_loop_b_hypot, _loop_base2)]
	table["pow"] = [_net_ns(_loop_js_pow, _loop_base1), _net_ns(_loop_b_pow, _loop_base1)]
	return table


func _print_micro(micro: Dictionary) -> void:
	print("cost of one call (typed GDScript, %d calls per run, median of %d runs, the loop's own cost subtracted):" % [MICRO_CALLS, MICRO_RUNS])
	print("  %-8s %12s %14s %8s   %s" % ["function", "JsMath ns", "builtin ns", "ratio", "the builtin compared"])
	var notes: Dictionary = {"hypot": "sqrt(a*a + b*b), NOT bit-exact (35% differ)", "pow": "pow(x, 1.7)"}
	for name: String in FUNCS:
		var cost: Array = micro[name]
		print("  %-8s %12.0f %14.0f %7.1fx   %s" % [name, cost[0], cost[1], cost[0] / maxf(cost[1], 1.0), notes.get(name, "engine " + name)])
	print("")


func _loop_base1(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += _xs[i & 1023]
	_sink += acc


func _loop_base2(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += _ys[i & 1023] + _ys[(i + 7) & 1023]
	_sink += acc


func _loop_js_sin(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += JsMath.sin(_xs[i & 1023])
	_sink += acc


func _loop_b_sin(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += sin(_xs[i & 1023])
	_sink += acc


func _loop_js_cos(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += JsMath.cos(_xs[i & 1023])
	_sink += acc


func _loop_b_cos(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += cos(_xs[i & 1023])
	_sink += acc


func _loop_js_atan(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += JsMath.atan(_xs[i & 1023])
	_sink += acc


func _loop_b_atan(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += atan(_xs[i & 1023])
	_sink += acc


func _loop_js_atan2(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += JsMath.atan2(_ys[i & 1023], _ys[(i + 7) & 1023])
	_sink += acc


func _loop_b_atan2(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += atan2(_ys[i & 1023], _ys[(i + 7) & 1023])
	_sink += acc


func _loop_js_exp(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += JsMath.exp(_zs[i & 1023])
	_sink += acc


func _loop_b_exp(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += exp(_zs[i & 1023])
	_sink += acc


func _loop_js_log(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += JsMath.log(_ps[i & 1023])
	_sink += acc


func _loop_b_log(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += log(_ps[i & 1023])
	_sink += acc


func _loop_js_hypot(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += JsMath.hypot(_ys[i & 1023], _ys[(i + 7) & 1023])
	_sink += acc


func _loop_b_hypot(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		var a: float = _ys[i & 1023]
		var b: float = _ys[(i + 7) & 1023]
		acc += sqrt(a * a + b * b)
	_sink += acc


func _loop_js_pow(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += JsMath.pow(_ps[i & 1023], 1.7)
	_sink += acc


func _loop_b_pow(n: int) -> void:
	var acc: float = 0.0
	for i: int in range(n):
		acc += pow(_ps[i & 1023], 1.7)
	_sink += acc
