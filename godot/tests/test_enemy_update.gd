extends "res://tests/test_case.gd"
## enemy/update (EnemyUpdateSystem and what it calls: EnemyAi, EnemySteering, PlayerDamage) as small hand-made situations, apart from the
## reference traces of test_reference_trace.gd, which hold the bit-exact comparison with the original (143,000 enemy steps, 32 contact hits).
## What is checked here is what the traces cannot say or do not reach: the rules of each function in isolation (separation, avoidance, prediction,
## damage), the order of the loop, the edge cases of the contact hit (the cooldown, the map edge, a nearly dead player, an enemy that cannot act),
## the assassin's state machine step by step, the draws, and that the float literals of the enemy code are read exactly.
##
## The expected values are worked out here from the original's code with plain arithmetic, in the original's operation order.

const DT: float = 1.0 / 60.0
## The source files of the enemy path; every float literal in them is checked (test_the_float_literals...).
const LITERAL_SOURCES: PackedStringArray = [
	"res://sim/enemy_ai.gd", "res://sim/enemy_steering.gd", "res://sim/player_damage.gd", "res://sim/sim_util.gd",
	"res://sim/enemy_status.gd", "res://sim/systems/enemy_update_system.gd",
]


func _new_game(rng_seed: int = 7) -> GameState:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = rng_seed
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game")
	return sim.game


## An enemy of `kind` with the stats of the current wave, as spawnEnemy would build it (without its draws): all AI timers are set to
## values that keep the enemy idle.
func _spawn(game: GameState, kind: String, id: int, x: float, y: float) -> EnemyState:
	var s: EnemySpec = Formulas.enemy_spec_for_game(kind, game.wave, game)
	var e: EnemyState = EnemyState.new()
	e.id = id
	e.x = x
	e.y = y
	e.kind = s.kind
	e.r = s.r
	e.hp = s.hp
	e.max_hp = s.hp
	e.base_max_hp = s.hp
	e.speed = s.speed
	e.damage = s.damage
	e.xp = s.xp
	e.action_cooldown_mul = s.action_cooldown_mul
	e.ability_cooldown_mul = s.ability_cooldown_mul
	e.spawn_wave = game.wave
	e.ai_seed = 1.0
	e.ability_cd = 5.0
	e.ai_timer = 0.5
	e.think_cd = 0.1
	e.tactic_cd = 1.0
	e.dot_number_timer = 0.2
	game.enemies.append(e)
	return e


func _step(game: GameState, system: EnemyUpdateSystem) -> void:
	system.run(DT)


# --- literals ---------------------------------------------------------------------------------------------------------

## The decimal literal as its exact value would round: `digits * 10^-scale` with digits an integer below 2^53 and 10^scale exact, so the
## division is correctly rounded by IEEE 754. (Null-safe for up to 15 digits and 10^22.)
func _correctly_rounded(literal: String) -> float:
	var text: String = literal.to_lower()
	var exponent: int = 0
	if text.contains("e"):
		var halves: PackedStringArray = text.split("e")
		text = halves[0]
		exponent = int(halves[1])
	var parts: PackedStringArray = text.split(".")
	var integer_digits: String = parts[0]
	var fraction_digits: String = parts[1] if parts.size() > 1 else ""
	var digits: String = (integer_digits + fraction_digits).lstrip("0")
	if digits.is_empty():
		return 0.0
	assert_true(digits.length() <= 15, "%s has at most 15 significant digits" % literal)
	var mantissa: float = float(digits.to_int())
	var scale: int = fraction_digits.length() - exponent
	var power: float = 1.0
	for i: int in range(absi(scale)):
		power *= 10.0
	return mantissa / power if scale >= 0 else mantissa * power


func test_the_float_literals_of_the_enemy_code_are_read_exactly() -> void:
	# Godot's float parser is not correctly rounded in general (the S3 finding behind the f64: markers of the defs); for the short literals the enemy
	# code uses it is, and this scans every literal of the files rather than a list that could miss one.
	var literal_re: RegEx = RegEx.create_from_string("(?<![\\w.])(\\d+\\.\\d+(?:[eE][-+]?\\d+)?|\\d+[eE][-+]?\\d+)(?![\\w.])")
	var checked: int = 0
	for path: String in LITERAL_SOURCES:
		for line: String in FileAccess.get_file_as_string(path).split("\n"):
			var code: String = line
			var hash_at: int = code.find("#")
			if hash_at >= 0:
				code = code.substr(0, hash_at)
			for found: RegExMatch in literal_re.search_all(code):
				var literal: String = found.get_string(1)
				assert_eq(literal.to_float(), _correctly_rounded(literal), "%s: the literal %s is read exactly" % [path, literal])
				checked += 1
	assert_true(checked > 100, "many literals were checked (%d)" % checked)
	# and the compiler's own reading of the ones that matter most, written the way the code writes them
	assert_eq(0.16, 16.0 / 100.0, "0.16")
	assert_eq(0.12, 12.0 / 100.0, "0.12")
	assert_eq(0.34, 34.0 / 100.0, "0.34")
	assert_eq(0.62, 62.0 / 100.0, "0.62")
	assert_eq(0.08, 8.0 / 100.0, "0.08")
	assert_eq(0.05, 5.0 / 100.0, "0.05")
	assert_eq(1.05, 105.0 / 100.0, "1.05")
	assert_eq(0.22, 22.0 / 100.0, "0.22")
	assert_eq(0.55, 55.0 / 100.0, "0.55")
	assert_eq(5.45, 545.0 / 100.0, "5.45")
	assert_eq(0.68, 68.0 / 100.0, "0.68")
	assert_eq(0.38, 38.0 / 100.0, "0.38")
	assert_eq(2.4, 24.0 / 10.0, "2.4")
	assert_eq(0.94, 94.0 / 100.0, "0.94")
	assert_eq(0.72, 72.0 / 100.0, "0.72")
	assert_eq(1.55, 155.0 / 100.0, "1.55")
	assert_eq(0.42, 42.0 / 100.0, "0.42")
	assert_eq(0.28, 28.0 / 100.0, "0.28")
	assert_eq(0.32, 32.0 / 100.0, "0.32")
	assert_eq(0.82, 82.0 / 100.0, "0.82")
	assert_eq(0.18, 18.0 / 100.0, "0.18")
	assert_eq(0.995, 995.0 / 1000.0, "0.995")
	assert_eq(1.0 / 30.0, EnemySteering.MAX_SMOOTH_DT, "1/30")
	assert_eq(1e-3, 1.0 / 1000.0, "1e-3")
	assert_eq(1e-6, 1.0 / 1000000.0, "1e-6")


func test_the_scanner_of_literals_finds_what_it_must() -> void:
	assert_eq(_correctly_rounded("0.16"), 16.0 / 100.0, "0.16")
	assert_eq(_correctly_rounded("5.45"), 545.0 / 100.0, "5.45")
	assert_eq(_correctly_rounded("1e-6"), 1.0 / 1000000.0, "1e-6")
	assert_eq(_correctly_rounded("12.0"), 12.0, "12.0")
	assert_eq(_correctly_rounded("0.0"), 0.0, "0.0")


func test_or_zero_and_or_one_follow_the_falsy_rule_of_javascript() -> void:
	var negative_zero: float = 0.0 * -1.0
	assert_eq(SimTrace.hex_of(negative_zero), "8000000000000000", "the test's -0 really is -0")
	assert_eq(SimTrace.hex_of(SimUtil.or_zero(negative_zero)), "0000000000000000", "x || 0 turns -0 into +0")
	assert_eq(SimUtil.or_zero(NAN), 0.0, "NaN || 0")
	assert_eq(SimUtil.or_zero(2.5), 2.5, "2.5 || 0")
	assert_eq(SimUtil.or_zero(-3.0), -3.0, "-3 || 0")
	assert_eq(SimUtil.or_one(0.0), 1.0, "0 || 1")
	assert_eq(SimUtil.or_one(negative_zero), 1.0, "-0 || 1")
	assert_eq(SimUtil.or_one(NAN), 1.0, "NaN || 1")
	assert_eq(SimUtil.or_one(0.5), 0.5, "0.5 || 1")


func test_segment_circle_hit_follows_the_original() -> void:
	# a point (a segment shorter than 1e-3): inside or outside the circle, tangent counts
	assert_true(SimUtil.segment_circle_hit(0.0, 0.0, 0.0, 0.0, 3.0, 4.0, 5.0), "a point on the circle (distance 5 <= 5)")
	assert_false(SimUtil.segment_circle_hit(0.0, 0.0, 0.0, 0.0, 3.0, 4.0, 4.99), "a point outside")
	assert_true(SimUtil.segment_circle_hit(0.0, 0.0, 0.0005, 0.0, 3.0, 4.0, 5.0), "len2 <= 1e-6 is a point too")
	# a segment that passes through the circle although both ends are outside
	assert_true(SimUtil.segment_circle_hit(-10.0, 0.0, 10.0, 0.0, 0.0, 1.0, 2.0), "passes through")
	assert_false(SimUtil.segment_circle_hit(-10.0, 0.0, 10.0, 0.0, 0.0, 3.0, 2.0), "passes by")
	# the nearest point is clamped to the segment: the circle is behind the end
	assert_true(SimUtil.segment_circle_hit(0.0, 0.0, 10.0, 0.0, -5.0, 0.0, 5.5), "clamped to the start: distance 5")
	assert_false(SimUtil.segment_circle_hit(0.0, 0.0, 10.0, 0.0, -5.0, 0.0, 4.9), "clamped to the start, out of reach")
	assert_true(SimUtil.segment_circle_hit(0.0, 0.0, 10.0, 0.0, 15.0, 0.0, 5.0), "clamped to the end: tangent")


# --- the AI tuning ------------------------------------------------------------------------------------------------------

func test_the_ai_skill_of_a_normal_enemy_is_three_quarters_of_the_waves_and_an_elite_plays_better() -> void:
	var game: GameState = _new_game()
	var e: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	game.enemy_ai_skill = 0.4
	assert_eq(EnemyAi.enemy_ai_skill_of(game, e), 0.4 * 0.75, "normal rank: skill * 0.75")
	game.enemy_ai_skill = 0.985
	assert_eq(EnemyAi.enemy_ai_skill_of(game, e), 0.985 * 0.75, "the wave's skill is at most 0.985")
	e.elite = true
	assert_eq(EnemyAi.enemy_ai_skill_of(game, e), 0.995, "an elite's 1.12 * 0.985 is clamped to 0.995")
	e.elite = false
	e.boss = true
	assert_eq(EnemyAi.enemy_ai_skill_of(game, e), 0.995, "a boss's too")
	# a game whose enemyAiSkill is not a finite number falls back to the skill of the wave
	game.enemy_ai_skill = NAN
	game.wave = 5
	var from_wave: float = WaveRules.enemy_ai_skill(5)
	e.boss = false
	assert_eq(EnemyAi.enemy_ai_skill_of(game, e), JsMath.clamp(from_wave * 0.75, 0.0, 0.995), "NaN -> enemyAiSkill(wave)")


func test_telegraph_dodge_and_difficulty_factors_on_normal() -> void:
	var game: GameState = _new_game()
	var e: EnemyState = _spawn(game, "assassin", 1, 1000.0, 1000.0)
	game.enemy_ai_skill = 0.0
	# skill 0: max(0.28, 0.42 * 1) * 1.16 (the normal rank's telegraph factor; telegraphMin and Max are 0)
	assert_eq(EnemyAi.enemy_ai_telegraph(game, 0.42, 0.28, e), 0.42 * 1.16, "telegraph at skill 0")
	game.enemy_ai_skill = 0.8
	var skill: float = 0.8 * 0.75
	assert_eq(EnemyAi.enemy_ai_telegraph(game, 0.42, 0.28, e), JsMath.js_max(0.28, 0.42 * (1.0 - skill * 0.34)) * 1.16, "telegraph at skill 0.6")
	assert_eq(EnemyAi.enemy_ai_telegraph(game, 0.1, 0.28, e), 0.28 * 1.16, "the minimum applies before the rank factor")
	assert_eq(EnemyAi.enemy_ai_dodge_mul(game, e), 1.0 + skill * 0.55 * 0.84, "dodge multiplier: 1 + skill * 0.55 * 0.84")
	assert_eq(EnemyAi.difficulty_wait_mul(game), 1.0, "1 / (0.82 + 1 * 0.18) is exactly 1")
	assert_eq(EnemyAi.difficulty_attack_range_mul(game), 1.0, "1 + (1 - 1) * 0.12")
	assert_true(EnemyAi.coordinated_attack_ready(game, e, "high"), "no coordination on normal")
	# an elite's telegraph: 0.95 factor, at least 0.26
	e.elite = true
	game.enemy_ai_skill = 0.0
	assert_eq(EnemyAi.enemy_ai_telegraph(game, 0.1, 0.0, e), JsMath.js_max(0.26, 0.1 * 0.95), "elite: the rank's minimum 0.26 wins")
	e.elite = false
	e.boss = true
	assert_eq(EnemyAi.enemy_ai_telegraph(game, 0.3, 0.0, e), JsMath.js_min(2.0, JsMath.js_max(1.0, 0.3 * 2.1)), "boss: between 1 and 2")


# --- steering -----------------------------------------------------------------------------------------------------------

func test_separation_averages_the_push_of_the_neighbours_in_range_and_skips_the_rest() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var a: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	var near: EnemyState = _spawn(game, "swarm", 2, 1020.0, 1000.0)       # 20 px to the right: pushes a to the left, weight 1 - 20/36
	_spawn(game, "swarm", 3, 1000.0, 1100.0)                              # 100 px: out of range
	_spawn(game, "swarm", 4, 1000.0, 1000.0)                              # same position: d2 <= 0.01, skipped
	var dead: EnemyState = _spawn(game, "swarm", 5, 1010.0, 1000.0)       # dead: skipped
	dead.hp = 0.0
	game.enemy_grid.rebuild(game.enemies)   # the dead one is not even bucketed
	steering.enemy_separation_vector(a, 36.0)
	assert_eq(steering.sep_x, -(1.0 - 20.0 / 36.0), "one neighbour in range: -1 * (1 - 20/36)")
	assert_eq(steering.sep_y, 0.0, "no vertical component (0 * w)")
	# two neighbours on opposite sides cancel and are averaged
	assert_true(near.id == 2, "the right neighbour is still there")
	var left: EnemyState = _spawn(game, "swarm", 6, 980.0, 1000.0)
	game.enemy_grid.rebuild(game.enemies)
	steering.enemy_separation_vector(a, 36.0)
	assert_eq(steering.sep_x, ((-(1.0 - 20.0 / 36.0)) + (1.0 - 20.0 / 36.0)) / 2.0, "left and right: the sum over the count")
	assert_true(left.id == 6, "the left neighbour exists")


func test_separation_reads_live_positions_from_the_buckets_of_the_last_rebuild() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var a: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	var b: EnemyState = _spawn(game, "swarm", 2, 1000.0, 1500.0)   # far away, in another cell
	game.enemy_grid.rebuild(game.enemies)
	# b moves next to a after the rebuild: it is still in its old bucket, which a does not scan, so it is not counted
	b.y = 1010.0
	steering.enemy_separation_vector(a, 36.0)
	assert_eq(steering.sep_x, 0.0, "not counted: the bucket of a's cells does not hold b")
	assert_eq(steering.sep_y, 0.0, "not counted")
	# after the next rebuild it is
	game.enemy_grid.rebuild(game.enemies)
	steering.enemy_separation_vector(a, 36.0)
	assert_eq(steering.sep_y, -(1.0 - 10.0 / 36.0), "counted after the rebuild")
	# c is in a's bucket but has moved out of range since: skipped by the distance test with its LIVE position; and a bucket member that
	# moved INTO range counts with its live position
	b.y = 1500.0
	var c: EnemyState = _spawn(game, "swarm", 3, 1005.0, 1000.0)
	game.enemy_grid.rebuild(game.enemies)
	c.x = 1500.0
	steering.enemy_separation_vector(a, 36.0)
	assert_eq(steering.sep_x, 0.0, "c's live position is out of range")
	c.x = 1018.0
	steering.enemy_separation_vector(a, 36.0)
	assert_eq(steering.sep_x, -(1.0 - 18.0 / 36.0), "c's live position counts although the bucket was built when it stood at 1005")


func test_separation_scans_the_whole_list_when_the_grid_is_empty() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var a: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	_spawn(game, "swarm", 2, 1000.0, 1024.0)
	assert_eq(game.enemy_grid.size(), 0, "the grid was never built")
	steering.enemy_separation_vector(a, 36.0)
	assert_eq(steering.sep_y, -(1.0 - 24.0 / 36.0), "pushed away from the enemy below")


func test_projectile_avoidance_pushes_sideways_from_approaching_projectiles_only() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var e: EnemyState = _spawn(game, "assassin", 1, 1000.0, 1000.0)
	game.enemy_ai_skill = 0.0   # skill 0: radius 120, at most 5 projectiles count
	steering.enemy_projectile_avoidance(e, 120.0)
	assert_eq(steering.avoid_x, 0.0, "no projectiles: zero")
	assert_eq(steering.avoid_y, 0.0, "no projectiles: zero")
	var approaching: ProjectileState = ProjectileState.new()
	approaching.x = 940.0
	approaching.y = 1000.0
	approaching.vx = 300.0       # flying toward the enemy (to the right)
	approaching.vy = 0.0
	game.projectiles.append(approaching)
	steering.enemy_projectile_avoidance(e, 120.0)
	# d = 60, w = 1 - 60/120 = 0.5; px2 = -0/300, py = 300/300 = 1; dx = 60, dy = 0: px2*dx + py*dy = 0 >= 0 -> side +1; ax += -0 * 1 * 0.5, ay += 1 * 1 * 0.5
	assert_eq(steering.avoid_y, 0.5, "pushed sideways (perpendicular to the flight) with weight 1 - d / radius")
	assert_eq(steering.avoid_x, 0.0, "no push along the flight")
	# a projectile that flies away, one too far, one on top of the enemy: all ignored
	game.projectiles.clear()
	for spec: Array in [[940.0, 1000.0, -300.0, 0.0], [800.0, 1000.0, 300.0, 0.0], [1000.5, 1000.0, 300.0, 0.0]]:
		var pr: ProjectileState = ProjectileState.new()
		pr.x = float(spec[0])
		pr.y = float(spec[1])
		pr.vx = float(spec[2])
		pr.vy = float(spec[3])
		game.projectiles.append(pr)
	steering.enemy_projectile_avoidance(e, 120.0)
	assert_eq(steering.avoid_x, 0.0, "receding, distant and overlapping projectiles are ignored: x")
	assert_eq(steering.avoid_y, 0.0, "receding, distant and overlapping projectiles are ignored: y")
	# at most 5 + floor(skill * 4) count (skill 0: 5): eight identical approaching projectiles add up to five
	game.projectiles.clear()
	for i: int in range(8):
		var pr2: ProjectileState = ProjectileState.new()
		pr2.x = 940.0
		pr2.y = 1000.0
		pr2.vx = 300.0
		game.projectiles.append(pr2)
	steering.enemy_projectile_avoidance(e, 120.0)
	assert_eq(steering.avoid_y, 0.5 + 0.5 + 0.5 + 0.5 + 0.5, "five hits at most at skill 0")
	game.enemy_ai_skill = 1.0   # the enemy's skill 0.75: floor(0.75 * 4) = 3 -> eight checks, radius 120 * (1 + 0.75 * 0.22)
	steering.enemy_projectile_avoidance(e, 120.0)
	var radius: float = 120.0 * (1.0 + 0.75 * 0.22)
	var w: float = 1.0 - 60.0 / radius
	assert_eq(steering.avoid_y, w + w + w + w + w + w + w + w, "eight hits at skill 0.75, weight against the widened radius")


func test_prediction_leads_the_player_by_its_velocity_and_acceleration_and_stays_on_the_map() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var e: EnemyState = _spawn(game, "assassin", 1, 1000.0, 1600.0)
	var p: PlayerState = game.player
	p.x = 1000.0
	p.y = 1000.0
	p.vx = 100.0
	p.vy = -50.0
	p.ax = 0.0
	p.ay = 0.0
	game.enemy_ai_skill = 0.0
	steering.predict_player_position(e, 650.0, 0.34)
	# distance 600, travel = 600 / 650, lead = min(0.34 * 1, travel * 0.92) = 0.34; accelT = 0
	assert_eq(steering.pred_x, 1000.0 + 100.0 * 0.34 + 0.0, "x + vx * lead + ox")
	assert_eq(steering.pred_y, 1000.0 + -50.0 * 0.34 + 0.0, "y + vy * lead + oy")
	# with skill and acceleration: accelT = 0.5 * lead * lead * skill * 0.16, the offset is limited to +-72
	game.enemy_ai_skill = 0.8
	var skill: float = 0.8 * 0.75
	p.ax = 1400.0
	p.ay = -1400.0
	steering.predict_player_position(e, 650.0, 0.34)
	var lead: float = JsMath.js_min(0.34 * (1.0 + skill * 0.28), (600.0 / 650.0) * (0.92 + skill * 0.18))
	var accel_t: float = 0.5 * lead * lead * skill * 0.16
	assert_eq(steering.pred_x, 1000.0 + 100.0 * lead + JsMath.clamp(1400.0 * accel_t, -72.0, 72.0), "with the acceleration")
	assert_eq(steering.pred_y, 1000.0 + -50.0 * lead + JsMath.clamp(-1400.0 * accel_t, -72.0, 72.0), "with the acceleration (y)")
	# kept on the map: a player at the edge moving outward
	p.x = 20.0
	p.vx = -1000.0
	p.ax = 0.0
	p.ay = 0.0
	steering.predict_player_position(e, 650.0, 0.34)
	assert_eq(steering.pred_x, 18.0, "clamped to 18 px from the edge")


func test_the_exp_cache_gives_the_very_double_of_the_direct_computation() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var e: EnemyState = _spawn(game, "swarm", 1, 5000.0, 5000.0)
	# smoothEnemyVelocity from rest toward (30, -40) with a limit of 50, at three different dt, twice each (the second time from the cache)
	for dt: float in [DT, 1.0 / 30.0, 0.0123, DT, 0.0123, 0.5]:
		e.vx = 3.0
		e.vy = -2.0
		steering.smooth_enemy_velocity(e, 30.0, -40.0, 50.0, dt)
		var safe_dt: float = JsMath.js_max(0.0, JsMath.js_min(1.0 / 30.0, dt))
		var blend: float = 1.0 - JsMath.exp(-12.5 * safe_dt)
		var nvx: float = 3.0 + (30.0 - 3.0) * blend
		var nvy: float = -2.0 + (-40.0 - -2.0) * blend
		var speed: float = JsMath.hypot(nvx, nvy)
		if speed > 50.0:
			nvx *= 50.0 / speed
			nvy *= 50.0 / speed
		assert_eq(e.vx, nvx, "dt %s: vx" % dt)
		assert_eq(e.vy, nvy, "dt %s: vy" % dt)
	# braking: faster than the limit + 6 uses the rate 18
	e.vx = 100.0
	e.vy = 0.0
	steering.smooth_enemy_velocity(e, 0.0, 0.0, 20.0, DT)
	var blend_brake: float = 1.0 - JsMath.exp(-18.0 * DT)
	var after: float = 100.0 + (0.0 - 100.0) * blend_brake
	var capped: float = 20.0 / after
	assert_eq(e.vx, after * capped if after > 20.0 else after, "braking blend 1 - exp(-18 dt), then the cap")
	# a limit of 0 (or less) stops the enemy; a velocity that is not finite counts as 0
	e.vx = 5.0
	steering.smooth_enemy_velocity(e, 1.0, 1.0, 0.0, DT)
	assert_eq(e.vx, 0.0, "limit 0 clears vx")
	assert_eq(e.vy, 0.0, "limit 0 clears vy")
	e.vx = NAN
	e.vy = INF
	steering.smooth_enemy_velocity(e, 10.0, 0.0, 50.0, DT)
	assert_eq(e.vx, 10.0 * (1.0 - JsMath.exp(-12.5 * DT)), "NaN counts as 0")
	assert_eq(e.vy, 0.0, "Infinity counts as 0 (0 + (0 - 0) * blend)")


# --- hurting the player ---------------------------------------------------------------------------------------------------

func test_incoming_damage_is_the_product_of_the_factors_in_the_original_order() -> void:
	var game: GameState = _new_game()
	var p: PlayerState = game.player
	assert_eq(PlayerDamage.calculate_incoming_player_damage(game, 8.0, NAN), 8.0, "the catalyst has no defense: damage as it comes")
	assert_eq(PlayerDamage.calculate_incoming_player_damage(game, 8.0, 1.18), 8.0 * 1.18, "the enemy's multiplier")
	assert_eq(PlayerDamage.calculate_incoming_player_damage(game, 8.0, INF), 8.0, "a multiplier that is not finite counts as 1")
	assert_eq(PlayerDamage.calculate_incoming_player_damage(game, 8.0, -2.0), 0.0, "a negative multiplier gives 0 (max(0, m))")
	assert_eq(PlayerDamage.calculate_incoming_player_damage(game, -5.0, NAN), 0.0, "a negative amount gives 0")
	assert_eq(PlayerDamage.calculate_incoming_player_damage(game, NAN, NAN), 0.0, "a NaN amount gives 0")
	p.defense = 0.2
	p.hazard_defense_bonus = 0.1
	assert_eq(PlayerDamage.effective_player_defense(game), 0.2 + 0.1, "defense + hazard defense")
	assert_eq(PlayerDamage.calculate_incoming_player_damage(game, 8.0, 1.18), 8.0 * 1.18 * 1.0 * 1.0 * (1.0 - (0.2 + 0.1)) * 1.0, "left to right: base * enemy * ability * taken * (1 - defense) * final")
	p.defense = 2.0
	assert_eq(PlayerDamage.effective_player_defense(game), 0.85, "defense is clamped to 0.85")
	p.defense = -5.0
	assert_eq(PlayerDamage.effective_player_defense(game), -0.9, "and to -0.9 from below")
	assert_eq(PlayerDamage.calculate_incoming_player_damage(game, 10.0, NAN), 10.0 * (1.0 - -0.9), "negative defense raises the damage")


func test_hurting_the_player_lowers_hp_flashes_the_screen_and_draws_three_values() -> void:
	var game: GameState = _new_game(11)
	var mirror: GameRng = GameRng.new(11)
	mirror.random()   # newGame's draw
	var p: PlayerState = game.player
	p.hp = 50.0
	var draws: int = game.rng.draws
	var lost: float = PlayerDamage.hurt_player(game, 8.0, true, 1.0)
	assert_eq(lost, 8.0, "the hp actually lost")
	assert_eq(p.hp, 42.0, "hp")
	assert_eq(game.damage_flash, 0.34, "the damage flash")
	assert_eq(game.rng.draws - draws, 3, "showDamageNumber draws three values")
	mirror.rand(-3.0, 3.0)
	mirror.rand(-5.0, 5.0)
	mirror.rand(0.0, 7.0)
	assert_eq(game.rng.random(), mirror.random(), "the stream is three draws further")
	# no hit effect for a hit that is not an enemy's (the flash is a hit effect), but the number is shown
	game.damage_flash = 0.0
	draws = game.rng.draws
	PlayerDamage.hurt_player(game, 2.0, false, NAN)
	assert_eq(game.damage_flash, 0.0, "no hit effect without enemyHit")
	assert_eq(game.rng.draws - draws, 3, "the number is still shown")
	# the flash is a maximum
	game.damage_flash = 0.5
	PlayerDamage.hurt_player(game, 2.0, true, NAN)
	assert_eq(game.damage_flash, 0.5, "max(0.5, 0.34)")


func test_a_nearly_dead_player_loses_only_what_it_has_and_draws_nothing_below_the_number_threshold() -> void:
	var game: GameState = _new_game()
	var p: PlayerState = game.player
	p.hp = 3.0
	var draws: int = game.rng.draws
	assert_eq(PlayerDamage.hurt_player(game, 8.0, true, 1.0), 3.0, "the damage is capped by the hp")
	assert_eq(p.hp, 0.0, "dead")
	assert_eq(game.rng.draws - draws, 3, "3 > 0.04: a number")
	# 0.03 hp lost: the amount is not above 0.04, so no number and no draws (the hit effect still happens)
	p.hp = 0.03
	game.damage_flash = 0.0
	draws = game.rng.draws
	assert_eq(PlayerDamage.hurt_player(game, 8.0, true, 1.0), 0.03, "0.03 lost")
	assert_eq(game.rng.draws - draws, 0, "amount <= 0.04: no number, no draws")
	assert_eq(game.damage_flash, 0.34, "but the flash")
	# no hp at all: nothing happens, not even the flash
	game.damage_flash = 0.0
	draws = game.rng.draws
	assert_eq(PlayerDamage.hurt_player(game, 8.0, true, 1.0), 0.0, "no hp to lose")
	assert_eq(game.damage_flash, 0.0, "no flash")
	assert_eq(game.rng.draws - draws, 0, "no draws")


func test_the_damage_number_gate_depends_on_the_particle_count() -> void:
	var game: GameState = _new_game()
	var mirror: GameRng = GameRng.new(7)
	mirror.random()
	# the limit is written out here, not read from the constant under test: damageLabelParticleLimit() is 1100 (560 in eco quality)
	for i: int in range(1099):
		game.particles.append(null)
	var draws: int = game.rng.draws
	assert_eq(PlayerDamage.show_damage_number(game, 5.0, false).size(), 3, "1099 particles: the number is shown (three values)")
	assert_eq(game.rng.draws - draws, 3, "1099 particles: the number is shown")
	game.particles.append(null)
	draws = game.rng.draws
	assert_eq(PlayerDamage.show_damage_number(game, 5.0, false).size(), 0, "1100 particles: nothing is returned")
	assert_eq(game.rng.draws - draws, 0, "1100 particles: no number, no draws")
	game.particles.clear()
	# a number above an enemy draws vx from (-2.5, 2.5): the stream shows which range was used
	var other: GameState = _new_game()
	PlayerDamage.show_damage_number(other, 5.0, true)
	mirror.rand(-3.0, 3.0)
	mirror.rand(-2.5, 2.5)
	mirror.rand(0.0, 7.0)
	assert_eq(other.rng.random(), mirror.random(), "x jitter, vx in (-2.5, 2.5), vy")
	for amount: float in [0.04, 0.0, -1.0, NAN, INF]:
		draws = other.rng.draws
		PlayerDamage.show_damage_number(other, amount, false)
		assert_eq(other.rng.draws - draws, 0, "amount %s: no number" % amount)
	# the amount threshold is 0.04, exclusive: just above it a number is shown
	for amount: float in [0.0401, 0.045, 0.049]:
		draws = other.rng.draws
		PlayerDamage.show_damage_number(other, amount, false)
		assert_eq(other.rng.draws - draws, 3, "amount %s: a number" % amount)


func test_the_damage_number_returns_the_three_values_it_drew_in_the_order_of_the_original() -> void:
	# `x: x + side + rand(-3, 3)`, `vx: targetId != null ? rand(-2.5, 2.5) : rand(-5, 5)`, `vy: -31 - rand(0, 7)`, in the order of the literal
	for has_target: bool in [false, true]:
		var game: GameState = _new_game(21)
		var mirror: GameRng = GameRng.new(21)
		mirror.random()
		var shown: PackedFloat64Array = PlayerDamage.show_damage_number(game, 5.0, has_target)
		var jitter_x: float = mirror.rand(-3.0, 3.0)
		var vx: float = mirror.rand(-2.5, 2.5) if has_target else mirror.rand(-5.0, 5.0)
		var vy: float = -31.0 - mirror.rand(0.0, 7.0)
		assert_eq(shown.size(), 3, "three values")
		assert_eq(SimTrace.hex_of(shown[0]), SimTrace.hex_of(jitter_x), "target %s: the x jitter is the first draw" % has_target)
		assert_eq(SimTrace.hex_of(shown[1]), SimTrace.hex_of(vx), "target %s: vx is the second draw" % has_target)
		assert_eq(SimTrace.hex_of(shown[2]), SimTrace.hex_of(vy), "target %s: vy is -31 minus the third draw" % has_target)
		assert_true(absf(shown[0]) <= 3.0 and absf(shown[1]) <= (2.5 if has_target else 5.0) and shown[2] <= -31.0 and shown[2] >= -38.0, "the ranges")
	# a hit that costs hp but less than 0.04 shows nothing
	var quiet: GameState = _new_game()
	assert_eq(PlayerDamage.show_damage_number(quiet, 0.04, false).size(), 0, "0.04 is not above 0.04")


# --- the update ---------------------------------------------------------------------------------------------------------------

func test_timers_tick_and_the_dot_number_timer_restarts_at_exactly_0_34() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	game.player.x = 9000.0
	game.player.y = 9000.0
	var e: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	e.tactic_cd = 1.0
	e.tactic_pulse = 0.5
	e.flash = 1.0
	e.telegraph = 0.3
	e.attack_anim = 0.2
	e.ability_cd = 2.0
	e.think_cd = 0.05
	e.dot_number_timer = 0.2
	system.run(DT)
	assert_eq(e.tactic_cd, 1.0 - DT, "tacticCd - dt")
	assert_eq(e.tactic_pulse, 0.5 - DT * 2.4, "tacticPulse - dt * 2.4")
	assert_eq(e.flash, 1.0 - DT * 5.0, "flash - dt * 5")
	assert_eq(e.telegraph, 0.3 - DT, "telegraph - dt")
	assert_eq(e.attack_anim, 0.2 - DT, "attackAnim - dt")
	assert_eq(e.ability_cd, 2.0 - DT, "abilityCd - dt")
	assert_eq(e.think_cd, 0.05 - DT, "thinkCd - dt")
	assert_eq(e.dot_number_timer, 0.2 - DT, "dotNumberTimer - dt")
	# the timers stop at 0 (max(0, ...)), except dotNumberTimer, which restarts at 0.34 when it is no longer above 0
	e.think_cd = 0.001
	e.ability_cd = 0.0
	e.dot_number_timer = DT   # DT - DT = 0 is not > 0
	system.run(DT)
	assert_eq(e.think_cd, 0.0, "thinkCd stays at 0")
	assert_eq(e.ability_cd, 0.0, "abilityCd stays at 0")
	assert_eq(e.dot_number_timer, 0.34, "dotNumberTimer restarts at exactly 0.34 (not carried over)")
	e.dot_number_timer = 0.001
	system.run(DT)
	assert_eq(e.dot_number_timer, 0.34, "also when it went below 0")


func test_the_swarm_moves_toward_the_player_and_circles_it_without_drawing() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 5000.0
	p.y = 5000.0
	var e: EnemyState = _spawn(game, "swarm", 1, 5000.0, 5400.0)
	game.enemy_ai_skill = 0.0
	var before: float = JsMath.hypot(e.x - p.x, e.y - p.y)
	var draws: int = game.rng.draws
	for i: int in range(120):
		game.t += DT
		system.run(DT)
	var after: float = JsMath.hypot(e.x - p.x, e.y - p.y)
	assert_true(after < before - 50.0, "the swarm closed in (%s -> %s)" % [before, after])
	assert_eq(game.rng.draws, draws, "an enemy that moves draws nothing on normal difficulty")
	assert_eq(e.ai_state, "idle", "a swarm stays idle")
	assert_true(JsMath.hypot(e.vx, e.vy) <= e.speed, "never faster than its speed")
	assert_eq(game.projectile_avoidance_epoch, 120, "the avoidance epoch counts the updates")


func test_the_enemies_are_visited_from_the_end_of_the_list() -> void:
	# two swarms on the player at the same moment: the one at the HIGHER index is processed first and hits; the player's cooldown (0.38 s) then
	# stops the other
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 5000.0
	p.y = 5000.0
	game.t = 10.0
	var first: EnemyState = _spawn(game, "swarm", 1, 5000.0, 5015.0)
	var second: EnemyState = _spawn(game, "swarm", 2, 5000.0, 5014.0)
	system.run(DT)
	assert_eq(p.last_hit, 10.0, "the player was hit")
	assert_true(second.attack_anim > 0.0, "the enemy at the end of the list hit first")
	assert_eq(first.attack_anim, 0.0, "the other found the player on cooldown")


func test_a_contact_hit_hurts_pushes_and_draws_and_the_cooldown_allows_one_hit_per_0_38_seconds() -> void:
	var game: GameState = _new_game(5)
	var mirror: GameRng = GameRng.new(5)
	mirror.random()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 5000.0
	p.y = 5000.0
	p.hp = 100.0
	game.t = 10.0
	var e: EnemyState = _spawn(game, "swarm", 1, 5000.0, 5020.0)   # touching: 13 + 10 = 23 > 20
	var draws: int = game.rng.draws
	system.run(DT)
	assert_eq(p.last_hit, 10.0, "lastHit = game.t")
	assert_eq(p.hp, 100.0 - e.damage, "hp - the enemy's damage")
	assert_eq(game.damage_flash, 0.34, "damage flash")
	assert_eq(game.rng.draws - draws, 3, "three draws for the number")
	assert_eq(e.attack_anim, 0.24, "triggerEnemyAttack(0.24)")
	assert_eq(e.attack_anim_max, 0.24, "attackAnimMax")
	# the player is pushed 22 px away from the enemy's end position (the enemy is below: pushed up)
	var ndx: float = 5000.0 - e.x
	var ndy: float = 5000.0 - e.y
	var nd: float = JsMath.hypot(ndx, ndy)
	assert_eq(p.x, JsMath.clamp(5000.0 + ndx / nd * 22.0, 18.0, 26000.0 - 18.0), "pushed in x")
	assert_eq(p.y, JsMath.clamp(5000.0 + ndy / nd * 22.0, 18.0, 26000.0 - 18.0), "pushed in y")
	assert_almost_eq(JsMath.hypot(p.x - 5000.0, p.y - 5000.0), 22.0, 1e-9, "22 px")
	assert_eq(e.facing, JsMath.atan2(5000.0 - e.y, 5000.0 - e.x), "the enemy faces the player's position BEFORE the push")
	# the cooldown: `game.t - p.lastHit > 0.38`, strictly
	p.last_hit = 0.0
	var hp: float = p.hp
	for case: Array in [[0.38, false], [0.38 + 1.0e-16, true], [0.5, true], [0.375, false]]:
		p.x = 5000.0
		p.y = 5000.0
		e.x = 5000.0
		e.y = 5020.0
		p.last_hit = 0.0
		p.hp = hp
		game.t = float(case[0])
		system.run(DT)
		assert_eq(p.hp < hp, bool(case[1]), "t - lastHit = %s: %s" % [case[0], "hit" if bool(case[1]) else "no hit"])


func test_the_push_stops_at_the_map_edge_and_a_dead_player_is_still_pushed() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 25.0
	p.y = 5000.0
	game.t = 10.0
	_spawn(game, "swarm", 1, 40.0, 5000.0)   # to the right of the player: pushes it left, toward the edge
	system.run(DT)
	assert_eq(p.x, 18.0, "clamped to 18 px from the edge")
	# a player without hp: no damage, no flash, no draws - but lastHit is set and the push happens
	var other: GameState = _new_game()
	var other_system: EnemyUpdateSystem = EnemyUpdateSystem.new(other)
	other.player.x = 5000.0
	other.player.y = 5000.0
	other.player.hp = 0.0
	other.t = 10.0
	var e: EnemyState = _spawn(other, "swarm", 1, 5000.0, 5020.0)
	var draws: int = other.rng.draws
	other_system.run(DT)
	assert_eq(other.player.last_hit, 10.0, "lastHit")
	assert_eq(other.damage_flash, 0.0, "no flash")
	assert_eq(other.rng.draws, draws, "no draws")
	assert_true(other.player.y < 5000.0, "pushed up, away from the enemy at %s" % e.y)


func test_an_enemy_that_cannot_act_does_not_hit_and_its_status_runs_down() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 5000.0
	p.y = 5000.0
	game.t = 10.0
	var e: EnemyState = _spawn(game, "swarm", 1, 5000.0, 5020.0)
	e.status.paralyze = 0.5
	system.run(DT)
	assert_eq(p.hp, p.max_hp, "paralyzed: no hit")
	assert_eq(p.last_hit, -99.0, "lastHit untouched")
	assert_eq(e.status.paralyze, 0.5 - DT, "paralyze ticks down")
	# paralyzed enemies move at 8 % of their speed
	var frozen: EnemyState = _spawn(game, "swarm", 2, 7000.0, 7000.0)
	var free: EnemyState = _spawn(game, "swarm", 3, 7000.0, 7000.0)
	frozen.status.paralyze = 5.0
	frozen.ai_seed = free.ai_seed
	system.run(DT)
	system.run(DT)
	assert_true(JsMath.hypot(frozen.vx, frozen.vy) < JsMath.hypot(free.vx, free.vy), "slower when paralyzed")


func test_an_enemy_without_hp_is_killed_in_the_loop_and_skipped() -> void:
	var game: GameState = _new_game(9)
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	game.player.x = 9000.0
	game.player.y = 9000.0
	var a: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	var b: EnemyState = _spawn(game, "swarm", 2, 2000.0, 2000.0)
	var c: EnemyState = _spawn(game, "swarm", 3, 3000.0, 3000.0)
	b.hp = 0.0
	var draws: int = game.rng.draws
	system.run(DT)
	assert_eq(game.kills, 1, "killEnemy counted it")
	assert_eq(game.rng.draws - draws, 2, "the experience orb of the kill: two draws")
	var ids: Array[int] = []
	for e: EnemyState in game.enemies:
		ids.append(e.id)
	assert_eq(ids, [1, 3] as Array[int], "swap-pop: enemy 3 (visited first) took the dead enemy's place")
	assert_true(a.x != 1000.0 or a.y != 1000.0, "a moved")
	assert_true(c.x != 3000.0 or c.y != 3000.0, "c moved (it was visited first and not again)")


func test_the_grid_is_rebuilt_at_the_start_of_the_update() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	game.player.x = 9000.0
	game.player.y = 9000.0
	var e: EnemyState = _spawn(game, "swarm", 1, 100.0, 100.0)
	assert_eq(game.enemy_grid.size(), 0, "no grid yet")
	system.run(DT)
	assert_eq(game.enemy_grid.size(), 1, "the update built it")
	assert_true(game.enemy_grid.bucket(game.enemy_grid.key_of(1, 1)).has(e), "with the enemy in the cell of its start position (100/96 = 1)")


# --- the assassin -----------------------------------------------------------------------------------------------------------

func test_the_assassin_winds_up_dashes_recovers_and_goes_back_to_idle() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 5000.0
	p.y = 5000.0
	game.enemy_ai_skill = 0.0
	var e: EnemyState = _spawn(game, "assassin", 1, 5000.0, 5300.0)   # 300 px away: in the 105-480 window
	e.ability_cd = 0.0
	# idle -> windup in the step the ability is ready: the telegraph is announced
	var expected_telegraph: float = EnemyAi.enemy_ai_telegraph(game, 0.42, 0.28, e)
	system.run(DT)
	assert_eq(e.ai_state, "windup", "the ability was ready")
	assert_eq(e.ai_timer, expected_telegraph, "aiTimer = enemyAiTelegraph(0.42, 0.28)")
	assert_eq(e.telegraph, expected_telegraph, "telegraph = aiTimer")
	# windup: aims at the predicted position, the timer runs; at <= 0 the dash starts (the telegraph is not clamped in that step)
	var x_before: float = e.x
	var y_before: float = e.y
	e.ai_timer = DT / 2.0
	system.run(DT)
	assert_eq(e.x, x_before, "the winding-up assassin does not move")
	assert_eq(e.y, y_before, "the winding-up assassin does not move")
	assert_eq(e.ai_state, "dash", "the timer ran out")
	assert_eq(e.ai_timer, 0.34, "dash lasts 0.34 s")
	assert_eq(e.telegraph, DT / 2.0 - DT, "telegraph = the timer after the decrement (negative: not clamped)")
	assert_eq(e.attack_anim, 0.34, "triggerEnemyAttack(0.34)")
	assert_eq(e.facing, JsMath.atan2(e.dash_y, e.dash_x), "facing along the dash")
	# the dash direction points at the player from where the assassin stood
	assert_true(e.dash_y < 0.0, "the dash points toward the player (up): %s, %s" % [e.dash_x, e.dash_y])
	assert_almost_eq(JsMath.hypot(e.dash_x, e.dash_y), 1.0, 1e-12, "a unit vector")
	# dash: velocity = dash * speed * 5.45, position += velocity * dt, timer -= dt
	var dash_x: float = e.dash_x
	var dash_y: float = e.dash_y
	x_before = e.x
	y_before = e.y
	system.run(DT)
	assert_eq(e.vx, dash_x * e.speed * 5.45, "vx = dashX * speed * 5.45")
	assert_eq(e.vy, dash_y * e.speed * 5.45, "vy = dashY * speed * 5.45")
	assert_eq(e.ai_timer, 0.34 - DT, "dash timer")
	assert_eq(e.ai_state, "dash", "still dashing")
	# the last dash step flips to recover with 0.68 s
	e.ai_timer = DT / 2.0
	system.run(DT)
	assert_eq(e.ai_state, "recover", "dash over")
	assert_eq(e.ai_timer, 0.68, "recover lasts 0.68 s")
	# recover: the timer runs, at <= 0 the assassin is idle again with (1.25 - skill * 0.16) * 1 * 1 seconds of cooldown
	e.ai_timer = DT / 2.0
	system.run(DT)
	assert_eq(e.ai_state, "idle", "recovered")
	assert_eq(e.ability_cd, 1.25 - 0.0 * 0.16, "abilityCd = (1.25 - skill * 0.16) * cooldown multiplier * wait multiplier")


func test_the_assassin_does_not_wind_up_out_of_the_window_or_while_the_ability_is_cooling_down() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 5000.0
	p.y = 5000.0
	game.enemy_ai_skill = 0.0
	var far: EnemyState = _spawn(game, "assassin", 1, 5000.0, 5600.0)    # 600 > 480
	var close: EnemyState = _spawn(game, "assassin", 2, 5000.0, 5090.0)  # 90 <= 105
	var cooling: EnemyState = _spawn(game, "assassin", 3, 5000.0, 5300.0)
	far.ability_cd = 0.0
	close.ability_cd = 0.0
	cooling.ability_cd = 3.0
	system.run(DT)
	assert_eq(far.ai_state, "idle", "too far")
	assert_eq(close.ai_state, "idle", "too close")
	assert_eq(cooling.ai_state, "idle", "cooling down")
	# the limits are exclusive: d < 480 and d > 105 (measured from the position at the START of the step)
	var edge: EnemyState = _spawn(game, "assassin", 4, 5000.0, 5000.0 + 480.0)
	edge.ability_cd = 0.0
	system.run(DT)
	assert_eq(edge.ai_state, "idle", "d = 480 is not < 480")


## One step of an idle assassin 300 px below a player that moves with (player_vx, 0), in a fresh game; the assassin is returned. With `by_hand`
## the step is not run by the system: the target of the idle branch is worked out here from the rule of the original and steerEnemy is
## called with it.
func _idle_assassin_step(player_vx: float, by_hand: bool, heading_from_velocity: bool) -> EnemyState:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 5000.0
	p.y = 5000.0
	p.vx = player_vx
	p.vy = 0.0
	game.enemy_ai_skill = 0.6
	var e: EnemyState = _spawn(game, "assassin", 1, 5000.0, 5300.0)
	e.strafe_dir = -1
	if not by_hand:
		system.run(DT)
		return e
	game.enemy_grid.rebuild(game.enemies)
	var steering: EnemySteering = EnemySteering.new(game)
	var skill: float = EnemyAi.enemy_ai_skill_of(game, e)
	var d: float = JsMath.hypot(p.x - e.x, p.y - e.y)
	var nx: float = (p.x - e.x) / d
	var ny: float = (p.y - e.y) / d
	var pm: float = JsMath.hypot(player_vx, 0.0)
	var mx: float = nx
	var my: float = ny
	if heading_from_velocity:
		mx = player_vx / pm
		my = 0.0 / pm
	steering.predict_player_position(e, 520.0, 0.28 + skill * 0.32)
	var side: float = float(e.strafe_dir)
	var tx: float = steering.pred_x + -my * side * (175.0 - skill * 30.0) - mx * (55.0 + skill * 24.0)
	var ty: float = steering.pred_y + mx * side * (175.0 - skill * 30.0) - my * (55.0 + skill * 24.0)
	steering.steer_enemy(e, tx, ty, e.speed * 0.94, DT, 0.72, 0.0, true, 1.55, 0.0)
	return e


func test_the_idle_assassin_circles_along_the_players_heading_only_above_8_px_per_second() -> void:
	# `const mx = pm > 8 ? pvx / pm : nx`: the heading of the player counts while its speed is MORE than 8 px/s, else the assassin uses the
	# direction to the player. The three speeds straddle the threshold.
	for speed_case: Array in [[7.9, false], [8.0, false], [8.1, true]]:
		var player_vx: float = speed_case[0]
		var uses_heading: bool = speed_case[1]
		var actual: EnemyState = _idle_assassin_step(player_vx, false, false)
		var expected: EnemyState = _idle_assassin_step(player_vx, true, uses_heading)
		var other: EnemyState = _idle_assassin_step(player_vx, true, not uses_heading)
		assert_eq(SimTrace.hex_of(actual.vx), SimTrace.hex_of(expected.vx), "player speed %s: vx from the rule" % player_vx)
		assert_eq(SimTrace.hex_of(actual.vy), SimTrace.hex_of(expected.vy), "player speed %s: vy from the rule" % player_vx)
		assert_eq(SimTrace.hex_of(actual.x), SimTrace.hex_of(expected.x), "player speed %s: x from the rule" % player_vx)
		assert_eq(SimTrace.hex_of(actual.y), SimTrace.hex_of(expected.y), "player speed %s: y from the rule" % player_vx)
		assert_true(actual.vx != other.vx or actual.vy != other.vy, "player speed %s: the test can tell the two headings apart" % player_vx)


func test_an_assassin_that_cannot_act_gives_up_a_dash_or_windup() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	game.player.x = 5000.0
	game.player.y = 5000.0
	var e: EnemyState = _spawn(game, "assassin", 1, 5000.0, 5300.0)
	e.ai_state = "dash"
	e.ai_timer = 0.2
	e.telegraph = 0.1
	e.ability_cd = 0.1
	e.status.paralyze = 1.0
	system.run(DT)
	assert_eq(e.ai_state, "idle", "back to idle")
	assert_eq(e.ai_timer, 0.0, "aiTimer 0")
	assert_eq(e.telegraph, 0.0, "telegraph 0")
	assert_eq(e.ability_cd, 0.8 * e.ability_cooldown_mul, "abilityCd = max(abilityCd, 0.8 * cooldown multiplier)")


## One update of an assassin and a swarm that both have a projectile coming at them (when `with_projectile`); returns [assassin, swarm].
func _dodge_run(with_projectile: bool) -> Array[EnemyState]:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	game.player.x = 5000.0
	game.player.y = 5000.0
	game.enemy_ai_skill = 0.0
	var assassin: EnemyState = _spawn(game, "assassin", 1, 5300.0, 5300.0)
	var swarm: EnemyState = _spawn(game, "swarm", 2, 5300.0, 6300.0)
	if with_projectile:
		for target: EnemyState in [assassin, swarm]:
			var pr: ProjectileState = ProjectileState.new()
			pr.x = target.x - 60.0
			pr.y = target.y
			pr.vx = 300.0
			pr.vy = 0.0
			game.projectiles.append(pr)
	system.run(DT)
	return [assassin, swarm] as Array[EnemyState]


func test_a_dodging_assassin_is_steered_away_from_a_projectile_and_a_swarm_is_not() -> void:
	var quiet: Array[EnemyState] = _dodge_run(false)
	var shot_at: Array[EnemyState] = _dodge_run(true)
	assert_true(quiet[0].vy != shot_at[0].vy or quiet[0].vx != shot_at[0].vx, "the assassin dodged: its velocity differs with a projectile in the way")
	assert_eq(quiet[1].vx, shot_at[1].vx, "the swarm does not dodge: the same vx")
	assert_eq(quiet[1].vy, shot_at[1].vy, "the swarm does not dodge: the same vy")


# --- the edges and thresholds that the reference traces never reach -----------------------------------------------------------
# The traces hold swarms and assassins far from the map edge, on the move, with at most three projectiles and no status effects. The rules
# below are in the original's code all the same; the expected values are worked out here from that code (the literal of each rule is written
# out in the test, so a changed constant in the sim cannot change the expectation with it).

func test_enemies_are_kept_12_px_inside_the_map_on_every_side() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var map_w: float = game.limits.map_w
	var map_h: float = game.limits.map_h
	game.player.x = map_w / 2.0
	game.player.y = map_h / 2.0
	var left: EnemyState = _spawn(game, "swarm", 1, -50.0, 9000.0)
	var right: EnemyState = _spawn(game, "swarm", 2, map_w + 50.0, 15000.0)
	var top: EnemyState = _spawn(game, "swarm", 3, 20000.0, -50.0)
	var bottom: EnemyState = _spawn(game, "swarm", 4, 6000.0, map_h + 50.0)
	system.run(DT)
	assert_eq(left.x, 12.0, "x clamped to 12")
	assert_eq(right.x, map_w - 12.0, "x clamped to the width - 12")
	assert_eq(top.y, 12.0, "y clamped to 12")
	assert_eq(bottom.y, map_h - 12.0, "y clamped to the height - 12")


func test_the_push_keeps_the_player_18_px_inside_the_map_on_every_side() -> void:
	var map_w: float = 26000.0
	var map_h: float = 26000.0
	# [player x, player y, enemy x, enemy y, expected player x, expected player y]: the enemy stands on the inner side, 15 px from the player
	var cases: Array = [
		[25.0, 5000.0, 40.0, 5000.0, 18.0, 5000.0],
		[map_w - 25.0, 5000.0, map_w - 40.0, 5000.0, map_w - 18.0, 5000.0],
		[5000.0, 25.0, 5000.0, 40.0, 5000.0, 18.0],
		[5000.0, map_h - 25.0, 5000.0, map_h - 40.0, 5000.0, map_h - 18.0],
	]
	for c: Array in cases:
		var game: GameState = _new_game()
		var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
		game.t = 10.0
		game.player.x = float(c[0])
		game.player.y = float(c[1])
		_spawn(game, "swarm", 1, float(c[2]), float(c[3]))
		system.run(DT)
		assert_eq(game.player.last_hit, 10.0, "case %s: the enemy hit" % [c])
		assert_eq(game.player.x if c[4] != c[0] else game.player.y, float(c[4]) if c[4] != c[0] else float(c[5]), "case %s: the pushed coordinate is clamped" % [c])


func test_the_speed_factors_apply_in_the_order_of_the_original() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var e: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	e.speed = 100.0
	assert_eq(system._enemy_speed(e), 100.0, "no status: speed * 1")
	e.status.root = 1.0
	assert_eq(system._enemy_speed(e), 100.0 * 0.3, "root x0.3")
	e.status.root = 0.0
	e.status.slow = 1.0
	assert_eq(system._enemy_speed(e), 100.0 * 0.52, "slow x0.52")
	e.status.slow = 0.0
	e.status.wet = 1.0
	assert_eq(system._enemy_speed(e), 100.0 * 0.9, "wet x0.9")
	e.status.wet = 0.0
	e.status.paralyze = 1.0
	assert_eq(system._enemy_speed(e), 100.0 * 0.08, "paralyze x0.08")
	e.status.paralyze = 0.0
	e.status.support_buff = 1.0
	assert_eq(system._enemy_speed(e), 100.0 * 1.18, "support buff x1.18")
	e.status.root = 1.0
	e.status.slow = 1.0
	e.status.wet = 1.0
	e.status.paralyze = 1.0
	assert_eq(system._enemy_speed(e), 100.0 * 0.3 * 0.52 * 0.9 * 0.08 * 1.18, "all of them, multiplied one after the other")
	e.status.airborne = 1.0
	assert_eq(system._enemy_speed(e), 0.0, "airborne stops the enemy (then the buff multiplies 0)")
	e.status = EnemyStatus.new()
	e.special_motion_lock = true
	assert_eq(system._enemy_speed(e), 0.0, "a motion lock stops the enemy")
	e.special_motion_lock = false
	e.strata = 3.0
	e.status.airborne = 1.0
	assert_eq(system._enemy_speed(e), 100.0 * (1.0 - 3.0 * 0.05), "strata: x(1 - strata * 0.05) ...")
	assert_eq(e.status.airborne, 0.0, "... and it lands the enemy")
	e.strata = 20.0
	assert_eq(system._enemy_speed(e), 100.0 * 0.2, "the strata factor is at least 0.2")


func test_a_berserk_enemy_at_half_hp_or_less_moves_and_hits_1_3_times_harder() -> void:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var e: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	e.max_hp = 100.0
	e.hp = 50.0
	assert_eq(system._special_enemy_speed_mul(e), 1.0, "no berserk ability: 1")
	assert_eq(system._special_enemy_damage_mul(e), 1.0, "no berserk ability: 1")
	e.special_abilities = PackedStringArray(["berserk"])
	assert_eq(system._special_enemy_speed_mul(e), 1.3, "hp / maxHp = 0.5 is 'at most half'")
	assert_eq(system._special_enemy_damage_mul(e), 1.3, "likewise for the damage")
	e.hp = 50.5
	assert_eq(system._special_enemy_speed_mul(e), 1.0, "0.505 is more than half")
	assert_eq(system._special_enemy_damage_mul(e), 1.0, "0.505 is more than half")
	e.hp = 20.0
	e.speed = 100.0
	assert_eq(system._enemy_speed(e), 100.0 * 1.3, "the speed factor is part of the speed")


func test_a_buffed_enemys_contact_hit_is_18_percent_stronger() -> void:
	var game: GameState = _new_game(5)
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var p: PlayerState = game.player
	p.x = 5000.0
	p.y = 5000.0
	p.hp = 100.0
	game.t = 10.0
	var e: EnemyState = _spawn(game, "swarm", 1, 5000.0, 5020.0)
	e.status.support_buff = 1.0
	system.run(DT)
	var expected_loss: float = PlayerDamage.calculate_incoming_player_damage(game, e.damage, 1.18 * 1.0)
	assert_true(expected_loss > e.damage, "the buff raises the damage")
	assert_eq(p.hp, 100.0 - expected_loss, "hp lost: damage * 1.18")


func _swarm_step(player_x: float, player_y: float, player_vx: float, player_vy: float, by_hand: bool) -> EnemyState:
	var game: GameState = _new_game()
	var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
	var map_w: float = game.limits.map_w
	var map_h: float = game.limits.map_h
	var p: PlayerState = game.player
	p.x = player_x
	p.y = player_y
	p.vx = player_vx
	p.vy = player_vy
	game.enemy_ai_skill = 0.8
	game.t = 3.7
	# the enemy stands 60 / 50 px from the player on the inner side of the map (it is kept 12 px inside, which the by-hand step does not do)
	var e: EnemyState = _spawn(game, "swarm", 6, player_x + (60.0 if player_x < 13000.0 else -60.0), player_y + (50.0 if player_y < 13000.0 else -50.0))
	e.strafe_dir = -1
	e.ai_seed = 2.0
	if not by_hand:
		system.run(DT)
		return e
	game.enemy_grid.rebuild(game.enemies)
	var steering: EnemySteering = EnemySteering.new(game)
	var skill: float = EnemyAi.enemy_ai_skill_of(game, e)
	var a: float = e.ai_seed + game.t * (0.16 + skill * 0.12) * float(e.strafe_dir)
	var ring: float = 42.0 - skill * 10.0 + float(e.id % 4 * 8)
	var lead: float = skill * 0.34
	var cx: float = JsMath.clamp(p.x + p.vx * lead, 18.0, map_w - 18.0)
	var cy: float = JsMath.clamp(p.y + p.vy * lead, 18.0, map_h - 18.0)
	var pinch: float = skill * JsMath.js_max(0.0, JsMath.sin(game.t * 0.9 + e.ai_seed)) * 12.0
	var tx: float = cx + JsMath.cos(a) * (ring - pinch)
	var ty: float = cy + JsMath.sin(a) * (ring - pinch)
	steering.steer_enemy(e, tx, ty, e.speed, DT, 0.62, 36.0, false, 1.05, 0.08 + skill * 0.05)
	return e


func test_the_swarm_aims_at_a_point_kept_18_px_inside_the_map() -> void:
	# a player at the edge that is running outward: the point the swarm circles is where the player is going, kept on the map
	var cases: Array = [
		[30.0, 9000.0, -1000.0, 0.0], [25970.0, 9000.0, 1000.0, 0.0], [9000.0, 30.0, 0.0, -1000.0], [9000.0, 25970.0, 0.0, 1000.0],
	]
	for c: Array in cases:
		var actual: EnemyState = _swarm_step(float(c[0]), float(c[1]), float(c[2]), float(c[3]), false)
		var expected: EnemyState = _swarm_step(float(c[0]), float(c[1]), float(c[2]), float(c[3]), true)
		for field_name: String in ["x", "y", "vx", "vy", "facing"]:
			assert_eq(SimTrace.hex_of(float(actual.get(field_name))), SimTrace.hex_of(float(expected.get(field_name))), "case %s: %s" % [c, field_name])


func test_the_prediction_is_limited_to_72_px_of_acceleration_and_kept_on_the_map() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var map_w: float = game.limits.map_w
	var map_h: float = game.limits.map_h
	var p: PlayerState = game.player
	var e: EnemyState = _spawn(game, "assassin", 1, 1000.0, 1600.0)
	game.enemy_ai_skill = 0.8
	p.x = 1000.0
	p.y = 1000.0
	p.vx = 0.0
	p.vy = 0.0
	p.ax = 1.0e6
	p.ay = -1.0e6
	steering.predict_player_position(e, 650.0, 0.34)
	assert_eq(steering.pred_x, 1000.0 + 72.0, "the acceleration offset is at most +72")
	assert_eq(steering.pred_y, 1000.0 - 72.0, "and at least -72")
	p.ax = -1.0e6
	p.ay = 1.0e6
	steering.predict_player_position(e, 650.0, 0.34)
	assert_eq(steering.pred_x, 1000.0 - 72.0, "-72 in x")
	assert_eq(steering.pred_y, 1000.0 + 72.0, "+72 in y")
	p.ax = 0.0
	p.ay = 0.0
	for case: Array in [[20.0, 9000.0, -1000.0, 0.0, 18.0, 9000.0], [map_w - 20.0, 9000.0, 1000.0, 0.0, map_w - 18.0, 9000.0],
			[9000.0, 20.0, 0.0, -1000.0, 9000.0, 18.0], [9000.0, map_h - 20.0, 0.0, 1000.0, 9000.0, map_h - 18.0]]:
		p.x = float(case[0])
		p.y = float(case[1])
		p.vx = float(case[2])
		p.vy = float(case[3])
		e.x = p.x
		e.y = p.y + 600.0
		steering.predict_player_position(e, 650.0, 0.34)
		assert_eq(steering.pred_x, float(case[4]), "case %s: x kept 18 px inside" % [case])
		assert_eq(steering.pred_y, float(case[5]), "case %s: y kept 18 px inside" % [case])
	# the projectile speed counts as at least 60 in the travel time: a slow shot is not 'arriving' later than that
	game.enemy_ai_skill = 0.0
	p.x = 5000.0
	p.y = 5000.0
	p.vx = 100.0
	p.vy = 0.0
	e.x = 5000.0
	e.y = 5030.0
	steering.predict_player_position(e, 1.0, 0.85)
	var lead: float = JsMath.js_min(0.85 * (1.0 + 0.0 * 0.28), (30.0 / 60.0) * (0.92 + 0.0 * 0.18))
	assert_eq(steering.pred_x, 5000.0 + 100.0 * lead + 0.0, "travel = distance / max(60, projectile speed)")


func test_the_small_thresholds_of_steering() -> void:
	# 1) a target 1.5e-3 px away is a target (the cut-off is 1e-3): the enemy is steered toward it at distance / dt
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var e: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	e.facing = 0.0
	steering.steer_enemy(e, 1000.0015, 1000.0, 100.0, DT, 0.62, 36.0, false, 1.05, 0.0)
	var td: float = 1000.0015 - 1000.0
	var arrival: float = td / DT
	var blend: float = 1.0 - JsMath.exp(-12.5 * DT)
	assert_eq(e.vx, 0.0 + (1.0 * arrival - 0.0) * blend, "target distance 1.5e-3 > 1e-3: steered at distance / dt")
	var vertical: EnemyState = _spawn(game, "swarm", 7, 3000.0, 3000.0)
	vertical.facing = 0.0
	steering.steer_enemy(vertical, 3000.0, 3000.0015, 100.0, DT, 0.62, 36.0, false, 1.05, 0.0)
	assert_eq(vertical.vy, 0.0 + (1.0 * ((3000.0015 - 3000.0) / DT) - 0.0) * blend, "the same for the vertical component")
	# 2) a desired direction of length 1.5e-3 is a direction (the cut-off is 1e-3): no target (distance 0), one neighbour 35.9129 px to the
	# right pushes with weight 1 - d / 36 = 0.0024 (times 0.62)
	var game2: GameState = _new_game()
	var steering2: EnemySteering = EnemySteering.new(game2)
	var e2: EnemyState = _spawn(game2, "swarm", 1, 1000.0, 1000.0)
	_spawn(game2, "swarm", 2, 1000.0 + 35.9129, 1000.0)
	game2.enemy_grid.rebuild(game2.enemies)
	steering2.steer_enemy(e2, 1000.0, 1000.0, 60.0, DT, 0.62, 36.0, false, 1.05, 0.0)
	assert_true(absf(steering2.sep_x * 0.62) > 1.0e-3 and absf(steering2.sep_x * 0.62) < 2.0e-3, "the push is between 1e-3 and 2e-3 (%s)" % (steering2.sep_x * 0.62))
	assert_true(e2.vx < -1.0, "a desired direction above 1e-3 steers the enemy at full speed (vx %s)" % e2.vx)
	# 3) a steering speed of 0.0015 turns the enemy gradually, 0.0005 (<= 1e-3) points it at once
	for case: Array in [[0.0005, true], [0.0015, false]]:
		var game3: GameState = _new_game()
		var steering3: EnemySteering = EnemySteering.new(game3)
		var e3: EnemyState = _spawn(game3, "swarm", 1, 1000.0, 1000.0)
		e3.facing = 3.0
		steering3.steer_enemy(e3, 1100.0, 1000.0, float(case[0]), DT, 0.62, 36.0, false, 1.05, 0.0)
		assert_eq(e3.facing == 0.0, bool(case[1]), "speed %s: %s" % [case[0], "facing = the desired angle" if bool(case[1]) else "facing turns by a share of the way"])


func test_separation_counts_neighbours_from_0_1_px_and_uses_the_body_radius_for_big_enemies() -> void:
	# a neighbour 0.12 px away (d2 = 0.0144 > 0.01) counts - in the grid scan and in the whole-list scan
	for use_grid: bool in [true, false]:
		var game: GameState = _new_game()
		var steering: EnemySteering = EnemySteering.new(game)
		var a: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
		var o: EnemyState = _spawn(game, "swarm", 2, 999.88, 1000.0)
		if use_grid:
			game.enemy_grid.rebuild(game.enemies)
		steering.enemy_separation_vector(a, 36.0)
		var dx: float = a.x - o.x
		var d2: float = dx * dx + 0.0 * 0.0
		var d: float = sqrt(d2)
		assert_eq(steering.sep_x, dx / d * (1.0 - d / 36.0), "grid %s: the very close neighbour pushes" % use_grid)
	# a big enemy (r 20) separates within max(34, r * 2.5) = 50 px: a neighbour at 51 does not count, one at 49 does
	for case: Array in [[51.0, false], [49.0, true]]:
		var game2: GameState = _new_game()
		var steering2: EnemySteering = EnemySteering.new(game2)
		var big: EnemyState = _spawn(game2, "swarm", 1, 1000.0, 1000.0)
		big.r = 20.0
		_spawn(game2, "swarm", 2, 1000.0 + float(case[0]), 1000.0)
		game2.enemy_grid.rebuild(game2.enemies)
		steering2.steer_enemy(big, 1000.0, 1000.0, 50.0, DT, 0.62, 0.0, false, 1.05, 0.0)
		assert_eq(steering2.sep_x != 0.0, bool(case[1]), "neighbour at %s px of an enemy with r 20" % case[0])


func _steer_with_separation_weight(kind: String, weight: float) -> EnemyState:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var e: EnemyState = _spawn(game, kind, 1, 1000.0, 1000.0)
	_spawn(game, "swarm", 2, 1020.0, 1005.0)
	game.enemy_grid.rebuild(game.enemies)
	steering.steer_enemy(e, 1500.0, 1000.0, 100.0, DT, weight, 36.0, false, 1.05, 0.0)
	return e


func test_an_absent_separation_weight_is_0_52_for_a_swarm_and_0_72_for_the_rest() -> void:
	# `separation ?? (e.kind === "swarm" ? 0.52 : 0.72)`; the callers of M1 always pass a weight, so this is checked against the explicit weights
	for case: Array in [["swarm", 0.52], ["assassin", 0.72]]:
		var from_default: EnemyState = _steer_with_separation_weight(String(case[0]), NAN)
		var explicit: EnemyState = _steer_with_separation_weight(String(case[0]), float(case[1]))
		assert_eq(SimTrace.hex_of(from_default.vx), SimTrace.hex_of(explicit.vx), "%s: vx" % case[0])
		assert_eq(SimTrace.hex_of(from_default.vy), SimTrace.hex_of(explicit.vy), "%s: vy" % case[0])
	var other_weight: EnemyState = _steer_with_separation_weight("swarm", 0.72)
	var default_swarm: EnemyState = _steer_with_separation_weight("swarm", NAN)
	assert_true(other_weight.vy != default_swarm.vy, "the test can tell the two weights apart")


func test_an_enemy_faster_than_its_limit_by_more_than_6_brakes_with_the_stronger_blend() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var e: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	# limit 93.95: the speed 100 is 6.05 above it -> braking (rate 18); limit 94.05: 5.95 above -> acceleration (rate 12.5)
	for case: Array in [[93.95, 18.0], [94.05, 12.5]]:
		e.vx = 100.0
		e.vy = 0.0
		steering.smooth_enemy_velocity(e, 0.0, 0.0, float(case[0]), DT)
		var blend: float = 1.0 - JsMath.exp(-float(case[1]) * DT)
		assert_eq(e.vx, 100.0 + (0.0 - 100.0) * blend, "limit %s: rate %s" % [case[0], case[1]])


func test_avoidance_counts_up_to_8_projectiles_at_the_highest_skill_below_the_cap() -> void:
	var game: GameState = _new_game()
	var steering: EnemySteering = EnemySteering.new(game)
	var e: EnemyState = _spawn(game, "assassin", 1, 1000.0, 1000.0)
	game.enemy_ai_skill = 1.31   # the enemy's skill: 0.9825; floor(0.9825 * 4) = 3 -> 5 + 3 = 8 checks (floor(0.9825 * 4.1) would be 4)
	for i: int in range(12):
		var pr: ProjectileState = ProjectileState.new()
		pr.x = 940.0
		pr.y = 1000.0
		pr.vx = 300.0
		game.projectiles.append(pr)
	steering.enemy_projectile_avoidance(e, 120.0)
	var radius: float = 120.0 * (1.0 + 0.9825 * 0.22)
	var w: float = 1.0 - 60.0 / radius
	assert_eq(steering.avoid_y, w + w + w + w + w + w + w + w, "eight hits: 5 + floor(0.9825 * 4)")


func test_segment_circle_hit_treats_only_segments_up_to_1e_minus_3_long_as_points() -> void:
	# a segment 1.2e-3 long (len2 = 1.44e-6 > 1e-6) is a segment: its far end is within reach of the circle although its start is not
	assert_true(SimUtil.segment_circle_hit(0.0, 0.0, 0.0012, 0.0, 5.0006, 0.0, 5.0), "1.2e-3: a segment, the end is inside by 0.0006")
	# a point (len2 <= 1e-6) is judged at its start
	assert_false(SimUtil.segment_circle_hit(0.0, 0.0, 0.0009, 0.0, 5.0006, 0.0, 5.0), "0.9e-3: a point, outside by 0.0006")


func test_the_ai_skill_is_capped_at_0_995_and_the_attack_range_grows_with_the_difficulty() -> void:
	var game: GameState = _new_game()
	var e: EnemyState = _spawn(game, "swarm", 1, 1000.0, 1000.0)
	game.enemy_ai_skill = 2.0
	assert_eq(EnemyAi.enemy_ai_skill_of(game, e), 0.995, "2.0 * 0.75 = 1.5 is capped at 0.995")
	game.difficulty = "hard"
	assert_eq(EnemyAi.difficulty_attack_range_mul(game), 1.0 + (1.3 - 1.0) * 0.12, "1 + (aggression - 1) * 0.12 with the aggression of hard (1.3)")
	assert_eq(EnemyAi.difficulty_wait_mul(game), 1.0 / (0.82 + 1.3 * 0.18), "1 / (0.82 + aggression * 0.18)")


func _assassin_at(game: GameState, distance: float, id: int) -> EnemyState:
	var e: EnemyState = _spawn(game, "assassin", id, 5000.0, 5000.0 + distance)
	e.ability_cd = 0.0
	return e


func test_the_assassins_attack_window_grows_with_the_skill_and_starts_beyond_105_px() -> void:
	# window: 105 < d < (480 + skill * 70) * attackRangeMul (skill = 0.75 * the wave's 1.0 here: 532.5)
	for case: Array in [[532.47, "windup"], [532.53, "idle"], [105.05, "windup"], [104.95, "idle"]]:
		var game: GameState = _new_game()
		var system: EnemyUpdateSystem = EnemyUpdateSystem.new(game)
		game.player.x = 5000.0
		game.player.y = 5000.0
		game.enemy_ai_skill = 1.0
		var e: EnemyState = _assassin_at(game, float(case[0]), 1)
		system.run(DT)
		assert_eq(e.ai_state, String(case[1]), "distance %s" % case[0])
	# the announcement lasts max(0.28, 0.42 * (1 - skill * 0.34)) * 1.16; at the top skill the minimum 0.28 wins
	var game2: GameState = _new_game()
	var system2: EnemyUpdateSystem = EnemyUpdateSystem.new(game2)
	game2.player.x = 5000.0
	game2.player.y = 5000.0
	game2.enemy_ai_skill = 2.0
	var top: EnemyState = _assassin_at(game2, 300.0, 1)
	system2.run(DT)
	assert_eq(top.ai_state, "windup", "wound up")
	assert_eq(top.ai_timer, 0.28 * 1.16, "at skill 0.995 the telegraph is 0.28 * 1.16")
