class_name SimTrace
extends RefCounted
## Writes the port's run in the format of the reference traces (swarm-trace/1, tools/reference-trace/FORMAT.md), so that
## tools/compare_trace.mjs and the tests can put the two side by side step by step.
##
## What is in a trace: a header line and one line per fixed step, recorded AFTER that step's update. A field is a float64 as 16
## hex digits of its big-endian IEEE-754 bit pattern ("f"), an integer ("i"), a string ("s") or a boolean ("b"). The groups and
## their fields are listed in the header ("fields": group -> ["name:type", ...]); rows are positional arrays in that order.
##
## The reference traces come from the ORIGINAL game, so they carry every field in REFERENCE_FIELDS (the copy of the schema in
## tools/reference-trace/hook.js; tests/test_reference_trace.gd fails when the two drift apart). The port carries only what it has
## got. This class finds the fields by name instead of listing them: a reference field `maxHp` is looked up as the property
## `max_hp` (camelCase -> snake_case) on the player, the camera, the game or the entity class of the group. A field with no such
## property is left out of every row of the port trace and listed in the header under "unported". When step S5 or S6 adds a
## property to EnemyState (or returns a projectile / XP orb class from entity_sample()), the trace carries it from then on, with
## no other change here.
##
## Values that are not a plain property of the same name (a nested object such as game.wave_spawn_theme, an array that the
## reference flattens to a string) go through the getter table, port_getters(): reference field -> Callable(object) -> value of the
## type of the field. A field with a getter counts as ported. The director fields of the wave group are the first entries; S5 adds
## its own the same way.
##
## Per-slot draws: attach() wraps every slot of the three update lists in a TracedSystem, which adds the gameRandom draws the
## slot makes to a sink under "<list>:<index>"; step_and_record() reads the sink after the step. Draws outside any slot
## (outside_draws) are the step's total minus the slots' sum.

const FORMAT: String = "swarm-trace/1"
const PRODUCER: String = "godot-port"
## Keys of the "counts" object, in this order.
const COUNT_FIELDS: PackedStringArray = ["enemies", "projectiles", "xp_orbs", "particles", "enemy_projectiles", "hazards"]
const LIST_NAMES: PackedStringArray = ["intro", "main", "ko"]

## The schema of the reference traces: group -> "name:type" entries, in row order (hook.js SCHEMA).
const REFERENCE_FIELDS: Dictionary = {
	"player": [
		"x:f", "y:f", "vx:f", "vy:f", "ax:f", "ay:f", "prevX:f", "prevY:f", "hp:f", "maxHp:f", "xp:f", "level:i", "xpNext:f",
		"xpBaseNext:f", "lastFacing:f", "attackAnim:f", "attackAngle:f", "koTimer:f", "walkPhase:f", "controlSlow:f", "lastHit:f",
	],
	"camera": ["x:f", "y:f", "prevX:f", "prevY:f"],
	"wave": [
		"t:f", "wave:i", "waveClock:f", "directorClock:f", "spawnBudget:f", "dayPhase:f", "pendingLevelUps:i", "nextEnemyId:i",
		"damageFlash:f", "screenFlash:f", "kills:i", "levelUpChoiceReadyAt:f",
		"pendingDirectorEnemyKind:s", "waveFeaturedChangeChance:f", "enemyAiTier:i", "enemyAiSkill:f", "enemiesVersion:i",
		"themeWave:i", "themeBaseKind:s", "themeFeaturedKind:s", "themeChanged:b", "themeChangeChance:f", "themeTotalSpawned:i",
		"themeCounts:s", "themeRecentMixed:s", "featuredEnemyHistory:s",
	],
	"enemy": [
		"id:i", "kind:s", "x:f", "y:f", "vx:f", "vy:f", "hp:f", "maxHp:f", "prevX:f", "prevY:f", "r:f", "speed:f", "facing:f",
		"aiState:s", "shootCd:f", "aiTimer:f", "abilityCd:f", "strafeDir:i", "aiSeed:f", "thinkCd:f", "animPhase:f", "tacticCd:f",
		"dotNumberTimer:f", "damage:f", "spawnWave:i", "flash:f", "telegraph:f", "attackAnim:f", "tacticPulse:f",
	],
	"projectile": ["x:f", "y:f", "vx:f", "vy:f", "life:f", "age:f", "r:f", "damage:f", "weapon:s"],
	"xp_orb": ["x:f", "y:f", "value:f", "r:f"],
}
## Order of the groups in a header.
const GROUPS: PackedStringArray = ["player", "camera", "wave", "enemy", "projectile", "xp_orb"]

const STATE_NAMES: Array[String] = ["menu", "playing", "paused", "levelup", "chest", "special", "ability", "abilityIntro", "ended"]


## One ported field of a group: the reference name, its type letter and the property it is read from.
class Field extends RefCounted:
	var field_name: String = ""
	var type: String = ""
	var property: String = ""
	var spec: String = ""
	## Set for a field of the getter table: called with the object of the row instead of reading `property`.
	var getter: Callable = Callable()


var sim: Sim = null
## key -> draws made by that slot in the current step (filled by the TracedSystem wrappers).
var sink: Dictionary = {}
var slot_ids: Dictionary = {}
var _fields: Dictionary = {}
var _draws_before: int = 0
## gameRandomDraws right after newGame (the draw of the starting weapon).
var _new_game_draws: int = 0


## Wraps the slots of `p_sim` and works out which fields of the reference schema the port has.
func _init(p_sim: Sim) -> void:
	sim = p_sim
	attach()
	var game: GameState = sim.game
	_new_game_draws = game.rng.draws
	_fields["player"] = ported_fields("player", game.player)
	_fields["camera"] = ported_fields("camera", game.camera)
	_fields["wave"] = ported_fields("wave", game)
	for group: String in ["enemy", "projectile", "xp_orb"]:
		_fields[group] = ported_fields(group, entity_sample(group))


# --- schema ------------------------------------------------------------------------------------------------------------

## An instance of the entity class of a list group, whose properties are looked up for the group's fields; null when the port
## has no such class yet. S6 adds its projectile and XP orb classes here: from then on their properties are traced with no other
## change (a field with a property of the snake_case name is carried, the others are listed under "unported").
static func entity_sample(group: String) -> Object:
	match group:
		"enemy":
			return EnemyState.new()
	return null


## camelCase -> snake_case: "prevX" -> "prev_x", "xpBaseNext" -> "xp_base_next".
static func snake_case(camel: String) -> String:
	var out: String = ""
	for i: int in range(camel.length()):
		var code: int = camel.unicode_at(i)
		if code >= 65 and code <= 90:
			out += "_" + char(code + 32)
		else:
			out += char(code)
	return out


static func script_variables(obj: Object) -> Dictionary:
	var names: Dictionary = {}
	if obj == null:
		return names
	for info: Dictionary in obj.get_property_list():
		if (int(info["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			names[String(info["name"])] = true
	return names


## The fields of `group` (reference order) that the port has: those with an entry in the getter table, and those that `sample`
## has a property of the snake_case name for. A null sample has only the getter fields.
static func ported_fields(group: String, sample: Object) -> Array[Field]:
	var names: Dictionary = script_variables(sample)
	var getters: Dictionary = (port_getters().get(group, {}) as Dictionary)
	var out: Array[Field] = []
	var specs: Array = REFERENCE_FIELDS[group]
	for entry: Variant in specs:
		var parts: PackedStringArray = TraceReader.split_spec(String(entry))
		var property: String = snake_case(parts[0])
		var getter: Callable = getters.get(parts[0], Callable())
		if getter.is_valid() or names.has(property):
			var field: Field = Field.new()
			field.field_name = parts[0]
			field.type = parts[1]
			field.property = property
			field.spec = String(entry)
			field.getter = getter
			out.append(field)
	return out


## The getter table: group -> { reference field name -> Callable(object of the row) -> value }. The value has the type of the
## field in REFERENCE_FIELDS ("f" float, "i" int, "s" String, "b" bool). It is where a reference value that is no plain
## property of the same name comes from; the nested waveSpawnTheme is flattened exactly as hook.js does it, and is the
## original's undefined (0, "", false) while game.wave_spawn_theme is null. Static so that S5 and S6 can add their lines (a test
## registers none: it checks the mechanism with the entries below).
static func port_getters() -> Dictionary:
	return {
		"wave": {
			"themeWave": _theme_wave,
			"themeBaseKind": _theme_base_kind,
			"themeFeaturedKind": _theme_featured_kind,
			"themeChanged": _theme_changed,
			"themeChangeChance": _theme_change_chance,
			"themeTotalSpawned": _theme_total_spawned,
			"themeCounts": _theme_counts,
			"themeRecentMixed": _theme_recent_mixed,
			"featuredEnemyHistory": _featured_enemy_history,
		},
	}


static func _theme_wave(game: GameState) -> int:
	return game.wave_spawn_theme.wave if game.wave_spawn_theme != null else 0


static func _theme_base_kind(game: GameState) -> String:
	return game.wave_spawn_theme.base_kind if game.wave_spawn_theme != null else ""


static func _theme_featured_kind(game: GameState) -> String:
	return game.wave_spawn_theme.featured_kind if game.wave_spawn_theme != null else ""


static func _theme_changed(game: GameState) -> bool:
	return game.wave_spawn_theme.changed if game.wave_spawn_theme != null else false


static func _theme_change_chance(game: GameState) -> float:
	return game.wave_spawn_theme.change_chance if game.wave_spawn_theme != null else 0.0


static func _theme_total_spawned(game: GameState) -> int:
	return game.wave_spawn_theme.total_spawned if game.wave_spawn_theme != null else 0


## "kind=n,kind=n" in the order of first spawn (the original's insertion order).
static func _theme_counts(game: GameState) -> String:
	if game.wave_spawn_theme == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for kind: Variant in game.wave_spawn_theme.counts.keys():
		parts.append("%s=%d" % [String(kind), int(game.wave_spawn_theme.counts[kind])])
	return ",".join(parts)


static func _theme_recent_mixed(game: GameState) -> String:
	return ",".join(game.wave_spawn_theme.recent_mixed) if game.wave_spawn_theme != null else ""


static func _featured_enemy_history(game: GameState) -> String:
	return ",".join(game.featured_enemy_history)


## The "name:type" entries of the ported fields of a group.
func ported_specs(group: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for field: Field in (_fields[group] as Array[Field]):
		out.append(field.spec)
	return out


## The reference fields of a group the port has no property for.
func unported_specs(group: String) -> PackedStringArray:
	var have: PackedStringArray = ported_specs(group)
	var out: PackedStringArray = PackedStringArray()
	var specs: Array = REFERENCE_FIELDS[group]
	for entry: Variant in specs:
		if not have.has(String(entry)):
			out.append(String(entry))
	return out


# --- hooking the slots ---------------------------------------------------------------------------------------------------

## Replaces every slot's system by a TracedSystem (once) and records the slot ids by list name.
func attach() -> void:
	var lists: Array = [sim.runner.intro, sim.runner.main, sim.runner.ko]
	for l: int in range(lists.size()):
		var ids: Array = []
		var list: Array = lists[l]
		for i: int in range(list.size()):
			var slot: SystemSlot = list[i]
			ids.append(slot.id)
			if not (slot.system is TracedSystem):
				slot.system = TracedSystem.new(slot.system, "%s:%d" % [LIST_NAMES[l], i], sink)
		slot_ids[LIST_NAMES[l]] = ids


# --- encoding ------------------------------------------------------------------------------------------------------------

## 16 lowercase hex digits of the big-endian bit pattern of `x`; any NaN is the canonical 7ff8000000000000.
static func hex_of(x: float) -> String:
	if is_nan(x):
		return "7ff8000000000000"
	return GoldenCodec.hex_of(x)


static func from_hex(hex: String) -> float:
	return GoldenCodec.from_hex(hex)


## Equality of two stored field values of type `type` (a parsed reference value may hold an integer as a float).
static func same_value(type: String, a: Variant, b: Variant) -> bool:
	match type:
		"i":
			return int(a) == int(b)
		"b":
			return bool(a) == bool(b)
	return String(a) == String(b)


static func state_name(game: GameState) -> String:
	return STATE_NAMES[int(game.state)]


func _read_row(fields: Array[Field], obj: Object) -> Array:
	var out: Array = []
	for field: Field in fields:
		var value: Variant = field.getter.call(obj) if field.getter.is_valid() else obj.get(field.property)
		match field.type:
			"f":
				out.append(hex_of(float(value)))
			"i":
				out.append(int(value))
			"b":
				out.append(bool(value))
			_:
				out.append(String(value))
	return out


func _read_list(group: String, items: Array) -> Array:
	var fields: Array[Field] = _fields[group]
	var out: Array = []
	for item: Variant in items:
		if item is Object:
			out.append(_read_row(fields, item as Object))
		else:
			out.append([])
	return out


## The movement input of a reference step, applied to the port the way the original's handlers leave `input`: the stick values
## (moveX / moveY, bit patterns) and the held movement keys. `input_row` is the step's "input" object.
static func apply_input(game: GameState, input_row: Dictionary) -> void:
	var inp: SimInput = game.input
	inp.clear()
	inp.move_x = from_hex(String(input_row["moveX"]))
	inp.move_y = from_hex(String(input_row["moveY"]))
	for code: Variant in (input_row["keys"] as Array):
		match String(code):
			"KeyA", "ArrowLeft":
				inp.key_left = true
			"KeyD", "ArrowRight":
				inp.key_right = true
			"KeyW", "ArrowUp":
				inp.key_up = true
			"KeyS", "ArrowDown":
				inp.key_down = true
			_:
				push_error("SimTrace.apply_input: %s is not a movement key" % String(code))


# --- recording -------------------------------------------------------------------------------------------------------------

## Starts the accounting of a step: forgets the previous step's slot draws and remembers the draw count. step_and_record() calls it.
func begin_step() -> void:
	sink.clear()
	_draws_before = sim.game.rng.draws


## Runs one fixed step of the sim under the given input (a reference step's "input" object) and returns the step's line as a
## Dictionary: capturePreviousTransforms(); update(FIXED_DT), exactly what the reference driver does.
func step_and_record(n: int, input_row: Dictionary) -> Dictionary:
	begin_step()
	apply_input(sim.game, input_row)
	sim.step(Sim.FIXED_DT)
	return record(n, input_row)


## The line for the state AFTER the step that was just made (the sink holds that step's draws).
func record(n: int, input_row: Dictionary) -> Dictionary:
	var game: GameState = sim.game
	var in_slots: int = 0
	var slot_draws: Dictionary = {}
	var keys: Array = sink.keys()
	keys.sort()
	for key: Variant in keys:
		slot_draws[key] = int(sink[key])
		in_slots += int(sink[key])
	var total: int = game.rng.draws - _draws_before
	var counts: Dictionary = {
		"enemies": game.enemies.size(), "projectiles": game.projectiles.size(), "xp_orbs": game.xp_orbs.size(),
		"particles": game.particles.size(), "enemy_projectiles": game.enemy_projectiles.size(), "hazards": game.hazards.size(),
	}
	return {
		"n": n,
		"input": input_row,
		"state": state_name(game),
		"draws": game.rng.draws,
		"slot_draws": slot_draws,
		"outside_draws": total - in_slots,
		"player": _read_row(_fields["player"], game.player),
		"camera": _read_row(_fields["camera"], game.camera),
		"wave": _read_row(_fields["wave"], game),
		"counts": counts,
		"enemies": _read_list("enemy", game.enemies),
		"projectiles": _read_list("projectile", game.projectiles),
		"xp_orbs": _read_list("xp_orb", game.xp_orbs),
	}


## The header of a port trace for a run made from `reference`'s configuration and inputs.
func make_header(reference: TraceReader, last_step: int) -> Dictionary:
	var config: SimConfig = sim.config
	var fields: Dictionary = {}
	var unported: Dictionary = {}
	for group: String in GROUPS:
		fields[group] = Array(ported_specs(group))
		unported[group] = Array(unported_specs(group))
	var header: Dictionary = {
		"format": FORMAT,
		"producer": PRODUCER,
		"source": {"path": "godot/sim", "engine": "Godot %s" % String(Engine.get_version_info()["string"])},
		"seed": config.rng_seed,
		"fx_seed": config.fx_seed,
		"character": config.character_id,
		"difficulty": config.difficulty,
		"mode": config.mode,
		"view": [int(config.view_w), int(config.view_h)],
		"coarse": config.coarse_pointer,
		"fixed_dt": hex_of(Sim.FIXED_DT),
		"new_game_draws": _new_game_draws,
		"input_script": reference.header.get("input_script", {}),
		"replayed_from": {"file": reference.path.get_file(), "source_sha256": (reference.header.get("source", {}) as Dictionary).get("sha256", "")},
		"slots": slot_ids,
		"fields": fields,
		"unported": unported,
		"count_fields": Array(COUNT_FIELDS),
		"stop": {"reason": "replayed", "step": last_step},
	}
	if reference.header.has("variant"):
		header["variant"] = reference.header["variant"]
		header["overrides"] = reference.header.get("overrides", {})
	return header


# --- replaying a reference trace -----------------------------------------------------------------------------------------

## The SimConfig that a reference trace was recorded with (seed, character, difficulty, mode, view, pointer, effects seed).
static func config_from_header(header: Dictionary) -> SimConfig:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = int(header["seed"])
	config.fx_seed = int(header.get("fx_seed", config.fx_seed))
	config.character_id = String(header["character"])
	config.difficulty = String(header["difficulty"])
	config.mode = String(header["mode"])
	var view: Array = header["view"]
	config.view_w = float(view[0])
	config.view_h = float(view[1])
	config.coarse_pointer = bool(header["coarse"])
	return config


## The player properties that a non-standard reference variant ("long_run", tools/reference-trace/capture.mjs --long-run) sets
## right after newGame(): header "overrides" maps "player.<referenceName>" to a float as hex. Only these three exist, the same
## list as ALLOWED_OVERRIDES in hook.js; anything else in a header is an error.
const OVERRIDE_PROPERTIES: PackedStringArray = ["player.xpNext", "player.hp", "player.maxHp"]


## Applies the header's overrides to a freshly started game. Returns false (after push_error) for an unknown key.
static func apply_overrides(game: GameState, overrides: Dictionary) -> bool:
	var ok: bool = true
	for key: Variant in overrides.keys():
		var override_name: String = String(key)
		if not OVERRIDE_PROPERTIES.has(override_name):
			push_error("SimTrace.apply_overrides: %s is not an override that the trace tools know (%s)" % [override_name, ", ".join(OVERRIDE_PROPERTIES)])
			ok = false
			continue
		game.player.set(snake_case(override_name.substr("player.".length())), from_hex(String(overrides[key])))
	return ok


## Replays the inputs of `reference` through a fresh Sim (same seed, character, difficulty, mode, view, and the overrides of a
## non-standard variant) for the first `until_step` steps (all of them when it is 0 or less). Returns
## { "header": Dictionary, "rows": Array of step Dictionaries }, empty when the sim cannot start the run.
static func replay(reference: TraceReader, until_step: int = 0) -> Dictionary:
	var sim: Sim = Sim.new()
	var config: SimConfig = config_from_header(reference.header)
	if not sim.new_game(config):
		return {}
	if not apply_overrides(sim.game, reference.header.get("overrides", {}) as Dictionary):
		return {}
	var trace: SimTrace = SimTrace.new(sim)
	var count: int = reference.steps.size() if until_step <= 0 else mini(until_step, reference.steps.size())
	var rows: Array = []
	rows.resize(count)
	for i: int in range(count):
		var ref_step: Dictionary = reference.steps[i]
		rows[i] = trace.step_and_record(int(ref_step["n"]), ref_step["input"])
	return {"header": trace.make_header(reference, count), "rows": rows}


# --- writing -------------------------------------------------------------------------------------------------------------

## The file's text: the header line and the step lines, each JSON on its own line, keys in insertion order.
static func to_text(header: Dictionary, rows: Array) -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append(JSON.stringify(header, "", false))
	for row: Variant in rows:
		lines.append(JSON.stringify(row, "", false))
	return "\n".join(lines) + "\n"


## Writes a trace; a path ending in .gz is gzip-compressed (a standard gzip stream: gunzip and Node's zlib read it).
## Returns true on success.
static func write_file(path: String, header: Dictionary, rows: Array) -> bool:
	var bytes: PackedByteArray = to_text(header, rows).to_utf8_buffer()
	if path.ends_with(".gz"):
		bytes = bytes.compress(FileAccess.COMPRESSION_GZIP)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("SimTrace: cannot write %s (error %d)" % [path, FileAccess.get_open_error()])
		return false
	file.store_buffer(bytes)
	file.close()
	return true
