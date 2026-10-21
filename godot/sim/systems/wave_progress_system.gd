class_name WaveProgressSystem
extends SimSystem
## wave/progress: updateWave(dt). The wave clock, the spawn budget and the enemy director (design section 8), and the step to the
## next wave (advanceWave, onWaveStart).
##
## One step: both clocks run down; the budget grows by the threat rate of the wave (1.15 + 0.095 per wave, times the difficulty's
## spawnRate); every 0.1 s (directorClock <= 0, which is then SET to 0.1, not added to: the cadence of 7 steps is a result of float
## subtraction) EnemyDirector.spawn_director_enemy_batch runs; when the wave clock is out, the next wave starts. The order is the
## original's: the director of the old wave ticks first, advanceWave comes last.
##
## M1 only has the normal waves of the standard mode on normal difficulty. The elite and boss waves (5, 10, ...) and the endless mode
## report themselves with push_error. The wave after wave 4 is not played: WaveRules.M1_LAST_WAVE ends the run (see _end_of_prototype).


func _init(p_game: GameState) -> void:
	super(p_game, "updateWave")


## # port: updateWave
func run(dt: float) -> void:
	game.wave_clock -= dt
	game.director_clock -= dt
	if game.mode == "endless":
		push_error("WaveProgressSystem: the endless mode (spawn pace, wave scaling) is not ported (M2)")
	var base_threat_rate: float = ((1.15 + float(game.wave) * 0.095 + float(maxi(0, game.wave - 15)) * 0.025)
			* game.current_difficulty().spawn_rate * _high_difficulty_threat_mul() * 1.0 * _contract_spawn_rate_mul())
	if not WaveRules.is_special_wave(game.wave, game.mode):
		# `game.hazards.some(h => h.type === "worldtree" && h.life > 0)`: there are no hazards before M2
		if game.hazards.size() > 0:
			push_error("WaveProgressSystem: hazards (the world tree changes the threat rate) are not ported (M2)")
		# anomalyFactorActive("af_horde") is false without meta runs; contracts.silence doubles the rate
		var silence_mul: float = 2.0 if SimUtil.truthy(game.contracts.get("silence", false)) else 1.0
		var normal_threat_rate: float = base_threat_rate * silence_mul * 1.0
		var world_tree_threat_rate: float = 1.0
		game.spawn_budget = JsMath.js_min(Defs.rules().director_budget_cap, game.spawn_budget + normal_threat_rate * world_tree_threat_rate * dt)
		if game.director_clock <= 0.0:
			EnemyDirector.spawn_director_enemy_batch(game)
			game.director_clock = 0.1
	else:
		push_error("WaveProgressSystem: elite and boss waves (wave %d) are not ported (M2)" % game.wave)
		return
	if game.wave_clock <= 0.0:
		if game.mode == "normal" and game.wave == WaveRules.M1_LAST_WAVE:
			_end_of_prototype()
		else:
			advance_wave()


## # port: highDifficultySpawnConfig()?.threatMul || 1. Hard and nightmare have a config; the port plays normal only.
func _high_difficulty_threat_mul() -> float:
	if game.difficulty == "hard" or game.difficulty == "nightmare":
		push_error("WaveProgressSystem: the threat multiplier of hard and nightmare is not ported (M1 is normal only)")
	return 1.0


## # port: contractSpawnRateMul. `m = 1; if (game?.contracts?.greed) m *= 1.25; if (game?.arenaWave === game?.wave) m *= 2`.
## arenaWave is 0 outside the arena contract, so it never equals a wave.
func _contract_spawn_rate_mul() -> float:
	var m: float = 1.0
	if SimUtil.truthy(game.contracts.get("greed", false)):
		m *= 1.25
	if game.arena_wave == game.wave:
		m *= 2.0
	return m


## The wave clock of the last wave of the milestone-1 prototype ran out: the clear is scored (awardWaveScore, as advanceWave does) and
## the run ends as a win (endRun(true)) instead of starting wave 5. Not in the original; see WaveRules.M1_LAST_WAVE.
func _end_of_prototype() -> void:
	award_wave_score(game.wave)
	EndRunSystem.end_run(game, true)


## # port: advanceWave. The cleared wave is scored, the featured-change chance grows by 0.01, the next wave gets its clock and a
## 2.2 budget bonus, and onWaveStart prepares it.
func advance_wave() -> void:
	var cleared_wave: int = game.wave
	# audio.wave("clear") is sound only
	award_wave_score(cleared_wave)
	if game.timed_contract != null:
		push_error("WaveProgressSystem.advance_wave: timed contracts (resolveTimedContractAtWaveEnd) are not ported (M2)")
	if game.arena_wave == cleared_wave:
		game.arena_wave = 0
	# applyEndlessWaveClearScaling: endless mode only (reported in run())
	game.wave_featured_change_chance = JsMath.js_min(1.0, game.wave_featured_change_chance + Defs.rules().featured_change_chance_per_clear)
	game.wave += 1
	game.wave_clock = Defs.rules().wave_duration  # effectiveWaveDuration()
	game.boss_defeated_this_wave = false
	game.boss_clear_timer = 0.0
	game.elite_defeated_this_wave = false
	game.elite_clear_timer = 0.0
	game.elite_gate_total = 0
	if not WaveRules.is_special_wave(game.wave, game.mode):
		game.spawn_budget = JsMath.js_min(Defs.rules().director_budget_cap, game.spawn_budget + 2.2)
	on_wave_start(game.wave)


## # port: awardWaveScore. Scores a cleared wave once: `rawScore += Math.floor(SCORE_RULES.waveClear * Math.max(1, wave))`.
func award_wave_score(wave: int) -> void:
	if game.scored_waves.has(wave):
		return
	game.scored_waves[wave] = true
	game.raw_score = JsMath.js_max(0.0, game.raw_score + floorf(Defs.rules().score_wave_clear * float(maxi(1, wave))))


## # port: onWaveStart (the normal waves). The enemy AI level, the wave's featured kind (prepareEnemyWaveTheme: from wave 3 one draw,
## two when the featured kind changes), the centre message. Left out: metaOnWaveStart (trial bookkeeping), audio, the unlock of
## UNLOCK_STEPS (a persistent profile and a message: step S8; wave 4 unlocks the ice element), timed contract targets.
func on_wave_start(w: int) -> void:
	game.enemy_ai_tier = WaveRules.enemy_ai_tier(w)  # refreshEnemyAiLevel
	game.enemy_ai_skill = WaveRules.enemy_ai_skill(w)
	WaveRules.prepare_enemy_wave_theme(game, w)
	game.boss_defeated_this_wave = false
	game.boss_clear_timer = 0.0
	game.elite_defeated_this_wave = false
	game.elite_clear_timer = 0.0
	game.elite_gate_total = 0
	game.message_until = game.t + 1.5  # showMessage(`WAVE ${w}`, 1.5)
	if WaveRules.is_special_wave(w, game.mode):
		push_error("WaveProgressSystem.on_wave_start: elite and boss waves (wave %d) are not ported (M2)" % w)
	if game.timed_contract != null:
		push_error("WaveProgressSystem.on_wave_start: timed contracts (maybeSpawnTimedContractTarget) are not ported (M2)")
