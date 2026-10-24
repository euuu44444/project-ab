extends "res://tests/test_case.gd"
## The slots of step S5 (area 1) as slots: what each does to the game state, apart from the golden comparisons of test_enemy_golden.gd and
## the reference traces of test_reference_trace.gd. Small hand-made situations whose answer is clear from the original's code.


func _new_game(rng_seed: int = 7) -> GameState:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = rng_seed
	var sim: Sim = Sim.new()
	assert_true(sim.new_game(config), "new_game")
	return sim.game


func _enemy(id: int, x: float, y: float, hp: float = 10.0, kind: String = "swarm") -> EnemyState:
	var e: EnemyState = EnemyState.new()
	e.id = id
	e.x = x
	e.y = y
	e.hp = hp
	e.kind = kind
	e.xp = 8.0
	e.spawn_wave = 1
	return e


func test_index_enemy_by_id_is_a_snapshot_taken_in_its_slot() -> void:
	var game: GameState = _new_game()
	var index: EnemyIndexSystem = EnemyIndexSystem.new(game)
	game.enemies.append(_enemy(4, 100.0, 100.0))
	game.enemies.append(_enemy(9, 200.0, 100.0))
	index.run(0.0)
	assert_eq(game.enemy_by_id.size(), 2, "both enemies are indexed")
	assert_true(game.enemy_by_id[4] == game.enemies[0] and game.enemy_by_id[9] == game.enemies[1], "by id")
	# an enemy that dies (here: leaves the list) after the rebuild stays in the map until the next rebuild; a new one is not in it
	var gone: EnemyState = game.enemies[0]
	game.enemies.remove_at(0)
	game.enemies.append(_enemy(12, 300.0, 100.0))
	assert_true(game.enemy_by_id.get(4) == gone, "a removed enemy is still in the snapshot")
	assert_false(game.enemy_by_id.has(12), "a new enemy is not in it")
	index.run(0.0)
	assert_false(game.enemy_by_id.has(4), "the next rebuild drops the removed enemy")
	assert_true(game.enemy_by_id.has(12), "and takes the new one")
	assert_eq(game.enemy_by_id.size(), 2, "two enemies")


func test_the_grid_slot_buckets_living_enemies_in_list_order_and_keeps_the_snapshot_until_the_next_rebuild() -> void:
	var game: GameState = _new_game()
	var slot: EnemySeparationGridSystem = EnemySeparationGridSystem.new(game)
	# 96 px cells; (cx, cy) = (floor(x / 96), floor(y / 96)); key = (cy + 2) * 275 + (cx + 2)
	game.enemies.append(_enemy(1, 10.0, 10.0))     # cell (0, 0)
	game.enemies.append(_enemy(2, 50.0, 90.0))     # cell (0, 0)
	game.enemies.append(_enemy(3, 100.0, 10.0))    # cell (1, 0)
	game.enemies.append(_enemy(4, 20.0, 20.0, 0.0))  # dead: not bucketed
	game.enemies.append(_enemy(5, 20.0, 200.0))    # cell (0, 2)
	slot.run(0.0)
	var grid: EnemyGrid = game.enemy_grid
	assert_eq(grid.size(), 3, "three non-empty buckets")
	var first: Array[EnemyState] = grid.bucket(grid.key_of(0, 0))
	assert_eq(first.size(), 2, "two enemies in cell (0, 0)")
	assert_eq(first[0].id, 1, "in list order")
	assert_eq(first[1].id, 2, "in list order")
	assert_eq(grid.bucket(grid.key_of(5, 5)).size(), 0, "an empty cell has an empty bucket")
	assert_eq(grid.key_of(0, 0), 2 * 275 + 2, "the key formula")
	# the enemy moves to another cell: the snapshot still has it in the old bucket until the next rebuild
	game.enemies[0].x = 500.0
	assert_eq(grid.bucket(grid.key_of(0, 0)).size(), 2, "stale bucket")
	assert_eq(grid.bucket(grid.key_of(0, 0))[0].x, 500.0, "with the live position")
	slot.run(0.0)
	assert_eq(grid.bucket(grid.key_of(0, 0)).size(), 1, "the rebuild moves it")
	assert_eq(grid.bucket(grid.key_of(5, 0)).size(), 1, "to cell (5, 0)")


func test_nearest_enemy_prefers_the_first_candidate_of_the_scan_on_a_tie() -> void:
	var game: GameState = _new_game()
	game.enemies.append(_enemy(1, 1000.0, 1000.0))
	game.enemies.append(_enemy(2, 1000.0, 1000.0))  # same place: a tie
	game.enemies.append(_enemy(3, 1500.0, 1000.0))
	game.enemy_grid.rebuild(game.enemies)
	var best: EnemyState = game.nearest_enemy(1000.0, 1000.0, 300.0)
	assert_true(best != null and best.id == 1, "the first of two equally close enemies wins (strict <)")
	assert_true(game.nearest_enemy(1000.0, 1000.0, 0.0) == null, "nothing is closer than a zero range")
	game.enemies[0].hp = 0.0
	assert_eq(game.nearest_enemy(1000.0, 1000.0, 300.0).id, 2, "a dead enemy is skipped at query time")
	assert_true(game.nearest_enemy(2000.0, 2000.0, 100.0) == null, "no enemy in range")


func test_cleanup_removes_dead_enemies_from_the_end_by_swap_pop_in_the_order_of_the_original() -> void:
	# the rule of TraceReader.next_enemy_order, which reproduces the reference lists, against the port's cleanup on many random lists
	var rng: GameRng = GameRng.new(99)
	for iteration: int in range(60):
		var game: GameState = _new_game()
		var count: int = 2 + rng.index(30)
		var before: Array[int] = []
		var removed: Array[int] = []
		for i: int in range(count):
			var dead: bool = rng.chance(0.3)
			game.enemies.append(_enemy(i + 1, 1000.0 + float(i), 1000.0, -1.0 if dead else 5.0))
			before.append(i + 1)
			if dead:
				removed.append(i + 1)
		var expected: Array[int] = TraceReader.next_enemy_order(before, [] as Array[int], removed)
		var version_before: int = game.enemies_version
		EnemyLifecycle.cleanup_dead_enemies(game)
		var got: Array[int] = []
		for e: EnemyState in game.enemies:
			got.append(e.id)
		assert_eq(got, expected, "round %d: the order after the cleanup" % iteration)
		assert_eq(game.kills, removed.size(), "round %d: kills" % iteration)
		assert_eq(game.enemies_version - version_before, removed.size(), "round %d: enemiesVersion grows by one per kill" % iteration)


func test_a_kill_draws_the_two_jitter_values_of_the_experience_orb_and_scores() -> void:
	var game: GameState = _new_game(31)
	var mirror: GameRng = GameRng.new(31)
	mirror.random()  # newGame's draw of the starting weapon
	var e: EnemyState = _enemy(1, 5000.0, 6000.0, 0.0, "swarm")
	e.spawn_wave = 3
	game.enemies.append(e)
	var before: int = game.rng.draws
	EnemyLifecycle.cleanup_dead_enemies(game)
	assert_eq(game.rng.draws - before, 2, "spawnXp draws x then y")
	var x: float = 5000.0 + mirror.rand(-12.0, 12.0)
	var y: float = 6000.0 + mirror.rand(-12.0, 12.0)
	assert_eq(game.xp_orbs.size(), 1, "one orb")
	assert_eq(game.xp_orbs[0].x, x, "orb x = enemy x + the first draw")
	assert_eq(game.xp_orbs[0].y, y, "orb y = enemy y + the second draw")
	assert_eq(game.xp_orbs[0].value, 8.0 * 1.1, "value xp * 1.1 (enemyXpDropMultiplier)")
	assert_eq(game.xp_orbs[0].r, 4.0, "radius 4")
	# floor((10 + floor(8 * 2)) * (1 + (3 - 1) * 0.02)) = floor(26 * 1.04)
	assert_eq(game.raw_score, floorf(26.0 * 1.04), "rawScore")
	assert_eq(game.kills, 1, "kills")
	assert_eq(game.enemies.size(), 0, "the enemy is gone")


func test_a_value_of_30_or_more_makes_three_orbs_and_100_or_more_eight() -> void:
	var game: GameState = _new_game(32)
	EnemyLifecycle.spawn_xp(game, 100.0, 100.0, 29.99)
	assert_eq(game.xp_orbs.size(), 1, "below 30: one orb")
	EnemyLifecycle.spawn_xp(game, 100.0, 100.0, 30.0)
	assert_eq(game.xp_orbs.size(), 1 + 3, "30: three orbs")
	assert_eq(game.xp_orbs[1].value, 10.0, "30 / 3")
	assert_eq(game.xp_orbs[1].r, 4.0, "radius 4")
	var draws: int = game.rng.draws
	EnemyLifecycle.spawn_xp(game, 100.0, 100.0, 100.0)
	assert_eq(game.xp_orbs.size(), 1 + 3 + 8, "100: eight orbs")
	assert_eq(game.xp_orbs[4].r, 6.0, "radius 6")
	assert_eq(game.rng.draws - draws, 16, "two draws per orb")


func test_the_squads_slot_does_nothing_on_normal_and_draws_nothing() -> void:
	var game: GameState = _new_game()
	var draws: int = game.rng.draws
	NightmareSquadsSystem.new(game).run(1.0 / 60.0)
	assert_eq(game.rng.draws, draws, "no draw")
	assert_true(NightmareSquadsSystem.new(game).is_implemented(), "and the slot is a real system")


func test_end_run_resets_the_squad_fields_of_every_enemy() -> void:
	var game: GameState = _new_game()
	var e: EnemyState = _enemy(1, 100.0, 100.0)
	e.squad_id = 4
	e.squad_role = "LEADER"
	e.squad_target_until = 5.0
	e.squad_attack_at = 6.0
	e.preferred_special = "x"
	game.enemies.append(e)
	EndRunSystem.end_run(game, true)
	assert_true(game.ended and game.run_won, "ended as a win")
	assert_eq(e.squad_id, 0, "squadId")
	assert_eq(e.squad_role, "INDIVIDUAL", "squadRole")
	assert_eq(e.squad_target_until, 0.0, "squadTargetUntil")
	assert_eq(e.squad_attack_at, 0.0, "squadAttackAt")
	assert_eq(e.preferred_special, "", "preferredSpecial")


func test_the_director_ticks_every_seven_steps_by_float_subtraction() -> void:
	# directorClock is SET to 0.1 after a tick and then loses 1/60 a step: 0.1 - 6/60 > 0 but 0.1 - 7/60 <= 0
	var game: GameState = _new_game()
	var system: WaveProgressSystem = WaveProgressSystem.new(game)
	var tick_steps: Array[int] = []
	for step: int in range(1, 60):
		var draws: int = game.rng.draws
		system.run(1.0 / 60.0)
		if game.rng.draws != draws:
			tick_steps.append(step)
	assert_eq(tick_steps.slice(0, 5), [1, 8, 15, 22, 29] as Array[int], "the first tick is in step 1 (the clock starts at 0), then every 7th step")
