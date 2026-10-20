class_name DayCycleSystem
extends SimSystem
## frame/day-cycle: updateDayCycle(dt). Advances the day phase; only the renderer reads it, and it never touches gameRandom.


func _init(p_game: GameState) -> void:
	super(p_game, "updateDayCycle")


## # port: updateDayCycle. `dayPhase = (dayPhase + dt / DAY_CYCLE_SECONDS) % 1`
func run(dt: float) -> void:
	if not is_finite(game.day_phase):
		game.day_phase = 0.18
	game.day_phase = JsMath.js_mod(game.day_phase + dt / Defs.rules().day_cycle_seconds, 1.0)
