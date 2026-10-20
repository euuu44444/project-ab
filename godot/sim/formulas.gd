class_name Formulas
extends RefCounted
## Pure formulas of the original that the simulation and the tests share: enemySpec, the XP curve, weaponDamage and
## weaponInterval. Each function says which function of original.html it ports; tests/test_formulas.gd compares them
## bit for bit with values produced by running the original (tests/golden/formulas.json).
##
## Floating-point order is the original's (left to right, base -> difficulty -> endless -> contract); never regroup an
## expression. Numbers that are `Math.floor` / `Math.round` results stay floats, as in JavaScript.


## # port: enemySpec. The `game` fields it reads are passed in: difficulty key, mode, and the three multipliers.
## An unknown kind gives a swarm, like the original. Every call returns a new EnemySpec.
static func enemy_spec(kind: String, wave: int, difficulty_key: String, mode: String, enemy_stat_mult: float,
		enemy_speed_mult: float, contract_enemy_stat_mul: float) -> EnemySpec:
	var rules: SimRules = Defs.rules()
	var standard_speed_wave: int = mini(wave, 30)
	var scale: float = 1.0 + (standard_speed_wave - 1) * 0.055 + maxi(0, wave - 30) * 8e-3
	var hp_scale: float = 1.0 + (wave - 1) * 0.095
	var w: float = float(wave)
	var s: EnemySpec = EnemySpec.new()
	match kind:
		"swarm":
			_fill(s, "swarm", 10.0, 28.0 * hp_scale, 72.0 * scale, 9.0 + w * 0.34, "#ef6b71", 8.0, 0.03, 0.02)
		"artillery":
			_fill(s, "artillery", 12.0, 46.0 * hp_scale, 53.0 * scale, 12.0 + w * 0.4, "#d87fd4", 14.0, 0.07, 0.04)
			s.shoot = 2.1
		"tank":
			_fill(s, "tank", 19.0, 148.0 * hp_scale, 39.0 * scale, 21.0 + w * 0.62, "#b94f58", 24.0, 0.27, 0.0)
		"support":
			_fill(s, "support", 12.0, 58.0 * hp_scale, 55.0 * scale, 5.0 + w * 0.18, "#65d5a3", 21.0, 0.09, 0.04)
		"controller":
			_fill(s, "controller", 13.0, 65.0 * hp_scale, 48.0 * scale, 7.0 + w * 0.22, "#7586e8", 23.0, 0.1, 0.05)
		"assassin":
			_fill(s, "assassin", 9.0, 35.0 * hp_scale, 78.0 * scale, 18.0 + w * 0.48, "#ff9c58", 16.0, 0.03, 0.14)
		"bomber":
			_fill(s, "bomber", 11.0, 42.0 * hp_scale, 82.0 * scale, 34.0 + w * 0.75, "#ffcc58", 17.0, 0.02, 0.04)
		"elite":
			_fill(s, "elite", 24.0, 560.0 * hp_scale, 55.0 * scale, 25.0 + w * 0.65, "#ffb64d", 95.0, 0.3, 0.03)
			s.elite = true
			s.shield = 180.0 * hp_scale
		"boss":
			var boss_hp_scale: float = 1.0 + (wave - 1) * 0.135
			_fill(s, "boss", 44.0, 2800.0 * boss_hp_scale, 38.0 * scale, 35.0 + w * 0.85, "#ff5268", 500.0, 0.36, 0.0)
			s.boss = true
			s.shoot = 1.6
			s.shield = 540.0 * boss_hp_scale
		_:
			_fill(s, "swarm", 10.0, 28.0 * hp_scale, 72.0 * scale, 9.0 + w * 0.34, "#ef6b71", 8.0, 0.03, 0.02)

	var difficulty: DifficultyDef = Defs.difficulty(difficulty_key)
	var boss_or_elite_hp: float = difficulty.boss_hp if s.boss else (difficulty.elite_hp if s.elite else 1.0)
	var difficulty_hp_mul: float = difficulty.enemy_hp * boss_or_elite_hp
	s.hp *= difficulty_hp_mul
	s.damage *= difficulty.enemy_damage
	s.speed *= difficulty.enemy_speed
	if s.shield != 0.0:
		s.shield *= difficulty_hp_mul

	var difficulty_attack_cd: float = difficulty.boss_attack_cd if s.boss else (difficulty.elite_attack_cd if s.elite else 1.0)
	var difficulty_ability_cd: float = difficulty.boss_attack_cd if s.boss else (difficulty.elite_ability_cd if s.elite else 1.0)
	s.projectile_speed_mul = difficulty.boss_projectile_speed if s.boss else 1.0
	var progression_cooldown_mul: float = 1.0

	if mode == "endless":
		var m: float = JsMath.js_min(rules.endless_enemy_stat_cap, JsMath.js_max(1.0, _or_one(enemy_stat_mult)))
		s.hp *= m
		s.damage *= m
		s.speed *= JsMath.js_min(rules.endless_enemy_speed_cap, JsMath.js_max(1.0, _or_one(enemy_speed_mult)))
		var defense_milestones: float = floorf(float(maxi(0, wave - 1)) / 50.0)
		s.armor = JsMath.js_min(rules.enemy_armor_max, s.armor + defense_milestones * rules.endless_armor_per_50_waves)
		s.evasion = JsMath.js_min(0.45, s.evasion + defense_milestones * rules.endless_evasion_per_50_waves)
		if s.shield != 0.0:
			s.shield *= m
		progression_cooldown_mul = JsMath.js_max(rules.endless_action_cooldown_min, 1.0 / m)

	# The game always has a `game` while it plays, so this block always runs (with cm = 1 it multiplies by 1).
	var cm: float = JsMath.js_max(1.0, _or_one(contract_enemy_stat_mul))
	s.hp *= cm
	s.speed *= cm
	s.damage *= cm
	s.armor = JsMath.js_min(rules.enemy_armor_max, s.armor * cm)
	s.evasion = JsMath.js_min(0.45, s.evasion * cm)
	if s.shield != 0.0:
		s.shield *= cm
	progression_cooldown_mul = JsMath.js_max(rules.endless_action_cooldown_min, progression_cooldown_mul / cm)

	s.action_cooldown_mul = progression_cooldown_mul * difficulty_attack_cd
	s.ability_cooldown_mul = progression_cooldown_mul * difficulty_ability_cd
	return s


## enemySpec for the state of a running game.
static func enemy_spec_for_game(kind: String, wave: int, game: GameState) -> EnemySpec:
	return enemy_spec(kind, wave, game.difficulty, game.mode, game.enemy_stat_mult, game.enemy_speed_mult, game.contract_enemy_stat_mul)


static func _fill(s: EnemySpec, kind: String, r: float, hp: float, speed: float, damage: float, color: String,
		xp: float, armor: float, evasion: float) -> void:
	s.kind = kind
	s.r = r
	s.hp = hp
	s.speed = speed
	s.damage = damage
	s.color = color
	s.xp = xp
	s.armor = armor
	s.evasion = evasion


## `x || 1` for a number: 1 when x is 0 or NaN.
static func _or_one(x: float) -> float:
	if x == 0.0 or is_nan(x):
		return 1.0
	return x


# --- XP curve -----------------------------------------------------------------------------------

## newGame: `xpBaseNext: XP_CURVE.initialRequirement`.
static func initial_xp_base_next() -> float:
	return Defs.rules().xp_initial_requirement


## newGame: `xpNext: Math.round(XP_CURVE.initialRequirement * XP_CURVE.requirementMultiplier)`.
static func initial_xp_next() -> float:
	var rules: SimRules = Defs.rules()
	return JsMath.js_round(rules.xp_initial_requirement * rules.xp_requirement_multiplier)


## gainXp: `p.xpBaseNext = Math.floor(p.xpBaseNext * XP_CURVE.growthMultiplier + XP_CURVE.flatGrowth)`.
static func next_xp_base(xp_base_next: float) -> float:
	var rules: SimRules = Defs.rules()
	return floorf(xp_base_next * rules.xp_growth_multiplier + rules.xp_flat_growth)


## gainXp: `p.xpNext = Math.round(p.xpBaseNext * XP_CURVE.requirementMultiplier)`.
static func xp_next_for(xp_base_next: float) -> float:
	return JsMath.js_round(xp_base_next * Defs.rules().xp_requirement_multiplier)


# --- weapons ------------------------------------------------------------------------------------

## # port: weaponDamage. `WEAPONS[w.id].damage * (1 + (w.level - 1) * 0.15)`. The weapon level has no cap.
static func weapon_damage(weapon_id: String, level: int) -> float:
	var def: WeaponDef = Defs.weapon(weapon_id)
	if def == null:
		return 0.0
	return def.damage * (1.0 + (level - 1) * 0.15)


## # port: weaponRawInterval (and, through it, effectivePlayerAttackSpeed, abilityWeaponSpeedMul, finalCooldownMul).
## Seconds between two shots of the weapon with the player's current attack speed, before the SAFE_ATTACK_INTERVAL floor.
static func weapon_raw_interval(weapon: WeaponState, game: GameState) -> float:
	var rules: SimRules = Defs.rules()
	var def: WeaponDef = Defs.weapon(weapon.id)
	if def == null:
		return rules.safe_attack_interval
	var rate: float = JsMath.js_max(1e-4, def.rate if def.rate != 0.0 else 1.0)
	var level: float = JsMath.js_max(1.0, float(weapon.level))
	var weapon_mul: float = _ability_weapon_speed_mul(weapon, game)
	var speed: float = JsMath.js_max(1e-4, _effective_player_attack_speed(game) * (1.0 + (level - 1.0) * 0.08) * weapon_mul)
	var raw: float = rate / speed * _final_cooldown_mul(game)
	if is_finite(raw) and raw > 0.0:
		return raw
	return rules.safe_attack_interval


## # port: weaponInterval. `Math.max(SAFE_ATTACK_INTERVAL, weaponRawInterval(w))`.
static func weapon_interval(weapon: WeaponState, game: GameState) -> float:
	return JsMath.js_max(Defs.rules().safe_attack_interval, weapon_raw_interval(weapon, game))


## # port: effectivePlayerAttackSpeed. The berserker and the character ability factors are 1 for the characters that
## have no such system; those that do are not ported yet (M2).
static func _effective_player_attack_speed(game: GameState) -> float:
	var rules: SimRules = Defs.rules()
	var base: float = game.player.attack_speed
	var result: float = (base if is_finite(base) else 1.0) * (1.0 + _berserker_frenzy(game) * rules.berserker_attack_speed_per_stack)
	result *= _ability_global_attack_speed_mul(game)
	return JsMath.clamp(result if is_finite(result) else 1.0, 0.05, 20.0)


## berserkerFrenzy(): 0 unless the character is the berserker.
static func _berserker_frenzy(game: GameState) -> float:
	if game.char_id == "berserker":
		push_error("Formulas: the berserker's frenzy is not ported yet (M2)")
	return 0.0


## abilityGlobalAttackSpeedMul(): 1 for the catalyst. Arcanist, berserker, archivist and striker have factors (M2).
static func _ability_global_attack_speed_mul(game: GameState) -> float:
	if game.char_id in ["arcanist", "berserker", "archivist", "striker"]:
		push_error("Formulas: the attack speed factor of '%s' is not ported yet (M2)" % game.char_id)
	return 1.0


## abilityWeaponSpeedMul(w): the catalyst's cat_haste on the catalytic ring is 1 at rank 0, which is all M1 has.
static func _ability_weapon_speed_mul(weapon: WeaponState, game: GameState) -> float:
	if not game.abilities_active():
		return 1.0
	if game.char_id == "catalyst" and weapon.id == "catalytic_ring":
		if game.specials.rank("cat_haste") > 0:
			push_error("Formulas: catalystHasteMul for rank > 0 is not ported yet (M2)")
		return 1.0
	if game.char_id in ["miko", "striker", "pathfinder"]:
		push_error("Formulas: the weapon speed factor of '%s' is not ported yet (M2)" % game.char_id)
	return 1.0


## finalCooldownMul(): `Math.max(2e-3, 1 - FINAL_BONUS_STEP.cooldown * finalBonusStacks("cooldown"))`.
static func _final_cooldown_mul(game: GameState) -> float:
	var stacks: float = game.specials.final_bonus_cooldown_stacks()
	return JsMath.js_max(2e-3, 1.0 - Defs.rules().final_bonus_step_cooldown * stacks)
