class_name WaveRules
extends RefCounted
## Wave predicates and the wave theme of the original (the parts newGame needs; the director itself is step S5).
## tests/golden/formulas.json (section "waves") holds the original's answers for waves 0..60 in both modes and for the
## seeded runs of prepareEnemyWaveTheme.
##
## The "anomaly factor" af_early (it moves every unlock wave) is a meta-progress feature outside M1; the unlock waves
## here are the plain ones.

## Not in the original: the last wave that the milestone-1 prototype plays (design section 8: the result screen comes after wave 4).
## The original goes on to wave 5, an elite wave (clearForSpecialWave, spawnEnemy("elite"), escorts), which milestone 1 does not have.
## WaveProgressSystem ends the run as a win when this wave's clock runs out, the way the original's `endRun(true)` ends a standard run
## at MAX_WAVE (30), instead of calling advanceWave.
const M1_LAST_WAVE: int = 4


## # port: isStandardEliteWave
static func is_standard_elite_wave(wave: int) -> bool:
	return wave == 5 or wave == 15 or wave == 25


## # port: isStandardBossWave
static func is_standard_boss_wave(wave: int) -> bool:
	return wave == 10 or wave == 20 or wave == 30


## # port: isEndlessEliteWave
static func is_endless_elite_wave(wave: int) -> bool:
	return wave >= 5 and wave % 5 == 0 and wave % 10 != 0


## # port: isEndlessBossWave
static func is_endless_boss_wave(wave: int) -> bool:
	return wave >= 10 and wave % 10 == 0


## # port: isEliteWave (`game.mode === "endless"` picks the endless rule)
static func is_elite_wave(wave: int, mode: String) -> bool:
	return is_endless_elite_wave(wave) if mode == "endless" else is_standard_elite_wave(wave)


## # port: isBossWave
static func is_boss_wave(wave: int, mode: String) -> bool:
	return is_endless_boss_wave(wave) if mode == "endless" else is_standard_boss_wave(wave)


## # port: isSpecialWave
static func is_special_wave(wave: int, mode: String) -> bool:
	return is_elite_wave(wave, mode) or is_boss_wave(wave, mode)


## # port: enemyArchetypeUnlockWave (without af_early). Infinity for a kind that has no archetype (elite, boss, unknown).
static func enemy_archetype_unlock_wave(kind: String) -> float:
	if not Defs.has_archetype(kind):
		return INF
	return JsMath.js_max(1.0, float(Defs.archetype(kind).unlock_wave))


## # port: progressionFeaturedEnemyKind
static func progression_featured_enemy_kind(wave: int, mode: String) -> String:
	var order: PackedStringArray = Defs.archetype_kinds()
	var unlocked: PackedStringArray = PackedStringArray()
	var final_unlock_wave: float = -INF
	for kind: String in order:
		var unlock: float = enemy_archetype_unlock_wave(kind)
		if float(wave) >= unlock:
			unlocked.append(kind)
		if is_finite(unlock):
			final_unlock_wave = JsMath.js_max(final_unlock_wave, unlock)
	if unlocked.is_empty():
		return "swarm"
	if float(wave) <= final_unlock_wave:
		return unlocked[unlocked.size() - 1]
	var rotation: int = -1
	var w: int = int(final_unlock_wave) + 1
	while w <= wave:
		if not is_special_wave(w, mode):
			rotation += 1
		w += 1
	return unlocked[maxi(0, rotation) % unlocked.size()]


## # port: prepareEnemyWaveTheme. Resets the director's pending kind and composition, and (unless the wave is an elite or
## boss wave) draws the wave's featured kind: one gameRandom() draw when more than one kind is unlocked, and a second one
## inside pickChangedFeaturedEnemyKind when the featured kind changes. Wave 1 has only the swarm unlocked: no draw.
## Returns the new theme, or null for a special wave.
static func prepare_enemy_wave_theme(game: GameState, wave: int) -> EnemyWaveTheme:
	game.pending_director_enemy_kind = ""
	game.pending_director_composition = null
	if is_special_wave(wave, game.mode):
		game.wave_spawn_theme = null
		return null
	var rules: SimRules = Defs.rules()
	var unlocked: PackedStringArray = PackedStringArray()
	for kind: String in Defs.archetype_kinds():
		if float(wave) >= enemy_archetype_unlock_wave(kind):
			unlocked.append(kind)
	var base_kind: String = progression_featured_enemy_kind(wave, game.mode)
	var change_chance: float = JsMath.clamp(game.wave_featured_change_chance, 0.0, 1.0)
	var changed: bool = unlocked.size() > 1 and game.rng.random() < change_chance
	var featured_kind: String = _pick_changed_featured_enemy_kind(game, base_kind, unlocked) if changed else base_kind
	var theme: EnemyWaveTheme = EnemyWaveTheme.new()
	theme.wave = wave
	theme.base_kind = base_kind
	theme.featured_kind = featured_kind
	theme.changed = changed
	theme.change_chance = change_chance
	theme.featured_share = rules.featured_share
	game.wave_spawn_theme = theme
	game.featured_enemy_history.append(featured_kind)
	while game.featured_enemy_history.size() > 6:
		game.featured_enemy_history.remove_at(0)
	return theme


## # port: pickChangedFeaturedEnemyKind
static func _pick_changed_featured_enemy_kind(game: GameState, base_kind: String, unlocked: PackedStringArray) -> String:
	var candidates: PackedStringArray = PackedStringArray()
	for kind: String in unlocked:
		if kind != base_kind:
			candidates.append(kind)
	var history: PackedStringArray = game.featured_enemy_history
	if candidates.size() > 1 and history.size() > 0:
		var without_last: PackedStringArray = PackedStringArray()
		for kind: String in candidates:
			if kind != history[history.size() - 1]:
				without_last.append(kind)
		if without_last.size() > 0:
			candidates = without_last
	if candidates.is_empty():
		return base_kind
	var total: float = 0.0
	var weights: PackedFloat64Array = PackedFloat64Array()
	for kind: String in candidates:
		var last2: int = _last_index_of(history, kind)
		var weight: float = 1.0
		if last2 >= 0:
			weight = 0.12 if last2 == history.size() - 1 else 0.42
		total += weight
		weights.append(weight)
	var roll: float = game.rng.random() * total
	for i: int in candidates.size():
		roll -= weights[i]
		if roll <= 0.0:
			return candidates[i]
	return candidates[candidates.size() - 1]


static func _last_index_of(list: PackedStringArray, value: String) -> int:
	var i: int = list.size() - 1
	while i >= 0:
		if list[i] == value:
			return i
		i -= 1
	return -1


## # port: enemyAiTier. `Math.max(0, Math.floor((Math.max(1, wave) - 1) / 5))`: 0 for waves 1-5, 1 for 6-10, ...
static func enemy_ai_tier(wave: int) -> int:
	return maxi(0, int(floorf(float(maxi(1, wave) - 1) / 5.0)))


## # port: enemyAiSkill. `clamp(1 - Math.exp(-w / 28), 0, 0.985)` with w = max(1, wave) - 1: how well the enemies of this wave play.
static func enemy_ai_skill(wave: int) -> float:
	var w: float = float(maxi(1, wave) - 1)
	return JsMath.clamp(1.0 - JsMath.exp(-w / 28.0), 0.0, 0.985)
