extends "res://tests/test_case.gd"
## The formulas of step S3 against values that tools/golden/defs_formulas.mjs computed by running the ORIGINAL functions
## (enemySpec, gainXp / collectXp, weaponDamage / weaponInterval, the wave predicates and prepareEnemyWaveTheme, inputVector,
## followPlayerWithCamera). Every double is compared bit for bit.

const SPEC_KEYS: PackedStringArray = [
	"r", "hp", "speed", "damage", "xp", "armor", "evasion", "shoot", "shield",
	"projectileSpeedMul", "actionCooldownMul", "abilityCooldownMul",
]


func _golden() -> Dictionary:
	return GoldenCodec.load_json("formulas")


func _new_sim(difficulty: String = "normal", mode: String = "normal", rng_seed: int = 424242) -> Sim:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = rng_seed
	config.difficulty = difficulty
	config.mode = mode
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game")
	return sim


func _spec_field(spec: EnemySpec, key: String) -> float:
	match key:
		"r":
			return spec.r
		"hp":
			return spec.hp
		"speed":
			return spec.speed
		"damage":
			return spec.damage
		"xp":
			return spec.xp
		"armor":
			return spec.armor
		"evasion":
			return spec.evasion
		"shoot":
			return spec.shoot
		"shield":
			return spec.shield
		"projectileSpeedMul":
			return spec.projectile_speed_mul
		"actionCooldownMul":
			return spec.action_cooldown_mul
		"abilityCooldownMul":
			return spec.ability_cooldown_mul
	push_error("unknown spec key %s" % key)
	return 0.0


func test_enemy_spec_matches_the_original() -> void:
	var section: Dictionary = _golden()["enemy_spec"]
	assert_eq(Array(section["numeric_keys"]), Array(SPEC_KEYS), "the golden's numeric keys")
	var total: int = 0
	for scenario: Dictionary in section["scenarios"]:
		var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		var stat_mult: float = GoldenTable.f(scenario["enemyStatMult"])
		var speed_mult: float = GoldenTable.f(scenario["enemySpeedMult"])
		var contract: float = GoldenTable.f(scenario["contractEnemyStatMul"])
		for row: String in scenario["rows"]:
			var t: PackedStringArray = GoldenTable.tokens(row)
			var kind_in: String = t[0]
			var wave: int = int(t[1])
			var spec: EnemySpec = Formulas.enemy_spec(kind_in, wave, scenario["difficulty"], scenario["mode"], stat_mult, speed_mult, contract)
			var where: String = "%s/%s/w%d" % [scenario["name"], kind_in, wave]
			mismatches.checked += 1
			if spec.kind != t[2] or spec.color != t[3]:
				mismatches.add("%s: kind/color %s %s, original %s %s" % [where, spec.kind, spec.color, t[2], t[3]])
			var flags: int = int(t[4])
			if spec.elite != ((flags & 1) != 0) or spec.boss != ((flags & 2) != 0):
				mismatches.add("%s: elite/boss flags differ" % where)
			var mask: int = int(t[5])
			var next_value: int = 6
			for i: int in SPEC_KEYS.size():
				var actual: float = _spec_field(spec, SPEC_KEYS[i])
				var expected: float = 0.0  # a key the original leaves out reads as 0 (`if (s.shield)`)
				if (mask & (1 << i)) != 0:
					expected = GoldenTable.f(t[next_value])
					next_value += 1
				mismatches.checked += 1
				if not GoldenCodec.same_double(actual, expected):
					mismatches.add("%s.%s: port %s, original %s" % [where, SPEC_KEYS[i], GoldenTable.show(actual), GoldenTable.show(expected)])
			total += 1
		assert_eq(mismatches.count, 0, mismatches.summary("enemy_spec scenario " + String(scenario["name"])))
	assert_true(total > 900, "enough enemySpec cases (%d)" % total)


func test_enemy_spec_for_game_reads_the_game_fields() -> void:
	var sim: Sim = _new_sim("hard", "endless")
	sim.game.enemy_stat_mult = 2.5
	sim.game.enemy_speed_mult = 1.2
	var from_game: EnemySpec = Formulas.enemy_spec_for_game("tank", 12, sim.game)
	var direct: EnemySpec = Formulas.enemy_spec("tank", 12, "hard", "endless", 2.5, 1.2, 1.0)
	assert_true(GoldenCodec.same_double(from_game.hp, direct.hp), "hp")
	assert_true(GoldenCodec.same_double(from_game.speed, direct.speed), "speed")
	assert_true(from_game.hp > Formulas.enemy_spec("tank", 12, "hard", "normal", 1.0, 1.0, 1.0).hp, "endless multipliers raise hp")


func test_xp_curve_matches_the_original() -> void:
	var section: Dictionary = _golden()["xp"]
	var initial: Dictionary = section["initial"]
	assert_true(GoldenCodec.same_double(Formulas.initial_xp_base_next(), GoldenCodec.from_hex(initial["xpBaseNext"])), "xpBaseNext of newGame")
	assert_true(GoldenCodec.same_double(Formulas.initial_xp_next(), GoldenCodec.from_hex(initial["xpNext"])), "xpNext of newGame")

	# every level: feed exactly the requirement
	var sim: Sim = _new_sim()
	var levels: Array = section["levels"]
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	_check_xp_row(sim.game, String(levels[0]), "start", mismatches)
	for i: int in range(1, levels.size()):
		sim.game.gain_xp(sim.game.player.xp_next)
		_check_xp_row(sim.game, String(levels[i]), "level %d" % (i + 1), mismatches)
	assert_eq(mismatches.count, 0, mismatches.summary("XP requirement per level"))

	for script: Dictionary in section["sequences"]:
		var sequence_sim: Sim = _new_sim()
		var sequence_mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		var rows: Array = script["rows"]
		var gains: Array = script["gains"]
		_check_xp_row(sequence_sim.game, String(rows[0]), "start", sequence_mismatches)
		for i: int in gains.size():
			sequence_sim.game.gain_xp(GoldenCodec.from_hex(gains[i]))
			_check_xp_row(sequence_sim.game, String(rows[i + 1]), "gain %d" % i, sequence_mismatches)
		assert_eq(sequence_mismatches.count, 0, sequence_mismatches.summary("XP sequence " + String(script["name"])))

	for scenario: Dictionary in section["collect"]:
		var collect_sim: Sim = _new_sim(scenario["difficulty"])
		var collect_mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		var collect_rows: Array = scenario["rows"]
		var values: Array = scenario["values"]
		_check_xp_row(collect_sim.game, String(collect_rows[0]), "start", collect_mismatches)
		for i: int in values.size():
			collect_sim.game.collect_xp(GoldenCodec.from_hex(values[i]))
			_check_xp_row(collect_sim.game, String(collect_rows[i + 1]), "collect %d" % i, collect_mismatches)
		assert_eq(collect_mismatches.count, 0, collect_mismatches.summary("collectXp on " + String(scenario["difficulty"])))


func _check_xp_row(game: GameState, row: String, where: String, mismatches: GoldenTable.Mismatches) -> void:
	var t: PackedStringArray = GoldenTable.tokens(row)
	var p: PlayerState = game.player
	mismatches.checked += 1
	if p.level != int(t[0]):
		mismatches.add("%s: level %d, original %s" % [where, p.level, t[0]])
	var pairs: Array = [["xp", p.xp, t[1]], ["xpBaseNext", p.xp_base_next, t[2]], ["xpNext", p.xp_next, t[3]]]
	for pair: Array in pairs:
		mismatches.checked += 1
		var expected: float = GoldenTable.f(pair[2])
		if not GoldenCodec.same_double(float(pair[1]), expected):
			mismatches.add("%s.%s: port %s, original %s" % [where, pair[0], GoldenTable.show(float(pair[1])), GoldenTable.show(expected)])
	mismatches.checked += 1
	if game.pending_level_ups != int(t[4]) or game.pending_level_numbers.size() != int(t[5]):
		mismatches.add("%s: pending %d/%d, original %s/%s" % [where, game.pending_level_ups, game.pending_level_numbers.size(), t[4], t[5]])
	var last: int = game.pending_level_numbers[game.pending_level_numbers.size() - 1] if game.pending_level_numbers.size() > 0 else 0
	mismatches.checked += 1
	if last != int(t[6]):
		mismatches.add("%s: last pending level %d, original %s" % [where, last, t[6]])


func test_weapon_damage_matches_the_original() -> void:
	var rows: Array = _golden()["weapon"]["damage"]
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	for row: String in rows:
		var t: PackedStringArray = GoldenTable.tokens(row)
		var actual: float = Formulas.weapon_damage(t[0], int(t[1]))
		var expected: float = GoldenTable.f(t[2])
		mismatches.checked += 1
		if not GoldenCodec.same_double(actual, expected):
			mismatches.add("%s L%s: port %s, original %s" % [t[0], t[1], GoldenTable.show(actual), GoldenTable.show(expected)])
	assert_eq(mismatches.count, 0, mismatches.summary("weaponDamage"))
	assert_eq(rows.size(), 24 * 15, "24 weapons x 15 levels")


func test_weapon_interval_matches_the_original() -> void:
	var scenarios: Array = _golden()["weapon"]["interval_scenarios"]
	var cases: int = 0
	for scenario: Dictionary in scenarios:
		var sim: Sim = _new_sim()
		sim.game.player.attack_speed = GoldenCodec.from_hex(scenario["attackSpeed"])
		sim.game.specials.final_bonus_cooldown = float(scenario["cooldownStacks"])
		var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		for row: String in scenario["rows"]:
			var t: PackedStringArray = GoldenTable.tokens(row)
			var weapon: WeaponState = WeaponState.new()
			weapon.id = t[0]
			weapon.level = int(t[1])
			var interval: float = Formulas.weapon_interval(weapon, sim.game)
			var raw: float = Formulas.weapon_raw_interval(weapon, sim.game)
			mismatches.checked += 2
			cases += 1
			if not GoldenCodec.same_double(interval, GoldenTable.f(t[2])):
				mismatches.add("%s L%s interval: port %s, original %s" % [t[0], t[1], GoldenTable.show(interval), GoldenTable.show(GoldenTable.f(t[2]))])
			if not GoldenCodec.same_double(raw, GoldenTable.f(t[3])):
				mismatches.add("%s L%s raw: port %s, original %s" % [t[0], t[1], GoldenTable.show(raw), GoldenTable.show(GoldenTable.f(t[3]))])
		assert_eq(mismatches.count, 0, mismatches.summary("weaponInterval scenario " + String(scenario["name"])))
	assert_true(cases > 400, "enough weaponInterval cases (%d)" % cases)
	# the numbers the analysis quotes for the catalytic ring
	var ring_sim: Sim = _new_sim()
	var ring: WeaponState = ring_sim.game.weapons[0]
	assert_eq(ring.id, "catalytic_ring", "the starting weapon")
	assert_eq(Formulas.weapon_interval(ring, ring_sim.game), 0.84, "catalytic ring level 1")


func test_wave_predicates_match_the_original() -> void:
	var section: Dictionary = _golden()["waves"]
	for mode: String in ["normal", "endless"]:
		var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		for row: String in section["predicates"][mode]:
			var t: PackedStringArray = GoldenTable.tokens(row)
			var wave: int = int(t[0])
			mismatches.checked += 4
			if WaveRules.is_elite_wave(wave, mode) != GoldenTable.b(t[1]):
				mismatches.add("%s w%d: elite" % [mode, wave])
			if WaveRules.is_boss_wave(wave, mode) != GoldenTable.b(t[2]):
				mismatches.add("%s w%d: boss" % [mode, wave])
			if WaveRules.is_special_wave(wave, mode) != GoldenTable.b(t[3]):
				mismatches.add("%s w%d: special" % [mode, wave])
			var featured: String = WaveRules.progression_featured_enemy_kind(wave, mode)
			if featured != t[4]:
				mismatches.add("%s w%d: featured kind %s, original %s" % [mode, wave, featured, t[4]])
		assert_eq(mismatches.count, 0, mismatches.summary("wave predicates in " + mode))
	var unlock_mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	for row: String in section["unlock"]:
		var t: PackedStringArray = GoldenTable.tokens(row)
		var actual: float = WaveRules.enemy_archetype_unlock_wave(t[0])
		unlock_mismatches.checked += 1
		if not GoldenCodec.same_double(actual, GoldenTable.f(t[1])):
			unlock_mismatches.add("%s: port %s, original %s" % [t[0], GoldenTable.show(actual), GoldenTable.show(GoldenTable.f(t[1]))])
	assert_eq(unlock_mismatches.count, 0, unlock_mismatches.summary("enemyArchetypeUnlockWave"))


func test_wave_theme_draws_match_the_original() -> void:
	var section: Dictionary = _golden()["waves"]["theme"]
	var total_draws: int = 0
	for run: Dictionary in section["runs"]:
		var sim: Sim = _new_sim()
		var game: GameState = sim.game
		game.rng.set_seed(int(run["seed"]))
		game.featured_enemy_history = PackedStringArray()
		game.wave_featured_change_chance = GoldenCodec.from_hex(run["waveFeaturedChangeChance"])
		game.wave_spawn_theme = null
		var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		for row: String in run["rows"]:
			var t: PackedStringArray = GoldenTable.tokens(row)
			var wave: int = int(t[0])
			game.pending_director_enemy_kind = "stale"
			game.pending_director_composition = {"stale": true}
			var before: int = game.rng.draws
			var theme: EnemyWaveTheme = WaveRules.prepare_enemy_wave_theme(game, wave)
			var where: String = "seed %s chance %s w%d" % [run["seed"], run["waveFeaturedChangeChance"], wave]
			mismatches.checked += 1
			if game.rng.draws - before != int(t[1]):
				mismatches.add("%s: %d draws, original %s" % [where, game.rng.draws - before, t[1]])
			if game.pending_director_enemy_kind != "" or game.pending_director_composition != null:
				mismatches.add("%s: pending director kind/composition not reset" % where)
			var history: String = ",".join(game.featured_enemy_history) if game.featured_enemy_history.size() > 0 else "-"
			if history != t[7]:
				mismatches.add("%s: history %s, original %s" % [where, history, t[7]])
			if GoldenTable.b(t[2]):
				if theme == null or game.wave_spawn_theme != theme:
					mismatches.add("%s: no theme" % where)
				else:
					if theme.wave != wave or theme.base_kind != t[3] or theme.featured_kind != t[4] or theme.changed != GoldenTable.b(t[5]):
						mismatches.add("%s: theme %s/%s/%s, original %s/%s/%s" % [where, theme.base_kind, theme.featured_kind, theme.changed, t[3], t[4], t[5]])
					if not GoldenCodec.same_double(theme.change_chance, GoldenTable.f(t[6])):
						mismatches.add("%s: change chance" % where)
					if not GoldenCodec.same_double(theme.featured_share, 0.5) or theme.total_spawned != 0 or not theme.counts.is_empty():
						mismatches.add("%s: fresh theme fields" % where)
			elif theme != null or game.wave_spawn_theme != null:
				mismatches.add("%s: a special wave has no theme" % where)
		assert_eq(mismatches.count, 0, mismatches.summary("wave theme run"))
		assert_eq(game.rng.draws, int(run["total_draws"]), "total draws of seed %s" % run["seed"])
		total_draws += game.rng.draws
	assert_true(total_draws > 40, "the runs draw (%d)" % total_draws)


func test_input_vector_matches_the_original() -> void:
	var section: Dictionary = _golden()["input_vector"]
	var input: SimInput = SimInput.new()
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	for row: String in section["subsets"]:
		var t: PackedStringArray = GoldenTable.tokens(row)
		_set_keys(input, t[0])
		input.move_x = 0.0
		input.move_y = 0.0
		_check_vector(input, GoldenTable.f(t[1]), GoldenTable.f(t[2]), "keys " + t[0], mismatches)
	assert_eq(mismatches.count, 0, mismatches.summary("inputVector over every key subset"))
	var combo_mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	for row: String in section["combos"]:
		var t: PackedStringArray = GoldenTable.tokens(row)
		_set_keys(input, t[0])
		input.move_x = GoldenTable.f(t[1])
		input.move_y = GoldenTable.f(t[2])
		_check_vector(input, GoldenTable.f(t[3]), GoldenTable.f(t[4]), "keys %s stick %s %s" % [t[0], t[1], t[2]], combo_mismatches)
	assert_eq(combo_mismatches.count, 0, combo_mismatches.summary("inputVector with the stick"))
	assert_eq((section["subsets"] as Array).size(), 256, "all 256 subsets of the 8 key names")


func _set_keys(input: SimInput, keys_token: String) -> void:
	var keys: PackedStringArray = PackedStringArray() if keys_token == "-" else keys_token.split(",")
	input.key_left = keys.has("KeyA") or keys.has("ArrowLeft")
	input.key_right = keys.has("KeyD") or keys.has("ArrowRight")
	input.key_up = keys.has("KeyW") or keys.has("ArrowUp")
	input.key_down = keys.has("KeyS") or keys.has("ArrowDown")


func _check_vector(input: SimInput, expected_x: float, expected_y: float, where: String, mismatches: GoldenTable.Mismatches) -> void:
	input.resolve()
	mismatches.checked += 1
	if not GoldenCodec.same_double(input.out_x, expected_x) or not GoldenCodec.same_double(input.out_y, expected_y):
		mismatches.add("%s: port (%s, %s), original (%s, %s)" % [where, GoldenTable.show(input.out_x), GoldenTable.show(input.out_y), GoldenTable.show(expected_x), GoldenTable.show(expected_y)])


func test_camera_follow_matches_the_original() -> void:
	var scripts: Array = _golden()["camera"]["scripts"]
	assert_eq(scripts.size(), 4, "four camera scripts")
	for script: Dictionary in scripts:
		var sim: Sim = _new_sim()
		var game: GameState = sim.game
		game.camera.x = GoldenCodec.from_hex(script["cam_x"])
		game.camera.y = GoldenCodec.from_hex(script["cam_y"])
		var system: CameraFollowSystem = CameraFollowSystem.new(game)
		var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		var step: int = 0
		for row: String in script["rows"]:
			var t: PackedStringArray = GoldenTable.tokens(row)
			game.player.x = GoldenTable.f(t[1])
			game.player.y = GoldenTable.f(t[2])
			system.run(GoldenTable.f(t[0]))
			mismatches.checked += 1
			if not GoldenCodec.same_double(game.camera.x, GoldenTable.f(t[3])) or not GoldenCodec.same_double(game.camera.y, GoldenTable.f(t[4])):
				mismatches.add("step %d: port (%s, %s), original (%s, %s)" % [step, GoldenTable.show(game.camera.x), GoldenTable.show(game.camera.y), GoldenTable.show(GoldenTable.f(t[3])), GoldenTable.show(GoldenTable.f(t[4]))])
			step += 1
		assert_eq(mismatches.count, 0, mismatches.summary("camera script " + String(script["name"])))
