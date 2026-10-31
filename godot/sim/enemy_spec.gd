class_name EnemySpec
extends RefCounted
## What enemySpec(kind, wave) of the original returns: the stats of a new enemy before the spawn adds its AI state.
## (Formulas.enemy_spec builds it.) A numeric field that the original leaves out (shoot for most kinds, shield for
## everything but elite and boss) is 0.0 here, which is how every reader of the original treats it (`if(s.shield)`).

var kind: String = "swarm"
var r: float = 0.0
var hp: float = 0.0
var speed: float = 0.0
var damage: float = 0.0
var color: String = ""
var xp: float = 0.0
var armor: float = 0.0
var evasion: float = 0.0
## Shot interval of the kinds that shoot (artillery 2.1, boss 1.6); 0.0 for the others.
var shoot: float = 0.0
var elite: bool = false
var boss: bool = false
var shield: float = 0.0
var projectile_speed_mul: float = 1.0
var action_cooldown_mul: float = 1.0
var ability_cooldown_mul: float = 1.0
