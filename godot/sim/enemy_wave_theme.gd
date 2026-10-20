class_name EnemyWaveTheme
extends RefCounted
## game.waveSpawnTheme of the original: which kind the wave features and what the director has spawned so far.

var wave: int = 0
var base_kind: String = "swarm"
var featured_kind: String = "swarm"
var changed: bool = false
var change_chance: float = 0.0
var featured_share: float = 0.0
var total_spawned: int = 0
## kind -> number spawned this wave (insertion order = first spawn order).
var counts: Dictionary = {}
## The last (up to 4) mixed kinds, oldest first.
var recent_mixed: PackedStringArray = PackedStringArray()
