class_name SimRules
extends RefCounted
## The numeric rules of the original that the simulation reads, typed once from res://sim/defs/*.json.
## (Obtain the shared instance with Defs.rules().) Names follow the original constants; the comment on each
## group names the declaration it comes from.

# rules.json
var wave_duration: float = 0.0               # WAVE_DURATION
var max_wave: int = 0                        # MAX_WAVE
var day_cycle_seconds: float = 0.0           # DAY_CYCLE_SECONDS (= WAVE_DURATION * 4)
var fixed_dt: float = 0.0                    # FIXED_DT (1/60)
var max_steps_per_frame: int = 0             # MAX_STEPS_PER_FRAME
var max_accumulated_seconds: float = 0.0     # MAX_ACCUMULATED_SECONDS
var level_up_choice_delay_seconds: float = 0.0  # LEVEL_UP_CHOICE_DELAY_SECONDS
var move_stick_max: float = 0.0              # MOVE_STICK_MAX
var xp_initial_requirement: float = 0.0      # XP_CURVE
var xp_growth_multiplier: float = 0.0
var xp_flat_growth: float = 0.0
var xp_requirement_multiplier: float = 0.0
var safe_attack_interval: float = 0.0        # SAFE_ATTACK_INTERVAL
var final_bonus_step_cooldown: float = 0.0   # FINAL_BONUS_STEP.cooldown
var walk_fps_min: float = 0.0                # CHARACTER_ANIMATION_FPS.walkMin / walkMax
var walk_fps_max: float = 0.0
var berserker_attack_speed_per_stack: float = 0.0  # BERSERKER_CONFIG.attackSpeedPerStack

# enemies.json
var featured_initial_change_chance: float = 0.0  # FEATURED_WAVE_CONFIG
var featured_share: float = 0.0
var director_budget_cap: float = 0.0         # DIRECTOR_BUDGET_CAP
var enemy_armor_max: float = 0.0             # ENEMY_ARMOR_MAX
var endless_enemy_stat_cap: float = 0.0      # ENDLESS_ENEMY_STAT_CAP
var endless_enemy_speed_cap: float = 0.0     # ENDLESS_ENEMY_SPEED_CAP
var endless_action_cooldown_min: float = 0.0  # ENDLESS_ACTION_COOLDOWN_MIN
var endless_armor_per_50_waves: float = 0.0  # ENDLESS_ARMOR_PER_50_WAVES
var endless_evasion_per_50_waves: float = 0.0  # ENDLESS_EVASION_PER_50_WAVES


func _init() -> void:
	wave_duration = _num("rules.json", "WAVE_DURATION")
	max_wave = int(_num("rules.json", "MAX_WAVE"))
	day_cycle_seconds = _num("rules.json", "DAY_CYCLE_SECONDS")
	fixed_dt = _num("rules.json", "FIXED_DT")
	max_steps_per_frame = int(_num("rules.json", "MAX_STEPS_PER_FRAME"))
	max_accumulated_seconds = _num("rules.json", "MAX_ACCUMULATED_SECONDS")
	level_up_choice_delay_seconds = _num("rules.json", "LEVEL_UP_CHOICE_DELAY_SECONDS")
	move_stick_max = _num("rules.json", "MOVE_STICK_MAX")
	var xp_curve: Dictionary = Defs.value("rules.json", "XP_CURVE")
	xp_initial_requirement = float(xp_curve["initialRequirement"])
	xp_growth_multiplier = float(xp_curve["growthMultiplier"])
	xp_flat_growth = float(xp_curve["flatGrowth"])
	xp_requirement_multiplier = float(xp_curve["requirementMultiplier"])
	safe_attack_interval = _num("rules.json", "SAFE_ATTACK_INTERVAL")
	final_bonus_step_cooldown = float((Defs.value("rules.json", "FINAL_BONUS_STEP") as Dictionary)["cooldown"])
	var fps: Dictionary = Defs.value("characters.json", "CHARACTER_ANIMATION_FPS")
	walk_fps_min = float(fps["walkMin"])
	walk_fps_max = float(fps["walkMax"])
	berserker_attack_speed_per_stack = float((Defs.value("characters.json", "BERSERKER_CONFIG") as Dictionary)["attackSpeedPerStack"])

	var featured: Dictionary = Defs.value("enemies.json", "FEATURED_WAVE_CONFIG")
	featured_initial_change_chance = float(featured["initialChangeChance"])
	featured_share = float(featured["featuredShare"])
	director_budget_cap = _num("enemies.json", "DIRECTOR_BUDGET_CAP")
	enemy_armor_max = _num("enemies.json", "ENEMY_ARMOR_MAX")
	endless_enemy_stat_cap = _num("enemies.json", "ENDLESS_ENEMY_STAT_CAP")
	endless_enemy_speed_cap = _num("enemies.json", "ENDLESS_ENEMY_SPEED_CAP")
	endless_action_cooldown_min = _num("enemies.json", "ENDLESS_ACTION_COOLDOWN_MIN")
	endless_armor_per_50_waves = _num("enemies.json", "ENDLESS_ARMOR_PER_50_WAVES")
	endless_evasion_per_50_waves = _num("enemies.json", "ENDLESS_EVASION_PER_50_WAVES")


static func _num(file_name: String, constant: String) -> float:
	return float(Defs.value(file_name, constant))
