class_name ReactionBuffs
extends RefCounted
## player.reactionBuffs of the original: the remaining seconds of the two reaction-triggered buffs. They are 0 in M1
## (no reactions), and tickPlayerReactionBuffs decays each toward 0.

var prism_resonance: float = 0.0
var void_echo: float = 0.0
