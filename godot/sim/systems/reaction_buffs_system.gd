class_name ReactionBuffsSystem
extends SimSystem
## player/reaction-buffs: tickPlayerReactionBuffs(dt). Counts the reaction buffs down to 0.


func _init(p_game: GameState) -> void:
	super(p_game, "tickPlayerReactionBuffs")


## # port: tickPlayerReactionBuffs. `for (key in b) b[key] = Math.max(0, b[key] - dt)`
func run(dt: float) -> void:
	var b: ReactionBuffs = game.player.reaction_buffs
	b.prism_resonance = JsMath.js_max(0.0, b.prism_resonance - dt)
	b.void_echo = JsMath.js_max(0.0, b.void_echo - dt)
