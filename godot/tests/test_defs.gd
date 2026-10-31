extends "res://tests/test_case.gd"
## The definition tables (res://sim/defs/*.json, extracted from the original by tools/extract_defs.mjs) and their loader.

const FILES: PackedStringArray = ["characters.json", "weapons.json", "enemies.json", "rules.json", "limits.json"]


func test_files_load_with_the_pinned_source() -> void:
	var bits: Dictionary = GoldenCodec.load_json("defs_bits")
	var expected_sha: String = String(bits.get("source_sha256", ""))
	assert_eq(expected_sha.length(), 64, "defs_bits.json carries the SHA-256 of original.html")
	for file_name: String in FILES:
		var data: Dictionary = Defs.file(file_name)
		assert_true(data.has("values"), "%s has values" % file_name)
		assert_eq(String(data.get("source_sha256", "")), expected_sha, "%s was extracted from the same original as the golden files" % file_name)
		assert_eq(String(data.get("source", "")), "webview-fg4/tests/fixtures/original.html", "%s names its source" % file_name)


func test_counts_and_order_of_the_tables() -> void:
	assert_eq(Defs.character_ids().size(), 10, "CHARACTERS")
	assert_eq(String(Defs.character_ids()[0]), "catalyst", "the first character is the default one")
	assert_eq(Defs.weapon_ids().size(), 24, "WEAPONS")
	assert_eq(Defs.archetype_kinds().size(), 7, "ENEMY_KIND_ORDER")
	assert_eq(Array(Defs.difficulty_keys()), ["easy", "normal", "hard", "nightmare"], "DIFFICULTY_KEYS")
	assert_eq(Array(Defs.archetype_kinds()), ["swarm", "assassin", "tank", "artillery", "bomber", "support", "controller"], "enemy kind order")
	assert_eq(Defs.signature_weapon_id("catalyst"), "catalytic_ring", "the catalyst's weapon")
	assert_eq(Defs.signature_weapon_id("nobody"), "pulse", "SIGNATURE_WEAPON_BY_CHARACTER[id] || 'pulse'")
	# JSON objects keep their key order when Godot parses them (the original's tables are ordered objects)
	var table: Dictionary = Defs.value("rules.json", "DIFFICULTY_CONFIG")
	assert_eq(Array(table.keys()), ["easy", "normal", "hard", "nightmare"], "key order of DIFFICULTY_CONFIG survives the parse")
	var archetypes: Dictionary = Defs.value("enemies.json", "ENEMY_ARCHETYPES")
	assert_eq(Array(archetypes.keys()), Array(Defs.archetype_kinds()), "key order of ENEMY_ARCHETYPES survives the parse")


func test_every_non_integer_number_equals_the_originals_double() -> void:
	# Godot's JSON parser is not correctly rounded for every double; the bits in defs_bits.json come from the original.
	var golden: Dictionary = GoldenCodec.load_json("defs_bits")
	var entries: Array = golden["entries"]
	assert_true(entries.size() > 100, "there are many non-integer numbers to check (%d)" % entries.size())
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	for entry: Variant in entries:
		var parts: PackedStringArray = String(entry).split(" ")
		var location: PackedStringArray = parts[0].split(":")
		var node: Variant = Defs.file(location[0])
		var found: bool = true
		for key: String in location[1].split("."):
			if node is Dictionary and (node as Dictionary).has(key):
				node = (node as Dictionary)[key]
			elif node is Array and key.is_valid_int() and int(key) < (node as Array).size():
				node = (node as Array)[int(key)]
			else:
				found = false
				break
		mismatches.checked += 1
		if not found:
			mismatches.add("%s is missing" % parts[0])
		elif not (node is float):
			mismatches.add("%s is %s, not a float" % [parts[0], type_string(typeof(node))])
		elif not GoldenCodec.same_double(float(node), GoldenCodec.from_hex(parts[1])):
			mismatches.add("%s: loaded %s, original %s" % [parts[0], GoldenTable.show(float(node)), GoldenTable.show(GoldenCodec.from_hex(parts[1]))])
	assert_eq(mismatches.count, 0, mismatches.summary("defs numbers"))


func test_infinity_and_other_markers_are_restored() -> void:
	assert_eq(Defs.difficulty("normal").prediction_max, INF, "DIFFICULTY_CONFIG.normal.predictionMax is Infinity")
	assert_eq(Defs.difficulty("hard").prediction_max, 0.4, "a finite predictionMax stays finite")
	for file_name: String in FILES:
		assert_false(_contains_marker(Defs.file(file_name)), "%s has no unrestored {\"$num\": ...} marker" % file_name)


func _contains_marker(node: Variant) -> bool:
	if node is Dictionary:
		var dict: Dictionary = node
		if dict.has("$num"):
			return true
		for value: Variant in dict.values():
			if _contains_marker(value):
				return true
	elif node is Array:
		for item: Variant in node as Array:
			if _contains_marker(item):
				return true
	return false


func test_pointer_dependent_limits_have_both_variants() -> void:
	var coarse: SimLimits = Defs.limits(true)
	var fine: SimLimits = Defs.limits(false)
	assert_eq(coarse.max_projectiles, 520, "coarse MAX_PROJECTILES")
	assert_eq(coarse.max_xp_orbs, 480, "coarse MAX_XP_ORBS")
	assert_eq(coarse.max_enemy_projectiles, 420, "coarse MAX_ENEMY_PROJECTILES")
	assert_eq(fine.max_projectiles, 900, "fine MAX_PROJECTILES")
	assert_eq(fine.max_xp_orbs, 900, "fine MAX_XP_ORBS")
	assert_eq(fine.max_enemy_projectiles, 720, "fine MAX_ENEMY_PROJECTILES")
	assert_true(GoldenCodec.same_double(coarse.hud_update_interval, 1.0 / 15.0), "coarse HUD_UPDATE_INTERVAL is 1/15")
	assert_true(GoldenCodec.same_double(fine.hud_update_interval, 1.0 / 24.0), "fine HUD_UPDATE_INTERVAL is 1/24")
	assert_eq(coarse.map_w, 26000.0, "MAP_W")
	assert_eq(coarse.map_h, 26000.0, "MAP_H")
	assert_eq(coarse.base_max_enemies, 100, "BASE_MAX_ENEMIES")
	assert_eq(coarse.enemy_separation_grid_size, 96, "ENEMY_SEPARATION_GRID_SIZE")
	assert_eq(coarse.enemy_separation_grid_stride, 275, "ENEMY_SEPARATION_GRID_STRIDE = floor(MAP_W / 96) + 5")
	assert_eq(coarse.projectile_avoid_grid_stride, 136, "PROJECTILE_AVOID_GRID_STRIDE")


func test_typed_wrappers_read_the_tables() -> void:
	var catalyst: CharacterDef = Defs.character("catalyst")
	assert_eq(catalyst.hp, 100.0, "catalyst hp")
	assert_eq(catalyst.speed, 180.0, "catalyst speed")
	assert_eq(catalyst.nullish("directDamageMul", 1.0), 0.85, "directDamageMul ?? 1")
	assert_eq(catalyst.nullish("damageMul", 5.0), 1.0, "damageMul is present")
	assert_eq(catalyst.nullish("dotDamageMul", 1.0), 1.0, "an absent key falls back")
	assert_eq(catalyst.truthy("strataMax", 8.0), 8.0, "strataMax || 8")
	assert_eq(Defs.character("ranger").truthy("strataMax", 8.0), 12.0, "ranger strataMax")
	assert_true(Defs.character("ranger").flag("woodDirectDamagePenaltyImmune"), "!!c.woodDirectDamagePenaltyImmune")
	assert_false(catalyst.flag("reactionGrowth"), "an absent flag is false")
	assert_eq(Defs.character("ranger").string_list("allowedElements"), PackedStringArray(["earth", "wood"]), "allowedElements")
	assert_eq(catalyst.string_list("allowedElements"), null, "no allowedElements array")
	var ring: WeaponDef = Defs.weapon("catalytic_ring")
	assert_eq(ring.damage, 24.0, "catalytic_ring damage")
	assert_eq(ring.rate, 0.84, "catalytic_ring rate")
	assert_eq(ring.signature_for, "catalyst", "signatureFor")
	assert_eq(Defs.weapon("pulse").signature_for, "", "a shared weapon has no signatureFor")
	var swarm: ArchetypeDef = Defs.archetype("swarm")
	assert_eq(swarm.cap, 999, "swarm cap")
	assert_eq(swarm.unlock_wave, 1, "swarm unlock wave")
	assert_eq(Defs.archetype("assassin").cost, 2.7, "assassin cost")
	assert_eq(Defs.difficulty("normal").enemy_hp, 1.0, "normal enemyHp")
	assert_eq(Defs.difficulty("nightmare").label, "NIGHTMARE", "label")
	assert_eq(Defs.difficulty("no-such-difficulty").label, "NORMAL", "an unknown key gives the normal entry")


func test_rules_are_the_originals() -> void:
	var rules: SimRules = Defs.rules()
	assert_true(GoldenCodec.same_double(rules.fixed_dt, 1.0 / 60.0), "FIXED_DT is 1/60")
	assert_true(GoldenCodec.same_double(Sim.FIXED_DT, rules.fixed_dt), "Sim.FIXED_DT is the extracted FIXED_DT")
	assert_eq(rules.max_steps_per_frame, 5, "MAX_STEPS_PER_FRAME")
	assert_true(GoldenCodec.same_double(rules.max_accumulated_seconds, (1.0 / 60.0) * 5.0), "MAX_ACCUMULATED_SECONDS = FIXED_DT * 5")
	assert_eq(rules.wave_duration, 36.0, "WAVE_DURATION")
	assert_eq(rules.day_cycle_seconds, 144.0, "DAY_CYCLE_SECONDS = WAVE_DURATION * 4")
	assert_eq(rules.max_wave, 30, "MAX_WAVE")
	assert_eq(rules.move_stick_max, 42.0, "MOVE_STICK_MAX")
	assert_eq(rules.xp_initial_requirement, 60.0, "XP_CURVE.initialRequirement")
	assert_eq(rules.xp_growth_multiplier, 1.18, "XP_CURVE.growthMultiplier")
	assert_eq(rules.xp_flat_growth, 18.0, "XP_CURVE.flatGrowth")
	assert_eq(rules.xp_requirement_multiplier, 0.85, "XP_CURVE.requirementMultiplier")
	assert_eq(rules.safe_attack_interval, 0.05, "SAFE_ATTACK_INTERVAL")
	assert_eq(rules.director_budget_cap, 18.0, "DIRECTOR_BUDGET_CAP")
	assert_eq(rules.featured_initial_change_chance, 0.05, "FEATURED_WAVE_CONFIG.initialChangeChance")
	assert_eq(rules.walk_fps_min, 10.0, "CHARACTER_ANIMATION_FPS.walkMin")
	assert_eq(rules.walk_fps_max, 12.0, "CHARACTER_ANIMATION_FPS.walkMax")


func test_the_android_export_ships_the_definition_files() -> void:
	# The tests run from the project folder and would not notice a definition table that is missing from the APK. Godot 4.7.2 happens
	# to pack *.json files with export_filter="all_resources" (measured in S3: a PCK exported without the include filter holds
	# sim/defs/*.json as well), but that is engine behaviour, not a documented guarantee; the include filter makes the shipping explicit
	# and tests/* stays excluded (the golden vectors are 8 MB).
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load("res://export_presets.cfg"), OK, "export_presets.cfg loads")
	var include_filter: String = String(config.get_value("preset.0", "include_filter", ""))
	var exclude_filter: String = String(config.get_value("preset.0", "exclude_filter", ""))
	for file_name: String in FILES:
		assert_true(_filter_matches(include_filter, "sim/defs/" + file_name), "include_filter '%s' ships sim/defs/%s" % [include_filter, file_name])
		assert_false(_filter_matches(exclude_filter, "sim/defs/" + file_name), "exclude_filter '%s' keeps sim/defs/%s" % [exclude_filter, file_name])
	assert_true(_filter_matches(exclude_filter, "tests/golden/math.json"), "the golden test vectors (8 MB) stay out of the APK")


## Godot's export filters: comma separated glob patterns relative to the project folder.
func _filter_matches(filter: String, path: String) -> bool:
	for pattern: String in filter.split(","):
		var stripped: String = pattern.strip_edges()
		if not stripped.is_empty() and path.match(stripped):
			return true
	return false
