class_name CharacterDef
extends RefCounted
## One entry of the original's CHARACTERS table (res://sim/defs/characters.json).
##
## hp and speed are always present. The other stats are optional in the original and read with `??` or `||`
## in newGame(); nullish() and truthy() have exactly those semantics, so the fallbacks stay next to the code
## that ports the expression. The text fields (name, desc, icon, accent, role) are kept for the UI.

var id: String = ""
var display_name: String = ""
var hp: float = 0.0
var speed: float = 0.0
var raw: Dictionary = {}


func _init(entry: Dictionary = {}) -> void:
	raw = entry
	id = String(entry.get("id", ""))
	display_name = String(entry.get("name", ""))
	hp = float(entry.get("hp", 0.0))
	speed = float(entry.get("speed", 0.0))


## `c.key ?? fallback`: the fallback only when the key is absent (the extracted data holds no null).
func nullish(key: String, fallback: float) -> float:
	if not raw.has(key) or raw[key] == null:
		return fallback
	return float(raw[key])


## `c.key || fallback`: the fallback when the key is absent or 0 (or NaN).
func truthy(key: String, fallback: float) -> float:
	if not raw.has(key):
		return fallback
	var v: float = float(raw[key])
	if v == 0.0 or is_nan(v):
		return fallback
	return v


## `!!c.key` for a boolean or number field.
func flag(key: String) -> bool:
	if not raw.has(key):
		return false
	var v: Variant = raw[key]
	if v is bool:
		return v
	if v is float or v is int:
		return float(v) != 0.0 and not is_nan(float(v))
	return v != null


func has_key(key: String) -> bool:
	return raw.has(key)


## `Array.isArray(c.key)`: the strings of an array field, or null if it is not an array.
func string_list(key: String) -> Variant:
	if not (raw.get(key) is Array):
		return null
	var out: PackedStringArray = PackedStringArray()
	for item: Variant in raw[key] as Array:
		out.append(String(item))
	return out
