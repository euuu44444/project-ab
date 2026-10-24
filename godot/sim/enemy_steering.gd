class_name EnemySteering
extends RefCounted
## How an enemy turns a target point into a velocity: steerEnemy and everything it calls in the original (enemySeparationVector,
## enemyProjectileAvoidance, solidHazardAvoidance, smoothEnemyVelocity), plus predictPlayerPosition, which the assassin aims with.
##
## One instance per game (the EnemyUpdateSystem owns it). The original returns two numbers through module-level scratch vectors
## (SEPARATION_VECTOR_SCRATCH, PROJECTILE_AVOID_VECTOR_SCRATCH, SOLID_AVOID_VECTOR_SCRATCH, PREDICTED_POSITION_SCRATCH); the port does the
## same with the members below, so nothing is allocated per enemy and step. Read a result right after the call that wrote it.
##
## Numerics. Every sin / cos / atan2 / exp / hypot / max / min / clamp is JsMath's, the operation order of each expression is the
## original's (left to right, as JavaScript evaluates it), and the `|| 0` / `|| 1` of the original are SimUtil.or_zero / or_one.
## One thing is cached: the exp() of the velocity blend and of the facing turn depends only on dt (and on which of the two blend rates
## applies), and dt is the same fixed step on every call, so the value is computed once per distinct dt. The cached value is the very double that
## the direct computation gives (the function is deterministic); tests/test_enemy_update.gd compares the two.
##
## Left out, because M1 never reaches it (each reports with push_error if a configuration could): the non-normal difficulties' target
## changes and decision noise in steerEnemy, solid hazards (ice walls, M2).

## Math.min(1 / 30, dt) of smoothEnemyVelocity.
const MAX_SMOOTH_DT: float = 1.0 / 30.0

var game: GameState = null

## SEPARATION_VECTOR_SCRATCH, written by enemy_separation_vector.
var sep_x: float = 0.0
var sep_y: float = 0.0
## PROJECTILE_AVOID_VECTOR_SCRATCH, written by enemy_projectile_avoidance.
var avoid_x: float = 0.0
var avoid_y: float = 0.0
## SOLID_AVOID_VECTOR_SCRATCH, written by solid_hazard_avoidance.
var solid_x: float = 0.0
var solid_y: float = 0.0
## PREDICTED_POSITION_SCRATCH, written by predict_player_position.
var pred_x: float = 0.0
var pred_y: float = 0.0

var _acceleration: float = 0.0
var _braking: float = 0.0
var _facing_rate: float = 0.0
var _map_w: float = 0.0
var _map_h: float = 0.0
var _cell_size: float = 96.0
# bit-identical caches of exp(-rate * dt), see the class comment (NAN never equals a dt, so the first call computes)
var _smooth_dt: float = NAN
var _blend_acceleration: float = 0.0
var _blend_braking: float = 0.0
var _turn_dt: float = NAN
var _turn_blend: float = 0.0


func _init(p_game: GameState) -> void:
	game = p_game
	var config: Dictionary = Defs.value("enemies.json", "ENEMY_STEERING_CONFIG")
	_acceleration = float(config["acceleration"])
	_braking = float(config["braking"])
	_facing_rate = float(config["facing"])
	_map_w = game.limits.map_w
	_map_h = game.limits.map_h
	_cell_size = float(game.limits.enemy_separation_grid_size)


## # port: steerEnemy. Moves `e` one step toward (tx, ty): the direction to the target plus the separation from its neighbours (weight
## `separation_weight`, search radius `separation_radius`, 0 = the default of 34 or 2.5 body radii), the dodge of player projectiles
## (`dodge`, strength `dodge_strength`), the push away from solid hazards and a sideways strafe (`strafe`, 0 = none) is turned into a unit
## direction; the velocity eases toward it (smoothEnemyVelocity), the facing turns toward it, and the position advances by velocity * dt.
## `separation_weight` NAN stands for the original's null (`separation ?? (swarm ? 0.52 : 0.72)`); every M1 caller passes a weight.
func steer_enemy(e: EnemyState, tx: float, ty: float, speed: float, dt: float, separation_weight: float, separation_radius: float,
		dodge: bool, dodge_strength: float, strafe: float) -> void:
	if not game.is_difficulty("normal"):
		# the nightmare squad targets, the tactical actions (LINE_OF_SIGHT, RETREAT, STRAFE ...) and difficultyDecisionNoise (which draws rand)
		push_error("EnemySteering.steer_enemy: the squad targets, tactical actions and decision noise of the easy, hard and nightmare difficulties are not ported (M1 is normal only)")
	var dx: float = tx - e.x
	var dy: float = ty - e.y
	var target_distance: float = JsMath.hypot(dx, dy)
	var m: float = SimUtil.or_one(target_distance)
	var vx: float = dx / m if target_distance > 1e-3 else 0.0
	var vy: float = dy / m if target_distance > 1e-3 else 0.0
	var skill: float = EnemyAi.enemy_ai_skill_of(game, e)
	enemy_separation_vector(e, separation_radius if separation_radius != 0.0 else JsMath.js_max(34.0, e.r * 2.5))
	var separation_mul: float = separation_weight
	if is_nan(separation_weight):
		separation_mul = 0.52 if e.kind == "swarm" else 0.72
	vx += sep_x * separation_mul
	vy += sep_y * separation_mul
	if dodge:
		enemy_projectile_avoidance(e, 120.0)
		var dodge_mul: float = dodge_strength * EnemyAi.enemy_ai_dodge_mul(game, e)
		vx += avoid_x * dodge_mul
		vy += avoid_y * dodge_mul
	solid_hazard_avoidance(e, 90.0)
	vx += solid_x
	vy += solid_y
	if strafe != 0.0:
		var px2: float = -dy / m
		var py: float = dx / m
		var strafe_force: float = strafe * (1.0 + skill * 0.22)
		vx += px2 * strafe_force * float(e.strafe_dir)
		vy += py * strafe_force * float(e.strafe_dir)
	m = JsMath.hypot(vx, vy)
	var has_desired_direction: bool = m > 1e-3
	var mx: float = vx / m if has_desired_direction else 0.0
	var my: float = vy / m if has_desired_direction else 0.0
	var max_speed: float = JsMath.js_max(0.0, SimUtil.or_zero(speed))
	var safe_dt: float = JsMath.js_max(0.0, SimUtil.or_zero(dt))
	var arrival_speed: float = target_distance / safe_dt if (target_distance > 1e-3 and safe_dt > 0.0) else max_speed
	var steering_speed: float = JsMath.js_min(max_speed, arrival_speed) if has_desired_direction else 0.0
	smooth_enemy_velocity(e, mx * steering_speed, my * steering_speed, steering_speed, dt)
	if has_desired_direction:
		var desired_facing: float = JsMath.atan2(my, mx)
		if steering_speed <= 1e-3:
			e.facing = desired_facing
		else:
			var current_facing: float = e.facing if is_finite(e.facing) else desired_facing
			if safe_dt != _turn_dt:
				_turn_dt = safe_dt
				_turn_blend = 1.0 - JsMath.exp(-_facing_rate * safe_dt)
			var turn_delta: float = JsMath.atan2(JsMath.sin(desired_facing - current_facing), JsMath.cos(desired_facing - current_facing))
			e.facing = current_facing + turn_delta * JsMath.js_min(1.0, _turn_blend)
	e.x += e.vx * dt
	e.y += e.vy * dt


## # port: smoothEnemyVelocity. The velocity eases toward the target velocity (rate 12.5 per second, 18 while the enemy is faster than
## its limit by more than 6), and its length is capped at `max_speed`.
func smooth_enemy_velocity(e: EnemyState, target_vx: float, target_vy: float, max_speed: float, dt: float) -> void:
	var limit: float = JsMath.js_max(0.0, SimUtil.or_zero(max_speed))
	if limit <= 0.0:
		clear_enemy_steering_velocity(e)
		return
	var current_vx: float = e.vx if is_finite(e.vx) else 0.0
	var current_vy: float = e.vy if is_finite(e.vy) else 0.0
	var current_speed: float = JsMath.hypot(current_vx, current_vy)
	var safe_dt: float = JsMath.js_max(0.0, JsMath.js_min(MAX_SMOOTH_DT, SimUtil.or_zero(dt)))
	var blend: float = 1.0
	if safe_dt > 0.0:
		if safe_dt != _smooth_dt:
			_smooth_dt = safe_dt
			_blend_acceleration = 1.0 - JsMath.exp(-_acceleration * safe_dt)
			_blend_braking = 1.0 - JsMath.exp(-_braking * safe_dt)
		blend = _blend_braking if current_speed > limit + 6.0 else _blend_acceleration
	var next_vx: float = current_vx + (target_vx - current_vx) * blend
	var next_vy: float = current_vy + (target_vy - current_vy) * blend
	var next_speed: float = JsMath.hypot(next_vx, next_vy)
	if next_speed > limit:
		var scale: float = limit / next_speed
		next_vx *= scale
		next_vy *= scale
	e.vx = next_vx if is_finite(next_vx) else 0.0
	e.vy = next_vy if is_finite(next_vy) else 0.0


## # port: clearEnemySteeringVelocity
func clear_enemy_steering_velocity(e: EnemyState) -> void:
	e.vx = 0.0
	e.vy = 0.0


## # port: enemySeparationVector. The average push away from the enemies within `radius`, each weighted by 1 - distance / radius, into
## sep_x / sep_y. It reads the grid of the last rebuild (cells row by row, enemies in bucket order) with the enemies' LIVE positions: enemies
## that have moved already in this step (higher list index) are where they moved to, the others are where they were. That, and the order of
## the sum, is what the original's result depends on. An empty grid falls back to the whole list.
func enemy_separation_vector(e: EnemyState, radius: float) -> void:
	var sx: float = 0.0
	var sy: float = 0.0
	var count: int = 0
	var r2: float = radius * radius
	var grid: EnemyGrid = game.enemy_grid
	if grid.size() > 0:
		var min_x: int = int(floorf((e.x - radius) / _cell_size))
		var max_x: int = int(floorf((e.x + radius) / _cell_size))
		var min_y: int = int(floorf((e.y - radius) / _cell_size))
		var max_y: int = int(floorf((e.y + radius) / _cell_size))
		for cy: int in range(min_y, max_y + 1):
			for cx: int in range(min_x, max_x + 1):
				var bucket: Array[EnemyState] = grid.bucket(grid.key_of(cx, cy))
				for other: EnemyState in bucket:
					if other == e or other.hp <= 0.0:
						continue
					var dx: float = e.x - other.x
					var dy: float = e.y - other.y
					var d2: float = dx * dx + dy * dy
					if d2 <= 0.01 or d2 > r2:
						continue
					var d: float = sqrt(d2)
					var w: float = 1.0 - d / radius
					sx += dx / d * w
					sy += dy / d * w
					count += 1
	else:
		for other: EnemyState in game.enemies:
			if other == e or other.hp <= 0.0:
				continue
			var dx2: float = e.x - other.x
			var dy2: float = e.y - other.y
			var d2b: float = dx2 * dx2 + dy2 * dy2
			if d2b <= 0.01 or d2b > r2:
				continue
			var db: float = sqrt(d2b)
			var wb: float = 1.0 - db / radius
			sx += dx2 / db * wb
			sy += dy2 / db * wb
			count += 1
	if count != 0:
		sx /= float(count)
		sy /= float(count)
	sep_x = sx
	sep_y = sy


## # port: enemyProjectileAvoidance. A sideways push away from the player projectiles that are flying toward `e` within `radius` (widened
## by the AI skill), at most 5 + floor(skill * 4) of them, in list order, into avoid_x / avoid_y.
##
## The original asks projectileAvoidanceCandidates for a short list of indices when there are 64 projectiles or more. That list is the
## projectiles of the cells around the enemy, sorted by index, so it is the same sequence as this scan with the projectiles that fail the
## distance test left out; the answer is the same (it differs only for a projectile at a NaN position).
func enemy_projectile_avoidance(e: EnemyState, radius: float) -> void:
	if game.projectiles.is_empty():
		avoid_x = 0.0
		avoid_y = 0.0
		return
	var skill: float = EnemyAi.enemy_ai_skill_of(game, e)
	radius *= 1.0 + skill * 0.22
	var ax: float = 0.0
	var ay: float = 0.0
	var hits: int = 0
	var r2: float = radius * radius
	var max_checks: int = 5 + int(floorf(skill * 4.0))
	for pr: ProjectileState in game.projectiles:
		var dx: float = e.x - pr.x
		var dy: float = e.y - pr.y
		var d2: float = dx * dx + dy * dy
		if d2 <= 1.0 or d2 > r2:
			continue
		if pr.vx * dx + pr.vy * dy <= 0.0:
			continue
		var d: float = sqrt(d2)
		var w: float = 1.0 - d / radius
		var sp: float = SimUtil.or_one(JsMath.hypot(pr.vx, pr.vy))
		var px2: float = -pr.vy / sp
		var py: float = pr.vx / sp
		var side: float = 1.0 if px2 * dx + py * dy >= 0.0 else -1.0
		ax += px2 * side * w
		ay += py * side * w
		hits += 1
		if hits >= max_checks:
			break
	avoid_x = ax
	avoid_y = ay


## # port: solidHazardAvoidance. The push away from solid hazards (ice walls); there are none before M2, so the vector is (0, 0) - and steerEnemy
## still adds it (`vx += solid.x`), which turns a -0 into +0.
func solid_hazard_avoidance(_e: EnemyState, _radius: float) -> void:
	if game.frame_solid_hazards.size() > 0:
		push_error("EnemySteering.solid_hazard_avoidance: solid hazards are not ported (M2)")
	solid_x = 0.0
	solid_y = 0.0


## # port: resolveEnemySolidCollisions. Keeps an enemy out of solid hazards; nothing to do while there are none.
func resolve_enemy_solid_collisions(_e: EnemyState, _from_x: float, _from_y: float) -> void:
	if game.frame_solid_hazards.size() > 0:
		push_error("EnemySteering.resolve_enemy_solid_collisions: solid hazards are not ported (M2)")


## # port: predictPlayerPosition. Where the player will be when something of speed `projectile_speed` fired now arrives (at most `max_lead`
## seconds ahead, widened by the AI skill), with the player's acceleration folded in (at most 72 px), kept on the map, into pred_x / pred_y.
func predict_player_position(e: EnemyState, projectile_speed: float, max_lead: float) -> void:
	var p: PlayerState = game.player
	var skill: float = EnemyAi.enemy_ai_skill_of(game, e)
	var travel: float = JsMath.hypot(p.x - e.x, p.y - e.y) / JsMath.js_max(60.0, projectile_speed)
	var lead: float = JsMath.js_min(max_lead * (1.0 + skill * 0.28), travel * (0.92 + skill * 0.18))
	if not game.is_difficulty("normal"):
		push_error("EnemySteering.predict_player_position: the prediction horizon and noise of the easy, hard and nightmare difficulties are not ported (M1 is normal only)")
	var accel_t: float = 0.5 * lead * lead * skill * 0.16
	var ox: float = JsMath.clamp(SimUtil.or_zero(p.ax) * accel_t, -72.0, 72.0)
	var oy: float = JsMath.clamp(SimUtil.or_zero(p.ay) * accel_t, -72.0, 72.0)
	pred_x = JsMath.clamp(p.x + SimUtil.or_zero(p.vx) * lead + ox, 18.0, _map_w - 18.0)
	pred_y = JsMath.clamp(p.y + SimUtil.or_zero(p.vy) * lead + oy, 18.0, _map_h - 18.0)
