class_name XpOrbState
extends RefCounted
## One entry of game.xpOrbs: `{x, y, value, r}` (pushXpOrb of the original). killEnemy creates them (step S5); updateXp moves,
## merges and collects them (step S6).

var x: float = 0.0
var y: float = 0.0
var value: float = 0.0
var r: float = 4.0
