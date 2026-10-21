extends "res://tests/test_case.gd"
## newGame() of the port (GameState.create, Sim.new_game) against tests/golden/new_game.json, which tools/golden/defs_new_game.mjs
## produced by evaluating the object literal of the ORIGINAL newGame() with the game's own constants:
##   * every field of the literal for the catalyst on normal difficulty (the M1 configuration), field by field;
##   * the other nine characters, the other difficulties and the endless mode as differences against that baseline;
##   * the ORIGINAL UPDATE_INTRO / UPDATE_MAIN / UPDATE_KO system lists (ids, phases, functions, `when` predicates);
##   * for eight seeds: the number of gameRandom draws newGame makes, the starting weapon's cooldown, the wave theme, and the next
##     three outputs of the generator (so the stream is at the same position afterwards).

## Fields of the literal that newGame changes AFTER the literal (initializeMetaRunRuntime, prepareEnemyWaveTheme(1), showMessage); the
## state after newGame is checked against the seeded section and the constants below instead.
const CHANGED_AFTER_LITERAL: PackedStringArray = [
	"progressEligible", "messageUntil", "waveSpawnTheme", "featuredEnemyHistory", "pendingDirectorEnemyKind",
	"pendingDirectorComposition",
]
## Keys of a golden snapshot that are no GameState field of the same name and are compared by hand.
const HANDLED_BY_HAND: PackedStringArray = ["runUnlocks", "weapons", "specials", "char_id"]
## Per-character states the port does not hold yet (M2: only the catalyst is playable); the golden records them as init-state markers.
const UNPORTED_CHARACTER_STATES: PackedStringArray = ["miko", "berserker", "sentinel", "striker", "harmonizer", "pathfinder"]
## PlayerState fields that are not in newGame's literal (the game creates them later and reads them with `|| 0`).
const PLAYER_FIELDS_OUTSIDE_THE_LITERAL: PackedStringArray = ["vx", "vy", "ax", "ay", "prev_x", "prev_y", "ko_art_id"]
## Fields of GameState that are not in the literal either: the original's globals (rng, input, view size, state) and the
## port's own bookkeeping.
const GAME_FIELDS_OUTSIDE_THE_LITERAL: PackedStringArray = [
	"rng", "fx_rng", "input", "view_w", "view_h", "limits", "state", "run_won", "char_id", "char_def",
	"run_unlocks_weapons", "run_unlocks_elements", "enemies_version", "spawn_composition_history", "special_escort_seq", "enemy_grid",
	"projectile_avoidance_epoch",
]


func _golden() -> Dictionary:
	return GoldenCodec.load_json("new_game")


func _config(character: String = "catalyst", difficulty: String = "normal", mode: String = "normal", rng_seed: int = 424242) -> SimConfig:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = rng_seed
	config.character_id = character
	config.difficulty = difficulty
	config.mode = mode
	config.allow_unported_character = character != "catalyst"
	return config


func _new_sim(config: SimConfig) -> Sim:
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game(%s, %s, %s)" % [config.character_id, config.difficulty, config.mode])
	return sim


## The names of the script variables of an object.
func _fields_of(obj: Object) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for info: Dictionary in obj.get_property_list():
		if (int(info["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			names.append(String(info["name"]))
	return names


# --- the comparator ---------------------------------------------------------------------------------

## Compares a value of the port with the snapshot of the original (see snapshot_encoding in the golden file). The original's null
## is null, or "" for the fields the port holds as a String.
func _match(actual: Variant, expected: Variant, path: String, mismatches: GoldenTable.Mismatches) -> void:
	mismatches.checked += 1
	if expected == null:
		if not (actual == null or (actual is String and actual == "")):
			mismatches.add("%s: port %s, original null" % [path, var_to_str(actual)])
		return
	if expected is bool:
		if not (actual is bool) or actual != expected:
			mismatches.add("%s: port %s, original %s" % [path, var_to_str(actual), expected])
		return
	if expected is float:
		# a number that is an integer in the original (JSON.parse_string turns every JSON number into a float)
		if not (actual is float or actual is int) or float(actual) != float(expected):
			mismatches.add("%s: port %s, original %s" % [path, var_to_str(actual), expected])
		return
	if expected is String:
		if not (actual is String) or actual != expected:
			mismatches.add("%s: port %s, original '%s'" % [path, var_to_str(actual), expected])
		return
	if not (expected is Dictionary):
		mismatches.add("%s: unsupported golden value %s" % [path, var_to_str(expected)])
		return
	var node: Dictionary = expected
	if node.has("f64"):
		if not (actual is float or actual is int) or not GoldenCodec.same_double(float(actual), GoldenCodec.from_hex(String(node["f64"]))):
			mismatches.add("%s: port %s, original %s" % [path, var_to_str(actual), GoldenCodec.from_hex(String(node["f64"]))])
	elif node.has("@array"):
		_match_array(actual, node, path, mismatches)
	elif node.has("@map") or node.has("@set"):
		var size: int = int(node["@map"]) if node.has("@map") else int(node["@set"])
		if not (actual is Dictionary) or (actual as Dictionary).size() != size:
			mismatches.add("%s: port %s, original a Map/Set of %d" % [path, var_to_str(actual), size])
	elif node.has("@marker"):
		mismatches.add("%s: a marker (%s) must be compared by hand" % [path, node["@marker"]])
	elif actual is Dictionary:
		var dict: Dictionary = actual
		for key: Variant in node.keys():
			if not dict.has(key):
				mismatches.add("%s.%s: missing in the port" % [path, key])
			else:
				_match(dict[key], node[key], "%s.%s" % [path, key], mismatches)
		if dict.size() != node.size():
			mismatches.add("%s: the port has %d keys, the original %d" % [path, dict.size(), node.size()])
	elif actual is Object:
		_match_object(actual, node, path, mismatches, PackedStringArray())
	else:
		mismatches.add("%s: port %s is no object" % [path, var_to_str(actual)])


func _match_array(actual: Variant, node: Dictionary, path: String, mismatches: GoldenTable.Mismatches) -> void:
	var size: int = int(node["@array"])
	if not (actual is Array or actual is PackedStringArray or actual is PackedInt32Array or actual is PackedFloat64Array):
		mismatches.add("%s: port %s, original an array of %d" % [path, var_to_str(actual), size])
		return
	if actual.size() != size:
		mismatches.add("%s: the port's array has %d items, the original's %d" % [path, actual.size(), size])
		return
	if node.has("items"):
		var items: Array = node["items"]
		for i: int in size:
			_match(actual[i], items[i], "%s[%d]" % [path, i], mismatches)


## Every key of the snapshot must be a field of the same name (snake_case) of the port's object.
func _match_object(obj: Object, node: Dictionary, path: String, mismatches: GoldenTable.Mismatches, skip: PackedStringArray) -> void:
	var fields: PackedStringArray = _fields_of(obj)
	for key: Variant in node.keys():
		var original_key: String = String(key)
		if skip.has(original_key):
			continue
		var field: String = original_key.to_snake_case()
		if not fields.has(field):
			mismatches.add("%s.%s: the port has no field '%s'" % [path, original_key, field])
			continue
		_match(obj.get(field), node[key], "%s.%s" % [path, original_key], mismatches)


# --- game state ---------------------------------------------------------------------------------------

func _check_game(game: GameState, expected: Dictionary, label: String, extra_skip: PackedStringArray = PackedStringArray()) -> GoldenTable.Mismatches:
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	var skip: PackedStringArray = PackedStringArray(CHANGED_AFTER_LITERAL)
	skip.append_array(HANDLED_BY_HAND)
	skip.append_array(extra_skip)
	_match_object(game, expected, label, mismatches, skip)
	return mismatches


func test_catalyst_state_equals_the_originals_literal() -> void:
	var baseline: Dictionary = _golden()["cases"]["baseline"]
	var sim: Sim = _new_sim(_config())
	var mismatches: GoldenTable.Mismatches = _check_game(sim.game, baseline, "game")
	assert_eq(mismatches.count, 0, mismatches.summary("newGame literal (catalyst, normal)"))
	assert_true(mismatches.checked > 190, "many fields were compared (%d)" % mismatches.checked)
	assert_eq(sim.game.char_id, baseline["char_id"], "char_id")
	assert_eq(sim.game.char_def.id, "catalyst", "char_def")


func test_player_has_every_field_of_the_literal_and_nothing_else() -> void:
	var baseline: Dictionary = _golden()["cases"]["baseline"]
	var expected_player: Dictionary = baseline["player"]
	var sim: Sim = _new_sim(_config())
	var fields: PackedStringArray = _fields_of(sim.game.player)
	var from_literal: PackedStringArray = PackedStringArray()
	for key: Variant in expected_player.keys():
		from_literal.append(String(key).to_snake_case())
	for field: String in fields:
		assert_true(from_literal.has(field) or PLAYER_FIELDS_OUTSIDE_THE_LITERAL.has(field), "PlayerState.%s is a field of the literal or documented as outside it" % field)
	for field: String in PLAYER_FIELDS_OUTSIDE_THE_LITERAL:
		assert_true(fields.has(field), "PlayerState.%s exists" % field)
		# the game reads vx, vy, ax, ay, prevX, prevY with `|| 0`: they start at 0
		if field != "ko_art_id":
			assert_eq(sim.game.player.get(field), 0.0, "%s starts at 0" % field)
	assert_eq(sim.game.player.ko_art_id, "", "koArtId starts unset")
	assert_eq(fields.size(), from_literal.size() + PLAYER_FIELDS_OUTSIDE_THE_LITERAL.size(), "no other player field")
	# the literal's own order of keys is also the order of the fields: the port's file mirrors the original's literal
	var literal_index: int = 0
	for field: String in fields:
		if PLAYER_FIELDS_OUTSIDE_THE_LITERAL.has(field):
			continue
		assert_eq(field, from_literal[literal_index], "field %d is in the literal's order" % literal_index)
		literal_index += 1


func test_every_field_of_the_game_literal_is_accounted_for() -> void:
	var baseline: Dictionary = _golden()["cases"]["baseline"]
	var sim: Sim = _new_sim(_config())
	var fields: PackedStringArray = _fields_of(sim.game)
	var covered: PackedStringArray = PackedStringArray()
	for key: Variant in baseline.keys():
		var original_key: String = String(key)
		if original_key == "char_id" or original_key == "runUnlocks":
			continue
		assert_true(fields.has(original_key.to_snake_case()), "GameState.%s exists for the literal's %s" % [original_key.to_snake_case(), original_key])
		covered.append(original_key.to_snake_case())
	for field: String in fields:
		assert_true(covered.has(field) or GAME_FIELDS_OUTSIDE_THE_LITERAL.has(field), "GameState.%s belongs to the literal or is documented as outside it" % field)
	for dropped: Variant in _golden()["dropped_fields"]:
		assert_false(baseline.has(dropped), "'%s' is not compared as a snapshot (the port keeps char_id/char_def instead)" % dropped)


func test_state_after_the_literal() -> void:
	# what initializeMetaRunRuntime, prepareEnemyWaveTheme(1) and showMessage add to the literal
	var sim: Sim = _new_sim(_config())
	var g: GameState = sim.game
	assert_true(g.progress_eligible, "progressEligible is true for the standard mode (initializeMetaRunRuntime)")
	assert_true(GoldenCodec.same_double(g.message_until, 1.6), "showMessage(..., 1.6) at t = 0")
	assert_eq(g.wave_spawn_theme.wave, 1, "theme wave")
	assert_eq(g.wave_spawn_theme.base_kind, "swarm", "theme base kind")
	assert_eq(g.wave_spawn_theme.featured_kind, "swarm", "theme featured kind")
	assert_false(g.wave_spawn_theme.changed, "wave 1 has only the swarm unlocked: no change")
	assert_eq(Array(g.featured_enemy_history), ["swarm"], "featuredEnemyHistory")
	assert_eq(g.pending_director_enemy_kind, "", "pendingDirectorEnemyKind is null")
	assert_eq(g.pending_director_composition, null, "pendingDirectorComposition is null")
	assert_eq(g.state, GameState.RunState.PLAYING, "state is playing")
	assert_true(g.is_player_alive(), "the player is alive")
	var endless: Sim = _new_sim(_config("catalyst", "normal", "endless"))
	assert_false(endless.game.progress_eligible, "endless runs do not count towards progress")


func test_other_characters_difficulties_and_the_endless_mode() -> void:
	var cases: Dictionary = _golden()["cases"]
	var baseline: Dictionary = cases["baseline"]
	var variants: Array = cases["variants"]
	assert_eq(variants.size(), 15, "variants in the golden file")
	for variant: Dictionary in variants:
		var character: String = variant["character"]
		var config: SimConfig = _config(character, variant["difficulty"], variant["mode"])
		var sim: Sim = _new_sim(config)
		if sim.game == null:
			continue
		var expected: Dictionary = baseline.duplicate(true)
		var diff: Dictionary = variant["diff"]
		for key: Variant in diff.keys():
			if key == "player":
				var player: Dictionary = expected["player"]
				for player_key: Variant in (diff["player"] as Dictionary).keys():
					player[player_key] = diff["player"][player_key]
			else:
				expected[key] = diff[key]
		var label: String = "%s/%s/%s" % [character, variant["mode"], variant["difficulty"]]
		var extra_skip: PackedStringArray = PackedStringArray(UNPORTED_CHARACTER_STATES)
		var mismatches: GoldenTable.Mismatches = _check_game(sim.game, expected, label, extra_skip)
		assert_eq(mismatches.count, 0, mismatches.summary("newGame literal for " + label))
		assert_eq(sim.game.char_id, expected["char_id"], "%s: char_id" % label)
		# the starting weapon is the character's signature weapon
		var weapon_marker: Dictionary = (expected["weapons"] as Dictionary)["items"][0]
		assert_eq(sim.game.weapons.size(), 1, "%s: one weapon" % label)
		assert_eq(sim.game.weapons[0].id, weapon_marker["id"], "%s: starting weapon" % label)
		_check_run_unlocks(sim.game, expected["runUnlocks"], label)
		# a character that is not the catalyst has no ability loadout in the port (M2)
		if character == "catalyst":
			_check_specials(sim.game, (expected["specials"] as Dictionary), label)
		else:
			assert_eq(sim.game.specials.char_id, character, "%s: specials.charId" % label)


func _check_run_unlocks(game: GameState, expected: Dictionary, label: String) -> void:
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	_match_array(game.run_unlocks_weapons, expected["weapons"], label + ".runUnlocks.weapons", mismatches)
	_match_array(game.run_unlocks_elements, expected["elements"], label + ".runUnlocks.elements", mismatches)
	assert_eq(mismatches.count, 0, mismatches.summary("runUnlocks of " + label))


func _check_specials(game: GameState, expected: Dictionary, label: String) -> void:
	assert_eq(expected["@marker"], "makeSpecialsState", "%s: specials marker" % label)
	assert_eq(game.specials.char_id, expected["charId"], "%s: specials.charId" % label)
	var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
	_match_array(game.specials.ability_ids, expected["abilityIds"], label + ".specials.abilityIds", mismatches)
	assert_eq(mismatches.count, 0, mismatches.summary("specials.abilityIds of " + label))
	for id: String in game.specials.ability_ids:
		assert_eq(game.specials.rank(id), 0, "%s: %s starts at rank 0" % [label, id])
	assert_eq(game.specials.meta_active.size(), 0, "%s: no meta-ability is active" % label)
	assert_true(game.abilities_active(), "%s: abilitiesActive()" % label)


func test_unknown_character_and_difficulty_fall_back_like_the_original() -> void:
	# `CHARACTERS.find(x => x.id === selectedCharacter) || CHARACTERS[0]`; `DIFFICULTY_CONFIG[selectedDifficulty] ? ... : "normal"`
	var config: SimConfig = _config("no-such-character", "no-such-difficulty")
	var sim: Sim = _new_sim(config)
	assert_eq(sim.game.char_id, "catalyst", "the first character")
	assert_eq(sim.game.difficulty, "normal", "difficulty")
	assert_eq(sim.game.current_difficulty().label, "NORMAL", "currentDifficulty()")


# --- system lists ---------------------------------------------------------------------------------------

func test_system_lists_equal_the_originals() -> void:
	var sim: Sim = _new_sim(_config())
	var lists: Dictionary = _golden()["system_lists"]
	var ours: Dictionary = {
		"UPDATE_INTRO_SYSTEMS": sim.runner.intro,
		"UPDATE_MAIN_SYSTEMS": sim.runner.main,
		"UPDATE_KO_SYSTEMS": sim.runner.ko,
	}
	assert_eq((lists["UPDATE_INTRO_SYSTEMS"] as Array).size(), 5, "the original's intro list")
	assert_eq((lists["UPDATE_MAIN_SYSTEMS"] as Array).size(), 43, "the original's main list")
	assert_eq((lists["UPDATE_KO_SYSTEMS"] as Array).size(), 5, "the original's ko list")
	for list_name: String in ours.keys():
		var slots: Array = ours[list_name]
		var rows: Array = lists[list_name]
		assert_eq(slots.size(), rows.size(), "%s: number of slots" % list_name)
		for i: int in mini(slots.size(), rows.size()):
			var slot: SystemSlot = slots[i]
			var t: PackedStringArray = String(rows[i]).split(" ", true, 3)
			var where: String = "%s[%d] %s" % [list_name, i, t[0]]
			assert_eq(slot.id, t[0], "%s: id" % where)
			assert_eq(slot.phase, t[1], "%s: phase" % where)
			assert_eq(slot.system.original_function, t[2], "%s: function called" % where)
			assert_eq(slot.has_when, t[3] != "-", "%s: has a `when` predicate" % where)


func test_stubs_say_where_the_original_draws_random_numbers() -> void:
	# The census of tools/census_rng_slots_chromium.mjs (the real original in Chromium, a gameRandom wrapper that credits each
	# draw to the running slot; verification/godot/s3/rng_slots.txt): in the M1 configuration only four slots draw: wave/progress,
	# enemy/update, projectile/player and enemy/cleanup-2. enemy/update draws through contact damage (hurtPlayer -> showDamageNumber,
	# 3 per hit); weapon/update draws nothing for the M1 weapons. A stub that is marked is the reason the port's draw count lags the
	# original until its step lands. Step S5 ported wave/progress, enemy/cleanup-2 and enemy/update, so those three are real slots now
	# (the census tool, which needs Chromium, still lists all four as the slots that draw and checks that the drawing slots are exactly
	# the marked placeholders and the real slots; the marked set is empty once S6 has landed).
	var sim: Sim = _new_sim(_config())
	var drawing: PackedStringArray = PackedStringArray()
	for slot: SystemSlot in sim.runner.stub_slots():
		var stub: StubSystem = slot.system as StubSystem
		assert_true(stub != null, "%s is a StubSystem" % slot.id)
		assert_true(stub.reason.length() > 10, "%s documents why it does nothing (%s)" % [slot.id, stub.owner_step])
		if stub.consumes_rng_in_m1:
			drawing.append(slot.id)
	# step S5 ported wave/progress, enemy/cleanup-2 and enemy/update (their draws are real now); projectile/player (hits) waits for S6
	assert_eq(Array(drawing), ["projectile/player"], "stubs that draw random numbers in the original")


# --- the generator after newGame ------------------------------------------------------------------------

func test_new_game_draws_and_leaves_the_stream_where_the_original_does() -> void:
	var seeded: Array = _golden()["seeded"]
	assert_eq(seeded.size(), 8, "eight seeds")
	var seen_424242: bool = false
	for entry: Dictionary in seeded:
		var rng_seed: int = int(entry["seed"])
		var sim: Sim = _new_sim(_config("catalyst", "normal", "normal", rng_seed))
		var g: GameState = sim.game
		var where: String = "seed %d" % rng_seed
		assert_eq(g.rng.draws, int(entry["draws"]), "%s: gameRandomDraws after newGame (the starting weapon's rand)" % where)
		assert_eq(sim.draws(), 1, "%s: one draw in all (analyst A: gameRandomDraws is 1)" % where)
		var weapon: Dictionary = entry["weapon"]
		var mismatches: GoldenTable.Mismatches = GoldenTable.Mismatches.new()
		var state: WeaponState = g.weapons[0]
		_match(state.id, weapon["id"], where + ".weapon.id", mismatches)
		_match(state.level, weapon["level"], where + ".weapon.level", mismatches)
		_match(state.cooldown, weapon["cooldown"], where + ".weapon.cooldown", mismatches)
		_match(state.ultimate_cd, weapon["ultimateCd"], where + ".weapon.ultimateCd", mismatches)
		_match(state.shot_seq, weapon["shotSeq"], where + ".weapon.shotSeq", mismatches)
		_match_array(state.elements, weapon["elements"], where + ".weapon.elements", mismatches)
		var mods: Dictionary = weapon["mods"]
		_match(state.mod_pierce, mods["pierce"], where + ".weapon.mods.pierce", mismatches)
		_match(state.mod_multishot, mods["multishot"], where + ".weapon.mods.multishot", mismatches)
		_match(state.mod_explosive, mods["explosive"], where + ".weapon.mods.explosive", mismatches)
		_match(state.mod_homing, mods["homing"], where + ".weapon.mods.homing", mismatches)
		var theme: Dictionary = entry["theme"]
		var port_theme: EnemyWaveTheme = g.wave_spawn_theme
		_match(port_theme.wave, theme["wave"], where + ".theme.wave", mismatches)
		_match(port_theme.base_kind, theme["baseKind"], where + ".theme.baseKind", mismatches)
		_match(port_theme.featured_kind, theme["featuredKind"], where + ".theme.featuredKind", mismatches)
		_match(port_theme.changed, theme["changed"], where + ".theme.changed", mismatches)
		_match(port_theme.change_chance, theme["changeChance"], where + ".theme.changeChance", mismatches)
		_match(port_theme.featured_share, theme["featuredShare"], where + ".theme.featuredShare", mismatches)
		_match(port_theme.total_spawned, theme["totalSpawned"], where + ".theme.totalSpawned", mismatches)
		_match(port_theme.counts, theme["counts"], where + ".theme.counts", mismatches)
		_match_array(port_theme.recent_mixed, theme["recentMixed"], where + ".theme.recentMixed", mismatches)
		_match_array(g.featured_enemy_history, entry["featuredEnemyHistory"], where + ".featuredEnemyHistory", mismatches)
		_match(g.pending_director_enemy_kind, entry["pendingDirectorEnemyKind"], where + ".pendingDirectorEnemyKind", mismatches)
		assert_eq(mismatches.count, 0, mismatches.summary("newGame state of " + where))
		# the stream continues exactly where the original's does
		var next: Array = entry["next"]
		for i: int in next.size():
			var value: float = g.rng.random()
			assert_true(GoldenCodec.same_double(value, GoldenCodec.from_hex(String(next[i]))), "%s: output %d after newGame is the original's (%s)" % [where, i, GoldenTable.show(value)])
		assert_eq(g.rng.draws, 1 + next.size(), "%s: draws counted after the next outputs" % where)
		if rng_seed == 424242:
			seen_424242 = true
	assert_true(seen_424242, "seed 424242 (the reference trace seed) is covered")
