class_name EnemySpawnPlan
extends RefCounted
## What createEnemyFieldSpawnPlan() returns: where and in which formation the enemies of one director batch appear.

## "scatter", "arc", "pincer", "line" (the pool of waves 1-6; the other formations are not reachable in M1).
var pattern: String = ""
var base_angle: float = 0.0
var radius: float = 0.0
## The formation's anchor point (clamped to the map).
var cx: float = 0.0
var cy: float = 0.0
var min_radius: float = 0.0
var max_radius: float = 0.0
var min_distance: float = 0.0
var batch_size: int = 4
