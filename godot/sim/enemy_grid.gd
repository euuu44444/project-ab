class_name EnemyGrid
extends RefCounted
## The enemy spatial grid of the original: game.enemySeparationGrid with its buckets, built by rebuildEnemySeparationGrid() and read by
## enemySeparationVector (enemy AI), queryEnemiesAabb / queryEnemiesCircleBroad (weapons, hits) and nearestEnemy (design 5.4).
##
## The grid is a snapshot. rebuild() runs at three points of a step (index/separation-1, the start of updateEnemies, index/separation-2);
## in between enemies move, die and spawn, so a reader sees buckets of the last rebuild with the LIVE positions of the enemies in them.
## That staleness is the original's and is kept: the order of the candidates (bucket order = enemy list order at the rebuild, cells
## in ascending key order = row by row) decides which enemy a weapon picks first and how the separation sum is accumulated.
##
## One implementation stands for the three of the original (rebuildEnemySeparationGridBasic, the Uint32Array "cells" variant with a query
## cache for >= 64 projectiles or >= 12 hazards, and the plain Map): all give the same buckets and the same candidate order, they only
## differ in speed. They also skip the rebuild when nothing changed ("changed" flag); a rebuild of unchanged input gives the same buckets,
## so this one always rebuilds. tests/golden/enemies.json holds the original's answers (including the >= 64 projectiles path).

var _cell_size: float = 96.0
var _stride: int = 275
var _max_cx: int = 270
var _max_cy: int = 270
## key -> Array[EnemyState], in list order. Only non-empty buckets exist, so size() is the original's `grid.size`.
var _buckets: Dictionary = {}
var _pool: Array[Array] = []
var _used: int = 0
var _sorted_keys: Array[int] = []
var _sort_dirty: bool = true
var _nearest_scratch: Array[EnemyState] = []
var _no_bucket: Array[EnemyState] = []


func _init(limits: SimLimits) -> void:
	_cell_size = float(limits.enemy_separation_grid_size)
	_stride = limits.enemy_separation_grid_stride
	_max_cx = limits.enemy_grid_max_cx
	_max_cy = limits.enemy_grid_max_cy


## # port: enemySeparationGridKey
func key_of(cx: int, cy: int) -> int:
	return (cy + 2) * _stride + (cx + 2)


## The number of non-empty buckets (`game.enemySeparationGrid.size`).
func size() -> int:
	return _buckets.size()


## The bucket of a cell key in enemy list order; an empty array when the cell has no bucket (the original skips a missing key). Do not modify it.
func bucket(key: int) -> Array[EnemyState]:
	if _buckets.has(key):
		return _buckets[key]
	return _no_bucket


## # port: rebuildEnemySeparationGrid (and rebuildEnemySeparationGridBasic). Only enemies with hp > 0 are bucketed (a NaN hp is not).
func rebuild(enemies: Array[EnemyState]) -> void:
	_buckets.clear()
	_sort_dirty = true
	var previous_used: int = _used
	var used: int = 0
	for e: EnemyState in enemies:
		if not (e.hp > 0.0):
			continue
		var key: int = key_of(int(floorf(e.x / _cell_size)), int(floorf(e.y / _cell_size)))
		var cell: Array[EnemyState]
		if _buckets.has(key):
			cell = _buckets[key]
		else:
			if used < _pool.size():
				cell = _pool[used]
				cell.clear()
			else:
				cell = []
				_pool.append(cell)
			used += 1
			_buckets[key] = cell
		cell.append(e)
	for i: int in range(used, previous_used):
		_pool[i].clear()
	_used = used


## # port: queryEnemiesAabb. Fills `out` (cleared first) with the living enemies of the cells that the box touches, widened by
## `cell_margin` cells, and returns it. Order: cells row by row (ascending key), enemies in bucket order; with an empty grid, the enemy
## list order. hp > 0 is checked again here (an enemy may have died since the rebuild).
func query_aabb(enemies: Array[EnemyState], min_x: float, min_y: float, max_x: float, max_y: float, out: Array[EnemyState],
		cell_margin: int = 0) -> Array[EnemyState]:
	out.clear()
	if _buckets.is_empty():
		for e: EnemyState in enemies:
			if e.hp > 0.0:
				out.append(e)
		return out
	var margin: float = float(cell_margin)
	var min_cx: int = int(JsMath.clamp(floorf(min_x / _cell_size) - margin, 0.0, float(_max_cx)))
	var max_cx: int = int(JsMath.clamp(floorf(max_x / _cell_size) + margin, 0.0, float(_max_cx)))
	var min_cy: int = int(JsMath.clamp(floorf(min_y / _cell_size) - margin, 0.0, float(_max_cy)))
	var max_cy: int = int(JsMath.clamp(floorf(max_y / _cell_size) + margin, 0.0, float(_max_cy)))
	var cell_count: int = (max_cx - min_cx + 1) * (max_cy - min_cy + 1)
	if cell_count > maxi(64, _buckets.size() * 4):
		# many cells: walk the occupied keys in ascending order instead (the same sequence as the row-by-row walk)
		if _sort_dirty or _sorted_keys.size() != _buckets.size():
			_sorted_keys.clear()
			for key_variant: Variant in _buckets.keys():
				_sorted_keys.append(int(key_variant))
			_sorted_keys.sort()
			_sort_dirty = false
		var first_key: int = key_of(min_cx, min_cy)
		var last_key: int = key_of(max_cx, max_cy)
		for key: int in _sorted_keys:
			if key < first_key:
				continue
			if key > last_key:
				break
			var cx: int = key % _stride - 2
			if cx < min_cx or cx > max_cx:
				continue
			for e: EnemyState in (_buckets[key] as Array[EnemyState]):
				if e.hp > 0.0:
					out.append(e)
		return out
	for cy: int in range(min_cy, max_cy + 1):
		for cx: int in range(min_cx, max_cx + 1):
			var cell_key: int = key_of(cx, cy)
			if not _buckets.has(cell_key):
				continue
			for e: EnemyState in (_buckets[cell_key] as Array[EnemyState]):
				if e.hp > 0.0:
					out.append(e)
	return out


## # port: queryEnemiesCircleBroad. The box of the circle (x - r .. x + r), see query_aabb.
func query_circle_broad(enemies: Array[EnemyState], x: float, y: float, r: float, out: Array[EnemyState],
		cell_margin: int = 0) -> Array[EnemyState]:
	return query_aabb(enemies, x - r, y - r, x + r, y + r, out, cell_margin)


## # port: nearestEnemy. The closest living enemy within `range` (strictly closer than the best so far, so on a tie the first
## candidate of the scan wins), or null.
func nearest_enemy(enemies: Array[EnemyState], x: float, y: float, range_limit: float) -> EnemyState:
	var best: EnemyState = null
	var best_d: float = range_limit * range_limit
	for e: EnemyState in query_circle_broad(enemies, x, y, range_limit, _nearest_scratch, 1):
		var d: float = SimUtil.dist2(x, y, e.x, e.y)
		if d < best_d:
			best_d = d
			best = e
	return best
