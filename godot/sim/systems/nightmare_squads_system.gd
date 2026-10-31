class_name NightmareSquadsSystem
extends SimSystem
## enemy/squads: updateNightmareSquads(dt). The squad director of the nightmare difficulty. Its first line is
## `if (!game || !isDifficulty("nightmare")) return;`, so on every other difficulty (M1 plays normal) the slot does nothing and
## draws nothing. The nightmare part (it draws rand(0.25, 0.42) for the squad clock) is not ported.


func _init(p_game: GameState) -> void:
	super(p_game, "updateNightmareSquads")


## # port: updateNightmareSquads (the guard)
func run(_dt: float) -> void:
	if game.difficulty == "nightmare":
		push_error("NightmareSquadsSystem: the nightmare squads are not ported (M1 is normal only)")
