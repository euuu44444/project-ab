class_name ProjectileState
extends RefCounted
## One entry of game.projectiles (a player projectile). Step S5 only needs what the enemy AI reads (an assassin dodges
## projectiles: enemyProjectileAvoidance uses x, y, vx and vy); the reference trace also records life, age, r, damage and the
## weapon id, so the test-only replay oracle can rebuild the list from a trace row. Step S6 owns this class and adds the rest
## of the original's projectile object (pierce, homing, owner weapon, ...).
##
## It is deliberately NOT registered in SimTrace.entity_sample() before step S6: the projectile group stays "unported", so the
## comparison never mistakes the oracle's copy of the reference for a result of the port.

var x: float = 0.0
var y: float = 0.0
var vx: float = 0.0
var vy: float = 0.0
var life: float = 0.0
var age: float = 0.0
var r: float = 0.0
var damage: float = 0.0
## The id of the weapon that fired it ("pulse", "catalytic_ring", ...).
var weapon: String = ""
