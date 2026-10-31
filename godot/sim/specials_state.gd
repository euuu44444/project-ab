class_name SpecialsState
extends RefCounted
## game.specials of the original (makeSpecialsState): the run's special abilities of the character and their ranks.
## M1 has no ability system (design section 8): the catalyst's five loadout abilities exist with rank 0, nothing is
## active, and the final bonus counters are 0. The structure is here because weaponInterval, abilityRank and the
## meta-ability hooks of the movement code read it.

var char_id: String = ""
## ids of the abilities of the run's loadout (`specials.abilityIds`), in loadout order.
var ability_ids: PackedStringArray = PackedStringArray()
## ability id -> rank (int); all 0 in M1.
var ranks: Dictionary = {}
## Abilities with a "meta" stage (`specials.metaActive`); empty in M1, so metaAbilityOnMove is a no-op.
var meta_active: Array = []
var pending_ability_levels: Array = []
var current_choices: Array = []
var reroll_used: bool = false
## FINAL_BONUS counters (`specials.finalBonus`): how many times each final bonus was taken.
var final_bonus_damage: float = 0.0
var final_bonus_area: float = 0.0
var final_bonus_cooldown: float = 0.0
var intro_until: float = 0.0
var intro_level: int = 0


func _init(p_char_id: String = "", p_ability_ids: PackedStringArray = PackedStringArray()) -> void:
	char_id = p_char_id
	ability_ids = p_ability_ids
	for id: String in p_ability_ids:
		ranks[id] = 0


## abilityRank(id): the rank if it is above 0, else 0.
func rank(id: String) -> int:
	var v: int = int(ranks.get(id, 0))
	return v if v > 0 else 0


## currentAbilityList().length
func ability_count() -> int:
	return ability_ids.size()


## finalBonusStacks("cooldown"): the counter as a whole number of stacks (0 unless finite and positive).
func final_bonus_cooldown_stacks() -> float:
	var n: float = final_bonus_cooldown
	if is_finite(n) and n > 0.0:
		return floorf(n)
	return 0.0
