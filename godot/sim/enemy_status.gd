class_name EnemyStatus
extends RefCounted
## `enemy.status` of the original: the 17 status timers/values of spawnEnemy's object literal, all 0 at spawn. Swarm and
## assassin never get any of them in M1 (no elements, no reactions, no afflictions); the fields exist because
## tickEnemyTimersAndStatus, killEnemy and the damage code read them, and so that enemy/update (step S5) and the weapons
## (step S6) can use them without changing the class.

var burn: float = 0.0
var burn_dps: float = 0.0
var poison: float = 0.0
var poison_dps: float = 0.0
var slow: float = 0.0
var wet: float = 0.0
var paralyze: float = 0.0
var airborne: float = 0.0
var exposed: float = 0.0
var erosion: float = 0.0
var superconduct: float = 0.0
var blind: float = 0.0
var necrotic: float = 0.0
var support_buff: float = 0.0
var heal_block: float = 0.0
var support_excluded: float = 0.0
var root: float = 0.0


## The timed part of tickEnemyTimersAndStatus: `for (const key of TIMED_ENEMY_STATUS_KEYS) if (e.status[key] > 0) e.status[key] = Math.max(0, e.status[key] - dt)`
## over slow, wet, paralyze, airborne, exposed, erosion, superconduct, blind, supportBuff, healBlock, supportExcluded, root (burn and poison are
## ticked on their own, with their damage). All of them are 0 in M1, so nothing changes.
func tick_timed(dt: float) -> void:
	if slow > 0.0:
		slow = JsMath.js_max(0.0, slow - dt)
	if wet > 0.0:
		wet = JsMath.js_max(0.0, wet - dt)
	if paralyze > 0.0:
		paralyze = JsMath.js_max(0.0, paralyze - dt)
	if airborne > 0.0:
		airborne = JsMath.js_max(0.0, airborne - dt)
	if exposed > 0.0:
		exposed = JsMath.js_max(0.0, exposed - dt)
	if erosion > 0.0:
		erosion = JsMath.js_max(0.0, erosion - dt)
	if superconduct > 0.0:
		superconduct = JsMath.js_max(0.0, superconduct - dt)
	if blind > 0.0:
		blind = JsMath.js_max(0.0, blind - dt)
	if support_buff > 0.0:
		support_buff = JsMath.js_max(0.0, support_buff - dt)
	if heal_block > 0.0:
		heal_block = JsMath.js_max(0.0, heal_block - dt)
	if support_excluded > 0.0:
		support_excluded = JsMath.js_max(0.0, support_excluded - dt)
	if root > 0.0:
		root = JsMath.js_max(0.0, root - dt)
