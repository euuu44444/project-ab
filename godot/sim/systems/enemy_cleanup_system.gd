class_name EnemyCleanupSystem
extends SimSystem
## enemy/cleanup-1 and enemy/cleanup-2: cleanupDeadEnemies(). Two slots of the main list run this system. cleanup-1 (before the enemies
## act) removes enemies that hazards killed; cleanup-2 (after the projectiles) removes the enemies that weapons and projectiles killed.
## Every enemy it removes goes through killEnemy (EnemyLifecycle): kills, score, the experience orb (two gameRandom draws) and the
## swap-pop that fixes the order of the enemy list.
##
## In M1 nothing kills an enemy before step S6 (weapons, projectiles, damage). The replay oracle of the tests sets hp = 0 on the enemies
## that the reference removed, in front of cleanup-2; this system then removes them with its own code.


func _init(p_game: GameState) -> void:
	super(p_game, "cleanupDeadEnemies")


## # port: cleanupDeadEnemies
func run(_dt: float) -> void:
	EnemyLifecycle.cleanup_dead_enemies(game)
