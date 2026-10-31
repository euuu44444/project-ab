extends "res://tests/test_case.gd"
## The enemy code of step S5 against tests/golden/enemies.json, which tools/golden/defs_enemies.mjs produced by running the ORIGINAL functions
## (cut out of original.html and evaluated in a node:vm context; the file's header lists what is real and what is stubbed): the enemy
## director (plans, formation points, the safe-point fallbacks that no reference trace reaches, spawnEnemy's object and its nine draws, the kind
## picks, updateWave stepped through wave changes, corners and full lists), cleanupDeadEnemies / killEnemy / spawnXp (including the merge of
## experience orbs at the cap) and the enemy grid with its queries (including the cells/cache path of >= 64 projectiles).
## Every number is compared as a bit pattern; the draw counter is compared with every result.

const GOLDEN_NAME: String = "enemies"
const DT: float = 1.0 / 60.0


func _golden() -> Dictionary:
	return GoldenCodec.load_json(GOLDEN_NAME)


# --- helpers --------------------------------------------------------------------------------------------------------

## column name -> index of a "name:type" list.
func _columns(specs: Array) -> Dictionary:
	var out: Dictionary = {}
	for i: int in range(specs.size()):
		out[String(specs[i]).get_slice(":", 0)] = i
	return out


func _new_game(rng_seed: int) -> GameState:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = rng_seed
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game(seed %d)" % rng_seed)
	return sim.game


func _player(golden: Dictionary, player_name: String) -> Dictionary:
	for p: Dictionary in golden["players"]:
		if String(p["name"]) == player_name:
			return p
	fail("no player %s in the golden file" % player_name)
	return {}


func _set_player(game: GameState, p: Dictionary) -> void:
	game.player.x = GoldenCodec.from_hex(String(p["x"]))
	game.player.y = GoldenCodec.from_hex(String(p["y"]))
	game.player.vx = GoldenCodec.from_hex(String(p["vx"]))
	game.player.vy = GoldenCodec.from_hex(String(p["vy"]))


func _same(actual: float, token: String) -> bool:
	return GoldenCodec.same_double(actual, GoldenCodec.from_hex(token))


func _add_float(mismatches: GoldenTable.Mismatches, where: String, actual: float, token: String) -> void:
	mismatches.checked += 1
	if not _same(actual, token):
		mismatches.add("%s: port %s, original %s" % [where, GoldenTable.show(actual), GoldenTable.show(GoldenCodec.from_hex(token))])


func _add_int(mismatches: GoldenTable.Mismatches, where: String, actual: int, expected: int) -> void:
	mismatches.checked += 1
	if actual != expected:
		mismatches.add("%s: port %d, original %d" % [where, actual, expected])


func _add_text(mismatches: GoldenTable.Mismatches, where: String, actual: String, expected: String) -> void:
	mismatches.checked += 1
	if actual != expected:
		mismatches.add("%s: port '%s', original '%s'" % [where, actual, expected])


func _dash(text: String) -> String:
	return "-" if text.is_empty() else text


# --- the plan, the formation points, the safe points ---------------------------------------------------------------------

func test_createEnemyFieldSpawnPlan_matches_the_original() -> void:
	var golden: Dictionary = _golden()
	var table: Dictionary = golden["plans"]
	var c: Dictionary = _columns(table["columns"])
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	for row: String in table["rows"]:
		var t: PackedStringArray = GoldenTable.tokens(row)
		var game: GameState = _new_game(424242)
		game.wave = int(t[c["wave"]])
		_set_player(game, _player(golden, t[c["player"]]))
		game.rng.set_seed(int(t[c["seed"]]))
		var plan: EnemySpawnPlan = EnemyDirector.create_enemy_field_spawn_plan(game, 4)
		var where: String = "seed %s wave %s %s" % [t[c["seed"]], t[c["wave"]], t[c["player"]]]
		_add_int(mismatches, where + " draws", game.rng.draws, int(t[c["draws"]]))
		_add_text(mismatches, where + " pattern", plan.pattern, t[c["pattern"]])
		_add_float(mismatches, where + " baseAngle", plan.base_angle, t[c["base_angle"]])
		_add_float(mismatches, where + " radius", plan.radius, t[c["radius"]])
		_add_float(mismatches, where + " cx", plan.cx, t[c["cx"]])
		_add_float(mismatches, where + " cy", plan.cy, t[c["cy"]])
		_add_float(mismatches, where + " minRadius", plan.min_radius, t[c["min_radius"]])
		_add_float(mismatches, where + " maxRadius", plan.max_radius, t[c["max_radius"]])
		_add_float(mismatches, where + " minDistance", plan.min_distance, t[c["min_distance"]])
		_add_int(mismatches, where + " batchSize", plan.batch_size, int(t[c["batch_size"]]))
	assert_true((table["rows"] as Array).size() > 200, "many plans (%d)" % (table["rows"] as Array).size())
	assert_eq(mismatches.count, 0, mismatches.summary("createEnemyFieldSpawnPlan"))


func test_enemyFieldSpawnPoint_matches_the_original_for_the_four_formations_of_waves_1_to_6() -> void:
	var golden: Dictionary = _golden()
	var table: Dictionary = golden["points"]
	var c: Dictionary = _columns(table["columns"])
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	var game: GameState = null
	var plan: EnemySpawnPlan = null
	var patterns: Dictionary = {}
	for row: String in table["rows"]:
		var t: PackedStringArray = GoldenTable.tokens(row)
		var index: int = int(t[c["index"]])
		var where: String = "seed %s %s %s #%d" % [t[c["seed"]], t[c["player"]], t[c["pattern"]], index]
		if index == 0:
			game = _new_game(424242)
			game.wave = 3
			_set_player(game, _player(golden, t[c["player"]]))
			game.rng.set_seed(int(t[c["seed"]]))
			plan = EnemyDirector.create_enemy_field_spawn_plan(game, 4)
			plan.pattern = t[c["pattern"]]
			_add_int(mismatches, where + " plan draws", game.rng.draws, int(t[c["plan_draws"]]))
		patterns[t[c["pattern"]]] = true
		_add_int(mismatches, where + " draws before", game.rng.draws, int(t[c["draws_before"]]))
		var point: EnemySpawnPoint = EnemyDirector.enemy_field_spawn_point(game, plan, index, 28.0, 24.0)
		_add_int(mismatches, where + " draws after", game.rng.draws, int(t[c["draws_after"]]))
		_add_float(mismatches, where + " x", point.x, t[c["x"]])
		_add_float(mismatches, where + " y", point.y, t[c["y"]])
		_add_float(mismatches, where + " distance", point.distance, t[c["distance"]])
	assert_eq(patterns.size(), 4, "scatter, arc, pincer and line are all covered")
	assert_eq(mismatches.count, 0, mismatches.summary("enemyFieldSpawnPoint"))


func test_safePointAround_and_safeEnemySpawnPoint_match_the_original_including_the_fallbacks() -> void:
	var golden: Dictionary = _golden()
	var table: Dictionary = golden["safe_points"]
	var c: Dictionary = _columns(table["columns"])
	var around: Array = table["around"]
	var enemy: Array = table["enemy"]
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	var fallback_ring: int = 0
	for row: String in table["rows"]:
		var t: PackedStringArray = GoldenTable.tokens(row)
		var case_index: int = int(t[c["case"]])
		var game: GameState = _new_game(424242)
		game.rng.set_seed(int(t[c["seed"]]))
		var where: String = "%s case %d (seed %s)" % [t[c["kind"]], case_index, t[c["seed"]]]
		var result: EnemySpawnPoint
		if t[c["kind"]] == "around":
			var a: Dictionary = around[case_index]
			result = EnemyDirector.safe_point_around(game, GoldenCodec.from_hex(a["cx"]), GoldenCodec.from_hex(a["cy"]), GoldenCodec.from_hex(a["minR"]),
					GoldenCodec.from_hex(a["maxR"]), GoldenCodec.from_hex(a["pad"]), GoldenCodec.from_hex(a["minD"]), int(a["attempts"]))
			if game.rng.draws == 2 * int(a["attempts"]) and int(a["attempts"]) > 2:
				fallback_ring += 1
		else:
			var e: Dictionary = enemy[case_index]
			game.player.x = GoldenCodec.from_hex(e["px"])
			game.player.y = GoldenCodec.from_hex(e["py"])
			result = EnemyDirector.safe_enemy_spawn_point(game, game.player, GoldenCodec.from_hex(e["minR"]), GoldenCodec.from_hex(e["maxR"]),
					GoldenCodec.from_hex(e["pad"]), GoldenCodec.from_hex(e["minD"]), GoldenCodec.from_hex(e["body"]))
		_add_int(mismatches, where + " draws", game.rng.draws, int(t[c["draws"]]))
		_add_float(mismatches, where + " x", result.x, t[c["x"]])
		_add_float(mismatches, where + " y", result.y, t[c["y"]])
		_add_float(mismatches, where + " distance", result.distance, t[c["distance"]])
	assert_true(fallback_ring >= 2, "the cases reach the fallback ring of safePointAround (%d)" % fallback_ring)
	assert_eq(mismatches.count, 0, mismatches.summary("safePointAround / safeEnemySpawnPoint"))


# --- spawnEnemy ---------------------------------------------------------------------------------------------------------

func _check_enemy(mismatches: GoldenTable.Mismatches, where: String, e: EnemyState, golden: Dictionary, t: PackedStringArray, c: Dictionary) -> void:
	_add_int(mismatches, where + " id", e.id, int(t[c["id"]]))
	_add_text(mismatches, where + " kind", e.kind, t[c["kind"]])
	_add_int(mismatches, where + " spawnWave", e.spawn_wave, int(t[c["spawn_wave"]]))
	_add_int(mismatches, where + " strafeDir", e.strafe_dir, int(t[c["strafe_dir"]]))
	_add_text(mismatches, where + " aiState", e.ai_state, t[c["ai_state"]])
	for field_name: Variant in golden["enemy_numbers"]:
		var prop: String = SimTrace.snake_case(String(field_name))
		_add_float(mismatches, "%s %s" % [where, field_name], float(e.get(prop)), t[c[String(field_name)]])
	var constants: Dictionary = golden["enemy_constants"]
	for field_name: Variant in constants.keys():
		_add_float(mismatches, "%s %s (constant)" % [where, field_name], float(e.get(SimTrace.snake_case(String(field_name)))), String(constants[field_name]))


func test_spawnEnemy_builds_the_original_object_with_the_original_draws() -> void:
	var golden: Dictionary = _golden()
	var table: Dictionary = golden["spawn_enemy"]
	var c: Dictionary = _columns(table["columns"])
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	var game: GameState = null
	var plan: EnemySpawnPlan = null
	var checked: int = 0
	for row: String in table["rows"]:
		var t: PackedStringArray = GoldenTable.tokens(row)
		var index: int = int(t[c["index"]])
		var where: String = "seed %s wave %s %s %s #%d" % [t[c["seed"]], t[c["wave"]], t[c["player"]], t[c["kind"]], index]
		if index == 0:
			game = _new_game(424242)
			game.wave = int(t[c["wave"]])
			_set_player(game, _player(golden, t[c["player"]]))
			game.rng.set_seed(int(t[c["seed"]]))
			plan = EnemyDirector.create_enemy_field_spawn_plan(game, 4)
			_add_int(mismatches, where + " plan draws", game.rng.draws, int(t[c["plan_draws"]]))
			_add_text(mismatches, where + " pattern", plan.pattern, t[c["pattern"]])
		_add_int(mismatches, where + " draws before", game.rng.draws, int(t[c["draws_before"]]))
		assert_true(EnemyDirector.spawn_enemy(game, t[c["kind"]], plan, index), "%s: spawned" % where)
		_add_int(mismatches, where + " draws after", game.rng.draws, int(t[c["draws_after"]]))
		_add_int(mismatches, where + " nextEnemyId", game.next_enemy_id, int(t[c["next_enemy_id"]]))
		_add_int(mismatches, where + " enemiesVersion", game.enemies_version, int(t[c["enemies_version"]]))
		_check_enemy(mismatches, where, game.enemies[game.enemies.size() - 1], golden, t, c)
		checked += 1
	assert_true(checked > 80, "many enemies were built (%d)" % checked)
	assert_eq(mismatches.count, 0, mismatches.summary("spawnEnemy"))


# --- the kind picks -----------------------------------------------------------------------------------------------------

func test_the_kind_picks_follow_the_original_with_the_real_counts() -> void:
	var table: Dictionary = _golden()["picks"]
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	var assassins_picked: int = 0
	for sc: Dictionary in table["scenarios"]:
		var game: GameState = _new_game(int(sc["seed"]))
		game.wave = int(sc["wave"])
		WaveRules.prepare_enemy_wave_theme(game, game.wave)
		if String(sc["name"]).ends_with("_cap"):
			game.wave_spawn_theme.featured_kind = "assassin"
			game.wave_spawn_theme.base_kind = "assassin"
		var where: String = String(sc["name"])
		_add_text(mismatches, where + " featured kind of the theme", game.wave_spawn_theme.featured_kind, String(sc["theme_featured"]))
		_add_int(mismatches, where + " draws after the theme", game.rng.draws, int(sc["draws_at_start"]))
		for i: int in range(int(sc["assassins"])):
			var a: EnemyState = EnemyState.new()
			a.kind = "assassin"
			a.id = 1000 + i
			game.enemies.append(a)
		for i: int in range(int(sc["swarms"])):
			var s: EnemyState = EnemyState.new()
			s.kind = "swarm"
			s.id = 2000 + i
			game.enemies.append(s)
		var picks: Array = sc["picks"]
		for i: int in range(picks.size()):
			var t: PackedStringArray = GoldenTable.tokens(String(picks[i]))
			var before: int = game.rng.draws
			var kind: String = EnemyDirector.pick_wave_directed_enemy_kind(game)
			var step_where: String = "%s pick %d" % [where, i]
			_add_int(mismatches, step_where + " draws before", before, int(t[0]))
			_add_int(mismatches, step_where + " draws after", game.rng.draws, int(t[1]))
			_add_text(mismatches, step_where + " kind", _dash(kind), t[2])
			if kind != "":
				if kind == "assassin":
					assassins_picked += 1
				var e: EnemyState = EnemyState.new()
				e.kind = kind
				e.id = 3000 + i
				game.enemies.append(e)
				EnemyDirector.register_director_enemy_spawn(game, kind)
		var theme: EnemyWaveTheme = game.wave_spawn_theme
		var counts: PackedStringArray = PackedStringArray()
		for k: Variant in theme.counts.keys():
			counts.append("%s=%d" % [String(k), int(theme.counts[k])])
		_add_text(mismatches, where + " final counts", _dash(",".join(counts)), String(sc["final_theme_counts"]))
		_add_int(mismatches, where + " final total", theme.total_spawned, int(sc["final_total_spawned"]))
		_add_text(mismatches, where + " final recent mixed", _dash(",".join(theme.recent_mixed)), String(sc["final_recent_mixed"]))
	assert_true(assassins_picked > 10, "assassins are picked in some scenarios (%d)" % assassins_picked)
	assert_eq(mismatches.count, 0, mismatches.summary("pickWaveDirectedEnemyKind"))


# --- updateWave stepped -------------------------------------------------------------------------------------------------

func _wave_game(sc: Dictionary) -> GameState:
	var game: GameState = _new_game(int(sc["seed"]))
	if int(sc["wave"]) != 1:
		game.wave = int(sc["wave"])
		WaveRules.prepare_enemy_wave_theme(game, game.wave)
	if sc["theme"] != null:
		game.wave_spawn_theme.featured_kind = String(sc["theme"])
		game.wave_spawn_theme.base_kind = String(sc["theme"])
	if sc["wave_clock"] != null:
		game.wave_clock = float(sc["wave_clock"])
	if sc["spawn_budget"] != null:
		game.spawn_budget = float(sc["spawn_budget"])
	var fill: Variant = sc["fill"]
	if fill != null:
		var next_id: int = 5000
		for kind: Variant in (fill as Dictionary).keys():
			for i: int in range(int((fill as Dictionary)[kind])):
				var e: EnemyState = EnemyState.new()
				e.kind = String(kind)
				e.id = next_id
				next_id += 1
				game.enemies.append(e)
	return game


func _history(game: GameState) -> String:
	return _dash(",".join(game.featured_enemy_history))


func _compare_wave_row(mismatches: GoldenTable.Mismatches, where: String, game: GameState, t: PackedStringArray, c: Dictionary) -> void:
	_add_int(mismatches, where + " draws", game.rng.draws, int(t[c["draws"]]))
	_add_int(mismatches, where + " wave", game.wave, int(t[c["wave"]]))
	_add_float(mismatches, where + " waveClock", game.wave_clock, t[c["wave_clock"]])
	_add_float(mismatches, where + " directorClock", game.director_clock, t[c["director_clock"]])
	_add_float(mismatches, where + " spawnBudget", game.spawn_budget, t[c["spawn_budget"]])
	_add_int(mismatches, where + " nextEnemyId", game.next_enemy_id, int(t[c["next_enemy_id"]]))
	_add_int(mismatches, where + " enemies", game.enemies.size(), int(t[c["enemies"]]))
	_add_int(mismatches, where + " enemiesVersion", game.enemies_version, int(t[c["enemies_version"]]))
	_add_text(mismatches, where + " pendingDirectorEnemyKind", _dash(game.pending_director_enemy_kind), t[c["pending_kind"]])
	_add_float(mismatches, where + " waveFeaturedChangeChance", game.wave_featured_change_chance, t[c["featured_change_chance"]])
	_add_int(mismatches, where + " enemyAiTier", game.enemy_ai_tier, int(t[c["ai_tier"]]))
	_add_float(mismatches, where + " enemyAiSkill", game.enemy_ai_skill, t[c["ai_skill"]])
	_add_float(mismatches, where + " rawScore", game.raw_score, t[c["raw_score"]])
	var scored: PackedStringArray = PackedStringArray()
	for w: Variant in game.scored_waves.keys():
		scored.append(str(w))
	_add_int(mismatches, where + " scoredWaves", game.scored_waves.size(), int(t[c["scored_waves"]]))
	_add_text(mismatches, where + " scoredWaves list", _dash(",".join(scored)), t[c["scored_wave_list"]])
	var theme: EnemyWaveTheme = game.wave_spawn_theme
	if theme == null:
		_add_int(mismatches, where + " themeWave", 0, int(t[c["theme_wave"]]))
	else:
		var counts: PackedStringArray = PackedStringArray()
		for k: Variant in theme.counts.keys():
			counts.append("%s=%d" % [String(k), int(theme.counts[k])])
		_add_int(mismatches, where + " themeWave", theme.wave, int(t[c["theme_wave"]]))
		_add_text(mismatches, where + " themeBase", theme.base_kind, t[c["theme_base"]])
		_add_text(mismatches, where + " themeFeatured", theme.featured_kind, t[c["theme_featured"]])
		_add_int(mismatches, where + " themeChanged", 1 if theme.changed else 0, 1 if t[c["theme_changed"]] == "1" else 0)
		_add_float(mismatches, where + " themeChangeChance", theme.change_chance, t[c["theme_change_chance"]])
		_add_int(mismatches, where + " themeTotal", theme.total_spawned, int(t[c["theme_total"]]))
		_add_text(mismatches, where + " themeCounts", _dash(",".join(counts)), t[c["theme_counts"]])
		_add_text(mismatches, where + " themeRecent", _dash(",".join(theme.recent_mixed)), t[c["theme_recent"]])
	_add_text(mismatches, where + " featuredEnemyHistory", _history(game), t[c["history"]])


func test_updateWave_stepped_matches_the_original_through_spawns_wave_changes_corners_and_full_lists() -> void:
	var golden: Dictionary = _golden()
	var waves: Dictionary = golden["waves"]
	var rc: Dictionary = _columns(waves["row_columns"])
	var sc_cols: Dictionary = _columns(waves["spawned_columns"])
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	var total_steps: int = 0
	var total_spawned: int = 0
	var wave_changes: int = 0
	for sc: Dictionary in waves["scenarios"]:
		var game: GameState = _wave_game(sc)
		var system: WaveProgressSystem = WaveProgressSystem.new(game)
		var steps: int = int(sc["steps"])
		var draws: PackedInt32Array = GoldenCodec.decode_i32(String(sc["draws"]))
		assert_eq(draws.size(), steps, "%s: a draw count per step" % sc["name"])
		var players: PackedFloat64Array = PackedFloat64Array()
		if sc["players"] != null:
			players = GoldenCodec.decode_f64(String(sc["players"]))
		var fixed: Array = []
		if sc["player_at"] != null:
			for token: Variant in sc["player_at"]:
				fixed.append(GoldenCodec.from_hex(String(token)))
		var rows_by_step: Dictionary = {}
		for row: String in sc["rows"]:
			rows_by_step[int(GoldenTable.tokens(row)[rc["step"]])] = row
		var spawned_by_step: Dictionary = {}
		for row: String in sc["spawned"]:
			var step_number: int = int(GoldenTable.tokens(row)[sc_cols["step"]])
			if not spawned_by_step.has(step_number):
				spawned_by_step[step_number] = []
			(spawned_by_step[step_number] as Array).append(row)
		var resets: Dictionary = {}
		for r: Array in sc["wave_clock_resets"]:
			resets[int(r[0])] = GoldenCodec.from_hex(String(r[1]))
		var known: int = game.enemies.size()
		for step: int in range(1, steps + 1):
			if resets.has(step):
				game.wave_clock = resets[step]
			var p: PlayerState = game.player
			if players.size() > 0:
				p.x = players[(step - 1) * 4]
				p.y = players[(step - 1) * 4 + 1]
				p.vx = players[(step - 1) * 4 + 2]
				p.vy = players[(step - 1) * 4 + 3]
			else:
				p.x = fixed[0]
				p.y = fixed[1]
				p.vx = fixed[2]
				p.vy = fixed[3]
			game.t += DT
			var wave_before: int = game.wave
			system.run(DT)
			if game.wave != wave_before:
				wave_changes += 1
			var where: String = "%s step %d" % [sc["name"], step]
			_add_int(mismatches, where + " draws", game.rng.draws, draws[step - 1])
			var spawned_rows: Array = spawned_by_step.get(step, [])
			_add_int(mismatches, where + " spawned", game.enemies.size() - known, spawned_rows.size())
			for i: int in range(mini(spawned_rows.size(), game.enemies.size() - known)):
				var t: PackedStringArray = GoldenTable.tokens(String(spawned_rows[i]))
				_check_spawned(mismatches, "%s enemy #%d" % [where, i], game.enemies[known + i], golden, t, sc_cols)
				total_spawned += 1
			known = game.enemies.size()
			if rows_by_step.has(step):
				_compare_wave_row(mismatches, where, game, GoldenTable.tokens(String(rows_by_step[step])), rc)
		total_steps += steps
	assert_true(total_steps > 3000, "many steps (%d)" % total_steps)
	assert_true(total_spawned > 80, "many spawned enemies were compared (%d)" % total_spawned)
	assert_true(wave_changes >= 2, "the scenarios change the wave (%d times)" % wave_changes)
	assert_eq(mismatches.count, 0, mismatches.summary("updateWave"))


func _check_spawned(mismatches: GoldenTable.Mismatches, where: String, e: EnemyState, golden: Dictionary, t: PackedStringArray, c: Dictionary) -> void:
	_add_int(mismatches, where + " id", e.id, int(t[c["id"]]))
	_add_text(mismatches, where + " kind", e.kind, t[c["kind"]])
	_add_int(mismatches, where + " spawnWave", e.spawn_wave, int(t[c["spawn_wave"]]))
	_add_int(mismatches, where + " strafeDir", e.strafe_dir, int(t[c["strafe_dir"]]))
	_add_text(mismatches, where + " aiState", e.ai_state, t[c["ai_state"]])
	for field_name: Variant in golden["enemy_numbers"]:
		_add_float(mismatches, "%s %s" % [where, field_name], float(e.get(SimTrace.snake_case(String(field_name)))), t[c[String(field_name)]])


func test_the_m1_prototype_ends_the_run_when_the_clock_of_wave_4_runs_out() -> void:
	# Not in the original (it starts wave 5, an elite wave): see WaveRules.M1_LAST_WAVE. The clear of wave 4 is scored, the run ends as a win.
	var game: GameState = _new_game(5)
	game.wave = 4
	WaveRules.prepare_enemy_wave_theme(game, 4)
	game.wave_clock = DT
	var system: WaveProgressSystem = WaveProgressSystem.new(game)
	var raw_before: float = game.raw_score
	system.run(DT)
	assert_eq(game.wave, 4, "the wave does not advance")
	assert_true(game.ended, "the run has ended")
	assert_true(game.run_won, "as a win")
	assert_eq(game.state, GameState.RunState.ENDED, "state ended")
	assert_eq(game.raw_score, raw_before + 400.0, "wave 4 is scored: floor(100 * 4)")
	# a wave before the last advances as usual
	var other: GameState = _new_game(5)
	other.wave = 3
	WaveRules.prepare_enemy_wave_theme(other, 3)
	other.wave_clock = DT
	WaveProgressSystem.new(other).run(DT)
	assert_eq(other.wave, 4, "wave 3 advances to wave 4")
	assert_false(other.ended, "the run goes on")
	assert_eq(other.wave_clock, 36.0, "a new wave has WAVE_DURATION")


# --- cleanup and kills --------------------------------------------------------------------------------------------------

func test_cleanupDeadEnemies_and_killEnemy_match_the_original() -> void:
	var table: Dictionary = _golden()["cleanup"]
	var ic: Dictionary = _columns(table["input_columns"])
	var oc: Dictionary = _columns(table["orb_columns"])
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	var merged: bool = false
	for sc: Dictionary in table["scenarios"]:
		var game: GameState = _new_game(424242)
		game.limits = SimLimits.new(true)
		game.limits.max_xp_orbs = int(sc["max_orbs"])
		game.rng.set_seed(int(sc["seed"]))
		game.wave = 2
		for row: Variant in sc["input"]:
			var t: PackedStringArray = GoldenTable.tokens(String(row))
			var e: EnemyState = EnemyState.new()
			e.id = int(t[ic["id"]])
			e.kind = t[ic["kind"]]
			e.x = GoldenCodec.from_hex(t[ic["x"]])
			e.y = GoldenCodec.from_hex(t[ic["y"]])
			e.hp = GoldenCodec.from_hex(t[ic["hp"]])
			e.xp = GoldenCodec.from_hex(t[ic["xp"]])
			e.spawn_wave = int(t[ic["spawn_wave"]])
			game.enemies.append(e)
		EnemyLifecycle.cleanup_dead_enemies(game)
		var where: String = String(sc["name"])
		_add_int(mismatches, where + " draws", game.rng.draws, int(sc["draws"]))
		_add_int(mismatches, where + " kills", game.kills, int(sc["kills"]))
		_add_float(mismatches, where + " rawScore", game.raw_score, String(sc["raw_score"]))
		_add_int(mismatches, where + " enemiesVersion", game.enemies_version, int(sc["enemies_version"]))
		_add_int(mismatches, where + " xpMergeCursor", game.xp_merge_cursor, int(sc["merge_cursor"]))
		var ids: PackedStringArray = PackedStringArray()
		for e: EnemyState in game.enemies:
			ids.append(str(e.id))
		_add_text(mismatches, where + " ids", _dash(",".join(ids)), String(sc["ids"]))
		var orbs: Array = sc["orbs"]
		_add_int(mismatches, where + " orbs", game.xp_orbs.size(), orbs.size())
		for i: int in range(mini(orbs.size(), game.xp_orbs.size())):
			var t: PackedStringArray = GoldenTable.tokens(String(orbs[i]))
			_add_float(mismatches, "%s orb %d x" % [where, i], game.xp_orbs[i].x, t[oc["x"]])
			_add_float(mismatches, "%s orb %d y" % [where, i], game.xp_orbs[i].y, t[oc["y"]])
			_add_float(mismatches, "%s orb %d value" % [where, i], game.xp_orbs[i].value, t[oc["value"]])
			_add_float(mismatches, "%s orb %d r" % [where, i], game.xp_orbs[i].r, t[oc["r"]])
		if int(sc["merge_cursor"]) != 0:
			merged = true
	assert_true(merged, "a scenario merges orbs at the cap")
	assert_eq(mismatches.count, 0, mismatches.summary("cleanupDeadEnemies"))


# --- the grid -----------------------------------------------------------------------------------------------------------

func _id_list(list: Array[EnemyState]) -> String:
	var ids: PackedStringArray = PackedStringArray()
	for e: EnemyState in list:
		ids.append(str(e.id))
	return _dash(",".join(ids))


func test_the_enemy_grid_and_its_queries_match_the_original() -> void:
	var table: Dictionary = _golden()["grid"]
	var ec: Dictionary = _columns(table["enemy_columns"])
	var qc: Dictionary = _columns(table["query_columns"])
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	var queries: int = 0
	var nonempty: int = 0
	for sc: Dictionary in table["scenarios"]:
		var game: GameState = _new_game(424242)
		for row: Variant in sc["input"]:
			var t: PackedStringArray = GoldenTable.tokens(String(row))
			var e: EnemyState = EnemyState.new()
			e.id = int(t[ec["id"]])
			e.x = GoldenCodec.from_hex(t[ec["x"]])
			e.y = GoldenCodec.from_hex(t[ec["y"]])
			e.hp = GoldenCodec.from_hex(t[ec["hp"]])
			game.enemies.append(e)
		var stages: Array = sc["stages"]
		for s: int in range(stages.size()):
			var stage: Dictionary = stages[s]
			match String(stage["label"]):
				"after_rebuild", "after_second_rebuild":
					game.enemy_grid.rebuild(game.enemies)
				"stale_after_moves_and_deaths":
					for e: EnemyState in game.enemies:
						if e.id % 4 == 0:
							e.x += 150.0
							e.y -= 90.0
						if e.id % 7 == 0:
							e.hp = 0.0
				"after_swap_and_spawn":
					game.enemies.remove_at(3)
					var spawn: EnemyState = EnemyState.new()
					spawn.id = 1000
					spawn.x = 12500.0
					spawn.y = 12500.0
					spawn.hp = 10.0
					game.enemies.append(spawn)
					game.enemy_grid.rebuild(game.enemies)
			var label: String = "%s/%s" % [sc["name"], stage["label"]]
			_add_int(mismatches, label + " grid.size", game.enemy_grid.size(), int(stage["size"]))
			var scratch: Array[EnemyState] = []
			for q: int in range((stage["queries"] as Array).size()):
				var t: PackedStringArray = GoldenTable.tokens(String(stage["queries"][q]))
				var cx: float = GoldenCodec.from_hex(t[qc["cx"]])
				var cy: float = GoldenCodec.from_hex(t[qc["cy"]])
				var r: float = GoldenCodec.from_hex(t[qc["r"]])
				var margin: int = int(t[qc["cell_margin"]])
				var circle: Array[EnemyState] = game.query_enemies_circle_broad(cx, cy, r, scratch, margin)
				var where: String = "%s query %d" % [label, q]
				var got_circle: String = _id_list(circle)
				_add_text(mismatches, where + " circle", got_circle, t[qc["circle_ids"]])
				var box: Array[EnemyState] = game.query_enemies_aabb(cx - r, cy - r * 0.5, cx + r * 1.5, cy + r, scratch, margin)
				_add_text(mismatches, where + " aabb", _id_list(box), t[qc["aabb_ids"]])
				var nearest: EnemyState = game.nearest_enemy(cx, cy, r)
				_add_int(mismatches, where + " nearest", nearest.id if nearest != null else 0, int(t[qc["nearest_id"]]))
				queries += 1
				if got_circle != "-":
					nonempty += 1
	assert_true(queries > 400, "many queries (%d)" % queries)
	assert_true(nonempty > 150, "many queries found enemies (%d)" % nonempty)
	assert_eq(mismatches.count, 0, mismatches.summary("enemy grid"))


# --- the shape of the enemy object --------------------------------------------------------------------------------------

func test_EnemyState_has_every_own_key_of_the_original_enemy_object_and_documents_the_rest() -> void:
	var golden: Dictionary = _golden()
	var names: Dictionary = SimTrace.script_variables(EnemyState.new())
	var from_original: Dictionary = {}
	for key: Variant in golden["enemy_keys"]:
		var prop: String = SimTrace.snake_case(String(key))
		from_original[prop] = true
		assert_true(names.has(prop), "EnemyState.%s exists for the original's key '%s'" % [prop, key])
	assert_eq((golden["enemy_keys"] as Array).size(), 75, "the original builds a swarm or an assassin with 75 own keys")
	# what else EnemyState has: keys that enemySpec leaves out for these kinds (read with `||`), and keys the game adds later
	var extras: Array[String] = []
	for prop: Variant in names.keys():
		if not from_original.has(prop):
			extras.append(String(prop))
	extras.sort()
	var expected: Array[String] = ["boss", "cat_bounce_seen_at", "defer_strata_auto", "elite", "last_damage_weapon_id", "preferred_special", "prev_x", "prev_y", "shield", "shoot"]
	assert_eq(extras, expected, "EnemyState has these fields beyond spawnEnemy's literal: absent-by-default spec keys and the keys the game adds later")
	# the nested objects
	var status_names: Dictionary = SimTrace.script_variables(EnemyStatus.new())
	var status_keys: Array = golden["status_keys"]
	assert_eq(status_names.size(), status_keys.size(), "EnemyStatus has the original's 17 status values and no more")
	for key: Variant in status_keys:
		assert_true(status_names.has(SimTrace.snake_case(String(key))), "EnemyStatus.%s" % SimTrace.snake_case(String(key)))
	var special_names: Dictionary = SimTrace.script_variables(EnemySpecialState.new())
	var special_keys: Array = golden["special_state_keys"]
	assert_eq(special_names.size(), special_keys.size(), "EnemySpecialState has the original's 4 keys")
	for key: Variant in special_keys:
		assert_true(special_names.has(SimTrace.snake_case(String(key))), "EnemySpecialState.%s" % SimTrace.snake_case(String(key)))


func test_Math_PI_of_the_director_is_the_double_of_the_original() -> void:
	assert_eq(GoldenCodec.hex_of(EnemyDirector.MATH_PI), "400921fb54442d18", "Math.PI bits")
	assert_true(GoldenCodec.same_double(EnemyDirector.MATH_PI, PI), "the engine's PI is the same double")
