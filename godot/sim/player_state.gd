class_name PlayerState
extends RefCounted
## game.player of the original. Fields follow the object literal of newGame() one to one (camelCase -> snake_case);
## from_character() is that literal. vx, vy, ax, ay, prev_x, prev_y and ko_art_id are not in the literal: the game
## creates them later and reads them with `|| 0`, so they start at 0 here.
##
## All numbers are 64-bit floats (JavaScript numbers); only counters are ints.

# position and body
var x: float = 0.0
var y: float = 0.0
var r: float = 13.0
var hp: float = 0.0
var max_hp: float = 0.0
var speed: float = 0.0
# damage multipliers (as additive bonuses: `(c.directDamageMul ?? 1) - 1`)
var general_damage_bonus: float = 0.0
var direct_damage_bonus: float = 0.0
var dot_damage_bonus: float = 0.0
var reaction_damage_bonus: float = 0.0
var structure_damage_bonus: float = 0.0
var true_damage_bonus: float = 0.0
var elem_mul: float = 1.0
var base_elem_mul: float = 1.0
# arcanist
var arcanist_reaction_stacks: float = 0.0
var arcanist_reaction_bonus: float = 0.0
var arcanist_reaction_boost: float = 0.0
var arcanist_reaction_last_at_by_key: Dictionary = {}
var reaction_growth: bool = false
# shared modifiers
var projectile_speed_mul: float = 1.0
var reaction_cooldown_mul: float = 1.0
var affliction_duration_mul: float = 1.0
var earth_wood_reaction_cooldown_mul: float = 1.0
# ranger
var strata_max: float = 8.0
var seed_growth_rate_mul: float = 1.0
var wood_direct_damage_penalty_immune: bool = false
var wood_death_grove_ignore_cooldown: bool = false
var wood_grove_ignore_damage_cap: bool = false
var wood_grove_heal_ratio: float = 0.04
## null for characters without an element restriction, else the allowed element ids.
var allowed_elements: Variant = null
# defense and experience
var defense: float = 0.0
var hazard_defense_bonus: float = 0.0
var xp_mul: float = 1.5
# archivist bank
var innate_bank: bool = false
var bank_damage_per_level: float = 0.0
var bank_crit_per_level: float = 0.0
var bank_crit_damage_per_level: float = 0.0
var bank_max_hp_per_level: float = 0.0
var bank_defense_per_level: float = 0.0
var bank_move_speed_per_level: float = 0.0
var bank_xp_penalty_per_level: float = 0.0
var bank_regen_per_level: float = 0.0
var base_defense_penalty: float = 0.0
var archivist_bank_applied_power: float = 0.0
# level and experience
var level: int = 1
var xp: float = 0.0
## The requirement before the multiplier (a float: Math.floor of a double); xp_next is the amount needed now.
var xp_base_next: float = 0.0
var xp_next: float = 0.0
# combat stats
var pickup: float = 88.0
var crit: float = 0.05
var crit_mul: float = 1.75
var attack_speed: float = 1.0
var area: float = 1.0
var knock: float = 1.0
var control_slow: float = 1.0
var regen: float = 0.0
var last_hit: float = -99.0
var miko_shield: float = 0.0
var final_area_applied: float = 1.0
# animation
var walk_phase: float = 0.0
var attack_anim: float = 0.0
var attack_anim_max: float = 0.28
var attack_angle: float = 0.0
var last_facing: float = 0.0
## id of the weapon that started the current attack animation ("" = none, the original's null).
var last_attack_weapon: String = ""
# knock-out
var ko_timer: float = 0.0
var ko_anim_max: float = 0.96
var ko_art_id: String = ""
# contract damage over time
var contract_burn: float = 0.0
var contract_burn_dps: float = 0.0
var contract_poison: float = 0.0
var contract_poison_dps: float = 0.0
var reaction_buffs: ReactionBuffs = ReactionBuffs.new()
# not in newGame's literal
var vx: float = 0.0
var vy: float = 0.0
var ax: float = 0.0
var ay: float = 0.0
var prev_x: float = 0.0
var prev_y: float = 0.0


## The `player: {...}` literal of newGame(). `c.key ?? d` is c.nullish(key, d), `c.key || d` is c.truthy(key, d).
static func from_character(c: CharacterDef, limits: SimLimits) -> PlayerState:
	var rules: SimRules = Defs.rules()
	var p: PlayerState = PlayerState.new()
	p.x = limits.map_w / 2.0
	p.y = limits.map_h / 2.0
	p.r = 13.0
	p.hp = c.hp
	p.max_hp = c.hp
	p.speed = c.speed
	p.general_damage_bonus = c.nullish("damageMul", 1.0) - 1.0
	p.direct_damage_bonus = c.nullish("directDamageMul", 1.0) - 1.0
	p.dot_damage_bonus = c.nullish("dotDamageMul", 1.0) - 1.0
	p.reaction_damage_bonus = c.nullish("reactionDamageMul", 1.0) - 1.0
	p.structure_damage_bonus = c.nullish("structureDamageMul", 1.0) - 1.0
	p.true_damage_bonus = c.nullish("trueDamageMul", 1.0) - 1.0
	p.elem_mul = c.nullish("elemMul", 1.0)
	p.base_elem_mul = c.nullish("elemMul", 1.0)
	p.reaction_growth = c.flag("reactionGrowth")
	p.projectile_speed_mul = c.nullish("projectileSpeed", 1.0)
	p.reaction_cooldown_mul = c.nullish("reactionCooldownMul", 1.0)
	p.affliction_duration_mul = c.nullish("afflictionDurationMul", 1.0)
	p.earth_wood_reaction_cooldown_mul = c.truthy("earthWoodReactionCooldownMul", 1.0)
	p.strata_max = c.truthy("strataMax", 8.0)
	p.seed_growth_rate_mul = c.truthy("seedGrowthRateMul", 1.0)
	p.wood_direct_damage_penalty_immune = c.flag("woodDirectDamagePenaltyImmune")
	p.wood_death_grove_ignore_cooldown = c.flag("woodDeathGroveIgnoreCooldown")
	p.wood_grove_ignore_damage_cap = c.flag("woodGroveIgnoreDamageCap")
	p.wood_grove_heal_ratio = c.nullish("woodGroveHealRatio", 0.04)
	p.allowed_elements = c.string_list("allowedElements")
	p.defense = c.nullish("defense", 0.0)
	p.hazard_defense_bonus = 0.0
	p.xp_mul = c.nullish("xpMul", 1.5)
	p.innate_bank = c.flag("innateBank")
	p.bank_damage_per_level = c.truthy("bankDamagePerLevel", 0.0)
	p.bank_crit_per_level = c.truthy("bankCritPerLevel", 0.0)
	p.bank_crit_damage_per_level = c.truthy("bankCritDamagePerLevel", 0.0)
	p.bank_max_hp_per_level = c.truthy("bankMaxHpPerLevel", 0.0)
	p.bank_defense_per_level = c.truthy("bankDefensePerLevel", 0.0)
	p.bank_move_speed_per_level = c.truthy("bankMoveSpeedPerLevel", 0.0)
	p.bank_xp_penalty_per_level = c.truthy("bankXpPenaltyPerLevel", 0.0)
	p.bank_regen_per_level = c.truthy("bankRegenPerLevel", 0.0)
	p.base_defense_penalty = c.truthy("baseDefensePenalty", 0.0)
	p.level = 1
	p.xp = 0.0
	p.xp_base_next = rules.xp_initial_requirement
	p.xp_next = Formulas.initial_xp_next()
	p.pickup = c.nullish("pickup", 88.0)
	p.crit = c.nullish("crit", 0.05)
	p.crit_mul = c.nullish("critMul", 1.75)
	p.attack_speed = c.nullish("attackSpeed", 1.0)
	p.area = c.nullish("area", 1.0)
	p.knock = c.nullish("knock", 1.0)
	p.regen = c.nullish("regen", 0.0)
	return p
