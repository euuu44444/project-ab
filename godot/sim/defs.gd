class_name Defs
extends RefCounted
## Loader of the definition data that tools/extract_defs.mjs cuts out of the original game (design step S3).
##
## The five files under res://sim/defs/ hold the game's own constant declarations (CHARACTERS, WEAPONS,
## ENEMY_ARCHETYPES, DIFFICULTY_CONFIG, XP_CURVE, limits, ...) under their original names in "values", and the
## three constants that depend on the device (MAX_PROJECTILES, ...) as "pointer": {"coarse": ..., "fine": ...}.
## They are generated, never edited by hand (tools/extract_defs.mjs --check fails on drift).
##
## JSON numbers: JSON.parse_string returns a float for every number, whether it is 100 or 0.25. The typed
## wrappers (CharacterDef, WeaponDef, DifficultyDef, ArchetypeDef, SimRules, SimLimits) turn them into int or
## float explicitly. JSON cannot hold Infinity, NaN or -0, so the extractor writes them as {"$num": "Infinity"}
## and so on, and it writes decimals with more than 15 significant digits (1/60 and the like, which Godot's JSON parser
## reads one ulp off) as {"$num": "f64:<16 hex digits of the IEEE-754 bits>"}; this loader restores them while reading.
## tests/test_defs.gd compares every non-integer number bit for bit with tests/golden/defs_bits.json (taken from the
## original) so that a mismatch cannot go unnoticed.
##
## Everything is loaded once and cached in static variables; the sim only reads it. The loader reports problems
## with push_error and returns empty values (a missing or broken file is a build error, not a game state).

const DEFS_DIR: String = "res://sim/defs"
const FILE_NAMES: PackedStringArray = [
	"characters.json", "weapons.json", "enemies.json", "rules.json", "limits.json",
]
const NUM_KEY: String = "$num"

static var _files: Dictionary = {}
static var _characters: Dictionary = {}
static var _character_ids: PackedStringArray = PackedStringArray()
static var _weapons: Dictionary = {}
static var _weapon_ids: PackedStringArray = PackedStringArray()
static var _difficulties: Dictionary = {}
static var _difficulty_keys: PackedStringArray = PackedStringArray()
static var _archetypes: Dictionary = {}
static var _rules: SimRules = null
static var _limits_coarse: SimLimits = null
static var _limits_fine: SimLimits = null


## The parsed file (a Dictionary with "values" and maybe "pointer"), restored numbers included.
static func file(file_name: String) -> Dictionary:
	if _files.has(file_name):
		return _files[file_name]
	var parsed: Dictionary = _read(file_name)
	_files[file_name] = parsed
	return parsed


## One constant of the original under its original name, e.g. value("rules.json", "XP_CURVE").
static func value(file_name: String, constant: String) -> Variant:
	var values: Dictionary = file(file_name).get("values", {})
	if not values.has(constant):
		push_error("Defs: %s has no constant %s" % [file_name, constant])
		return null
	return values[constant]


## A pointer-dependent constant ("coarse" = Android/touch, "fine" = mouse).
static func pointer_value(file_name: String, constant: String, coarse: bool) -> Variant:
	var pointer: Dictionary = file(file_name).get("pointer", {})
	var variant: Dictionary = pointer.get("coarse" if coarse else "fine", {})
	if not variant.has(constant):
		push_error("Defs: %s has no pointer constant %s" % [file_name, constant])
		return null
	return variant[constant]


static func character_ids() -> PackedStringArray:
	_ensure_characters()
	return _character_ids


static func has_character(id: String) -> bool:
	_ensure_characters()
	return _characters.has(id)


static func character(id: String) -> CharacterDef:
	_ensure_characters()
	if not _characters.has(id):
		push_error("Defs: unknown character '%s'" % id)
		return null
	return _characters[id]


static func weapon_ids() -> PackedStringArray:
	_ensure_weapons()
	return _weapon_ids


static func has_weapon(id: String) -> bool:
	_ensure_weapons()
	return _weapons.has(id)


static func weapon(id: String) -> WeaponDef:
	_ensure_weapons()
	if not _weapons.has(id):
		push_error("Defs: unknown weapon '%s'" % id)
		return null
	return _weapons[id]


## The weapon the character starts with (SIGNATURE_WEAPON_BY_CHARACTER[id] || "pulse").
static func signature_weapon_id(character_id: String) -> String:
	var by_character: Dictionary = value("characters.json", "SIGNATURE_WEAPON_BY_CHARACTER")
	if by_character.has(character_id):
		return String(by_character[character_id])
	return "pulse"


static func difficulty_keys() -> PackedStringArray:
	_ensure_difficulties()
	return _difficulty_keys


static func has_difficulty(key: String) -> bool:
	_ensure_difficulties()
	return _difficulties.has(key)


## DIFFICULTY_CONFIG[key]; an unknown key gives the "normal" entry, like currentDifficulty() of the game.
static func difficulty(key: String) -> DifficultyDef:
	_ensure_difficulties()
	if _difficulties.has(key):
		return _difficulties[key]
	return _difficulties["normal"]


static func archetype_kinds() -> PackedStringArray:
	_ensure_archetypes()
	var kinds: PackedStringArray = PackedStringArray()
	for kind: Variant in value("enemies.json", "ENEMY_KIND_ORDER"):
		kinds.append(String(kind))
	return kinds


static func has_archetype(kind: String) -> bool:
	_ensure_archetypes()
	return _archetypes.has(kind)


static func archetype(kind: String) -> ArchetypeDef:
	_ensure_archetypes()
	if not _archetypes.has(kind):
		push_error("Defs: unknown enemy archetype '%s'" % kind)
		return null
	return _archetypes[kind]


static func rules() -> SimRules:
	if _rules == null:
		_rules = SimRules.new()
	return _rules


## The limits of one pointer variant. The simulation uses the coarse one (Android, touch).
static func limits(coarse: bool = true) -> SimLimits:
	if coarse:
		if _limits_coarse == null:
			_limits_coarse = SimLimits.new(true)
		return _limits_coarse
	if _limits_fine == null:
		_limits_fine = SimLimits.new(false)
	return _limits_fine


## Forgets everything that was loaded (tests of the loader itself).
static func reset_cache() -> void:
	_files = {}
	_characters = {}
	_character_ids = PackedStringArray()
	_weapons = {}
	_weapon_ids = PackedStringArray()
	_difficulties = {}
	_difficulty_keys = PackedStringArray()
	_archetypes = {}
	_rules = null
	_limits_coarse = null
	_limits_fine = null


# --- loading ------------------------------------------------------------------------------------

static func _read(file_name: String) -> Dictionary:
	var path: String = DEFS_DIR.path_join(file_name)
	if not FileAccess.file_exists(path):
		push_error("Defs: %s does not exist" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("Defs: %s is not a JSON object" % path)
		return {}
	var root: Dictionary = parsed
	if int(root.get("format", 0)) != 1:
		push_error("Defs: %s has an unsupported format" % path)
		return {}
	return _restore_numbers(root) as Dictionary


## Replaces {"$num": "Infinity" | "-Infinity" | "NaN" | "-0"} by the number, anywhere in the tree.
static func _restore_numbers(node: Variant) -> Variant:
	if node is Dictionary:
		var dict: Dictionary = node
		if dict.size() == 1 and dict.has(NUM_KEY):
			var marker: String = String(dict[NUM_KEY])
			match marker:
				"Infinity":
					return INF
				"-Infinity":
					return -INF
				"NaN":
					return NAN
				"-0":
					return -0.0
			if marker.begins_with("f64:") and marker.length() == 20:
				return _double_from_hex(marker.substr(4))
			push_error("Defs: unknown number marker %s" % marker)
			return 0.0
		for key: Variant in dict.keys():
			dict[key] = _restore_numbers(dict[key])
		return dict
	if node is Array:
		var array: Array = node
		for i: int in array.size():
			array[i] = _restore_numbers(array[i])
		return array
	return node


## The double with the given IEEE-754 bit pattern (16 hex digits, most significant first).
static func _double_from_hex(hex: String) -> float:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(8)
	bytes.encode_u32(4, hex.substr(0, 8).hex_to_int())
	bytes.encode_u32(0, hex.substr(8, 8).hex_to_int())
	return bytes.decode_double(0)


static func _ensure_characters() -> void:
	if not _characters.is_empty():
		return
	for entry: Variant in value("characters.json", "CHARACTERS"):
		var def: CharacterDef = CharacterDef.new(entry as Dictionary)
		_characters[def.id] = def
		_character_ids.append(def.id)


static func _ensure_weapons() -> void:
	if not _weapons.is_empty():
		return
	var table: Dictionary = value("weapons.json", "WEAPONS")
	for id: Variant in table.keys():
		var def: WeaponDef = WeaponDef.new(String(id), table[id] as Dictionary)
		_weapons[def.id] = def
		_weapon_ids.append(def.id)


static func _ensure_difficulties() -> void:
	if not _difficulties.is_empty():
		return
	var table: Dictionary = value("rules.json", "DIFFICULTY_CONFIG")
	for key: Variant in value("rules.json", "DIFFICULTY_KEYS"):
		_difficulties[String(key)] = DifficultyDef.new(table[key] as Dictionary)
		_difficulty_keys.append(String(key))


static func _ensure_archetypes() -> void:
	if not _archetypes.is_empty():
		return
	var table: Dictionary = value("enemies.json", "ENEMY_ARCHETYPES")
	for kind: Variant in table.keys():
		_archetypes[String(kind)] = ArchetypeDef.new(table[kind] as Dictionary)
