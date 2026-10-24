class_name EnemyLifecycle
extends RefCounted
## How enemies leave the game: cleanupDeadEnemies and killEnemy of the original (the only code that removes an enemy from
## game.enemies), with the score and the experience orb the kill leaves behind.
##
## killEnemy is called from three places: cleanupDeadEnemies (the slots enemy/cleanup-1 and enemy/cleanup-2) and, inside
## updateEnemies, for an enemy that a damage-over-time status or a contact kills there (step S5, area 2). In the M1 configuration
## nothing lowers an enemy's hp before step S6 (weapons, projectiles, damage), so the port reaches it only through the replay oracle
## of the tests (which sets hp = 0 on the enemies that the reference removed) and through unit tests.
##
## What killEnemy does for a swarm or an assassin in M1 (catalyst, normal, waves 1-4), in the original's order, and what is left out:
##   hazard-based effects (groves, wildfire whirl, rot world), superconduct and deep erosion spreading, the archivist's records, the
##   bomber's fuse, berserker/miko kill effects, ability kill hooks, boss/elite effects and loot, timed contracts, squads
##       -> none applies; each is a guard that reports with push_error if a configuration could reach it (M2)
##   game.kills++ ; awardEnemyScore                       -> ported
##   spawnXp(e.x, e.y, e.xp * enemyXpDropMultiplier(e))   -> ported: TWO gameRandom draws (x jitter, then y jitter) for the orb
##   audio.kill, burst(x, y, color, 5)                    -> sound and particles; burst draws from the effects generator only
##                                                           (TODO(S6/S7): the fx layer adds the particles; they never touch the simulation)
##   swap-pop of the enemy list, enemiesVersion++         -> ported


## # port: cleanupDeadEnemies. Walks the list from the last index to the first and kills every enemy with hp <= 0 (a NaN hp is not
## dead). Walking backwards with the swap-pop of killEnemy makes the order of the list after several kills the original's.
static func cleanup_dead_enemies(game: GameState) -> void:
	var i: int = game.enemies.size() - 1
	while i >= 0:
		var e: EnemyState = game.enemies[i]
		if e.hp <= 0.0:
			kill_enemy(game, i, e)
		i -= 1


## # port: killEnemy (the M1 path, see the class comment). `index` is the position of `e` in game.enemies.
static func kill_enemy(game: GameState, index: int, e: EnemyState) -> void:
	_guard_unported_kill_effects(game, e)
	game.kills += 1
	award_enemy_score(game, e)
	spawn_xp(game, e.x, e.y, e.xp * enemy_xp_drop_multiplier(game, e))
	# TODO(S6/S7): burst(e.x, e.y, e.color, 5) - 5 death particles from the effects generator (FxRng, never gameRandom); the fx layer adds them.
	# TODO(S6): a kill that a weapon caused sets e.lastDamageWeaponId first; abilityOnKill then runs catalystSpawnResidue for the catalytic ring
	# (rank of cat_residue > 0: ONE gameRandom draw, `gameRandom() * 6.28`, for the field's phase) - not reachable at rank 0 (all M1 ranks).
	# detachEnemyFromSquad: `!e.squadId` returns (squads exist on nightmare only)
	var last: EnemyState = game.enemies.pop_back()
	if index < game.enemies.size():
		game.enemies[index] = last
	game.enemies_version += 1


## # port: awardEnemyScore. `if (game && !game.ended) game.rawScore = Math.max(0, (game.rawScore || 0) + rawEnemyScore(e))`
static func award_enemy_score(game: GameState, e: EnemyState) -> void:
	if not game.ended:
		game.raw_score = JsMath.js_max(0.0, game.raw_score + raw_enemy_score(game, e))


## # port: rawEnemyScore. `Math.floor((base + xpPart) * waveMul)` with the kill's base score, the doubled xp value and a 2 % per wave bonus.
static func raw_enemy_score(game: GameState, e: EnemyState) -> float:
	var rules: SimRules = Defs.rules()
	var base: float = rules.score_boss_kill if e.boss else (rules.score_elite_kill if e.elite else rules.score_normal_kill)
	var xp_part: float = JsMath.js_max(0.0, floorf(e.xp * 2.0))  # `(e.xp || 0)`: a float field is never undefined
	var wave: float = float(e.spawn_wave) if e.spawn_wave != 0 else float(game.wave if game.wave != 0 else 1)  # `e.spawnWave || game?.wave || 1`
	var wave_mul: float = 1.0 + JsMath.js_max(0.0, wave - 1.0) * 0.02
	return floorf((base + xp_part) * wave_mul)


## # port: enemyXpDropMultiplier. `base * (1 + contractBonus)`: 4 for a boss, 2.5 for an elite, 1.1 for the rest; the contract bonuses
## (greed, night, the arena wave) are 0 in M1.
static func enemy_xp_drop_multiplier(game: GameState, e: EnemyState) -> float:
	var base: float = 4.0 if e.boss else (2.5 if e.elite else 1.1)
	var contract_bonus: float = 0.0
	if SimUtil.truthy(game.contracts.get("greed", false)):
		contract_bonus += 0.5
	if SimUtil.truthy(game.contracts.get("night", false)):
		contract_bonus += 0.75
	if game.arena_wave != 0 and e.spawn_wave == game.arena_wave:
		contract_bonus += 2.0
	return base * (1.0 + contract_bonus)


## # port: spawnXp. One orb for a value below 30, 3 below 100, else 8; each orb's position is jittered by rand(-12, 12) in x and THEN in y
## (two draws per orb). The value is split evenly.
static func spawn_xp(game: GameState, x: float, y: float, value: float) -> void:
	var parts: int = 8 if value >= 100.0 else (3 if value >= 30.0 else 1)
	var radius: float = 6.0 if value >= 100.0 else 4.0
	for i: int in range(parts):
		var jitter_x: float = game.rng.rand(-12.0, 12.0)
		var jitter_y: float = game.rng.rand(-12.0, 12.0)
		push_xp_orb(game, x + jitter_x, y + jitter_y, value / float(parts), radius)


## # port: pushXpOrb. Appends an orb while there is room (MAX_XP_ORBS); at the cap the orb is merged into the one the merge cursor
## points at (value added, position averaged, radius the larger of the two).
static func push_xp_orb(game: GameState, x: float, y: float, value: float, r: float) -> void:
	var list: Array[XpOrbState] = game.xp_orbs
	if list.size() < game.limits.max_xp_orbs:
		var orb: XpOrbState = XpOrbState.new()
		orb.x = x
		orb.y = y
		orb.value = value
		orb.r = r
		list.append(orb)
		return
	var idx: int = game.xp_merge_cursor % list.size()
	game.xp_merge_cursor = (idx + 1) % list.size()
	var o: XpOrbState = list[idx]
	o.value = (o.value if is_finite(o.value) else 0.0) + value
	o.x = (o.x + x) * 0.5
	o.y = (o.y + y) * 0.5
	o.r = JsMath.js_max(o.r if o.r != 0.0 else 4.0, r if r != 0.0 else 4.0)


## The parts of killEnemy that do nothing in M1: report (push_error) when a configuration would make one of them do something.
static func _guard_unported_kill_effects(game: GameState, e: EnemyState) -> void:
	if e.boss or e.elite:
		push_error("EnemyLifecycle.kill_enemy: boss and elite kills (effects, loot, wave clear) are not ported (M2)")
	if e.kind == "bomber" and e.fuse_started and not e.exploded:
		push_error("EnemyLifecycle.kill_enemy: the bomber's explosion is not ported (M2)")
	if game.hazards.size() > 0:
		push_error("EnemyLifecycle.kill_enemy: hazards (groves, wildfire whirl, rot world) are not ported (M2)")
	if e.status.superconduct > 0.0 or e.deep_erosion_mark > 0.0:
		push_error("EnemyLifecycle.kill_enemy: superconduct / deep erosion spreading is not ported (M2)")
	if e.squad_id != 0:
		push_error("EnemyLifecycle.kill_enemy: squads (nightmare) are not ported (M2)")
	if game.timed_contract != null:
		push_error("EnemyLifecycle.kill_enemy: timed contracts are not ported (M2)")
	if game.char_id != "catalyst":
		push_error("EnemyLifecycle.kill_enemy: the kill hooks of '%s' (berserker, miko, ranger, striker ...) are not ported (M2)" % game.char_id)
	elif game.abilities_active():
		# abilityOnKill: catalystLinkOnDeath (rank 3 of cat_link) and catalystSpawnResidue (any rank of cat_residue; it would draw)
		if game.specials.rank("cat_link") >= 3 or (game.specials.rank("cat_residue") > 0 and e.last_damage_weapon_id == "catalytic_ring"):
			push_error("EnemyLifecycle.kill_enemy: the catalyst's link burst and residue field are not ported (M2)")

