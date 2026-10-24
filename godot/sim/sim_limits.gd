class_name SimLimits
extends RefCounted
## Map size, entity caps and grid sizes (res://sim/defs/limits.json). The pointer-dependent caps exist in two
## variants in the original (`IS_COARSE_POINTER ? A : B`); the simulation of the Android build uses the coarse one
## (MAX_PROJECTILES 520, MAX_XP_ORBS 480, MAX_ENEMY_PROJECTILES 420).

var coarse_pointer: bool = true
var map_w: float = 0.0
var map_h: float = 0.0
var base_max_enemies: int = 0
var max_hazards: int = 0
var max_enemy_collision_radius: float = 0.0
var nova_projectile_radius: float = 0.0
var nova_projectile_art_size: float = 0.0
var enemy_separation_grid_size: int = 0
var enemy_separation_grid_stride: int = 0
var enemy_grid_max_cx: int = 0
var enemy_grid_max_cy: int = 0
var projectile_avoid_grid_size: int = 0
var projectile_avoid_grid_stride: int = 0
var projectile_avoid_grid_max_cy: int = 0
# pointer dependent
var max_projectiles: int = 0
var max_xp_orbs: int = 0
var max_enemy_projectiles: int = 0
var hud_update_interval: float = 0.0
var world_chunk_cache_min: int = 0
var world_chunk_cache_max: int = 0


func _init(p_coarse_pointer: bool = true) -> void:
	coarse_pointer = p_coarse_pointer
	map_w = _num("MAP_W")
	map_h = _num("MAP_H")
	base_max_enemies = int(_num("BASE_MAX_ENEMIES"))
	max_hazards = int(_num("MAX_HAZARDS"))
	max_enemy_collision_radius = _num("MAX_ENEMY_COLLISION_RADIUS")
	nova_projectile_radius = _num("NOVA_PROJECTILE_RADIUS")
	nova_projectile_art_size = _num("NOVA_PROJECTILE_ART_SIZE")
	enemy_separation_grid_size = int(_num("ENEMY_SEPARATION_GRID_SIZE"))
	enemy_separation_grid_stride = int(_num("ENEMY_SEPARATION_GRID_STRIDE"))
	enemy_grid_max_cx = int(_num("ENEMY_GRID_MAX_CX"))
	enemy_grid_max_cy = int(_num("ENEMY_GRID_MAX_CY"))
	projectile_avoid_grid_size = int(_num("PROJECTILE_AVOID_GRID_SIZE"))
	projectile_avoid_grid_stride = int(_num("PROJECTILE_AVOID_GRID_STRIDE"))
	projectile_avoid_grid_max_cy = int(_num("PROJECTILE_AVOID_GRID_MAX_CY"))
	max_projectiles = int(_pointer("MAX_PROJECTILES"))
	max_xp_orbs = int(_pointer("MAX_XP_ORBS"))
	max_enemy_projectiles = int(_pointer("MAX_ENEMY_PROJECTILES"))
	hud_update_interval = _pointer("HUD_UPDATE_INTERVAL")
	world_chunk_cache_min = int(_pointer("WORLD_CHUNK_CACHE_MIN"))
	world_chunk_cache_max = int(_pointer("WORLD_CHUNK_CACHE_MAX"))


func _num(constant: String) -> float:
	return float(Defs.value("limits.json", constant))


func _pointer(constant: String) -> float:
	return float(Defs.pointer_value("limits.json", constant, coarse_pointer))
