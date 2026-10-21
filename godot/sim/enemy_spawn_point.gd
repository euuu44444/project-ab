class_name EnemySpawnPoint
extends RefCounted
## A spawn position `{x, y, distance}` as safePointAround / safeEnemySpawnPoint / enemyFieldSpawnPoint return it.

var x: float = 0.0
var y: float = 0.0
## Distance to the player (safePointAround: to its centre argument); -1 for the "nothing found yet" placeholder.
var distance: float = 0.0


static func make(p_x: float, p_y: float, p_distance: float) -> EnemySpawnPoint:
	var point: EnemySpawnPoint = EnemySpawnPoint.new()
	point.x = p_x
	point.y = p_y
	point.distance = p_distance
	return point
