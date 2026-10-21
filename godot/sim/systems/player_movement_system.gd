class_name PlayerMovementSystem
extends SimSystem
## player/movement: updatePlayerMovement(dt). Turns the input into the player's new position, velocity and
## acceleration (enemy AI aims at the velocity and the acceleration, so they are part of the simulation) and advances
## the walk animation.
##
## What the original calls here and what it does in the M1 configuration (catalyst, no hazards, no abilities):
##   updatePlayerControlHazards   only resets hazardDefenseBonus (game.hazards is empty)       -> ported, hazards loop included
##   effectivePlayerMoveSpeedMul  1.0: no archivist bank, no berserker frenzy, no sentinel/harmonizer -> _move_speed_mul()
##   pathfinderAddDistance        returns at once unless the character is the pathfinder      -> guard only
##   metaAbilityOnMove            loops over specials.metaActive, which is empty in M1         -> guard only
##
## This slot is not the only writer of the player's x/y: enemy/update (updateEnemies -> contact damage, EnemyUpdateSystem) pushes the player
## 22 px away from the enemy that hit (`p.x = clamp(p.x + ndx / nd * 22, 18, MAP_W - 18)`, same for y), together with the hp loss, the damage
## flash and three gameRandom draws per hit. Ported in step S5: the player's position stays the original's through the hits (frame 586 is the
## first of them for seed 424242 with the design 9.2 input).


func _init(p_game: GameState) -> void:
	super(p_game, "updatePlayerMovement")


## # port: updatePlayerMovement
func run(dt: float) -> void:
	var p: PlayerState = game.player
	var inp: SimInput = game.input
	inp.resolve()  # inputVector()
	p.control_slow = 1.0
	_update_control_hazards()
	var prev_px: float = p.x
	var prev_py: float = p.y
	var prev_vx: float = p.vx
	var prev_vy: float = p.vy
	var move_speed: float = p.speed * _move_speed_mul()
	var limits: SimLimits = game.limits
	# Left to right, as written: ((mv.x * moveSpeed) * controlSlow) * dt
	p.x = JsMath.clamp(p.x + inp.out_x * move_speed * p.control_slow * dt, 18.0, limits.map_w - 18.0)
	p.y = JsMath.clamp(p.y + inp.out_y * move_speed * p.control_slow * dt, 18.0, limits.map_h - 18.0)
	var dt_floor: float = JsMath.js_max(1e-3, dt)
	p.vx = (p.x - prev_px) / dt_floor
	p.vy = (p.y - prev_py) / dt_floor
	p.ax = JsMath.clamp((p.vx - prev_vx) / dt_floor, -1400.0, 1400.0)
	p.ay = JsMath.clamp((p.vy - prev_vy) / dt_floor, -1400.0, 1400.0)
	_path_finder_add_distance()
	_meta_ability_on_move()
	var visual_speed: float = JsMath.hypot(p.vx, p.vy)
	p.attack_anim = JsMath.js_max(0.0, p.attack_anim - dt)
	if visual_speed > 8.0:
		var rules: SimRules = Defs.rules()
		var walk_fps: float = rules.walk_fps_min + JsMath.js_min(rules.walk_fps_max - rules.walk_fps_min, visual_speed / 110.0)
		p.walk_phase = JsMath.js_mod(p.walk_phase + dt * walk_fps, 1e4)
		p.last_facing = JsMath.atan2(p.vy, p.vx)


## # port: updatePlayerControlHazards
func _update_control_hazards() -> void:
	var p: PlayerState = game.player
	p.hazard_defense_bonus = 0.0
	if game.hazards.size() > 0:
		push_error("PlayerMovementSystem: slow zones and frost sanctums (game.hazards) are not ported yet (M2)")


## # port: effectivePlayerMoveSpeedMul. The product of archivistBankMoveSpeedMul, berserkerMoveSpeedMul,
## berserkerConvergeMoveMul, sentinelMoveSpeedMul and harmonizerMoveSpeedMul, clamped to [0.05, 20]. For the catalyst every
## factor is exactly 1 (a bank power of 0, a frenzy of 0, ability rank 0, no sentinel or harmonizer state).
func _move_speed_mul() -> float:
	if game.char_id != "catalyst":
		push_error("PlayerMovementSystem: the movement speed factors of '%s' are not ported yet (M2)" % game.char_id)
	return JsMath.clamp(1.0, 0.05, 20.0)


## # port: pathfinderAddDistance (`if (!pathfinderActive()) return;`)
func _path_finder_add_distance() -> void:
	if game.char_id == "pathfinder" and game.pathfinder != null:
		push_error("PlayerMovementSystem: the pathfinder's distance charge is not ported yet (M2)")


## # port: metaAbilityOnMove. Walks specials.metaActive, which is empty unless an ability with a meta stage has a rank.
func _meta_ability_on_move() -> void:
	if game.specials.meta_active.size() > 0:
		push_error("PlayerMovementSystem: meta abilities (momentum pulse, camp guard) are not ported yet (M2)")
