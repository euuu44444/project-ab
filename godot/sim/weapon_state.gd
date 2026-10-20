class_name WeaponState
extends RefCounted
## One entry of game.weapons (makeWeapon of the original).

var id: String = ""
var level: int = 1
## Seconds until the next shot.
var cooldown: float = 0.0
var ultimate_cd: float = 0.0
var shot_seq: int = 0
var elements: PackedStringArray = PackedStringArray()
var mod_pierce: int = 0
var mod_multishot: int = 0
var mod_explosive: int = 0
var mod_homing: int = 0


## # port: makeWeapon (without the blueprint branch, which M1's levels do not use: `useBlueprint` needs
## game.blueprintNext). Draws once: `cooldown: rand(0, 0.3)`.
static func make(weapon_id: String, rng: GameRng) -> WeaponState:
	var w: WeaponState = WeaponState.new()
	w.id = weapon_id
	w.level = 1
	w.cooldown = rng.rand(0.0, 0.3)
	return w
