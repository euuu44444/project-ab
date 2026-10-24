class_name EnemyState
extends RefCounted
## One enemy of game.enemies: the object literal of spawnEnemy() (original.html @1204045) plus the keys the game adds later.
## Names are the original's, camelCase -> snake_case, so the trace schema finds them by name (SimTrace: `aiState` is
## `ai_state`). spawn_enemy() in enemy_director.gd fills it in the original's order, with the original's draws.
##
## Absent keys. swarm and assassin do not have `shoot`, `elite`, `boss` and `shield` (enemySpec only sets them for the kinds that
## shoot / elite / boss), nor `summonCd`, `decisionCd` and `tacticalAction` (hard/nightmare/non-normal only); the original reads
## every one of them with `||`, so "absent" is 0 / false here. `maxShield` is `s.shield || 0`.
##
## Keys the game adds after the spawn (not in the literal; the defaults here stand for "not yet written"):
##   prevX / prevY        capturePreviousTransforms (0 in the spawn step: the trace records the undefined as 0)
##   lastDamageWeaponId   the weapon that last hurt it (step S6)
##   deferStrataAuto, catBounceSeenAt   weapon/ability bookkeeping (step S6)
##   preferredSpecial     elite/boss ability choice; endRun resets it to ""
##
## Fields that only the weapons and the damage code write (hp, flash, afflictions, knockback ...) stay at their spawn values
## until step S6.

var id: int = 0
var x: float = 0.0
var y: float = 0.0
var vx: float = 0.0
var vy: float = 0.0
# --- enemySpec(kind, wave) ---------------------------------------------------------------------------------------
var kind: String = "swarm"
var r: float = 0.0
var hp: float = 0.0
var speed: float = 0.0
var damage: float = 0.0
var color: String = ""
var xp: float = 0.0
var armor: float = 0.0
var evasion: float = 0.0
var shoot: float = 0.0
var elite: bool = false
var boss: bool = false
var shield: float = 0.0
var projectile_speed_mul: float = 1.0
var action_cooldown_mul: float = 1.0
var ability_cooldown_mul: float = 1.0
# --- the literal's own keys ----------------------------------------------------------------------------------------
var spawn_wave: int = 0
var base_max_hp: float = 0.0
var max_hp: float = 0.0
var max_shield: float = 0.0
var status: EnemyStatus = EnemyStatus.new()
var strata: float = 0.0
var strata_timer: float = 0.0
var strata_stored: float = 0.0
var strata_locked: float = 0.0
var seed_timer: float = 0.0
var seed_power: float = 0.0
var seed_growth: float = 0.0
var seed_growth_mult: float = 1.0
var seed_generation: int = 0
var seed_weapon: WeaponState = null
var photosynthesis_timer: float = 0.0
var ice_core_stored: float = 0.0
var deep_erosion_mark: float = 0.0
var generic_resonance_streak: float = 0.0
## Object.create(null) maps in the original: afflictions, afflictionSrc, chainOwner, chainStates, reactionCd.
var afflictions: Dictionary = {}
var affliction_src: Dictionary = {}
var chain_owner: Dictionary = {}
var chain_states: Dictionary = {}
var reaction_cd: Dictionary = {}
var shoot_cd: float = 0.0
var flash: float = 0.0
## "idle" at spawn; the assassin also uses "windup", "dash" and "recover".
var ai_state: String = "idle"
var ai_timer: float = 0.0
var ability_cd: float = 0.0
var telegraph: float = 0.0
var attack_anim: float = 0.0
var attack_anim_max: float = 0.24
var fuse: float = 0.0
var fuse_started: bool = false
var exploded: bool = false
var dash_x: float = 0.0
var dash_y: float = 0.0
## 1 or -1 (`chance(0.5) ? 1 : -1`).
var strafe_dir: int = 1
var ai_seed: float = 0.0
var think_cd: float = 0.0
var facing: float = 0.0
var anim_phase: float = 0.0
var tactic_cd: float = 0.0
var tactic_pulse: float = 0.0
var dot_number_timer: float = 0.0
var dot_number_fire: float = 0.0
var dot_number_poison: float = 0.0
var special_abilities: PackedStringArray = PackedStringArray()
var special_cooldowns: Dictionary = {}
var special_state: EnemySpecialState = EnemySpecialState.new()
var special_motion_lock: bool = false
var last_damaged_at: float = -999.0
var squad_id: int = 0
var squad_role: String = "INDIVIDUAL"
var squad_target_x: float = 0.0
var squad_target_y: float = 0.0
var squad_target_until: float = 0.0
var squad_attack_at: float = 0.0
# --- keys the game adds later ----------------------------------------------------------------------------------------
var prev_x: float = 0.0
var prev_y: float = 0.0
var last_damage_weapon_id: String = ""
var defer_strata_auto: bool = false
var cat_bounce_seen_at: float = 0.0
var preferred_special: String = ""
