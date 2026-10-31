class_name ScreenFlashSystem
extends SimSystem
## fx/screen-flash: decayScreenFlashes(dt). Fades the full-screen flash and the damage flash.


func _init(p_game: GameState) -> void:
	super(p_game, "decayScreenFlashes")


## # port: decayScreenFlashes
func run(dt: float) -> void:
	game.screen_flash = JsMath.js_max(0.0, game.screen_flash - dt * 1.7)
	game.damage_flash = JsMath.js_max(0.0, game.damage_flash - dt * 3.4)
