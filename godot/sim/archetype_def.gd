class_name ArchetypeDef
extends RefCounted
## One entry of the original's ENEMY_ARCHETYPES table: what the wave director needs to know about a kind.

var display_name: String = ""
var label: String = ""
## Spawn budget the director pays for one enemy.
var cost: float = 0.0
## First wave in which the kind may appear.
var unlock_wave: int = 0
var weight: float = 0.0
## Most enemies of the kind alive at once.
var cap: int = 0


func _init(entry: Dictionary = {}) -> void:
	display_name = String(entry.get("name", ""))
	label = String(entry.get("label", ""))
	cost = float(entry.get("cost", 0.0))
	unlock_wave = int(entry.get("unlockWave", 0))
	weight = float(entry.get("weight", 0.0))
	cap = int(entry.get("cap", 0))
