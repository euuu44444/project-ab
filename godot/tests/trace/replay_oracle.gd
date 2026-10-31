class_name ReplayOracle
extends RefCounted
## TEST-ONLY replay oracle (design section 11, step S5): lets the port follow a reference trace past the first effect that belongs to
## a later step (S6: weapons, projectiles, damage, experience), so that everything step S5 ports can be compared bit for bit from the
## first enemy to the end of every trace.
##
## What it does, per step n of the replay (index k = n - 1), and why that is faithful to the reference:
##  (a) DRY DRAWS. A slot that is still a placeholder (SimSystem.is_implemented() is false) and that draws in the reference gets
##      `slot_draws[k][slot]` values drawn from gameRandom right after it ran, so the stream stays where the original has it (S6's
##      projectile/player draws crit rolls and damage numbers; enemy/update draws the 3 values of a contact hit until it is ported). A slot
##      that IS implemented is never topped up: the comparison of the slot draws then checks the port's own draws against the reference.
##      The number of injected draws is counted per slot (injected_total()), so the debt of the later steps stays visible.
##  (b) FORCED KILLS. Before enemy/cleanup-2 the enemies that the reference removed in this step (TraceReader.removed_enemy_ids(k)) get
##      hp = 0, and the port's own cleanupDeadEnemies removes them (swap-pop from the end, killEnemy: kills, score, the xp orb and its two
##      draws). The reference's victims die in projectile/player (main:29) and leave in cleanup-2 (main:31); nothing in between (slot 30) reads
##      or writes an enemy list. They were alive during this step's enemy/update, as they are here. The oracle checks that no other enemy has
##      hp <= 0 at that point (nothing in the port damages an enemy before S6) and that every id it is told to kill exists.
##  (c) PROJECTILES. An assassin dodges player projectiles (enemyProjectileAvoidance reads x, y, vx, vy of game.projectiles in list order).
##      Nothing between the end of step n - 1 and enemy/update of step n changes that list, so at the start of step n it is rebuilt from the
##      reference's rows of step n - 1 (empty for n = 1). The port has no weapons before S6.
##
## What it leaves to the comparison (not the oracle's business): fields that only damage changes (enemy hp, flash ...), the experience orbs
## after pickup, the player's experience; see tests/test_reference_trace.gd.
##
## It is impossible to enable in the exported game: the classes live under res://tests/, which export_presets.cfg excludes
## (`exclude_filter="tests/*"`), and nothing under res://sim, res://render or main.gd mentions it (tests/test_replay_oracle.gd scans for that).
## It is installed from outside, by replacing SystemSlot.system with an OracleSystem (install()); the simulation has no hook for it.

## The reference trace being followed.
var reference: TraceReader = null
var game: GameState = null
## The 0-based index of the step being run (set by begin_step).
var step_index: int = -1
## slot key ("main:29") -> draws injected for placeholders over the whole replay.
var injected: Dictionary = {}
## Forced kills over the whole replay.
var forced_kills: int = 0
## Whatever went wrong (a slot that drew more than the reference, an id that is not in the port's list ...); the test asserts it is empty.
var problems: PackedStringArray = PackedStringArray()
var _cleanup_two_key: String = ""
var _projectile_fields: Dictionary = {}


## Wraps every slot of `sim` in an OracleSystem for `p_reference`. Call before SimTrace.new(sim), which puts its TracedSystem over the wrapper.
static func install(sim: Sim, p_reference: TraceReader) -> ReplayOracle:
	var oracle: ReplayOracle = ReplayOracle.new()
	oracle.reference = p_reference
	oracle.game = sim.game
	oracle._cleanup_two_key = p_reference.slot_key("main", "enemy/cleanup-2")
	var lists: Array = [sim.runner.intro, sim.runner.main, sim.runner.ko]
	for l: int in range(lists.size()):
		var list: Array = lists[l]
		for i: int in range(list.size()):
			var slot: SystemSlot = list[i]
			slot.system = OracleSystem.new(slot.system, oracle, slot.id, "%s:%d" % [SimTrace.LIST_NAMES[l], i])
	for index: int in range(p_reference.field_specs("projectile").size()):
		oracle._projectile_fields[p_reference.field_specs("projectile")[index][0]] = index
	return oracle


## Starts step `k` (0-based): the projectile list as it stood at the end of the step before. Call before Sim.step().
func begin_step(k: int) -> void:
	step_index = k
	_rebuild_projectiles(k - 1)


## The number of draws injected so far, over all slots.
func injected_total() -> int:
	var total: int = 0
	for key: Variant in injected.keys():
		total += int(injected[key])
	return total


## Called by OracleSystem in front of a slot.
func before_slot(slot_id: String) -> void:
	if slot_id == "enemy/cleanup-2":
		_force_kills()


## Called by OracleSystem behind a slot: `drawn` is what the slot's own code drew.
func after_slot(_slot_id: String, key: String, implemented: bool, drawn: int) -> void:
	if implemented or step_index < 0:
		return
	var wanted: int = reference.slot_draws(step_index, key)
	if drawn > wanted:
		problems.append("step %d %s: the placeholder drew %d values, the reference %d" % [step_index + 1, key, drawn, wanted])
		return
	for i: int in range(wanted - drawn):
		game.rng.random()
	if wanted > drawn:
		injected[key] = int(injected.get(key, 0)) + wanted - drawn


func _force_kills() -> void:
	var removed: Array[int] = reference.removed_enemy_ids(step_index)
	var targets: Dictionary = {}
	for id: int in removed:
		targets[id] = true
	var found: int = 0
	for e: EnemyState in game.enemies:
		if targets.has(e.id):
			e.hp = 0.0
			found += 1
		elif e.hp <= 0.0:
			problems.append("step %d: enemy %d has hp <= 0 in front of enemy/cleanup-2 and the reference did not remove it" % [step_index + 1, e.id])
	if found != removed.size():
		problems.append("step %d: the reference removed %d enemies, %d of them are in the port's list" % [step_index + 1, removed.size(), found])
	forced_kills += found


## game.projectiles := copies of the reference's projectile rows of step `row_index` (an empty list before the first step).
func _rebuild_projectiles(row_index: int) -> void:
	game.projectiles.clear()
	if row_index < 0:
		return
	for row: Variant in (reference.steps[row_index]["projectiles"] as Array):
		var values: Array = row as Array
		var p: ProjectileState = ProjectileState.new()
		p.x = _float_of(values, "x")
		p.y = _float_of(values, "y")
		p.vx = _float_of(values, "vx")
		p.vy = _float_of(values, "vy")
		p.life = _float_of(values, "life")
		p.age = _float_of(values, "age")
		p.r = _float_of(values, "r")
		p.damage = _float_of(values, "damage")
		p.weapon = String(values[int(_projectile_fields["weapon"])])
		game.projectiles.append(p)


func _float_of(values: Array, field_name: String) -> float:
	return SimTrace.from_hex(String(values[int(_projectile_fields[field_name])]))
