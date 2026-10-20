class_name EnemyState
extends RefCounted
## One enemy of game.enemies. Step S3 only needs the position fields (capturePreviousTransforms writes prev_x / prev_y
## for every enemy); step S5 adds the rest of spawnEnemy's object here.

var id: int = 0
var kind: String = "swarm"
var x: float = 0.0
var y: float = 0.0
var vx: float = 0.0
var vy: float = 0.0
var prev_x: float = 0.0
var prev_y: float = 0.0
var hp: float = 0.0
