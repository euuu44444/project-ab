class_name EnemyAi
extends RefCounted
## The enemy AI's tuning functions of the original: how well the enemies of this wave play (enemyAiSkillOf and the rank table), how long their
## attacks are announced (enemyAiTelegraph), how hard they dodge, how aggressive the difficulty makes them, and the coordination hooks of the
## higher difficulties. Pure functions of the game state; they draw nothing on normal difficulty.
##
## Difficulty. M1 plays normal. The branches of the other difficulties (hard, easy, nightmare: decision noise, think delays, squad coordination)
## draw from gameRandom and change the targets of the steering; they are not ported, and each reports with push_error when it is reached.

## One entry of ENEMY_AI_RANK_TUNING (res://sim/defs/enemies.json): the AI multipliers of a normal enemy, an elite and a boss.
class Tuning extends RefCounted:
	var skill: float = 1.0
	var think: float = 1.0
	var telegraph: float = 1.0
	var telegraph_min: float = 0.0
	var telegraph_max: float = 0.0
	var dodge: float = 1.0

static var _tunings: Dictionary = {}


## # port: enemyAiRankTuning (with enemyAiRank): `ENEMY_AI_RANK_TUNING[boss ? "boss" : elite ? "elite" : "normal"] || ENEMY_AI_RANK_TUNING.normal`
static func enemy_ai_rank_tuning(e: EnemyState) -> Tuning:
	var rank: String = "boss" if e.boss else ("elite" if e.elite else "normal")
	return rank_tuning(rank)


static func rank_tuning(rank: String) -> Tuning:
	if _tunings.is_empty():
		var table: Dictionary = Defs.value("enemies.json", "ENEMY_AI_RANK_TUNING")
		for key: Variant in table.keys():
			var entry: Dictionary = table[key]
			var tuning: Tuning = Tuning.new()
			tuning.skill = float(entry["skill"])
			tuning.think = float(entry["think"])
			tuning.telegraph = float(entry["telegraph"])
			tuning.telegraph_min = float(entry["telegraphMin"])
			tuning.telegraph_max = float(entry["telegraphMax"])
			tuning.dodge = float(entry["dodge"])
			_tunings[String(key)] = tuning
	return _tunings[rank] if _tunings.has(rank) else _tunings["normal"]


## # port: currentEnemyAiSkill. `game.enemyAiSkill` when it is a finite number (onWaveStart sets it), else enemyAiSkill(game.wave); on normal
## difficulty nothing is blended in.
static func current_enemy_ai_skill(game: GameState) -> float:
	var base: float = game.enemy_ai_skill if is_finite(game.enemy_ai_skill) else WaveRules.enemy_ai_skill(game.wave)
	if not game.is_difficulty("normal"):
		push_error("EnemyAi.current_enemy_ai_skill: the skill blend of the easy, hard and nightmare difficulties is not ported (M1 is normal only)")
	return base


## # port: enemyAiSkillOf. `clamp(base * enemyAiRankTuning(e).skill, 0, 0.995)`: 0.75 of the wave's skill for a normal enemy.
static func enemy_ai_skill_of(game: GameState, e: EnemyState) -> float:
	return JsMath.clamp(current_enemy_ai_skill(game) * enemy_ai_rank_tuning(e).skill, 0.0, 0.995)


## # port: enemyAiTelegraph. `applyRankTelegraph(e, Math.max(min, base * (1 - skill * 0.34)))` on normal difficulty.
static func enemy_ai_telegraph(game: GameState, base: float, minimum: float, e: EnemyState) -> float:
	var normal_telegraph: float = JsMath.js_max(minimum, base * (1.0 - enemy_ai_skill_of(game, e) * 0.34))
	if not game.is_difficulty("normal"):
		push_error("EnemyAi.enemy_ai_telegraph: the telegraph factors of the easy, hard and nightmare difficulties are not ported (M1 is normal only)")
	return apply_rank_telegraph(e, normal_telegraph)


## # port: applyRankTelegraph (with applyAnomalyTelegraph, which only changes an elite's or a boss's value when the af_telegraph anomaly factor
## is active; factors belong to meta runs, outside M1).
static func apply_rank_telegraph(e: EnemyState, value: float) -> float:
	if e == null:
		return value
	var t: Tuning = enemy_ai_rank_tuning(e)
	var v: float = value * t.telegraph
	if t.telegraph_min != 0.0:
		v = JsMath.js_max(t.telegraph_min, v)
	if t.telegraph_max != 0.0:
		v = JsMath.js_min(t.telegraph_max, v)
	return v


## # port: enemyAiDodgeMul. `1 + skill * 0.55 * dodge`, left to right.
static func enemy_ai_dodge_mul(game: GameState, e: EnemyState) -> float:
	return 1.0 + enemy_ai_skill_of(game, e) * 0.55 * enemy_ai_rank_tuning(e).dodge


## # port: difficultyAggression
static func difficulty_aggression(game: GameState) -> float:
	return game.current_difficulty().aggression


## # port: difficultyAttackRangeMul. `1 + (aggression - 1) * 0.12`
static func difficulty_attack_range_mul(game: GameState) -> float:
	return 1.0 + (difficulty_aggression(game) - 1.0) * 0.12


## # port: difficultyWaitMul. `1 / (0.82 + aggression * 0.18)`: exactly 1 on normal (aggression 1).
static func difficulty_wait_mul(game: GameState) -> float:
	return 1.0 / (0.82 + difficulty_aggression(game) * 0.18)


## # port: coordinatedAttackReady. Normal difficulty has no coordination: always ready. (easy: a decision timer, hard: a lock for high
## threats, nightmare: the squad's attack time; none of them is ported.)
static func coordinated_attack_ready(game: GameState, _e: EnemyState, _threat: String = "normal") -> bool:
	if not game.is_difficulty("normal"):
		push_error("EnemyAi.coordinated_attack_ready: the attack coordination of the easy, hard and nightmare difficulties is not ported (M1 is normal only)")
	return true


## # port: commitCoordinatedAttack. Nothing to commit on normal difficulty (the other difficulties draw rand(0.1, 0.24) / rand(0.15, 0.4) here).
static func commit_coordinated_attack(game: GameState, _e: EnemyState, _threat: String = "normal") -> void:
	if not game.is_difficulty("normal"):
		push_error("EnemyAi.commit_coordinated_attack: the attack coordination of the easy, hard and nightmare difficulties is not ported (M1 is normal only)")
