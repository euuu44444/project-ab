class_name EnemyUpdateSystem
extends SimSystem
## enemy/update: updateEnemies(dt). Every enemy ticks its timers, moves by its kind's AI and, when it touches the player, hurts and pushes the
## player. This is where the enemies' positions and the contact damage come from; it is the biggest consumer of JsMath in the simulation.
##
## One step, in the original's order: the epoch of the projectile-avoidance cache is bumped, solid hazards are collected, the separation grid is
## rebuilt (the second rebuild of the step before the enemies move: index/separation-1 ran before the weapons and the player's damage, see EnemyGrid),
## then the enemies are visited FROM THE END of the list to the start - which also means the enemies spawned in this very step move first, and
## that an enemy sees the enemies of a higher index at their new positions and the others at their old ones. For each enemy:
##   tickEnemyTimersAndStatus -> (a dead enemy is killed) -> canAct -> updateSpecialEnemyAbilities -> distance to the player -> speed factors ->
##   the kind's mover (moveBasicEnemy for a swarm, moveAssassinEnemy) -> solid collisions -> map clamp -> contact with the player.
## The player is LIVE: after a contact hit pushed it, the enemies of a lower index steer toward its new position.
##
## M1 (catalyst, normal difficulty, swarm and assassin, waves 1-4). What the original does here and is not ported, because no M1 enemy has the state
## for it (each is a guard that reports with push_error if a configuration could reach it): the other kinds' movers (artillery, tank, support,
## controller, bomber, elite, boss), special abilities, element afflictions, chains, strata and seeds, burn and poison (and with them the damage
## numbers above an enemy), solid hazards, squads and the tactical decisions of the other difficulties, miko barrier and bind, overhaul slows.
## Sound (audio.enemyAttack) is not part of the simulation.
##
## Draws: gameRandom is used by one thing in here, the damage number of a contact hit (PlayerDamage.show_damage_number: 3 values). An enemy
## that moves draws nothing on normal difficulty.
##
## Cost (design 5.5; x86-64 development VM, Godot 4.7.2 headless, 100 swarm enemies bunched around the player, as the swarm AI makes them): about
## 8 ms per update, of which about 2.7 ms are the separation scans (6,700 candidate pairs per step), 0.6 ms the timers and the rest
## moveBasicEnemy / steerEnemy / smoothEnemyVelocity (the JsMath calls). The budget of 4 ms per step is exceeded by this scenario alone; the
## options of design 5.5 / 12 are for step S9, after S6 has added the weapons and projectiles to the measurement.

var _steering: EnemySteering = null


func _init(p_game: GameState) -> void:
	super(p_game, "updateEnemies")
	_steering = EnemySteering.new(p_game)


## # port: updateEnemies
func run(dt: float) -> void:
	game.projectile_avoidance_epoch += 1
	var p: PlayerState = game.player
	var difficulty: DifficultyDef = game.current_difficulty()
	var attack_range_mul: float = EnemyAi.difficulty_attack_range_mul(game)
	_active_solid_hazards()
	game.enemy_grid.rebuild(game.enemies)
	var map_w: float = game.limits.map_w
	var map_h: float = game.limits.map_h
	for i: int in range(game.enemies.size() - 1, -1, -1):
		var e: EnemyState = game.enemies[i]
		var ai_skill: float = EnemyAi.enemy_ai_skill_of(game, e)
		_tick_enemy_timers_and_status(e, dt, p)
		if e.hp <= 0.0:
			EnemyLifecycle.kill_enemy(game, i, e)
			continue
		var can_act: bool = e.status.paralyze <= 0.0 and e.status.airborne <= 0.0 and not e.special_motion_lock
		_update_special_enemy_abilities(e)
		can_act = can_act and not e.special_motion_lock
		var collision_start_x: float = e.x
		var collision_start_y: float = e.y
		var dx: float = p.x - e.x
		var dy: float = p.y - e.y
		var d: float = SimUtil.or_one(JsMath.hypot(dx, dy))
		var nx: float = dx / d
		var ny: float = dy / d
		var speed: float = _enemy_speed(e)
		# the dispatch of the original: boss, artillery, tank, support, controller, assassin, bomber, elite, else moveBasicEnemy
		if e.boss or e.kind == "artillery" or e.kind == "tank" or e.kind == "support" or e.kind == "controller":
			_report_unported_mover(e)
			_move_basic_enemy(e, p, dt, ai_skill, speed)
		elif e.kind == "assassin":
			_move_assassin_enemy(e, p, dt, ai_skill, can_act, attack_range_mul, d, nx, ny, speed)
		elif e.kind == "bomber" or e.elite:
			_report_unported_mover(e)
			_move_basic_enemy(e, p, dt, ai_skill, speed)
		else:
			_move_basic_enemy(e, p, dt, ai_skill, speed)
		_steering.resolve_enemy_solid_collisions(e, collision_start_x, collision_start_y)
		e.x = JsMath.clamp(e.x, 12.0, map_w - 12.0)
		e.y = JsMath.clamp(e.y, 12.0, map_h - 12.0)
		var rr: float = p.r + e.r
		var contact_cd_mul: float = difficulty.boss_attack_cd if e.boss else (difficulty.elite_attack_cd if e.elite else 1.0)
		if (SimUtil.segment_circle_hit(collision_start_x, collision_start_y, e.x, e.y, p.x, p.y, rr) and can_act and not e.fuse_started
				and game.t - p.last_hit > 0.38 * contact_cd_mul):
			var ndx: float = p.x - e.x
			var ndy: float = p.y - e.y
			var nd: float = SimUtil.or_one(JsMath.hypot(ndx, ndy))
			p.last_hit = game.t
			var buff: float = 1.18 if e.status.support_buff > 0.0 else 1.0
			# audio.enemyAttack(kind + "_contact", ...): sound only
			_trigger_enemy_attack(e, 0.24, JsMath.atan2(p.y - e.y, p.x - e.x))
			PlayerDamage.hurt_player(game, e.damage, true, buff * _special_enemy_damage_mul(e))
			p.x = JsMath.clamp(p.x + ndx / nd * 22.0, 18.0, map_w - 18.0)
			p.y = JsMath.clamp(p.y + ndy / nd * 22.0, 18.0, map_h - 18.0)
		if e.hp <= 0.0:
			EnemyLifecycle.kill_enemy(game, i, e)


## The movers of the other kinds (moveBossEnemy, moveArtilleryEnemy, moveTankEnemy, moveSupportEnemy, moveControllerEnemy, moveBomberEnemy,
## moveEliteEnemy) belong to M2. The enemy is moved like a swarm after the report so that the loop goes on.
func _report_unported_mover(e: EnemyState) -> void:
	push_error("EnemyUpdateSystem: the mover of '%s' (boss, elite, artillery, tank, support, controller, bomber) is not ported (M2)" % e.kind)


## # port: activeSolidHazards. Collects the hazards that block movement into game.frameSolidHazards; the port has no hazards before M2.
func _active_solid_hazards() -> void:
	game.frame_solid_hazards.clear()
	if game.hazards.size() > 0:
		push_error("EnemyUpdateSystem: hazards (solid ice walls) are not ported (M2)")


## The speed factors of updateEnemies: `e.speed * specialEnemySpeedMul(e)`, then strata, root, slow, wet, paralyze, airborne, support buff, the
## special-motion lock. (mikoBarrierActive, mikoBindUntil and ovSlowUntil do not exist on an M1 enemy: `undefined > t` is false.)
func _enemy_speed(e: EnemyState) -> float:
	var speed: float = e.speed * _special_enemy_speed_mul(e)
	if SimUtil.or_zero(e.strata) > 0.0:
		speed *= JsMath.js_max(0.2, 1.0 - SimUtil.or_zero(e.strata) * 0.05)
		e.status.airborne = 0.0
	if e.status.root > 0.0:
		speed *= 0.3
	if e.status.slow > 0.0:
		speed *= 0.52
	if e.status.wet > 0.0:
		speed *= 0.9
	if e.status.paralyze > 0.0:
		speed *= 0.08
	if e.status.airborne > 0.0:
		speed = 0.0
	if e.status.support_buff > 0.0:
		speed *= 1.18
	if e.special_motion_lock:
		speed = 0.0
	return speed


## # port: specialEnemySpeedMul. `hasSpecialAbility(e, "berserk") && e.hp / e.maxHp <= 0.5 ? 1.3 : 1`
func _special_enemy_speed_mul(e: EnemyState) -> float:
	return 1.3 if e.special_abilities.has("berserk") and e.hp / e.max_hp <= 0.5 else 1.0


## # port: specialEnemyDamageMul
func _special_enemy_damage_mul(e: EnemyState) -> float:
	return 1.3 if e.special_abilities.has("berserk") and e.hp / e.max_hp <= 0.5 else 1.0


## # port: updateSpecialEnemyAbilities. Its first line returns for an enemy without special abilities and without a pending attack - every swarm
## and assassin; elites and bosses (barrage, volley, spiral, phase, regeneration ...) are M2.
func _update_special_enemy_abilities(e: EnemyState) -> void:
	if e.special_abilities.is_empty() and e.special_state.pending_attack == null:
		return
	push_error("EnemyUpdateSystem: special enemy abilities (elites and bosses) are not ported (M2)")


## # port: tickEnemyTimersAndStatus. The countdowns that run for every enemy; the statuses, afflictions and damage over time that follow in the
## original have nothing to do in M1 (all zero or empty), so they are guards.
func _tick_enemy_timers_and_status(e: EnemyState, dt: float, _p: PlayerState) -> void:
	e.tactic_cd = JsMath.js_max(0.0, SimUtil.or_zero(e.tactic_cd) - dt)
	e.tactic_pulse = JsMath.js_max(0.0, SimUtil.or_zero(e.tactic_pulse) - dt * 2.4)
	e.flash = JsMath.js_max(0.0, e.flash - dt * 5.0)
	e.telegraph = JsMath.js_max(0.0, e.telegraph - dt)
	e.attack_anim = JsMath.js_max(0.0, SimUtil.or_zero(e.attack_anim) - dt)
	e.ability_cd = JsMath.js_max(0.0, e.ability_cd - dt)  # ovActionUntil does not exist on an M1 enemy: no overhaul action rate
	e.think_cd = JsMath.js_max(0.0, SimUtil.or_zero(e.think_cd) - dt)
	# `if (!isDifficulty("normal")) { decisionCd, evaluateEnemyTacticalAction, enemyAiThinkDelay (draws rand) }`: not ported, see EnemySteering.steer_enemy
	# tickElementAfflictions / tickChainStates / tickEarthWoodStates: nothing to tick without afflictions, chain states, strata or a seed
	if e.afflictions.size() > 0 or e.chain_states.size() > 0 or SimUtil.or_zero(e.strata) > 0.0 or SimUtil.or_zero(e.seed_timer) > 0.0:
		push_error("EnemyUpdateSystem: element afflictions, chain states, strata and seeds are not ported (M2)")
	e.deep_erosion_mark = JsMath.js_max(0.0, SimUtil.or_zero(e.deep_erosion_mark) - dt)
	e.status.tick_timed(dt)
	if e.status.burn > 0.0 or e.status.poison > 0.0:
		push_error("EnemyUpdateSystem: burn and poison (damage over time on an enemy) are not ported (M2)")
	_flush_dot_damage_numbers(e, dt)
	if e.status.burn <= 0.0:
		e.status.burn_dps = 0.0
	if e.status.poison <= 0.0:
		e.status.poison_dps = 0.0
	# `(e.lavaHardened || 0) > 0`: the lava element's state does not exist on an M1 enemy


## # port: flushDotDamageNumbers. Every 0.34 s the damage dealt by burn and poison is shown as one number; the timer runs, the numbers do not
## exist in M1 (no burn, no poison). `dotNumberTimer` is set to exactly 0.34 when it reaches 0, not carried over.
func _flush_dot_damage_numbers(e: EnemyState, dt: float) -> void:
	e.dot_number_timer = SimUtil.or_zero(e.dot_number_timer) - dt
	if e.dot_number_timer > 0.0:
		return
	if e.dot_number_fire > 0.0 or e.dot_number_poison > 0.0:
		push_error("EnemyUpdateSystem: the damage numbers of burn and poison above an enemy are not ported (M2)")
	e.dot_number_fire = 0.0
	e.dot_number_poison = 0.0
	e.dot_number_timer = 0.34


## # port: triggerEnemyAttack. Starts the attack animation (at least `duration` seconds) and turns the enemy toward `angle`.
func _trigger_enemy_attack(e: EnemyState, duration: float, angle: float) -> void:
	e.attack_anim = JsMath.js_max(SimUtil.or_zero(e.attack_anim), duration)
	e.attack_anim_max = e.attack_anim
	if is_finite(angle):
		e.facing = angle


## `e.abilityCooldownMul || e.actionCooldownMul || 1`
func _ability_cooldown_mul(e: EnemyState) -> float:
	if e.ability_cooldown_mul != 0.0 and not is_nan(e.ability_cooldown_mul):
		return e.ability_cooldown_mul
	return SimUtil.or_one(e.action_cooldown_mul)


## # port: moveBasicEnemy. The swarm circles the player at a ring radius (42 minus the skill's share, plus 0 to 24 by id) around where the
## player is going, its angle turning at 0.16 + skill * 0.12 radians per second in its own direction, with a breathing pinch of the radius.
func _move_basic_enemy(e: EnemyState, p: PlayerState, dt: float, ai_skill: float, speed: float) -> void:
	var map_w: float = game.limits.map_w
	var map_h: float = game.limits.map_h
	var a: float = e.ai_seed + game.t * (0.16 + ai_skill * 0.12) * float(e.strafe_dir)
	var ring: float = 42.0 - ai_skill * 10.0 + float(e.id % 4 * 8)
	var lead: float = ai_skill * 0.34
	var cx: float = JsMath.clamp(p.x + SimUtil.or_zero(p.vx) * lead, 18.0, map_w - 18.0)
	var cy: float = JsMath.clamp(p.y + SimUtil.or_zero(p.vy) * lead, 18.0, map_h - 18.0)
	var pinch: float = ai_skill * JsMath.js_max(0.0, JsMath.sin(game.t * 0.9 + e.ai_seed)) * 12.0
	var tx: float = cx + JsMath.cos(a) * (ring - pinch)
	var ty: float = cy + JsMath.sin(a) * (ring - pinch)
	_steering.steer_enemy(e, tx, ty, speed, dt, 0.62, 36.0, false, 1.05, 0.08 + ai_skill * 0.05)


## # port: moveAssassinEnemy. idle: circle to the player's side and behind it (175 px out, 55 behind) and, when the ability is ready and the
## player is 105-480 px away, wind up (the telegraph); windup: aim at where the player will be; dash: fly along the aim at 5.45 times the speed
## for 0.34 s; recover: back away from the player for 0.68 s, then idle with a new cooldown.
func _move_assassin_enemy(e: EnemyState, p: PlayerState, dt: float, ai_skill: float, can_act: bool, attack_range_mul: float, d: float,
		nx: float, ny: float, speed: float) -> void:
	if not can_act:
		if e.ai_state == "dash" or e.ai_state == "windup":
			e.ai_state = "idle"
			e.ai_timer = 0.0
			e.telegraph = 0.0
			e.ability_cd = JsMath.js_max(e.ability_cd, 0.8 * _ability_cooldown_mul(e))
	elif e.ai_state == "dash":
		e.facing = JsMath.atan2(e.dash_y, e.dash_x)
		e.vx = e.dash_x * speed * 5.45
		e.vy = e.dash_y * speed * 5.45
		e.x += e.vx * dt
		e.y += e.vy * dt
		e.ai_timer -= dt
		if e.ai_timer <= 0.0:
			e.ai_state = "recover"
			e.ai_timer = 0.68 * EnemyAi.difficulty_wait_mul(game)
	elif e.ai_state == "windup":
		_steering.predict_player_position(e, 650.0, 0.34 + ai_skill * 0.22)
		var ax: float = _steering.pred_x - e.x
		var ay: float = _steering.pred_y - e.y
		var m: float = SimUtil.or_one(JsMath.hypot(ax, ay))
		e.dash_x = ax / m
		e.dash_y = ay / m
		e.facing = JsMath.atan2(e.dash_y, e.dash_x)
		e.ai_timer -= dt
		e.telegraph = e.ai_timer
		if e.ai_timer <= 0.0:
			e.ai_state = "dash"
			e.ai_timer = 0.34
			# audio.enemyAttack("assassin_dash", ...): sound only
			_trigger_enemy_attack(e, 0.34, e.facing)
	elif e.ai_state == "recover":
		_steering.steer_enemy(e, e.x - nx * 130.0, e.y - ny * 130.0, speed * 0.68, dt, 0.72, 0.0, true, 1.4, 0.0)
		e.ai_timer -= dt
		if e.ai_timer <= 0.0:
			e.ai_state = "idle"
			e.ability_cd = (1.25 - ai_skill * 0.16) * _ability_cooldown_mul(e) * EnemyAi.difficulty_wait_mul(game)
	else:
		var pvx: float = SimUtil.or_zero(p.vx)
		var pvy: float = SimUtil.or_zero(p.vy)
		var pm: float = SimUtil.or_one(JsMath.hypot(pvx, pvy))
		var mx: float = pvx / pm if pm > 8.0 else nx
		var my: float = pvy / pm if pm > 8.0 else ny
		var side: float = float(e.strafe_dir)
		_steering.predict_player_position(e, 520.0, 0.28 + ai_skill * 0.32)
		var tx: float = _steering.pred_x + -my * side * (175.0 - ai_skill * 30.0) - mx * (55.0 + ai_skill * 24.0)
		var ty: float = _steering.pred_y + mx * side * (175.0 - ai_skill * 30.0) - my * (55.0 + ai_skill * 24.0)
		_steering.steer_enemy(e, tx, ty, speed * 0.94, dt, 0.72, 0.0, true, 1.55, 0.0)
		if e.ability_cd <= 0.0 and d < (480.0 + ai_skill * 70.0) * attack_range_mul and d > 105.0 and EnemyAi.coordinated_attack_ready(game, e, "high"):
			e.ai_state = "windup"
			e.ai_timer = EnemyAi.enemy_ai_telegraph(game, 0.42, 0.28, e)
			e.telegraph = e.ai_timer
			# audio.enemyAttack("assassin_charge", ...): sound only
			EnemyAi.commit_coordinated_attack(game, e, "high")
