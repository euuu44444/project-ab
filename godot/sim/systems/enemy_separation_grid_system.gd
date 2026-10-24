class_name EnemySeparationGridSystem
extends SimSystem
## index/separation-1 and index/separation-2: rebuildEnemySeparationGrid(). Two slots of the main list run this system: separation-1 right
## after the enemy index (before the enemies move) and separation-2 after enemy/update (the enemies' final positions of the step, for the
## weapons and projectiles that come later). updateEnemies rebuilds the grid once more at its own start (step S5, enemy/update). See EnemyGrid.


func _init(p_game: GameState) -> void:
	super(p_game, "rebuildEnemySeparationGrid")


## # port: rebuildEnemySeparationGrid
func run(_dt: float) -> void:
	game.enemy_grid.rebuild(game.enemies)
