class_name EnemyDirector
extends RefCounted
## The enemy director of the original (design section 8: updateWave / spawnDirectorEnemyBatch for the normal waves): which kind to
## spawn, where, and with which random numbers. Static functions on the GameState, one per function of the original, each headed with
## `# port: <name>`; the order and the number of gameRandom draws are the original's (the reference traces compare gameRandomDraws).
##
## M1 configuration. Difficulty "normal" (HIGH_DIFFICULTY_SPAWN_CONFIG has no entry, so `cfg` is null and no composition is used),
## waves 1-4 (the formation pools "scatter, arc" and "scatter, arc, pincer, line"), swarm and assassin. What the original does
## beyond that is not ported and reports itself with push_error where a configuration could reach it: the composition path of hard and
## nightmare, the formations surround ... convoy, elite and boss spawns (assignSpecialAbilities, escorts), solid hazards in the way
## (solidSpawnClearance), the nightmare squads. `planned` (a map of kinds a composition has reserved) is always empty on the paths
## that M1 reaches and is left out of pickWaveDirectedEnemyKind / pickBalancedMixedEnemyKind.
##
## Draws per director tick (verified against the reference traces): the plan 2 + [hypot(vx, vy) <= 24] + [pattern != "pincer"],
## a kind pick (1 draw) whenever pendingDirectorEnemyKind is empty and the featured-share rule does not decide, and per enemy the
## formation's points (scatter 2, arc 2, pincer 1, line 0) + the 9 of spawnEnemy.

## Math.PI. JsMath.A2_PI is the bit pattern 0x400921FB54442D18, which is the double of Math.PI.
const MATH_PI: float = JsMath.A2_PI
## The `pad` that spawnEnemy passes to enemyFieldSpawnPoint (the margin to the map edge).
const SPAWN_PAD: float = 28.0
## The sizes a batch has: maxBatch is `cfg?.maxBatch || 4`.
const DEFAULT_BATCH_SIZE: int = 4
## The 4-enemy spread of the "arc" formation.
const ARC_SPREAD_4: PackedFloat64Array = [-0.42, -0.14, 0.14, 0.42]
## `ENEMY_FIELD_SPAWN_PATTERNS` pools below wave 7 (inline in createEnemyFieldSpawnPlan).
const POOL_EARLY: PackedStringArray = ["scatter", "arc"]
const POOL_MID: PackedStringArray = ["scatter", "arc", "pincer", "line"]


# --- the wave theme and the kind picks ---------------------------------------------------------------------------------------

## # port: enemyCount
static func enemy_count(game: GameState, kind: String) -> int:
	var n: int = 0
	for e: EnemyState in game.enemies:
		if e.kind == kind:
			n += 1
	return n


## # port: currentEnemyWaveTheme. The theme of the current wave; prepareEnemyWaveTheme (which draws) when it is not that of this wave.
## null for the elite and boss waves.
static func current_enemy_wave_theme(game: GameState) -> EnemyWaveTheme:
	if WaveRules.is_special_wave(game.wave, game.mode):
		return null
	if game.wave_spawn_theme != null and game.wave_spawn_theme.wave == game.wave:
		return game.wave_spawn_theme
	return WaveRules.prepare_enemy_wave_theme(game, game.wave)


## # port: unlockedNormalEnemyKinds (without `planned`). The kinds of ENEMY_KIND_ORDER that are unlocked in the current wave and below
## their cap.
static func unlocked_normal_enemy_kinds(game: GameState) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for kind: String in Defs.archetype_kinds():
		if not Defs.has_archetype(kind):
			continue
		if float(game.wave) < WaveRules.enemy_archetype_unlock_wave(kind):
			continue
		if enemy_count(game, kind) < Defs.archetype(kind).cap:
			out.append(kind)
	return out


## # port: pickBalancedMixedEnemyKind. The kind of the mixed share: one gameRandom draw whenever there is a candidate, none otherwise
## (returns "" = the original's null). The weights decide only when there are several candidates.
static func pick_balanced_mixed_enemy_kind(game: GameState, exclude_featured: bool = true) -> String:
	var theme: EnemyWaveTheme = current_enemy_wave_theme(game)
	var candidates: PackedStringArray = unlocked_normal_enemy_kinds(game)
	if exclude_featured and theme != null:
		var mixed: PackedStringArray = PackedStringArray()
		for kind: String in candidates:
			if kind != theme.featured_kind:
				mixed.append(kind)
		if mixed.size() > 0:
			candidates = mixed
	if candidates.is_empty():
		return ""
	var total: float = 0.0
	var weights: PackedFloat64Array = PackedFloat64Array()
	for kind: String in candidates:
		var a: ArchetypeDef = Defs.archetype(kind)
		var wave_count: int = int(theme.counts.get(kind, 0)) if theme != null else 0
		var weight: float = JsMath.clamp(sqrt(JsMath.js_max(0.01, a.weight)), 0.7, 1.6) / (1.0 + float(wave_count) * 0.62)
		if theme != null and theme.recent_mixed.size() > 0 and theme.recent_mixed[theme.recent_mixed.size() - 1] == kind:
			weight *= 0.28
		if kind == "support" and enemy_count(game, kind) > 4:
			weight *= 0.45
		if kind == "controller" and enemy_count(game, kind) > 4:
			weight *= 0.55
		total += weight
		weights.append(weight)
	var roll: float = game.rng.random() * total
	for i: int in range(candidates.size()):
		roll -= weights[i]
		if roll <= 0.0:
			return candidates[i]
	return candidates[candidates.size() - 1]


## # port: pickWaveDirectedEnemyKind. The featured kind while its share of the wave's spawns is behind `featuredShare` (no draw),
## else the mixed pick (one draw). "" is the original's null.
static func pick_wave_directed_enemy_kind(game: GameState) -> String:
	var theme: EnemyWaveTheme = current_enemy_wave_theme(game)
	if theme == null:
		return pick_balanced_mixed_enemy_kind(game, false)
	var target_after_next: float = JsMath.js_round(float(theme.total_spawned + 1) * theme.featured_share)
	var featured_now: int = int(theme.counts.get(theme.featured_kind, 0))
	var featured_def: ArchetypeDef = Defs.archetype(theme.featured_kind) if Defs.has_archetype(theme.featured_kind) else null
	if float(featured_now) < target_after_next and featured_def != null and enemy_count(game, theme.featured_kind) < featured_def.cap:
		return theme.featured_kind
	var mixed: String = pick_balanced_mixed_enemy_kind(game, true)
	if mixed != "":
		return mixed
	if featured_def != null and enemy_count(game, theme.featured_kind) < featured_def.cap:
		return theme.featured_kind
	return ""


## # port: registerDirectorEnemySpawn
static func register_director_enemy_spawn(game: GameState, kind: String) -> void:
	var theme: EnemyWaveTheme = current_enemy_wave_theme(game)
	if theme == null or not Defs.has_archetype(kind):
		return
	theme.total_spawned += 1
	theme.counts[kind] = int(theme.counts.get(kind, 0)) + 1
	if kind != theme.featured_kind:
		theme.recent_mixed.append(kind)
		while theme.recent_mixed.size() > 4:
			theme.recent_mixed.remove_at(0)


# --- the batch ---------------------------------------------------------------------------------------------------------------

## # port: spawnDirectorEnemyBatch (the non-composition path). Plans a formation, then spawns up to 4 enemies while the budget lasts.
## Returns the number of enemies spawned. The kind pick happens BEFORE the budget check, so a tick that ends for lack of budget can
## leave a picked kind in pendingDirectorEnemyKind, which the next tick uses without a draw.
static func spawn_director_enemy_batch(game: GameState) -> int:
	if game.difficulty == "hard" or game.difficulty == "nightmare":
		push_error("EnemyDirector.spawn_director_enemy_batch: the composition path of hard and nightmare is not ported (M1 is normal only)")
		return 0
	var plan: EnemySpawnPlan = create_enemy_field_spawn_plan(game, DEFAULT_BATCH_SIZE)
	var spawned: int = 0
	while spawned < DEFAULT_BATCH_SIZE and game.enemies.size() < game.limits.base_max_enemies:
		var kind: String = game.pending_director_enemy_kind
		if kind == "":
			kind = pick_wave_directed_enemy_kind(game)
		game.pending_director_enemy_kind = kind
		if kind == "":
			break
		var archetype: ArchetypeDef = Defs.archetype(kind)
		var cost: float = archetype.cost if archetype.cost != 0.0 else INF  # `archetype?.cost || Infinity`
		if enemy_count(game, kind) >= archetype.cap:
			game.pending_director_enemy_kind = ""
			continue
		if cost > game.spawn_budget + 1e-3:
			break
		if not spawn_enemy(game, kind, plan, spawned):
			break
		game.pending_director_enemy_kind = ""
		game.spawn_budget -= cost
		spawned += 1
		register_director_enemy_spawn(game, kind)
	return spawned


# --- where ---------------------------------------------------------------------------------------------------------------------

## # port: createEnemyFieldSpawnPlan (normal difficulty: no high-difficulty radii or patterns). Draws the formation (one draw), the
## direction of the player's movement when the player is (nearly) standing still (one draw; a moving player gives the direction by
## atan2), the base angle unless the formation is a pincer (one draw) and the radius (one draw).
static func create_enemy_field_spawn_plan(game: GameState, batch_size: int) -> EnemySpawnPlan:
	var p: PlayerState = game.player
	var view_radius: float = JsMath.js_max(game.view_w, game.view_h) * 0.62
	var min_radius: float = view_radius + 90.0
	var max_radius: float = view_radius + 280.0
	var min_distance: float = JsMath.js_max(220.0, min_radius * 0.72)
	var pool: PackedStringArray
	if game.wave <= 2:
		pool = POOL_EARLY
	elif game.wave <= 6:
		pool = POOL_MID
	else:
		pool = Defs.rules().enemy_field_spawn_patterns
	var pattern: String = pool[game.rng.index(pool.size())]
	var move_speed: float = JsMath.hypot(_or_zero(p.vx), _or_zero(p.vy))
	var move_angle: float
	if move_speed > 24.0:
		move_angle = JsMath.atan2(_or_zero(p.vy), _or_zero(p.vx))
	else:
		move_angle = game.rng.random() * MATH_PI * 2.0
	var base_angle: float
	if pattern == "pincer":
		base_angle = move_angle + MATH_PI / 2.0
	else:
		base_angle = game.rng.random() * MATH_PI * 2.0
	var radius: float = game.rng.rand(min_radius, max_radius)
	var plan: EnemySpawnPlan = EnemySpawnPlan.new()
	plan.pattern = pattern
	plan.base_angle = base_angle
	plan.radius = radius
	plan.cx = JsMath.clamp(p.x + JsMath.cos(base_angle) * radius, 28.0, game.limits.map_w - 28.0)
	plan.cy = JsMath.clamp(p.y + JsMath.sin(base_angle) * radius, 28.0, game.limits.map_h - 28.0)
	plan.min_radius = min_radius
	plan.max_radius = max_radius
	plan.min_distance = min_distance
	plan.batch_size = maxi(1, batch_size if batch_size != 0 else 4)  # Math.max(1, opts.batchSize | 0 || 4)
	return plan


## # port: enemyFieldSpawnPoint. The position of the `index`-th enemy of a batch. A formation point that falls short of the plan's
## minimum distance to the player (map edge clamp) or into a solid hazard is replaced by safeEnemySpawnPoint (more draws).
## `plan` null (a single spawn outside the director) goes to safeEnemySpawnPoint directly.
static func enemy_field_spawn_point(game: GameState, plan: EnemySpawnPlan, index: int, pad: float, body_radius: float) -> EnemySpawnPoint:
	var p: PlayerState = game.player
	if plan == null:
		var plain_min_radius: float = JsMath.js_max(game.view_w, game.view_h) * 0.62 + 90.0
		var plain_max_radius: float = plain_min_radius + 190.0
		return safe_enemy_spawn_point(game, p, plain_min_radius, plain_max_radius, pad, JsMath.js_max(220.0, plain_min_radius * 0.72), body_radius)
	var i: int = maxi(0, index)
	var n: int = plan.batch_size
	var angle: float = plan.base_angle
	var radius: float = plan.radius
	var x: float = plan.cx
	var y: float = plan.cy
	match plan.pattern:
		"scatter":
			return safe_point_around(game, p.x, p.y, plan.min_radius, plan.max_radius, pad, plan.min_distance, 16)
		"arc":
			var slot: int = i % n
			var spread: float
			if n == 4:
				spread = ARC_SPREAD_4[slot]
			elif n <= 1:
				spread = 0.0
			else:
				spread = (float(slot) - float(n - 1) * 0.5) * (0.9 / JsMath.js_max(1.0, float(n - 1)))
			angle += spread + game.rng.rand(-0.055, 0.055)
			radius *= 1.0 + game.rng.rand(-0.07, 0.07)
			x = p.x + JsMath.cos(angle) * radius
			y = p.y + JsMath.sin(angle) * radius
		"pincer":
			var side: int = i % 2
			var rank: int = i >> 1  # `i / 2 | 0`
			angle += MATH_PI if side != 0 else 0.0
			angle += (1.0 if rank != 0 else -1.0) * game.rng.rand(0.05, 0.16)
			radius *= 1.0 + float(rank) * 0.06
			x = p.x + JsMath.cos(angle) * radius
			y = p.y + JsMath.sin(angle) * radius
		"line":
			var tangent_x: float = -JsMath.sin(angle)
			var tangent_y: float = JsMath.cos(angle)
			var offset: float = (float(i) - float(n - 1) * 0.5) * 76.0
			x = plan.cx + tangent_x * offset
			y = plan.cy + tangent_y * offset
		_:
			push_error("EnemyDirector.enemy_field_spawn_point: the formation '%s' is not reachable in M1 (waves 1-4) and not ported" % plan.pattern)
	x = JsMath.clamp(x, pad, game.limits.map_w - pad)
	y = JsMath.clamp(y, pad, game.limits.map_h - pad)
	var actual_distance: float = JsMath.hypot(x - p.x, y - p.y)
	if actual_distance < plan.min_distance:
		return safe_enemy_spawn_point(game, p, plan.min_radius, plan.max_radius, pad, plan.min_distance, body_radius)
	if solid_spawn_clearance(game, x, y, body_radius) < 0.0:
		return safe_enemy_spawn_point(game, p, plan.min_radius, plan.max_radius, pad, plan.min_distance, body_radius)
	return EnemySpawnPoint.make(x, y, actual_distance)


## # port: safePointAround. A random point on the ring around (cx, cy) that is at least `min_distance` away, from up to `attempts`
## tries (each: the angle draw, then the radius draw); else the farthest point seen, tried again on a fixed 8-direction ring.
static func safe_point_around(game: GameState, cx: float, cy: float, min_radius: float, max_radius: float, pad: float,
		min_distance: float, attempts: int = 16) -> EnemySpawnPoint:
	var map_w: float = game.limits.map_w
	var map_h: float = game.limits.map_h
	min_radius = JsMath.js_max(0.0, min_radius)
	max_radius = JsMath.js_max(min_radius, max_radius)
	min_distance = JsMath.js_max(0.0, min_distance)
	var best: EnemySpawnPoint = EnemySpawnPoint.make(JsMath.clamp(cx, pad, map_w - pad), JsMath.clamp(cy, pad, map_h - pad), -1.0)
	for attempt: int in range(attempts):
		var angle: float = game.rng.random() * MATH_PI * 2.0
		var radius: float = game.rng.rand(min_radius, max_radius)
		var x: float = JsMath.clamp(cx + JsMath.cos(angle) * radius, pad, map_w - pad)
		var y: float = JsMath.clamp(cy + JsMath.sin(angle) * radius, pad, map_h - pad)
		var distance: float = JsMath.hypot(x - cx, y - cy)
		if distance > best.distance:
			best = EnemySpawnPoint.make(x, y, distance)
		if distance >= min_distance:
			return EnemySpawnPoint.make(x, y, distance)
	var center_angle: float = JsMath.atan2(map_h * 0.5 - cy, map_w * 0.5 - cx)
	var fallback_radius: float = JsMath.js_max(min_distance, min_radius)
	for i: int in range(8):
		var fallback_angle: float = center_angle + float(i) * MATH_PI / 4.0
		var fx: float = JsMath.clamp(cx + JsMath.cos(fallback_angle) * fallback_radius, pad, map_w - pad)
		var fy: float = JsMath.clamp(cy + JsMath.sin(fallback_angle) * fallback_radius, pad, map_h - pad)
		var fallback_distance: float = JsMath.hypot(fx - cx, fy - cy)
		if fallback_distance > best.distance:
			best = EnemySpawnPoint.make(fx, fy, fallback_distance)
	return best


## # port: safeEnemySpawnPoint. Up to 12 safePointAround(8 attempts) tries for a point that is far enough from the player and clear of
## solid hazards, then a walk over 3 radii x 32 directions (no draws), then the best point seen or one more safePointAround.
static func safe_enemy_spawn_point(game: GameState, p: PlayerState, min_radius: float, max_radius: float, pad: float,
		min_distance: float, body_radius: float) -> EnemySpawnPoint:
	var map_w: float = game.limits.map_w
	var map_h: float = game.limits.map_h
	var best: EnemySpawnPoint = null
	var best_clearance: float = -INF
	for attempt: int in range(12):
		var point: EnemySpawnPoint = safe_point_around(game, p.x, p.y, min_radius, max_radius, pad, min_distance, 8)
		var distance: float = JsMath.hypot(point.x - p.x, point.y - p.y)
		if distance < min_distance:
			continue
		var clearance: float = solid_spawn_clearance(game, point.x, point.y, body_radius)
		if clearance > best_clearance:
			best_clearance = clearance
			best = EnemySpawnPoint.make(point.x, point.y, distance)
		if clearance >= 0.0:
			return best
	var radii: PackedFloat64Array = [max_radius, (min_radius + max_radius) * 0.5, min_radius]
	var start: float = JsMath.atan2(map_h * 0.5 - p.y, map_w * 0.5 - p.x)
	for radius: float in radii:
		for i: int in range(32):
			var angle: float = start + float(i) * MATH_PI / 16.0
			var px: float = JsMath.clamp(p.x + JsMath.cos(angle) * radius, pad, map_w - pad)
			var py: float = JsMath.clamp(p.y + JsMath.sin(angle) * radius, pad, map_h - pad)
			var distance: float = JsMath.hypot(px - p.x, py - p.y)
			if distance < min_distance:
				continue
			var clearance: float = solid_spawn_clearance(game, px, py, body_radius)
			if clearance > best_clearance:
				best_clearance = clearance
				best = EnemySpawnPoint.make(px, py, distance)
			if clearance >= 0.0:
				return best
	if best != null:
		return best
	return safe_point_around(game, p.x, p.y, min_radius, max_radius, pad, min_distance, 16)


## # port: solidSpawnClearance. The distance of a spawn point to the nearest solid hazard (Infinity when there is none). Solid hazards
## (the world tree and the like) come with M2; the list is empty in M1.
static func solid_spawn_clearance(game: GameState, _x: float, _y: float, _body_radius: float) -> float:
	if game.frame_solid_hazards.size() > 0:
		push_error("EnemyDirector.solid_spawn_clearance: solid hazards are not ported yet (M2)")
	return INF


# --- the enemy -------------------------------------------------------------------------------------------------------------------

## # port: spawnEnemy (the director path: a spawn plan and the index of the enemy in the batch; no `near`, no elite or boss).
## Returns false when the enemy list is full. The object is built in the original's literal order, so its nine gameRandom draws
## come in this order: shootCd, aiTimer, abilityCd, strafeDir, aiSeed, thinkCd, (facing: none), animPhase, tacticCd,
## dotNumberTimer. On normal difficulty the later `summonCd` / `decisionCd` / `tacticalAction` blocks do not run.
static func spawn_enemy(game: GameState, kind: String, plan: EnemySpawnPlan, spawn_index: int) -> bool:
	if game.enemies.size() >= game.limits.base_max_enemies and kind != "boss" and kind != "elite":
		return false
	if kind == "boss" or kind == "elite":
		push_error("EnemyDirector.spawn_enemy: elite and boss spawns (assignSpecialAbilities, escorts) are not ported (M2)")
		return false
	if game.difficulty != "normal":
		push_error("EnemyDirector.spawn_enemy: only the normal difficulty is ported (M1); '%s' draws more per enemy" % game.difficulty)
		return false
	var p: PlayerState = game.player
	var s: EnemySpec = Formulas.enemy_spec_for_game(kind, game.wave, game)
	var body_radius: float = JsMath.js_max(24.0, (s.r if s.r != 0.0 else 12.0) + 4.0)  # `Math.max(24, (s.r || 12) + 4)`
	var point: EnemySpawnPoint = enemy_field_spawn_point(game, plan, spawn_index, SPAWN_PAD, body_radius)
	var e: EnemyState = EnemyState.new()
	e.id = game.next_enemy_id
	game.next_enemy_id += 1
	e.x = point.x
	e.y = point.y
	e.vx = 0.0
	e.vy = 0.0
	e.kind = s.kind
	e.r = s.r
	e.hp = s.hp
	e.speed = s.speed
	e.damage = s.damage
	e.color = s.color
	e.xp = s.xp
	e.armor = s.armor
	e.evasion = s.evasion
	e.shoot = s.shoot
	e.elite = s.elite
	e.boss = s.boss
	e.shield = s.shield
	e.projectile_speed_mul = s.projectile_speed_mul
	e.action_cooldown_mul = s.action_cooldown_mul
	e.ability_cooldown_mul = s.ability_cooldown_mul
	e.spawn_wave = game.wave
	e.base_max_hp = s.hp
	e.max_hp = s.hp
	e.max_shield = s.shield  # `s.shield || 0`
	e.shoot_cd = game.rng.rand(0.4, 1.8) * SimUtil.or_one(s.action_cooldown_mul)
	e.ai_timer = game.rng.rand(0.1, 0.8)
	e.ability_cd = game.rng.rand(1.2, 3.2) * _ability_cooldown_factor(s)
	e.strafe_dir = 1 if game.rng.chance(0.5) else -1
	e.ai_seed = game.rng.random() * MATH_PI * 2.0
	e.think_cd = game.rng.rand(0.05, 0.25)
	e.facing = JsMath.atan2(p.y - point.y, p.x - point.x)
	e.anim_phase = game.rng.random() * MATH_PI * 2.0
	e.tactic_cd = game.rng.rand(0.7, 2.1)
	e.dot_number_timer = game.rng.rand(0.08, 0.35)
	game.enemies.append(e)
	game.enemies_version += 1
	return true


## `s.abilityCooldownMul || s.actionCooldownMul || 1`
static func _ability_cooldown_factor(s: EnemySpec) -> float:
	if s.ability_cooldown_mul != 0.0 and not is_nan(s.ability_cooldown_mul):
		return s.ability_cooldown_mul
	return SimUtil.or_one(s.action_cooldown_mul)


## `x || 0`: 0 when x is 0, -0 or NaN (so a -0 becomes +0, which atan2 can tell apart).
static func _or_zero(x: float) -> float:
	return 0.0 if x == 0.0 or is_nan(x) else x
