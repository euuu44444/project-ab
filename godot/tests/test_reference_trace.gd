extends "res://tests/test_case.gd"
## The reference traces (tests/reference/*.jsonl.gz, recorded from the ORIGINAL game in Chromium 141 by tools/reference-trace/capture.mjs;
## format: tools/reference-trace/FORMAT.md) against the port: Sim is run on the very inputs of each trace (same seed, character,
## difficulty, mode and 390x844 view), and what the port has ported has to match the reference bit for bit.
##
## The replay follows the reference with the TEST-ONLY replay oracle (tests/trace/replay_oracle.gd, design section 11, step S5), because
## the port does not have weapons, projectiles, damage and experience pickup yet (step S6): the placeholder slot projectile/player draws what
## the reference's slot drew, the enemies the reference removed are killed in front of enemy/cleanup-2, the projectile list is the reference's
## (the assassin dodges it). What the oracle cannot supply is left out of the comparison, and each exclusion has a reason:
##   * enemy hp and flash (only damage changes them, step S6), the projectile group, counts.projectiles / counts.particles;
##   * the experience orbs after the first pickup, the player's experience and level, pendingLevelUps and levelUpChoiceReadyAt: compared
##     up to the first pickup (the "pickup" boundary, the first step in which player.xp changes);
##   * the animation fields attackAnim, attackAngle, lastFacing: weapons set them; teacher-forced tier (_compare_animation).
## Everything else is compared at every step from step 1 to the last: the draw counter and the draws of every slot (enemy/update's contact
## damage draws included: it is ported, so they are the port's own), the clock, the wave and the whole enemy director (budget, clocks, theme,
## ids, spawn order), the list of enemies with their ids in the original's order (spawns append, killEnemy swap-pops from the end) and EVERY
## field of every enemy except hp and flash (position, velocity, facing, AI state and timers, the values spawnEnemy draws), the kills, and the
## player's position, velocity, hp, lastHit, the camera and the damage flash (which contact hits push, hurt and flash).
##
## The boundaries printed for every trace (and stored in the header as `boundaries`, where the test checks that tools/lib/trace_io.mjs
## firstEffects and first_effects() below agree) are the first steps with an effect that belongs to step S6:
##   * weapon fire: the first step in which the player's attackAnim is not 0 (triggerPlayerAttackAnimation sets attackAnim,
##     attackAngle and lastFacing). Weapons are step S6.
##   * pickup: the first step in which the player's xp is not its first value (an orb was collected: pickup/xp, step S6).
## The contact hits on the player (the 22 px push, hp, the damage flash, the 3 draws) were a third boundary until enemy/update was ported (step
## S5); they are compared now, and _coverage_of counts them (and the assassin's dodges and states) from the reference rows.
##
## Traces of the non-standard "long_run" variant (header "variant"; player.xpNext, hp and maxHp set to 1e9 so that the run goes on
## through waves 3 and 4) are replayed with the same overrides (SimTrace.apply_overrides) and checked the same way.

const REFERENCE_DIR: String = "res://tests/reference"
const MANDATORY_TRACES: PackedStringArray = ["dirs8_424242.jsonl.gz", "dirs8_24681357.jsonl.gz"]
const ORIGINAL_RELATIVE: String = "../webview-fg4/tests/fixtures/original.html"
const ZERO_BITS: String = "0000000000000000"

## Fields of the player, the camera and the damage flash that movement, the camera and a contact hit write, compared at every step.
const MOVEMENT_FIELDS: Dictionary = {
	"player": ["x", "y", "vx", "vy", "ax", "ay", "prevX", "prevY", "walkPhase", "controlSlow", "hp", "maxHp", "koTimer", "lastHit"],
	"camera": ["x", "y", "prevX", "prevY"],
	"wave": ["damageFlash"],
}
## The clock, the day cycle, the wave and the whole enemy director: compared at EVERY step from step 1, whatever happens to the player
## (the director's draws do not depend on where the player was pushed; its spawn positions do, and are not in this list).
const DIRECTOR_FIELDS: Dictionary = {
	"wave": [
		"t", "wave", "waveClock", "directorClock", "spawnBudget", "dayPhase", "nextEnemyId", "screenFlash", "kills",
		"pendingDirectorEnemyKind", "waveFeaturedChangeChance", "enemyAiTier", "enemyAiSkill", "enemiesVersion",
		"themeWave", "themeBaseKind", "themeFeaturedKind", "themeChanged", "themeChangeChance", "themeTotalSpawned", "themeCounts",
		"themeRecentMixed", "featuredEnemyHistory",
	],
}
## Fields that the collection of experience orbs changes (pickup/xp, step S6), compared up to the step before the first pickup.
const PICKUP_FIELDS: Dictionary = {
	"player": ["xp", "level", "xpNext", "xpBaseNext"],
	"wave": ["pendingLevelUps", "levelUpChoiceReadyAt"],
}
## The fields of an enemy that the comparison covers, at every step for every enemy (the order of the list is compared with them): every field
## of the reference schema (SimTrace.REFERENCE_FIELDS["enemy"]) except hp and flash, which only damage changes (step S6). maxHp (poison only),
## r, speed, damage, spawnWave, shootCd, strafeDir, aiSeed and animPhase are fixed by spawnEnemy and nothing in M1 changes them; the rest is
## what enemy/update writes: the position and velocity, the facing, the AI state and its timers, the cooldowns that tick every step.
const ENEMY_COMPARED_FIELDS: PackedStringArray = [
	"id", "kind", "x", "y", "vx", "vy", "maxHp", "prevX", "prevY", "r", "speed", "facing", "aiState", "shootCd", "aiTimer", "abilityCd",
	"strafeDir", "aiSeed", "thinkCd", "animPhase", "tacticCd", "dotNumberTimer", "damage", "spawnWave", "telegraph", "attackAnim", "tacticPulse",
]
## The enemy fields that are NOT compared, each with its reason.
const ENEMY_EXCLUDED_FIELDS: PackedStringArray = ["hp", "flash"]
## At least this many steps must be compared per trace, or the test would prove nothing.
const MIN_COMPARED_STEPS: int = 100
## What the committed traces must hold, summed (the long run alone has 30 contact hits and 58 steps with a dodging assassin): contact hits
## (hurtPlayer, the push, the 3 draws), steps in which an assassin dodges a projectile (enemyProjectileAvoidance).
const MIN_CONTACT_HITS: int = 20
const MIN_DODGE_STEPS: int = 20
## Animation tier: at least this many steps in which attackAnim is counting down (so that the decrement is checked), and, in the
## traces whose player moves, this many steps in which lastFacing is set from the velocity (atan2) to a non-zero angle.
const MIN_DECREMENT_STEPS: int = 50
const MIN_FACING_STEPS: int = 100
## The long-run variant's overrides: every one is 1e9.
const LONG_RUN_KEYS: PackedStringArray = ["player.hp", "player.maxHp", "player.xpNext"]

var _cache: Dictionary = {}
## What the committed traces exercise of the enemy code, summed over the traces of one run of the comparison (see _coverage_of).
var _coverage_total: Dictionary = {}


func _trace_files() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(REFERENCE_DIR)
	if dir == null:
		return out
	for file_name: String in dir.get_files():
		if file_name.ends_with(".jsonl.gz") or file_name.ends_with(".jsonl"):
			out.append(file_name)
	out.sort()
	return out


func _load(file_name: String) -> TraceReader:
	if _cache.has(file_name):
		return _cache[file_name]
	var reader: TraceReader = TraceReader.load_file("%s/%s" % [REFERENCE_DIR, file_name])
	_cache[file_name] = reader
	return reader


func _original_sha256() -> String:
	var path: String = ProjectSettings.globalize_path("res://").path_join(ORIGINAL_RELATIVE).simplify_path()
	if not FileAccess.file_exists(path):
		return ""
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode()


# --- the committed traces ---------------------------------------------------------------------------------------------

func test_the_committed_reference_traces_are_complete_and_consistent() -> void:
	var files: PackedStringArray = _trace_files()
	for name: String in MANDATORY_TRACES:
		assert_true(files.has(name), "%s is committed in tests/reference" % name)
	var original_hash: String = _original_sha256()
	var long_runs: int = 0
	for file_name: String in files:
		var ref: TraceReader = _load(file_name)
		assert_true(ref != null, "%s loads" % file_name)
		if ref == null:
			continue
		_check_trace(file_name, ref, original_hash)
		if String(ref.header.get("variant", "")) == "long_run":
			long_runs += 1
	assert_true(long_runs >= 1, "a long-run trace (waves 3 and later) is committed")


func _check_trace(file_name: String, ref: TraceReader, original_hash: String) -> void:
	var h: Dictionary = ref.header
	assert_eq(String(h.get("producer", "")), "original-chromium", "%s: recorded from the original" % file_name)
	assert_true(String(h.get("chromium_version", "")).begins_with("141."), "%s: recorded with Chromium 141 (got %s)" % [file_name, h.get("chromium_version", "")])
	assert_eq(h["coarse"], true, "%s: IS_COARSE_POINTER was true" % file_name)
	assert_eq((h["view"] as Array).size(), 2, "%s: view has two entries" % file_name)
	assert_eq(int((h["view"] as Array)[0]), 390, "%s: viewW" % file_name)
	assert_eq(int((h["view"] as Array)[1]), 844, "%s: viewH" % file_name)
	assert_eq(String(h["character"]), "catalyst", "%s: character" % file_name)
	assert_eq(String(h["difficulty"]), "normal", "%s: difficulty" % file_name)
	assert_eq(String(h["mode"]), "normal", "%s: standard mode" % file_name)
	if original_hash != "":
		assert_eq(String((h["source"] as Dictionary)["sha256"]), original_hash, "%s: recorded from the current original.html (re-record with tools/reference-trace/capture.mjs --all)" % file_name)
	var variant: String = String(h.get("variant", "standard"))
	var is_long_run: bool = variant == "long_run"
	assert_true(variant == "standard" or is_long_run, "%s: variant is standard or long_run (got %s)" % [file_name, variant])
	if is_long_run:
		var overrides: Dictionary = h.get("overrides", {})
		assert_eq(overrides.size(), LONG_RUN_KEYS.size(), "%s: the long run overrides exactly %s" % [file_name, ", ".join(LONG_RUN_KEYS)])
		for key: String in LONG_RUN_KEYS:
			assert_eq(String(overrides.get(key, "")), SimTrace.hex_of(1.0e9), "%s: %s is 1e9" % [file_name, key])
	else:
		assert_false(h.has("overrides"), "%s: a standard trace has no overrides" % file_name)
	# the Node implementation of the boundaries (capture.mjs, trace_io.mjs firstEffects) and this file's agree
	var declared: Dictionary = h.get("boundaries", {})
	var computed: Dictionary = first_effects(ref)
	var declared_keys: Array = declared.keys()
	declared_keys.sort()
	assert_eq(declared_keys, ["fire", "pickup", "steps"], "%s: the header has exactly the boundaries fire, pickup and steps (contact is no boundary since step S5)" % file_name)
	assert_eq(int(declared.get("fire", -1)), int(computed["fire"]), "%s: header boundaries.fire equals first_effects()" % file_name)
	assert_eq(int(declared.get("pickup", -1)), int(computed["pickup"]), "%s: header boundaries.pickup equals first_effects()" % file_name)
	assert_eq(int(declared.get("steps", -1)), ref.steps.size(), "%s: header boundaries.steps" % file_name)
	# a field that the game never defined would have been recorded as zeros
	assert_eq((h["stats"] as Dictionary).get("never_defined", ["missing"]), [], "%s: every recorded field was defined by the game at least once" % file_name)
	var slots: Dictionary = h["slots"]
	assert_eq((slots["intro"] as Array).size(), 5, "%s: intro slots" % file_name)
	assert_eq((slots["main"] as Array).size(), 43, "%s: main slots" % file_name)
	assert_eq((slots["ko"] as Array).size(), 5, "%s: ko slots" % file_name)
	# the schema of the file is the schema this reader and SimTrace know (a drift would silently drop fields from the comparison)
	for group: String in SimTrace.GROUPS:
		assert_eq((h["fields"] as Dictionary).get(group, []), SimTrace.REFERENCE_FIELDS[group], "%s: fields of %s" % [file_name, group])

	var steps: Array[Dictionary] = ref.steps
	var stop: Dictionary = h["stop"]
	assert_eq(steps.size(), int(stop["step"]), "%s: the last step is the stop step" % file_name)
	assert_eq(ref.slot_key("main", "wave/progress"), "main:5", "%s: slot key lookup" % file_name)
	assert_eq(ref.slot_key("main", "no/such-slot"), "", "%s: unknown slot id" % file_name)
	# step 1 of the original: the director's first tick draws 28 values, 27 when the player moves (the movement angle is not drawn)
	var first_tick: int = 28 if String((h["input_script"] as Dictionary)["name"]) == "idle" else 27
	assert_eq(ref.slot_draws(0, "main:5"), first_tick, "%s: wave/progress draws %d values at step 1" % [file_name, first_tick])
	if is_long_run:
		var reason: String = String(stop["reason"])
		assert_true(reason == "max_steps" or reason.begins_with("wave:") or reason.begins_with("state:"), "%s: a long run stops at a step cap, a wave or the end of the run (got %s)" % [file_name, reason])
	else:
		assert_eq(String(stop["reason"]), "level_up", "%s: stops at the first level-up" % file_name)
	var pending_i: int = ref.field_index("wave", "pendingLevelUps")
	var previous_draws: int = int(h["new_game_draws"])
	var bad_order: int = 0
	var bad_draws: int = 0
	var bad_outside: int = 0
	var early_pending: int = 0
	var max_particles: int = 0
	for i: int in range(steps.size()):
		var s: Dictionary = steps[i]
		if int(s["n"]) != i + 1:
			bad_order += 1
		var in_slots: int = 0
		for key: Variant in (s["slot_draws"] as Dictionary).keys():
			in_slots += int((s["slot_draws"] as Dictionary)[key])
		if int(s["draws"]) != previous_draws + in_slots + int(s["outside_draws"]):
			bad_draws += 1
		if int(s["outside_draws"]) != 0:
			bad_outside += 1
		previous_draws = int(s["draws"])
		var pending: int = int((s["wave"] as Array)[pending_i])
		if (pending > 0) != (i == steps.size() - 1 and not is_long_run):
			early_pending += 1
		max_particles = maxi(max_particles, int((s["counts"] as Dictionary)["particles"]))
	assert_eq(bad_order, 0, "%s: step numbers run 1..n" % file_name)
	assert_eq(bad_draws, 0, "%s: draws = previous draws + slot draws + outside draws at every step" % file_name)
	assert_eq(bad_outside, 0, "%s: no gameRandom draw outside the update slots" % file_name)
	assert_eq(early_pending, 0, "%s: pendingLevelUps is above 0 at the last step only (never, in a long run)" % file_name)
	assert_true(max_particles < 560, "%s: particles stay below the damage-number gate (max %d)" % [file_name, max_particles])


# --- the port against the reference -----------------------------------------------------------------------------------

func test_the_sim_matches_each_reference_trace_with_the_replay_oracle() -> void:
	var files: PackedStringArray = _trace_files()
	assert_true(files.size() >= MANDATORY_TRACES.size(), "reference traces are present")
	_coverage_total = {"hits": 0, "dodge_steps": 0, "states": {}}
	for file_name: String in files:
		var ref: TraceReader = _load(file_name)
		if ref == null:
			fail("%s did not load" % file_name)
			continue
		_compare_with_the_port(file_name, ref)
	# the comparison only proves something about the enemy code that the traces exercise (worked out from the reference rows, see _coverage_of)
	var states: Dictionary = _coverage_total["states"]
	print("      all traces: %d contact hits, %d steps with a dodging assassin, assassin states %s" % [int(_coverage_total["hits"]), int(_coverage_total["dodge_steps"]), str(states.keys())])
	assert_true(int(_coverage_total["hits"]) >= MIN_CONTACT_HITS, "the traces hold at least %d contact hits (got %d)" % [MIN_CONTACT_HITS, int(_coverage_total["hits"])])
	assert_true(int(_coverage_total["dodge_steps"]) >= MIN_DODGE_STEPS, "the traces hold at least %d steps in which an assassin dodges a projectile (got %d)" % [MIN_DODGE_STEPS, int(_coverage_total["dodge_steps"])])
	for state: String in ["idle", "windup", "dash", "recover"]:
		assert_true(states.has(state), "an assassin is seen in the state '%s' (got %s)" % [state, str(states.keys())])


func test_the_enemy_comparison_covers_every_reference_field_except_the_excluded_ones() -> void:
	var covered: Dictionary = {}
	for field_name: String in ENEMY_COMPARED_FIELDS:
		covered[field_name] = true
	for field_name: String in ENEMY_EXCLUDED_FIELDS:
		assert_false(covered.has(field_name), "%s is excluded and not compared" % field_name)
		covered[field_name] = true
	var schema: Array = SimTrace.REFERENCE_FIELDS["enemy"]
	assert_eq(covered.size(), schema.size(), "compared + excluded = the reference's enemy fields")
	for spec: Variant in schema:
		assert_true(covered.has(TraceReader.split_spec(String(spec))[0]), "%s is compared or excluded" % spec)


func _compare_with_the_port(file_name: String, ref: TraceReader) -> void:
	var boundary: Dictionary = first_effects(ref)
	var fire: int = boundary["fire"]
	var pickup: int = boundary["pickup"]
	var last: int = ref.steps.size()
	var pickup_steps: int = mini(pickup - 1, last)
	var coverage: Dictionary = _coverage_of(ref)
	_coverage_total["hits"] = int(_coverage_total.get("hits", 0)) + int(coverage["hits"])
	_coverage_total["dodge_steps"] = int(_coverage_total.get("dodge_steps", 0)) + int(coverage["dodge_steps"])
	for state: Variant in (coverage["states"] as Dictionary).keys():
		(_coverage_total["states"] as Dictionary)[state] = true
	print("      %s%s: first weapon shot at step %s, first pickup at step %s, %d steps; everything but enemy hp and flash compared for steps 1..%d (%d contact hits from step %s, %d steps with a dodging assassin, assassin states %s), experience fields for 1..%d" % [
		file_name, " (long run)" if String(ref.header.get("variant", "")) == "long_run" else "",
		str(fire) if fire <= last else "none", str(pickup) if pickup <= last else "none",
		last, last, int(coverage["hits"]), str(coverage["first_hit"]) if int(coverage["hits"]) > 0 else "-", int(coverage["dodge_steps"]),
		str((coverage["states"] as Dictionary).keys()), pickup_steps,
	])
	assert_true(last >= MIN_COMPARED_STEPS, "%s: at least %d steps are compared (got %d)" % [file_name, MIN_COMPARED_STEPS, last])
	var replay: Dictionary = SimTrace.replay(ref, 0, true)
	assert_false(replay.is_empty(), "%s: the sim starts the run" % file_name)
	if replay.is_empty():
		return
	var port_header: Dictionary = replay["header"]
	var rows: Array = replay["rows"]
	var oracle: ReplayOracle = replay["oracle"]
	assert_eq(rows.size(), last, "%s: replayed steps" % file_name)
	assert_eq(oracle.problems, PackedStringArray(), "%s: the replay oracle found nothing wrong (%s)" % [file_name, "; ".join(oracle.problems)])
	_check_oracle_debt(file_name, ref, oracle)

	_compare_draws(file_name, ref, rows)
	assert_eq(_compare_fields(file_name, ref, port_header, rows, DIRECTOR_FIELDS, last), 0, "%s: the clock, the wave and the enemy director equal the reference at every step" % file_name)
	assert_eq(_compare_fields(file_name, ref, port_header, rows, MOVEMENT_FIELDS, last), 0, "%s: the player, camera and damage flash (movement and contact hits) equal the reference at every step" % file_name)
	assert_eq(_compare_fields(file_name, ref, port_header, rows, PICKUP_FIELDS, pickup_steps), 0, "%s: the experience fields equal the reference up to the first pickup" % file_name)
	_compare_enemy_lists(file_name, ref, port_header, rows, last)
	_compare_animation(file_name, ref, last)


## What a reference trace exercises of the enemy code, worked out from the reference rows alone (not from the port), so that the comparison above
## cannot pass by comparing nothing: `hits` the contact hits (steps in which enemy/update drew), `states` the AI states of assassins, and
## `dodge_steps` the steps in which an assassin had a player projectile of the step before within 120 px that was flying toward it (the
## condition of enemyProjectileAvoidance with the radius not yet widened by the skill, so a lower bound).
func _coverage_of(ref: TraceReader) -> Dictionary:
	var update_key: String = ref.slot_key("main", "enemy/update")
	var kind_i: int = ref.field_index("enemy", "kind")
	var state_i: int = ref.field_index("enemy", "aiState")
	var x_i: int = ref.field_index("enemy", "x")
	var y_i: int = ref.field_index("enemy", "y")
	var px_i: int = ref.field_index("projectile", "x")
	var py_i: int = ref.field_index("projectile", "y")
	var pvx_i: int = ref.field_index("projectile", "vx")
	var pvy_i: int = ref.field_index("projectile", "vy")
	var hits: int = 0
	var first_hit: int = 0
	var dodge_steps: int = 0
	var states: Dictionary = {}
	for n: int in range(ref.steps.size()):
		if ref.slot_draws(n, update_key) > 0:
			hits += 1
			if first_hit == 0:
				first_hit = n + 1
		var step: Dictionary = ref.steps[n]
		var assassins: Array = []
		for row: Variant in (step["enemies"] as Array):
			if String((row as Array)[kind_i]) == "assassin":
				states[String((row as Array)[state_i])] = true
				assassins.append(row)
		if n == 0 or assassins.is_empty():
			continue
		var before: Dictionary = ref.steps[n - 1]
		var dodging: bool = false
		for row: Variant in (before["enemies"] as Array):
			if String((row as Array)[kind_i]) != "assassin" or dodging:
				continue
			var ex: float = SimTrace.from_hex(String((row as Array)[x_i]))
			var ey: float = SimTrace.from_hex(String((row as Array)[y_i]))
			for projectile: Variant in (before["projectiles"] as Array):
				var pr: Array = projectile
				var dx: float = ex - SimTrace.from_hex(String(pr[px_i]))
				var dy: float = ey - SimTrace.from_hex(String(pr[py_i]))
				var d2: float = dx * dx + dy * dy
				if d2 > 1.0 and d2 <= 14400.0 and SimTrace.from_hex(String(pr[pvx_i])) * dx + SimTrace.from_hex(String(pr[pvy_i])) * dy > 0.0:
					dodging = true
					break
		if dodging:
			dodge_steps += 1
	return {"hits": hits, "first_hit": first_hit, "states": states, "dodge_steps": dodge_steps}


## The oracle's debt is what step S6 still owes: the draws it injected are exactly the reference's draws of the slots that are still placeholders in a
## production Sim (projectile/player), and it killed exactly the enemies the reference removed. Every other slot that draws (wave/progress,
## enemy/update, enemy/cleanup-2) has to be a real system: its draws are the port's own and compared with the reference in _compare_draws.
func _check_oracle_debt(file_name: String, ref: TraceReader, oracle: ReplayOracle) -> void:
	var config: SimConfig = SimTrace.config_from_header(ref.header)
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "%s: a production sim for the list of placeholders" % file_name)
	var placeholders: Array[String] = []
	var lists: Array = [sim.runner.intro, sim.runner.main, sim.runner.ko]
	for l: int in range(lists.size()):
		var list: Array = lists[l]
		for i: int in range(list.size()):
			if not (list[i] as SystemSlot).system.is_implemented():
				placeholders.append("%s:%d" % [SimTrace.LIST_NAMES[l], i])
	for id: String in ["wave/progress", "enemy/update", "enemy/cleanup-2"]:
		assert_false(placeholders.has(ref.slot_key("main", id)), "%s: %s is a real system, not a placeholder" % [file_name, id])
	var expected: Dictionary = {}
	for key: String in placeholders:
		var total: int = 0
		for i: int in range(ref.steps.size()):
			total += ref.slot_draws(i, key)
		if total > 0:
			expected[key] = total
	assert_eq(oracle.injected, expected, "%s: the oracle drew only for the placeholders (%s) and drew what the reference's slots drew" % [file_name, ", ".join(placeholders)])
	var kills_i: int = ref.field_index("wave", "kills")
	var final_kills: int = int((ref.steps[ref.steps.size() - 1]["wave"] as Array)[kills_i])
	assert_eq(oracle.forced_kills, final_kills, "%s: the oracle killed exactly the enemies the reference removed (wave.kills at the end)" % file_name)
	print("      %s: replay oracle injected %s dry draws (the debt of step S6), forced %d kills" % [file_name, str(oracle.injected_total()), oracle.forced_kills])


## `draws` (cumulative), the draws of every slot and the draws outside any slot, step by step. Placeholders are filled by the oracle, so a
## difference here is a difference of an implemented slot: the director, the kills, ... (the first one is reported).
func _compare_draws(file_name: String, ref: TraceReader, rows: Array) -> void:
	for i: int in range(ref.steps.size()):
		var ref_step: Dictionary = ref.steps[i]
		var port_step: Dictionary = rows[i]
		if int(ref_step["draws"]) != int(port_step["draws"]):
			fail("%s step %d: gameRandomDraws reference %d, port %d" % [file_name, i + 1, int(ref_step["draws"]), int(port_step["draws"])])
			return
		var ref_slots: Dictionary = ref_step["slot_draws"]
		var port_slots: Dictionary = port_step["slot_draws"]
		var keys: Dictionary = {}
		for key: Variant in ref_slots.keys():
			keys[key] = true
		for key: Variant in port_slots.keys():
			keys[key] = true
		for key: Variant in keys.keys():
			if int(ref_slots.get(key, 0)) != int(port_slots.get(key, 0)):
				fail("%s step %d: slot %s draws: reference %d, port %d" % [file_name, i + 1, key, int(ref_slots.get(key, 0)), int(port_slots.get(key, 0))])
				return
		if int(port_step["outside_draws"]) != 0:
			fail("%s step %d: the port drew %d values outside its slots" % [file_name, i + 1, int(port_step["outside_draws"])])
			return
		if String(ref_step["state"]) != String(port_step["state"]):
			fail("%s step %d: state reference %s, port %s" % [file_name, i + 1, ref_step["state"], port_step["state"]])
			return
	assert_true(true, "%s: draws, slot draws and state equal at all %d steps" % [file_name, ref.steps.size()])


## The enemy list at every step: the same ids in the same order (spawns append, kills swap-pop from the end) and ENEMY_COMPARED_FIELDS of each
## enemy: everything but hp and flash, which only damage changes (step S6).
func _compare_enemy_lists(file_name: String, ref: TraceReader, port_header: Dictionary, rows: Array, up_to: int) -> void:
	var names: PackedStringArray = ENEMY_COMPARED_FIELDS.duplicate()
	var ref_index: Array[int] = []
	var port_index: Array[int] = []
	var types: Array[String] = []
	var port_specs: Array = (port_header["fields"] as Dictionary)["enemy"]
	for field_name: String in names:
		var r: int = ref.field_index("enemy", field_name)
		var p: int = _spec_index(port_specs, field_name)
		if r < 0 or p < 0:
			fail("%s: enemy.%s is missing (reference index %d, port index %d)" % [file_name, field_name, r, p])
			return
		ref_index.append(r)
		port_index.append(p)
		types.append(TraceReader.split_spec(String((ref.header["fields"] as Dictionary)["enemy"][r]))[1])
	var compared_rows: int = 0
	for n: int in range(1, up_to + 1):
		var ref_rows: Array = ref.steps[n - 1]["enemies"]
		var port_rows: Array = (rows[n - 1] as Dictionary)["enemies"]
		if ref_rows.size() != port_rows.size():
			fail("%s step %d: the enemy list has %d enemies in the reference, %d in the port" % [file_name, n, ref_rows.size(), port_rows.size()])
			return
		for j: int in range(ref_rows.size()):
			var ref_row: Array = ref_rows[j]
			var port_row: Array = port_rows[j]
			for k: int in range(names.size()):
				if not SimTrace.same_value(types[k], ref_row[ref_index[k]], port_row[port_index[k]]):
					fail("%s step %d enemies[%d] (id %s).%s: reference %s, port %s" % [
						file_name, n, j, str(ref_row[ref_index[0]]), names[k], _describe(types[k], ref_row[ref_index[k]]), _describe(types[k], port_row[port_index[k]]),
					])
					return
			compared_rows += 1
	assert_true(compared_rows > 0, "%s: enemy rows were compared (%d)" % [file_name, compared_rows])


## Compares the named fields of the replayed rows with the reference for steps 1..up_to; reports the first difference of the trace.
## Returns the number of differing steps (it stops at the first).
func _compare_fields(file_name: String, ref: TraceReader, port_header: Dictionary, rows: Array, fields: Dictionary, up_to: int) -> int:
	for group: String in fields.keys():
		var port_specs: Array = (port_header["fields"] as Dictionary)[group]
		for field_name: String in (fields[group] as Array):
			var ref_i: int = ref.field_index(group, field_name)
			var port_i: int = _spec_index(port_specs, field_name)
			if ref_i < 0 or port_i < 0:
				fail("%s: %s.%s is missing (reference index %d, port index %d)" % [file_name, group, field_name, ref_i, port_i])
				return 1
			var type: String = TraceReader.split_spec(String((ref.header["fields"] as Dictionary)[group][ref_i]))[1]
			for n: int in range(1, up_to + 1):
				var expected: Variant = (ref.steps[n - 1][group] as Array)[ref_i]
				var actual: Variant = ((rows[n - 1] as Dictionary)[group] as Array)[port_i]
				if not SimTrace.same_value(type, expected, actual):
					fail("%s step %d %s.%s: reference %s, port %s" % [file_name, n, group, field_name, _describe(type, expected), _describe(type, actual)])
					return 1
	return 0


## The animation fields attackAnim, attackAngle and lastFacing, step by step up to `up_to`.
##
## The port has no weapons, so after the reference's first shot (which sets all three: triggerPlayerAttackAnimation) the two runs
## differ in these fields by construction. The comparison is therefore teacher-forced: before every step n > 1 the port's three
## values are set to the reference's values at the end of step n - 1, and after the step the port's values are compared with the
## reference's, on the steps in which the reference shows no shot: attackAnim equals max(0, attackAnim before - FIXED_DT) and
## attackAngle is unchanged. What is checked there is exactly the part of updatePlayerMovement that the sim has: the countdown of
## attackAnim, and `if (speed > 8) lastFacing = atan2(vy, vx)` (otherwise lastFacing stays), against hundreds of reference values.
## A shot that leaves attackAnim at its countdown value and attackAngle at its old bits would be taken for no shot; it would show up
## as a lastFacing mismatch, never as a silent pass. Steps with a shot are not compared (the port cannot shoot before step S6).
func _compare_animation(file_name: String, ref: TraceReader, up_to: int) -> void:
	var sim: Sim = Sim.new()
	var config: SimConfig = SimTrace.config_from_header(ref.header)
	if not sim.new_game(config) or not SimTrace.apply_overrides(sim.game, ref.header.get("overrides", {}) as Dictionary):
		fail("%s: the sim does not start the run for the animation tier" % file_name)
		return
	var oracle: ReplayOracle = ReplayOracle.install(sim, ref)  # the run stays in step with the reference, whatever else the port has ported
	var anim_i: int = ref.field_index("player", "attackAnim")
	var angle_i: int = ref.field_index("player", "attackAngle")
	var facing_i: int = ref.field_index("player", "lastFacing")
	var vx_i: int = ref.field_index("player", "vx")
	var vy_i: int = ref.field_index("player", "vy")
	var player: PlayerState = sim.game.player
	var compared: int = 0
	var decrementing: int = 0
	var facing_set: int = 0
	var shots: int = 0
	var before_anim: String = SimTrace.hex_of(player.attack_anim)
	var before_angle: String = SimTrace.hex_of(player.attack_angle)
	for n: int in range(1, up_to + 1):
		var step: Dictionary = ref.steps[n - 1]
		var row: Array = step["player"] as Array
		if n > 1:
			player.attack_anim = SimTrace.from_hex(before_anim)
			player.attack_angle = SimTrace.from_hex(before_angle)
			player.last_facing = SimTrace.from_hex(String((ref.steps[n - 2]["player"] as Array)[facing_i]))
		var countdown: String = SimTrace.hex_of(maxf(0.0, SimTrace.from_hex(before_anim) - Sim.FIXED_DT))
		var shot: bool = String(row[anim_i]) != countdown or String(row[angle_i]) != before_angle
		SimTrace.apply_input(sim.game, step["input"] as Dictionary)
		oracle.begin_step(n - 1)
		sim.step(Sim.FIXED_DT)
		if shot:
			shots += 1
		else:
			compared += 1
			if SimTrace.from_hex(before_anim) > 0.0:
				decrementing += 1
			var speed: float = sqrt(SimTrace.from_hex(String(row[vx_i])) * SimTrace.from_hex(String(row[vx_i])) + SimTrace.from_hex(String(row[vy_i])) * SimTrace.from_hex(String(row[vy_i])))
			if speed > 8.0 and SimTrace.from_hex(String(row[facing_i])) != 0.0:
				facing_set += 1
			var ported: Array = [SimTrace.hex_of(player.attack_anim), SimTrace.hex_of(player.attack_angle), SimTrace.hex_of(player.last_facing)]
			var expected: Array = [String(row[anim_i]), String(row[angle_i]), String(row[facing_i])]
			var names: Array = ["attackAnim", "attackAngle", "lastFacing"]
			for k: int in range(3):
				if ported[k] != expected[k]:
					fail("%s step %d player.%s: reference %s, port %s (%s)" % [
						file_name, n, names[k], _describe("f", expected[k]), _describe("f", ported[k]),
						"teacher-forced from step %d" % (n - 1) if n > 1 else "from newGame, nothing forced",
					])
					return
		before_anim = String(row[anim_i])
		before_angle = String(row[angle_i])
	print("      %s: animation fields compared on %d steps (%d with a shot skipped; attackAnim counting down on %d, lastFacing set from the velocity to a non-zero angle on %d)" % [
		file_name, compared, shots, decrementing, facing_set,
	])
	assert_true(decrementing >= MIN_DECREMENT_STEPS, "%s: at least %d steps with attackAnim counting down (got %d)" % [file_name, MIN_DECREMENT_STEPS, decrementing])
	var script_name: String = String((ref.header["input_script"] as Dictionary)["name"])
	if script_name != "idle":
		assert_true(facing_set >= MIN_FACING_STEPS, "%s: at least %d steps with lastFacing set by atan2 (got %d)" % [file_name, MIN_FACING_STEPS, facing_set])


func _spec_index(specs: Array, field_name: String) -> int:
	for i: int in range(specs.size()):
		if TraceReader.split_spec(String(specs[i]))[0] == field_name:
			return i
	return -1


func _describe(type: String, value: Variant) -> String:
	if type == "f":
		return "%s (%s)" % [str(SimTrace.from_hex(String(value))), String(value)]
	return str(value)


## The first step (1-based; steps + 1 when it never happens) at which the reference shows
##   "fire":    the player's attackAnim is not 0 (a weapon shot);
##   "pickup":  the player's xp differs from its first value (an experience orb was collected).
## The same definition as tools/lib/trace_io.mjs firstEffects. (There used to be a third boundary, "contact", the first contact hit on the
## player; enemy/update is ported since step S5, so the port reproduces the hits and nothing is bounded by them. _coverage_of counts them.)
func first_effects(ref: TraceReader) -> Dictionary:
	var steps: Array[Dictionary] = ref.steps
	var none: int = steps.size() + 1
	var fire: int = none
	var pickup: int = none
	var attack_i: int = ref.field_index("player", "attackAnim")
	var xp_i: int = ref.field_index("player", "xp")
	var xp_start: String = String((steps[0]["player"] as Array)[xp_i])
	for i: int in range(steps.size()):
		var s: Dictionary = steps[i]
		var n: int = i + 1
		if fire == none and String((s["player"] as Array)[attack_i]) != ZERO_BITS:
			fire = n
		if pickup == none and String((s["player"] as Array)[xp_i]) != xp_start:
			pickup = n
		if fire != none and pickup != none:
			break
	return {"fire": fire, "pickup": pickup}


# --- the tracing code itself -------------------------------------------------------------------------------------------

func _new_sim(rng_seed: int = 424242) -> Sim:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = rng_seed
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game")
	return sim


func _input_row(move_x: float, move_y: float, keys: Array) -> Dictionary:
	return {"moveX": SimTrace.hex_of(move_x), "moveY": SimTrace.hex_of(move_y), "keys": keys}


func test_the_port_schema_is_a_partition_of_the_reference_schema() -> void:
	var sim: Sim = _new_sim()
	var trace: SimTrace = SimTrace.new(sim)
	for group: String in SimTrace.GROUPS:
		var reference: Array = SimTrace.REFERENCE_FIELDS[group]
		var ported: PackedStringArray = trace.ported_specs(group)
		var unported: PackedStringArray = trace.unported_specs(group)
		assert_eq(ported.size() + unported.size(), reference.size(), "%s: every reference field is either ported or listed as unported" % group)
		for spec: Variant in reference:
			assert_true(ported.has(String(spec)) != unported.has(String(spec)), "%s: %s is in exactly one of the two lists" % [group, spec])
	# the fields of step S3 are all ported
	for group: String in ["player", "camera", "wave"]:
		assert_eq(trace.unported_specs(group).size(), 0, "%s: the port has every field of the group" % group)
	assert_true(trace.ported_specs("enemy").has("x:f"), "enemy.x is ported (EnemyState)")
	# step S5: EnemyState has every field of the enemy group, XpOrbState every field of the xp_orb group; the projectile group waits for S6
	assert_eq(trace.unported_specs("enemy").size(), 0, "enemy: the port has every field of the group (step S5)")
	assert_eq(trace.unported_specs("xp_orb").size(), 0, "xp_orb: the port has every field of the group (step S5)")
	assert_eq(trace.unported_specs("projectile").size(), 9, "projectile: nothing yet (step S6)")
	assert_eq(SimTrace.snake_case("prevX"), "prev_x", "prevX -> prev_x")
	assert_eq(SimTrace.snake_case("xpBaseNext"), "xp_base_next", "xpBaseNext -> xp_base_next")
	assert_eq(SimTrace.snake_case("levelUpChoiceReadyAt"), "level_up_choice_ready_at", "levelUpChoiceReadyAt")


func test_the_slot_wrappers_credit_the_draws_to_the_slot_that_makes_them() -> void:
	var sim: Sim = _new_sim()
	# a slot that draws three values, as wave/progress does in the original; the wrapper is installed over it
	var drawing: DrawingSystem = DrawingSystem.new(sim.game, 3)
	sim.runner.main[5].system = drawing
	var trace: SimTrace = SimTrace.new(sim)
	var before: int = sim.game.rng.draws
	var row: Dictionary = trace.step_and_record(1, _input_row(0.0, 0.0, []))
	assert_eq(row["slot_draws"], {"main:5": 3}, "the draws are credited to main:5")
	assert_eq(row["outside_draws"], 0, "nothing was drawn outside a slot")
	assert_eq(row["draws"], before + 3, "draws is the cumulative count")
	assert_eq(row["n"], 1, "step number")
	assert_eq(row["state"], "playing", "state")
	# a draw that happens outside every slot is counted as such
	trace.begin_step()
	sim.game.rng.random()
	var outside_row: Dictionary = trace.record(2, _input_row(0.0, 0.0, []))
	assert_eq(outside_row["outside_draws"], 1, "a draw outside the slots is reported")
	assert_eq(outside_row["slot_draws"], {}, "and credited to no slot")
	# the wrappers are transparent: the placeholders still say they are placeholders
	assert_true(sim.runner.main[3].system.is_implemented(), "player/movement is reported as implemented through the wrapper")
	assert_true(sim.runner.stub_slots().size() > 0, "the placeholders are still reported through the wrapper")


## A system that draws a fixed number of values from gameRandom.
class DrawingSystem extends SimSystem:
	var count: int = 0

	func _init(p_game: GameState, p_count: int) -> void:
		super(p_game, "test")
		count = p_count

	func run(_dt: float) -> void:
		for i: int in range(count):
			game.rng.random()


func test_the_input_of_a_reference_step_reaches_the_sim() -> void:
	var sim: Sim = _new_sim()
	var row: Dictionary = {"moveX": SimTrace.hex_of(0.5), "moveY": SimTrace.hex_of(-0.25), "keys": ["KeyA", "ArrowDown"]}
	SimTrace.apply_input(sim.game, row)
	var inp: SimInput = sim.game.input
	assert_eq(inp.move_x, 0.5, "moveX")
	assert_eq(inp.move_y, -0.25, "moveY")
	assert_true(inp.key_left and inp.key_down, "KeyA and ArrowDown")
	assert_false(inp.key_right or inp.key_up, "no other key")
	SimTrace.apply_input(sim.game, _input_row(0.0, 0.0, ["ArrowLeft", "KeyD", "KeyW"]))
	assert_true(inp.key_left and inp.key_right and inp.key_up, "ArrowLeft, KeyD, KeyW")
	assert_false(inp.key_down, "the previous step's keys are released")
	assert_eq(SimTrace.hex_of(0.0), ZERO_BITS, "hex of zero")
	var minus_one: float = -1.0
	var negative_zero: float = 0.0 * minus_one  # computed at run time: a literal -0.0 may be folded to +0.0
	assert_eq(SimTrace.hex_of(negative_zero), "8000000000000000", "hex of negative zero")
	assert_eq(SimTrace.hex_of(NAN), "7ff8000000000000", "any NaN is canonical")
	assert_eq(SimTrace.hex_of(1.0 / 60.0), "3f91111111111111", "hex of FIXED_DT")
	assert_eq(SimTrace.from_hex("3f91111111111111"), 1.0 / 60.0, "FIXED_DT round trip")


func test_a_written_trace_is_standard_gzip_and_reads_back() -> void:
	# Replay the first steps of the first committed trace, write them as .gz, read them back and compare line by line.
	var files: PackedStringArray = _trace_files()
	if files.is_empty():
		fail("no committed trace")
		return
	var ref: TraceReader = _load(files[0])
	var replay: Dictionary = SimTrace.replay(ref, 40)
	var header: Dictionary = replay["header"]
	var rows: Array = replay["rows"]
	var path: String = "user://test_reference_trace_roundtrip.jsonl.gz"
	assert_true(SimTrace.write_file(path, header, rows), "the trace is written")
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	assert_true(bytes.size() > 2 and bytes[0] == 0x1f and bytes[1] == 0x8b, "the file starts with the gzip magic bytes")
	var back: TraceReader = TraceReader.load_file(path)
	assert_true(back != null, "the file reads back")
	if back != null:
		assert_eq(back.steps.size(), rows.size(), "all steps are there")
		assert_eq(String(back.header["format"]), SimTrace.FORMAT, "format")
		assert_eq(String(back.header["producer"]), "godot-port", "producer")
		assert_eq(int(back.header["seed"]), int(ref.header["seed"]), "seed")
		var mismatches: int = 0
		for i: int in range(rows.size()):
			var wrote: Dictionary = rows[i]
			var read: Dictionary = back.steps[i]
			if int(read["n"]) != int(wrote["n"]) or int(read["draws"]) != int(wrote["draws"]) or read["state"] != wrote["state"]:
				mismatches += 1
			if not _same_row(read["player"], wrote["player"], back, "player"):
				mismatches += 1
		assert_eq(mismatches, 0, "the rows survive the round trip")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# the unported fields are listed in the header, and the reference input is carried over
	assert_true(header.has("unported"), "the header lists the unported fields")
	assert_eq(((header["unported"] as Dictionary)["projectile"] as Array).size(), 9, "the projectile fields are all unported (S6)")
	assert_eq(String((header["input_script"] as Dictionary)["name"]), String((ref.header["input_script"] as Dictionary)["name"]), "input script name")


# --- the enemy list, the getter table, the long-run variant ------------------------------------------------------------

func test_the_enemy_list_follows_the_spawn_and_removal_rule_in_every_committed_trace() -> void:
	for file_name: String in _trace_files():
		var ref: TraceReader = _load(file_name)
		if ref == null:
			continue
		var kills_i: int = ref.field_index("wave", "kills")
		var bad_order: int = 0
		var bad_kills: int = 0
		var not_ascending: int = 0
		var removed_total: int = 0
		var previous_kills: int = 0
		var highest_id: int = 0
		for i: int in range(ref.steps.size()):
			var spawned: Array[int] = ref.spawned_enemy_ids(i)
			var removed: Array[int] = ref.removed_enemy_ids(i)
			var predicted: Array[int] = TraceReader.next_enemy_order(ref.enemy_ids(i - 1), spawned, removed)
			if predicted != ref.enemy_ids(i):
				bad_order += 1
			# every removal is a kill, and the kills counter grows by exactly the number of removed enemies
			var kills: int = int((ref.steps[i]["wave"] as Array)[kills_i])
			if kills - previous_kills != removed.size():
				bad_kills += 1
			previous_kills = kills
			removed_total += removed.size()
			for id: int in spawned:
				if id <= highest_id:
					not_ascending += 1
				highest_id = maxi(highest_id, id)
		assert_eq(bad_order, 0, "%s: spawned enemies are appended in id order, removed ones leave by swap-pop: the list order of every step follows" % file_name)
		assert_eq(bad_kills, 0, "%s: wave.kills grows by the number of removed enemies at every step (no despawns)" % file_name)
		assert_eq(not_ascending, 0, "%s: enemy ids only grow" % file_name)
		assert_eq(removed_total, previous_kills, "%s: removed enemies in all = final wave.kills" % file_name)
	# the rule itself on a small case: [1,2,3,4], 5 and 6 spawned, 2 and 5 removed -> walk from the end: 5 leaves (6 takes its place), then 2 (6 moves again)
	var order: Array[int] = TraceReader.next_enemy_order([1, 2, 3, 4], [5, 6], [2, 5])
	assert_eq(order, [1, 6, 3, 4] as Array[int], "next_enemy_order: swap-pop from the end of the list")


func _wave_value(trace: SimTrace, row: Dictionary, field_name: String) -> Variant:
	var specs: PackedStringArray = trace.ported_specs("wave")
	for i: int in range(specs.size()):
		if TraceReader.split_spec(specs[i])[0] == field_name:
			return (row["wave"] as Array)[i]
	fail("wave.%s is not carried by the port trace" % field_name)
	return null


func test_the_getter_table_flattens_the_wave_theme_the_way_the_reference_does() -> void:
	var sim: Sim = _new_sim()
	var trace: SimTrace = SimTrace.new(sim)
	# every getter belongs to a field of the reference schema
	var getters: Dictionary = SimTrace.port_getters()
	for group: Variant in getters.keys():
		var names: Array[String] = []
		for spec: Variant in (SimTrace.REFERENCE_FIELDS[group] as Array):
			names.append(TraceReader.split_spec(String(spec))[0])
		for field_name: Variant in (getters[group] as Dictionary).keys():
			assert_true(names.has(String(field_name)), "%s.%s of the getter table is a reference field" % [group, field_name])
	# newGame already prepares the theme of wave 1 (as in the reference at step 1)...
	var row: Dictionary = trace.record(1, _input_row(0.0, 0.0, []))
	assert_eq(_wave_value(trace, row, "themeWave"), 1, "after newGame: themeWave")
	assert_eq(_wave_value(trace, row, "themeFeaturedKind"), "swarm", "after newGame: themeFeaturedKind")
	# ...and a game without a theme (special waves) gives the zeros of the original's undefined
	sim.game.wave_spawn_theme = null
	row = trace.record(1, _input_row(0.0, 0.0, []))
	assert_eq(_wave_value(trace, row, "themeWave"), 0, "no theme: themeWave")
	assert_eq(_wave_value(trace, row, "themeFeaturedKind"), "", "no theme: themeFeaturedKind")
	assert_eq(_wave_value(trace, row, "themeChanged"), false, "no theme: themeChanged")
	assert_eq(_wave_value(trace, row, "themeCounts"), "", "no theme: themeCounts")
	# and a theme is flattened like hook.js does: counts "kind=n,kind=n" in insertion order, the lists comma separated
	var theme: EnemyWaveTheme = EnemyWaveTheme.new()
	theme.wave = 3
	theme.base_kind = "assassin"
	theme.featured_kind = "swarm"
	theme.changed = true
	theme.change_chance = 0.1
	theme.total_spawned = 3
	theme.counts = {"swarm": 2, "assassin": 1}
	theme.recent_mixed = PackedStringArray(["assassin"])
	sim.game.wave_spawn_theme = theme
	sim.game.featured_enemy_history = PackedStringArray(["swarm", "assassin"])
	row = trace.record(2, _input_row(0.0, 0.0, []))
	assert_eq(_wave_value(trace, row, "themeWave"), 3, "themeWave")
	assert_eq(_wave_value(trace, row, "themeBaseKind"), "assassin", "themeBaseKind")
	assert_eq(_wave_value(trace, row, "themeFeaturedKind"), "swarm", "themeFeaturedKind")
	assert_eq(_wave_value(trace, row, "themeChanged"), true, "themeChanged")
	assert_eq(_wave_value(trace, row, "themeChangeChance"), SimTrace.hex_of(0.1), "themeChangeChance")
	assert_eq(_wave_value(trace, row, "themeTotalSpawned"), 3, "themeTotalSpawned")
	assert_eq(_wave_value(trace, row, "themeCounts"), "swarm=2,assassin=1", "themeCounts")
	assert_eq(_wave_value(trace, row, "themeRecentMixed"), "assassin", "themeRecentMixed")
	assert_eq(_wave_value(trace, row, "featuredEnemyHistory"), "swarm,assassin", "featuredEnemyHistory")
	# plain properties of the same name need no getter
	sim.game.pending_director_enemy_kind = "assassin"
	sim.game.enemies_version = 7
	row = trace.record(3, _input_row(0.0, 0.0, []))
	assert_eq(_wave_value(trace, row, "pendingDirectorEnemyKind"), "assassin", "pendingDirectorEnemyKind")
	assert_eq(_wave_value(trace, row, "enemiesVersion"), 7, "enemiesVersion")


func test_the_overrides_of_a_long_run_header_are_applied_by_the_replay() -> void:
	var ref: TraceReader = TraceReader.load_file("%s/%s" % [REFERENCE_DIR, MANDATORY_TRACES[0]])  # a private copy: the header is edited
	if ref == null:
		fail("%s did not load" % MANDATORY_TRACES[0])
		return
	var big: String = SimTrace.hex_of(1.0e9)
	ref.header["variant"] = "long_run"
	ref.header["overrides"] = {"player.xpNext": big, "player.hp": big, "player.maxHp": big}
	var replay: Dictionary = SimTrace.replay(ref, 3)
	assert_false(replay.is_empty(), "the replay starts")
	if replay.is_empty():
		return
	var port_header: Dictionary = replay["header"]
	assert_eq(String(port_header.get("variant", "")), "long_run", "the port header names the variant")
	assert_eq((port_header["overrides"] as Dictionary).size(), 3, "and carries the overrides")
	var specs: Array = (port_header["fields"] as Dictionary)["player"]
	var row: Array = ((replay["rows"] as Array)[0] as Dictionary)["player"] as Array
	for field_name: String in ["xpNext", "hp", "maxHp"]:
		assert_eq(String(row[_spec_index(specs, field_name)]), big, "player.%s is 1e9 in the first row" % field_name)
	# a standard trace's header has neither key, so the port header has neither
	var standard: Dictionary = SimTrace.replay(_load(MANDATORY_TRACES[0]), 1)["header"]
	assert_false(standard.has("variant") or standard.has("overrides"), "no variant, no overrides in a standard port trace")


func test_the_long_run_trace_reaches_what_the_standard_traces_never_see() -> void:
	var found: int = 0
	for file_name: String in _trace_files():
		var ref: TraceReader = _load(file_name)
		if ref == null or String(ref.header.get("variant", "")) != "long_run":
			continue
		found += 1
		var kind_i: int = ref.field_index("enemy", "kind")
		var wave_i: int = ref.field_index("wave", "wave")
		var theme_i: int = ref.field_index("wave", "themeFeaturedKind")
		var kinds: Dictionary = {}
		var max_wave: int = 0
		var assassin_theme_steps: int = 0
		for step: Dictionary in ref.steps:
			for enemy_row: Variant in (step["enemies"] as Array):
				kinds[String((enemy_row as Array)[kind_i])] = true
			max_wave = maxi(max_wave, int((step["wave"] as Array)[wave_i]))
			if String((step["wave"] as Array)[theme_i]) == "assassin":
				assassin_theme_steps += 1
		assert_true(kinds.has("swarm") and kinds.has("assassin"), "%s: swarm and assassin enemies appear (kinds %s)" % [file_name, str(kinds.keys())])
		assert_true(max_wave >= 3, "%s: the run reaches wave 3 (got %d)" % [file_name, max_wave])
		assert_true(assassin_theme_steps > 0, "%s: the director features assassins in some steps" % file_name)
		print("      %s: %d steps, waves up to %d, enemy kinds %s, assassin theme in %d steps" % [file_name, ref.steps.size(), max_wave, str(kinds.keys()), assassin_theme_steps])
	assert_true(found >= 1, "a long-run trace is committed")


## Equality of two player rows after a JSON round trip (integers come back as floats).
func _same_row(a: Array, b: Array, reader: TraceReader, group: String) -> bool:
	var specs: Array[PackedStringArray] = reader.field_specs(group)
	if a.size() != b.size() or a.size() != specs.size():
		return false
	for i: int in range(a.size()):
		if not SimTrace.same_value(specs[i][1], a[i], b[i]):
			return false
	return true
