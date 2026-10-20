class_name WeaponDef
extends RefCounted
## One entry of the original's WEAPONS table (res://sim/defs/weapons.json).

var id: String = ""
var display_name: String = ""
var style: String = ""
var shape: String = ""
var color: String = ""
## Seconds per shot at attack speed 1 and weapon level 1 (the original calls it `rate`).
var rate: float = 0.0
## Base damage at weapon level 1.
var damage: float = 0.0
var speed: float = 0.0
var range_px: float = 0.0
## The character this weapon belongs to ("" for the shared weapons).
var signature_for: String = ""
var raw: Dictionary = {}


func _init(p_id: String = "", entry: Dictionary = {}) -> void:
	raw = entry
	id = p_id
	display_name = String(entry.get("name", ""))
	style = String(entry.get("style", ""))
	shape = String(entry.get("shape", ""))
	color = String(entry.get("color", ""))
	rate = float(entry.get("rate", 0.0))
	damage = float(entry.get("damage", 0.0))
	speed = float(entry.get("speed", 0.0))
	range_px = float(entry.get("range", 0.0))
	signature_for = String(entry.get("signatureFor", ""))
