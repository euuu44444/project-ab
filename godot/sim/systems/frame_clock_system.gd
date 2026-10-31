class_name FrameClockSystem
extends SimSystem
## frame/clock: advanceFrameClock(dt). The game clock keeps running during the knock-out animation.


func _init(p_game: GameState) -> void:
	super(p_game, "advanceFrameClock")


## # port: advanceFrameClock. Accumulates (`game.t += dt`); never compute n * dt, the sum is what the original's clock is.
func run(dt: float) -> void:
	game.t += dt
