class_name EnemyIndexSystem
extends SimSystem
## index/enemy-by-id: rebuildEnemyIndex(). game.enemyById maps an enemy id to the enemy; readers (homing projectiles, damage text) look an
## enemy up by the id they stored.
##
## It is a snapshot taken in this slot: an enemy that dies later in the step (cleanup-2) stays in the map until the next rebuild, an
## enemy that spawns later in the step (wave/progress comes BEFORE this slot, so none) would be missing. The original skips the rebuild
## when the list, its length and enemiesVersion are unchanged (every change of the list bumps the version), which gives the same content,
## so this always rebuilds.


func _init(p_game: GameState) -> void:
	super(p_game, "rebuildEnemyIndex")


## # port: rebuildEnemyIndex
func run(_dt: float) -> void:
	game.enemy_by_id.clear()
	for e: EnemyState in game.enemies:
		game.enemy_by_id[e.id] = e
