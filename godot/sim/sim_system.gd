class_name SimSystem
extends RefCounted
## One system of the original's update lists (UPDATE_INTRO_SYSTEMS, UPDATE_MAIN_SYSTEMS, UPDATE_KO_SYSTEMS).
## Subclasses implement run(dt) and, for the slots that have a `when` predicate in the original, when().
## `original_function` names the function the original's `run` closure calls; tests compare it with the original's lists.

var game: GameState = null
var original_function: String = ""


func _init(p_game: GameState, p_original_function: String) -> void:
	game = p_game
	original_function = p_original_function


## The slot's work for one fixed step of `dt` seconds.
func run(_dt: float) -> void:
	pass


## The slot's `when` predicate (only consulted for slots with has_when).
func when() -> bool:
	return true


## False for a placeholder that does nothing yet.
func is_implemented() -> bool:
	return true
