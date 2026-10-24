extends "res://tests/test_case.gd"
## The test-only replay oracle (tests/trace/replay_oracle.gd, design section 11 step S5): what it does, and the proof that the exported game cannot enable it.
##
## "Impossible to enable in the exported game" has four legs, all checked here:
##   1. the oracle classes live under res://tests/, and every export preset excludes `tests/*` (export_presets.cfg), so the exported package does not
##      contain them at all;
##   2. nothing the export includes mentions them: no script under res://sim or res://render, not main.gd, no scene;
##   3. the simulation has no hook for it: SimConfig, Sim, SystemRunner, SystemSlot and GameState have no property or method that has "oracle" in its name,
##      and a simulation built the production way (Sim.new_game, as main.gd does) has only its own systems in its slots;
##   4. the oracle works only by replacing SystemSlot.system from outside (ReplayOracle.install), which production code never calls.

const EXPORT_PRESETS: String = "res://export_presets.cfg"
const ORACLE_CLASSES: PackedStringArray = ["ReplayOracle", "OracleSystem"]
## Words that would show a reference to the oracle in a file that the export includes.
const ORACLE_WORDS: PackedStringArray = ["ReplayOracle", "OracleSystem", "replay_oracle", "oracle_system"]
const PRODUCTION_ROOTS: PackedStringArray = ["res://sim", "res://render"]


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


## The text of a GDScript file without its `#` comments (a `#` inside a string would be cut too, which only makes the scan weaker for that line).
func _code_without_comments(text: String) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for line: String in text.split("\n"):
		var at: int = line.find("#")
		lines.append(line if at < 0 else line.substr(0, at))
	return "\n".join(lines)


func _scripts_under(dir_path: String, found: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return  # res://render may not exist yet
	for sub: String in dir.get_directories():
		if not sub.begins_with("."):
			_scripts_under(dir_path.path_join(sub), found)
	for file_name: String in dir.get_files():
		if file_name.ends_with(".gd") or file_name.ends_with(".tscn") or file_name.ends_with(".tres"):
			found.append(dir_path.path_join(file_name))


func test_the_oracle_classes_live_under_tests_which_every_export_preset_excludes() -> void:
	for class_name_text: String in ORACLE_CLASSES:
		var path: String = ""
		for info: Dictionary in ProjectSettings.get_global_class_list():
			if String(info["class"]) == class_name_text:
				path = String(info["path"])
		assert_true(path.begins_with("res://tests/"), "%s is defined under res://tests/ (%s)" % [class_name_text, path])
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(EXPORT_PRESETS), OK, "export_presets.cfg loads")
	var presets: int = 0
	for section: String in config.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			presets += 1
			var exclude: String = String(config.get_value(section, "exclude_filter", ""))
			assert_true(exclude.contains("tests/*"), "%s (%s) excludes tests/* from the export (exclude_filter = '%s')" % [section, config.get_value(section, "name", ""), exclude])
	assert_true(presets >= 1, "there is an export preset (%d)" % presets)


func test_nothing_that_the_export_includes_mentions_the_oracle() -> void:
	var files: PackedStringArray = PackedStringArray()
	for root: String in PRODUCTION_ROOTS:
		_scripts_under(root, files)
	files.append("res://main.gd")
	files.append("res://main.tscn")
	assert_true(files.size() > 40, "the production files were found (%d)" % files.size())
	for path: String in files:
		var text: String = _read(path)
		assert_false(text.is_empty() and path.ends_with("main.gd"), "%s is readable" % path)
		# comments may explain that a test tool exists; code (and scene files) may not contain the word at all
		var code: String = _code_without_comments(text) if path.ends_with(".gd") else text
		for word: String in ORACLE_WORDS:
			assert_false(code.contains(word), "%s does not refer to %s" % [path, word])
		assert_false(code.to_lower().contains("oracle"), "%s has no code that mentions an oracle" % path)
	# the scan itself finds a mention when there is one
	assert_true("class_name Foo\nvar x: ReplayOracle".contains(ORACLE_WORDS[0]), "the scanner sees a reference")
	# the oracle's own files are among the test files, which the export excludes
	assert_true(FileAccess.file_exists("res://tests/trace/replay_oracle.gd") and FileAccess.file_exists("res://tests/trace/oracle_system.gd"), "the oracle files exist under tests/trace")


func test_the_simulation_has_no_hook_for_the_oracle_and_a_production_sim_has_only_its_own_systems() -> void:
	for script: Script in [SimConfig, Sim, SystemRunner, SystemSlot, GameState, SimSystem]:
		for info: Dictionary in script.get_script_property_list():
			assert_false(String(info["name"]).to_lower().contains("oracle"), "%s has no property '%s'" % [script.get_global_name(), info["name"]])
		for info: Dictionary in script.get_script_method_list():
			assert_false(String(info["name"]).to_lower().contains("oracle"), "%s has no method '%s'" % [script.get_global_name(), info["name"]])
	var config: SimConfig = SimConfig.new()
	config.rng_seed = 1
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game")
	var slots: int = 0
	for list: Array[SystemSlot] in [sim.runner.intro, sim.runner.main, sim.runner.ko]:
		for slot: SystemSlot in list:
			slots += 1
			assert_false(slot.system is OracleSystem, "slot %s is not an OracleSystem" % slot.id)
			assert_false(slot.system is TracedSystem, "slot %s is not traced (tracing is a test tool too)" % slot.id)
	assert_eq(slots, 53, "all 53 slots are the simulation's own")


# --- what the oracle does ----------------------------------------------------------------------------------------------------

## A reference trace that is just big enough for the oracle: two main slots, enemies, projectiles.
func _fake_reference() -> TraceReader:
	var ref: TraceReader = TraceReader.new()
	ref.header = {
		"slots": {"intro": [], "main": ["a/placeholder", "b/implemented", "enemy/cleanup-2"], "ko": []},
		"fields": {
			"enemy": ["id:i"],
			"projectile": ["x:f", "y:f", "vx:f", "vy:f", "life:f", "age:f", "r:f", "damage:f", "weapon:s"],
		},
	}
	var proj: Array = [SimTrace.hex_of(1.5), SimTrace.hex_of(-2.5), SimTrace.hex_of(3.0), SimTrace.hex_of(4.0), SimTrace.hex_of(0.5), SimTrace.hex_of(0.25),
		SimTrace.hex_of(5.0), SimTrace.hex_of(7.0), "pulse"]
	ref.steps = [
		{"slot_draws": {"main:0": 3, "main:1": 5}, "enemies": [[1], [2], [3]], "projectiles": [proj]},
		{"slot_draws": {"main:0": 2}, "enemies": [[1], [3]], "projectiles": []},
	] as Array[Dictionary]
	return ref


class DrawSystem extends SimSystem:
	var count: int = 0
	var implemented: bool = true

	func _init(p_game: GameState, p_count: int, p_implemented: bool) -> void:
		super(p_game, "test")
		count = p_count
		implemented = p_implemented

	func run(_dt: float) -> void:
		for i: int in range(count):
			game.rng.random()

	func is_implemented() -> bool:
		return implemented


func _oracle_sim(ref: TraceReader) -> Array:
	var config: SimConfig = SimConfig.new()
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game")
	# three test slots instead of the real main list
	sim.runner.main.clear()
	sim.runner.main.append(SystemSlot.new("a/placeholder", "test", DrawSystem.new(sim.game, 1, false)))
	sim.runner.main.append(SystemSlot.new("b/implemented", "test", DrawSystem.new(sim.game, 2, true)))
	sim.runner.main.append(SystemSlot.new("enemy/cleanup-2", "enemy", EnemyCleanupSystem.new(sim.game)))
	var oracle: ReplayOracle = ReplayOracle.install(sim, ref)
	return [sim, oracle]


func test_a_placeholder_gets_the_missing_draws_and_an_implemented_slot_gets_none() -> void:
	var ref: TraceReader = _fake_reference()
	var made: Array = _oracle_sim(ref)
	var sim: Sim = made[0]
	var oracle: ReplayOracle = made[1]
	for id: int in [1, 2, 3]:
		var e: EnemyState = EnemyState.new()
		e.id = id
		e.hp = 10.0
		sim.game.enemies.append(e)
	var before: int = sim.game.rng.draws
	oracle.begin_step(1)  # the reference's second step removed enemy 2 and made 2 draws in the placeholder
	sim.runner.run_systems(sim.runner.main, 1.0 / 60.0)
	# placeholder: drew 1, the reference 2 -> 1 injected; implemented: drew 2 (the reference's 5 of step 1 are NOT made up); cleanup-2: killed enemy 2
	assert_eq(oracle.injected, {"main:0": 1}, "one draw was injected for the placeholder, none for the implemented slot")
	assert_eq(oracle.injected_total(), 1, "total")
	assert_eq(sim.game.rng.draws - before, 2 + 2 + 2, "2 (placeholder, own + injected) + 2 (implemented) + 2 (the xp orb of the kill)")
	assert_eq(oracle.problems, PackedStringArray(), "nothing wrong")
	assert_eq(oracle.forced_kills, 1, "enemy 2 was killed")
	var ids: Array = []
	for e: EnemyState in sim.game.enemies:
		ids.append(e.id)
	assert_eq(ids, [1, 3], "the list is the reference's")
	assert_eq(sim.game.kills, 1, "killEnemy counted it")
	assert_eq(sim.game.xp_orbs.size(), 1, "and left an experience orb")


func test_the_oracle_reports_a_placeholder_that_draws_more_than_the_reference_and_an_unknown_enemy() -> void:
	var ref: TraceReader = _fake_reference()
	var made: Array = _oracle_sim(ref)
	var sim: Sim = made[0]
	var oracle: ReplayOracle = made[1]
	sim.runner.main[0].system = OracleSystem.new(DrawSystem.new(sim.game, 9, false), oracle, "a/placeholder", "main:0")
	# the port's list lacks enemy 2 and has an extra dead enemy 7
	for id: int in [1, 3, 7]:
		var e: EnemyState = EnemyState.new()
		e.id = id
		e.hp = 10.0 if id != 7 else 0.0
		sim.game.enemies.append(e)
	oracle.begin_step(1)
	sim.runner.run_systems(sim.runner.main, 1.0 / 60.0)
	var text: String = "; ".join(oracle.problems)
	assert_true(text.contains("main:0") and text.contains("drew 9 values, the reference 2"), "too many draws are reported: %s" % text)
	assert_true(text.contains("enemy 7 has hp <= 0"), "an unexpected dead enemy is reported: %s" % text)
	assert_true(text.contains("removed 1 enemies, 0 of them"), "an id that is not in the list is reported: %s" % text)


func test_the_projectile_list_is_rebuilt_from_the_reference_rows_of_the_step_before() -> void:
	var ref: TraceReader = _fake_reference()
	var made: Array = _oracle_sim(ref)
	var sim: Sim = made[0]
	var oracle: ReplayOracle = made[1]
	oracle.begin_step(0)
	assert_eq(sim.game.projectiles.size(), 0, "before the first step the list is empty")
	oracle.begin_step(1)
	assert_eq(sim.game.projectiles.size(), 1, "step 2 starts with the projectile that the reference had at the end of step 1")
	var p: ProjectileState = sim.game.projectiles[0]
	assert_eq(p.x, 1.5, "x")
	assert_eq(p.y, -2.5, "y")
	assert_eq(p.vx, 3.0, "vx")
	assert_eq(p.vy, 4.0, "vy")
	assert_eq(p.life, 0.5, "life")
	assert_eq(p.age, 0.25, "age")
	assert_eq(p.r, 5.0, "r")
	assert_eq(p.damage, 7.0, "damage")
	assert_eq(p.weapon, "pulse", "weapon")
	oracle.begin_step(2 - 1)  # the same step again: the list is rebuilt, not appended
	assert_eq(sim.game.projectiles.size(), 1, "rebuilt, not appended")


func test_the_wrapper_is_invisible_to_the_runner() -> void:
	var ref: TraceReader = _fake_reference()
	var made: Array = _oracle_sim(ref)
	var sim: Sim = made[0]
	assert_false(sim.runner.main[0].system.is_implemented(), "a placeholder stays a placeholder behind the wrapper")
	assert_true(sim.runner.main[1].system.is_implemented(), "an implemented slot stays implemented")
	assert_true(sim.runner.main[0].system is OracleSystem, "the slot's system is the wrapper")
