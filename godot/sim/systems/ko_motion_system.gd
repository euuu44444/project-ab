class_name KoMotionSystem
extends SimSystem
## player/ko-motion: tickKnockOutMotion(dt). While the knock-out animation plays the player stands still and only the
## KO timer runs down.


func _init(p_game: GameState) -> void:
	super(p_game, "tickKnockOutMotion")


## # port: tickKnockOutMotion
func run(dt: float) -> void:
	var p: PlayerState = game.player
	p.ko_timer = JsMath.js_max(0.0, p.ko_timer - dt)
	p.vx = 0.0
	p.vy = 0.0
	p.ax = 0.0
	p.ay = 0.0
	p.attack_anim = 0.0
