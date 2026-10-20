class_name DifficultyDef
extends RefCounted
## One entry of the original's DIFFICULTY_CONFIG (res://sim/defs/rules.json). Every field is a float; the AI
## fields are used from step S5 on. predictionMax is Infinity for "normal".

var label: String = ""
var enemy_hp: float = 1.0
var enemy_damage: float = 1.0
var spawn_rate: float = 1.0
var enemy_speed: float = 1.0
var xp: float = 1.0
var score: float = 1.0
var ai_think: float = 1.0
var decision_error: float = 0.0
var skill_blend: float = 0.0
var aggression: float = 1.0
var prediction_min: float = 0.0
var prediction_max: float = INF
var elite_hp: float = 1.0
var elite_attack_cd: float = 1.0
var elite_ability_cd: float = 1.0
var boss_hp: float = 1.0
var boss_attack_cd: float = 1.0
var boss_projectile_speed: float = 1.0


func _init(entry: Dictionary = {}) -> void:
	label = String(entry.get("label", ""))
	enemy_hp = float(entry.get("enemyHp", 1.0))
	enemy_damage = float(entry.get("enemyDamage", 1.0))
	spawn_rate = float(entry.get("spawnRate", 1.0))
	enemy_speed = float(entry.get("enemySpeed", 1.0))
	xp = float(entry.get("xp", 1.0))
	score = float(entry.get("score", 1.0))
	ai_think = float(entry.get("aiThink", 1.0))
	decision_error = float(entry.get("decisionError", 0.0))
	skill_blend = float(entry.get("skillBlend", 0.0))
	aggression = float(entry.get("aggression", 1.0))
	prediction_min = float(entry.get("predictionMin", 0.0))
	prediction_max = float(entry.get("predictionMax", INF))
	elite_hp = float(entry.get("eliteHp", 1.0))
	elite_attack_cd = float(entry.get("eliteAttackCd", 1.0))
	elite_ability_cd = float(entry.get("eliteAbilityCd", 1.0))
	boss_hp = float(entry.get("bossHp", 1.0))
	boss_attack_cd = float(entry.get("bossAttackCd", 1.0))
	boss_projectile_speed = float(entry.get("bossProjectileSpeed", 1.0))
