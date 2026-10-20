extends "res://tests/test_case.gd"
## Sim.step() against the ORIGINAL update(): scripted input (keys, touch stick, variable dt, edge clamps, screen flashes, reaction
## buffs, the knock-out sequence) is run through the port, and the recorded state is compared bit for bit with
## tests/golden/sim_scripts.json, which tools/golden/defs_sim_scripts.mjs produced by running the original update(),
## runSystems(), updatePlayerMovement(), followPlayerWithCamera() ... (cut out of original.html, in a node:vm context) on the
## state that the original newGame literal builds. The golden file lists which functions it stubbed out (`stubbed_noop`); the
## scripts contain no enemies and no weapon fire, so none of those functions writes the recorded fields.
##
## Also: the random-number accounting of the slots implemented in step S3, interpolation snapshots, and the guards of update().

const SEED: int = 424242
## Index of each recorded column (the golden file's `columns`, "kind:name").
const COL_STEP: int = 0
const COL_STATE: int = 1
const COL_T: int = 2
const COL_DAY_PHASE: int = 3
const COL_HP: int = 4
const COL_KO_TIMER: int = 5
const COL_ENDED: int = 6
const COL_SCREEN_FLASH: int = 7
const COL_DAMAGE_FLASH: int = 8
const COL_X: int = 9
const COL_Y: int = 10
const COL_PREV_X: int = 11
const COL_PREV_Y: int = 12
const COL_VX: int = 13
const COL_VY: int = 14
const COL_AX: int = 15
const COL_AY: int = 16
const COL_WALK_PHASE: int = 17
const COL_LAST_FACING: int = 18
const COL_ATTACK_ANIM: int = 19
const COL_CONTROL_SLOW: int = 20
const COL_HAZARD_DEFENSE: int = 21
const COL_PRISM: int = 22
const COL_VOID_ECHO: int = 23
const COL_CAM_X: int = 24
const COL_CAM_Y: int = 25
const COL_CAM_PREV_X: int = 26
const COL_CAM_PREV_Y: int = 27
const COLUMN_NAMES: PackedStringArray = [
	"step", "state", "t", "dayPhase", "hp", "koTimer", "ended", "screenFlash", "damageFlash", "x", "y", "prevX", "prevY", "vx", "vy",
	"ax", "ay", "walkPhase", "lastFacing", "attackAnim", "controlSlow", "hazardDefenseBonus", "prismResonance", "voidEcho",
	"camX", "camY", "camPrevX", "camPrevY",
]


func _golden() -> Dictionary:
	return GoldenCodec.load_json("sim_scripts")


func _new_sim(rng_seed: int = SEED, view_w: float = 390.0, view_h: float = 844.0) -> Sim:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = rng_seed
	config.view_w = view_w
	config.view_h = view_h
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game")
	return sim


## The port's value of a recorded column.
func _field(game: GameState, column: int) -> Variant:
	var p: PlayerState = game.player
	match column:
		COL_STATE:
			return "playing" if game.state == GameState.RunState.PLAYING else ("ended" if game.state == GameState.RunState.ENDED else "other")
		COL_T:
			return game.t
		COL_DAY_PHASE:
			return game.day_phase
		COL_HP:
			return p.hp
		COL_KO_TIMER:
			return p.ko_timer
		COL_ENDED:
			return game.ended
		COL_SCREEN_FLASH:
			return game.screen_flash
		COL_DAMAGE_FLASH:
			return game.damage_flash
		COL_X:
			return p.x
		COL_Y:
			return p.y
		COL_PREV_X:
			return p.prev_x
		COL_PREV_Y:
			return p.prev_y
		COL_VX:
			return p.vx
		COL_VY:
			return p.vy
		COL_AX:
			return p.ax
		COL_AY:
			return p.ay
		COL_WALK_PHASE:
			return p.walk_phase
		COL_LAST_FACING:
			return p.last_facing
		COL_ATTACK_ANIM:
			return p.attack_anim
		COL_CONTROL_SLOW:
			return p.control_slow
		COL_HAZARD_DEFENSE:
			return p.hazard_defense_bonus
		COL_PRISM:
			return p.reaction_buffs.prism_resonance
		COL_VOID_ECHO:
			return p.reaction_buffs.void_echo
		COL_CAM_X:
			return game.camera.x
		COL_CAM_Y:
			return game.camera.y
		COL_CAM_PREV_X:
			return game.camera.prev_x
		COL_CAM_PREV_Y:
			return game.camera.prev_y
	push_error("unknown column %d" % column)
	return null


## The assignment `game.<path> = value` that a golden script makes just before a step.
func _apply_set(game: GameState, path: String, value: float) -> void:
	match path:
		"player.x":
			game.player.x = value
		"player.y":
			game.player.y = value
		"player.hp":
			game.player.hp = value
		"player.koTimer":
			game.player.ko_timer = value
		"screenFlash":
			game.screen_flash = value
		"damageFlash":
			game.damage_flash = value
		"player.reactionBuffs.prismResonance":
			game.player.reaction_buffs.prism_resonance = value
		"player.reactionBuffs.voidEcho":
			game.player.reaction_buffs.void_echo = value
		_:
			fail("unknown set path %s" % path)


func _apply_input(input: SimInput, key_mask: int, move_x: float, move_y: float) -> void:
	input.key_left = (key_mask & 1) != 0
	input.key_right = (key_mask & 2) != 0
	input.key_up = (key_mask & 4) != 0
	input.key_down = (key_mask & 8) != 0
	input.move_x = move_x
	input.move_y = move_y


func _compare_row(game: GameState, row: String, script_name: String, mismatches: GoldenTable.Mismatches) -> void:
	var t: PackedStringArray = GoldenTable.tokens(row)
	var step: String = t[COL_STEP]
	assert_eq(t.size(), COLUMN_NAMES.size(), "%s step %s: row has every column" % [script_name, step])
	for column: int in range(COL_STATE, COLUMN_NAMES.size()):
		mismatches.checked += 1
		var actual: Variant = _field(game, column)
		var where: String = "%s step %s %s" % [script_name, step, COLUMN_NAMES[column]]
		if column == COL_STATE:
			if actual != t[column]:
				mismatches.add("%s: port '%s', original '%s'" % [where, actual, t[column]])
		elif column == COL_ENDED:
			if actual != GoldenTable.b(t[column]):
				mismatches.add("%s: port %s, original %s" % [where, actual, t[column]])
		else:
			var expected: float = GoldenTable.f(t[column])
			if not GoldenCodec.same_double(float(actual), expected):
				mismatches.add("%s: port %s, original %s" % [where, GoldenTable.show(float(actual)), GoldenTable.show(expected)])


func test_scripted_input_matches_the_original_update() -> void:
	var golden: Dictionary = _golden()
	var scripts: Array = golden["scripts"]
	assert_eq(scripts.size(), 13, "scripted runs in the golden file")
	var expected_columns: Array = []
	for name: String in COLUMN_NAMES:
		expected_columns.append(name)
	var golden_columns: Array = []
	for column: Variant in golden["columns"]:
		golden_columns.append(String(column).get_slice(":", 1))
	assert_eq(golden_columns, expected_columns, "the golden file's columns are the ones this test reads")
	var total_steps: int = 0
	var total_rows: int = 0
	for script: Dictionary in scripts:
		var name: String = script["name"]
		var steps: int = int(script["steps"])
		var triples: PackedFloat64Array = GoldenCodec.decode_f64(script["input_f64"])
		var key_masks: PackedByteArray = Marshalls.base64_to_raw(script["input_keys"])
		assert_eq(triples.size(), steps * 3, "%s: stick x, stick y, dt per step" % name)
		assert_eq(key_masks.size(), steps, "%s: a key mask per step" % name)
		var sets_by_step: Dictionary = {}
		for entry: Array in script["sets"]:
			var step_number: int = int(entry[0])
			if not sets_by_step.has(step_number):
				sets_by_step[step_number] = []
			(sets_by_step[step_number] as Array).append([String(entry[1]), GoldenCodec.from_hex(String(entry[2]))])
		var rows_by_step: Dictionary = {}
		for row: Variant in script["rows"]:
			rows_by_step[int(GoldenTable.tokens(String(row))[COL_STEP])] = String(row)
		var sim: Sim = _new_sim()
		var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		for index: int in steps:
			var step_number: int = index + 1
			for assignment: Array in sets_by_step.get(step_number, []):
				_apply_set(sim.game, assignment[0], assignment[1])
			_apply_input(sim.game.input, key_masks[index], triples[index * 3], triples[index * 3 + 1])
			sim.step(triples[index * 3 + 2])
			if rows_by_step.has(step_number):
				_compare_row(sim.game, rows_by_step[step_number], name, mismatches)
				total_rows += 1
		assert_eq(rows_by_step.size(), (script["rows"] as Array).size(), "%s: one row per recorded step" % name)
		assert_true(rows_by_step.has(steps), "%s: the last step is recorded" % name)
		assert_eq(mismatches.count, 0, mismatches.summary("script " + name))
		assert_eq(sim.steps, steps, "%s: Sim counted the steps" % name)
		total_steps += steps
	assert_true(total_steps > 1900, "many steps were replayed (%d)" % total_steps)
	assert_true(total_rows > 300, "many rows were compared (%d)" % total_rows)


func test_no_slot_of_step_s3_draws_a_random_number() -> void:
	# Measured in the original (tools/census_rng_slots_chromium.mjs): only wave/progress, enemy/update (contact damage),
	# projectile/player and enemy/cleanup-2 draw from gameRandom in the M1 configuration. Everything this step implements
	# (clock, movement, camera, KO, ...) must leave the draw counter alone,
	# whatever the input - after newGame's single draw (the starting weapon's cooldown) it stays 1.
	for rng_seed: int in [SEED, 24681357]:
		var sim: Sim = _new_sim(rng_seed)
		assert_eq(sim.draws(), 1, "seed %d: newGame draws once" % rng_seed)
		for step_number: int in 600:
			_apply_input(sim.game.input, 2 if step_number < 200 else (4 if step_number < 400 else 0), 0.3, -0.2)
			sim.step()
		assert_eq(sim.draws(), 1, "seed %d: 600 steps of movement draw nothing" % rng_seed)
		# the generator is where newGame left it: the next output is the second of the stream
		var reference: SeededRng = SeededRng.new(rng_seed)
		reference.next_u32()
		assert_eq(sim.game.rng.random(), float(reference.next_u32()) / 4294967296.0, "seed %d: the stream was not touched" % rng_seed)


func test_port_stubs_are_not_slots_the_golden_runs_for_real() -> void:
	# The golden file replaced a list of functions by no-ops (stubbed_noop) and ran the others for real. A slot that the port leaves
	# as a placeholder must be one of the stubbed ones, else the port would skip code that the golden proves matters; and every
	# function a slot of the port calls must be known to the golden file at all.
	var golden: Dictionary = _golden()
	var real: Array = golden["real_functions"]
	var stubbed: Array = golden["stubbed_noop"]
	var custom: Array = golden["custom_stubs"]
	var sim: Sim = _new_sim()
	var all_slots: Array[SystemSlot] = []
	all_slots.append_array(sim.runner.intro)
	all_slots.append_array(sim.runner.main)
	all_slots.append_array(sim.runner.ko)
	for slot: SystemSlot in all_slots:
		var function_name: String = slot.system.original_function
		assert_true(real.has(function_name) or stubbed.has(function_name) or custom.has(function_name), "%s: the golden file knows %s" % [slot.id, function_name])
		if not slot.system.is_implemented():
			assert_false(real.has(function_name), "%s: the placeholder %s does something in the golden's runs" % [slot.id, function_name])
			assert_true(stubbed.has(function_name), "%s: the placeholder %s was stubbed in the golden's runs" % [slot.id, function_name])


func test_implemented_slots_are_the_ones_the_design_assigns_to_s3() -> void:
	var sim: Sim = _new_sim()
	var implemented: PackedStringArray = PackedStringArray()
	for list: Array[SystemSlot] in [sim.runner.intro, sim.runner.main, sim.runner.ko]:
		for slot: SystemSlot in list:
			if slot.system.is_implemented():
				implemented.append(slot.id)
	var expected: Array = [
		"frame/clock", "frame/day-cycle",
		"player/reaction-buffs", "player/movement", "player/camera", "fx/screen-flash", "player/regen",
		"player/ko-motion", "fx/screen-flash", "frame/end-run",
	]
	assert_eq(Array(implemented), expected, "implemented slots in list order (intro, main, ko)")
	assert_eq(sim.runner.stub_slots().size(), 53 - expected.size(), "every other slot is a documented placeholder")


# --- interpolation snapshots --------------------------------------------------------------------------------

func test_previous_transforms_are_the_state_before_the_step() -> void:
	var sim: Sim = _new_sim()
	var g: GameState = sim.game
	var first: EnemyState = EnemyState.new()
	first.x = 100.5
	first.y = 200.25
	var second: EnemyState = EnemyState.new()
	second.x = -3.0
	second.y = 7.0
	g.enemies.append(first)
	g.enemies.append(second)
	g.input.key_right = true
	var before_x: float = g.player.x
	var before_cam_x: float = g.camera.x
	sim.step()
	assert_eq(g.player.prev_x, before_x, "player.prevX is the position before the step")
	assert_eq(g.player.prev_y, g.limits.map_h / 2.0, "player.prevY")
	assert_true(g.player.x > before_x, "the player moved right")
	assert_eq(g.camera.prev_x, before_cam_x, "camera.prevX")
	assert_eq(first.prev_x, 100.5, "enemy.prevX")
	assert_eq(first.prev_y, 200.25, "enemy.prevY")
	assert_eq(second.prev_x, -3.0, "second enemy prevX")
	# the second step captures the first step's result
	var after_first: float = g.player.x
	sim.step()
	assert_eq(g.player.prev_x, after_first, "prevX follows the position of the previous step")


# --- guards of update() -------------------------------------------------------------------------------------

func test_update_does_nothing_unless_the_state_is_playing() -> void:
	for state: GameState.RunState in [GameState.RunState.MENU, GameState.RunState.PAUSED, GameState.RunState.LEVELUP, GameState.RunState.CHEST,
			GameState.RunState.SPECIAL, GameState.RunState.ABILITY, GameState.RunState.ABILITY_INTRO, GameState.RunState.ENDED]:
		var sim: Sim = _new_sim()
		sim.game.state = state
		sim.game.input.key_right = true
		sim.step()
		assert_eq(sim.game.t, 0.0, "state %d: the clock does not run" % state)
		assert_eq(sim.game.player.x, sim.game.limits.map_w / 2.0, "state %d: the player does not move" % state)


func test_dt_is_clamped_to_one_thirtieth_and_nan_counts_as_zero() -> void:
	var sim: Sim = _new_sim()
	sim.step(0.5)
	assert_true(GoldenCodec.same_double(sim.game.t, 1.0 / 30.0), "dt above 1/30 is cut to 1/30")
	var sim2: Sim = _new_sim()
	sim2.step(NAN)
	sim2.step(INF)
	sim2.step(-1.0)
	assert_eq(sim2.game.t, 0.0, "a dt that is not finite or is negative advances nothing")
	assert_eq(sim2.steps, 3, "the steps are counted anyway")


func test_knock_out_sequence() -> void:
	# the player dies at the start of a step: the main list stops at its first slot, the KO animation (koAnimMax 0.96 s) plays,
	# then endRun(false) ends the run
	var sim: Sim = _new_sim()
	var g: GameState = sim.game
	g.input.key_right = true
	sim.step()
	var x_alive: float = g.player.x
	g.player.hp = 0.0
	sim.step()
	assert_true(g.player.ko_timer > 0.0, "the knock-out starts")
	assert_eq(g.player.ko_timer, 0.96, "koTimer = koAnimMax")
	assert_false(g.input.key_right, "enterKnockOutIfDead clears the input")
	assert_eq(g.player.x, x_alive, "the main list was cut short: no movement in the dying step")
	assert_false(g.is_player_alive(), "dead")
	assert_eq(g.state, GameState.RunState.PLAYING, "the run has not ended yet")
	var steps_to_end: int = 0
	while g.state == GameState.RunState.PLAYING and steps_to_end < 200:
		sim.step()
		steps_to_end += 1
	assert_eq(g.state, GameState.RunState.ENDED, "the run ends after the animation")
	assert_true(g.ended, "game.ended")
	assert_false(g.run_won, "a lost run")
	assert_true(steps_to_end >= 57 and steps_to_end <= 59, "0.96 s of KO animation is 58 fixed steps (%d)" % steps_to_end)
	var t_at_end: float = g.t
	sim.step()
	assert_eq(g.t, t_at_end, "nothing runs after the end")


## A test slot: runs `action` (1 = the player dies, 2 = the state becomes LEVELUP, 3 = count and draw one number).
class ProbeSystem extends SimSystem:
	var action: int = 0
	var runs: int = 0

	func _init(p_game: GameState, p_action: int) -> void:
		super(p_game, "probe")
		action = p_action

	func run(_dt: float) -> void:
		runs += 1
		if action == 1:
			game.player.hp = 0.0
		elif action == 2:
			game.state = GameState.RunState.LEVELUP
		elif action == 3:
			game.rng.random()


## runSystems checks the state and the player's life before EVERY slot of the main list, not only before the first one:
## a slot in the middle of the list (updateEnemies: contact damage kills the player; the pending-choice slot: a level-up
## opens) stops everything after it in the same step. The slots after it draw random numbers in the original
## (projectile/player, enemy/cleanup-2), so a lost check would change the draw count.
func _probe_sim(killer_action: int, killer_index: int) -> Array:
	var sim: Sim = _new_sim()
	var killer: ProbeSystem = ProbeSystem.new(sim.game, killer_action)
	var after: ProbeSystem = ProbeSystem.new(sim.game, 3)
	var last: ProbeSystem = ProbeSystem.new(sim.game, 3)
	sim.runner.main.insert(killer_index, SystemSlot.new("test/killer", "enemy", killer))
	sim.runner.main.insert(killer_index + 1, SystemSlot.new("test/after", "enemy", after))
	sim.runner.main.append(SystemSlot.new("test/last", "hud", last))
	sim.game.screen_flash = 1.0
	sim.game.damage_flash = 1.0
	return [sim, killer, after, last]


func test_a_slot_in_the_middle_of_the_main_list_that_kills_the_player_stops_the_rest_of_the_step() -> void:
	var control: Array = _probe_sim(0, 15)
	var control_sim: Sim = control[0]
	control_sim.step()
	assert_eq((control[2] as ProbeSystem).runs, 1, "control: the slot after the (inert) killer runs")
	assert_eq((control[3] as ProbeSystem).runs, 1, "control: the last slot runs")
	assert_eq(control_sim.draws(), 3, "control: newGame's draw and the two probe draws")
	assert_true(control_sim.game.screen_flash < 1.0, "control: the screen flash decays in the main list")
	# fx/screen-flash is slot 39 (counting from 0) of the original's list: a killer inserted at an index below it leaves the flash untouched
	for killer_index: int in [0, 1, 15, 26, 38]:
		var made: Array = _probe_sim(1, killer_index)
		var sim: Sim = made[0]
		var g: GameState = sim.game
		sim.step()
		var where: String = "the player dies in slot %d" % killer_index
		assert_eq((made[1] as ProbeSystem).runs, 1, "%s: the killer ran" % where)
		assert_eq((made[2] as ProbeSystem).runs, 0, "%s: the next slot did not run" % where)
		assert_eq((made[3] as ProbeSystem).runs, 0, "%s: the last slot did not run" % where)
		assert_eq(sim.draws(), 1, "%s: no draw after the kill (only newGame's)" % where)
		assert_eq(g.screen_flash, 1.0, "%s: fx/screen-flash did not run" % where)
		assert_eq(g.damage_flash, 1.0, "%s: fx/screen-flash did not run (damage flash)" % where)
		assert_eq(g.player.ko_timer, 0.96, "%s: the knock-out starts in the same step" % where)
		assert_eq(g.state, GameState.RunState.PLAYING, "%s: the run has not ended yet" % where)
		assert_eq(g.t, 1.0 / 60.0, "%s: the intro list ran (clock)" % where)
		# the next step plays the KO list, which does not contain the main list's slots
		sim.step()
		assert_eq((made[2] as ProbeSystem).runs, 0, "%s: the KO list does not run the main list's slots" % where)
		assert_true(g.player.ko_timer < 0.96, "%s: the KO list ran (animation timer %f)" % [where, g.player.ko_timer])
		assert_true(g.screen_flash < 1.0, "%s: fx/screen-flash of the KO list ran" % where)


func test_a_slot_that_leaves_the_playing_state_stops_the_rest_of_the_step() -> void:
	for slot_index: int in [0, 15, 40]:
		var made: Array = _probe_sim(2, slot_index)
		var sim: Sim = made[0]
		sim.step()
		var where: String = "state becomes LEVELUP in slot %d" % slot_index
		assert_eq(sim.game.state, GameState.RunState.LEVELUP, where)
		assert_eq((made[2] as ProbeSystem).runs, 0, "%s: the next slot did not run" % where)
		assert_eq((made[3] as ProbeSystem).runs, 0, "%s: the last slot did not run" % where)
		assert_eq(sim.draws(), 1, "%s: no draw after the change" % where)
		assert_false(sim.game.player.ko_timer > 0.0, "%s: no knock-out" % where)


func test_view_size_is_an_input_of_the_sim() -> void:
	var sim: Sim = _new_sim(SEED, 390.0, 844.0)
	assert_eq(sim.game.view_w, 390.0, "viewW")
	assert_eq(sim.game.view_h, 844.0, "viewH")
	sim.set_view_size(1280.0, 720.0)
	assert_eq(sim.game.view_w, 1280.0, "set_view_size: viewW")
	assert_eq(sim.game.view_h, 720.0, "set_view_size: viewH")
	assert_eq(Defs.limits(true).max_projectiles, sim.game.limits.max_projectiles, "the sim uses the coarse pointer caps")
	assert_eq(sim.game.limits.max_projectiles, 520, "MAX_PROJECTILES on Android")
