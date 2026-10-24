class_name EnemySpecialState
extends RefCounted
## `enemy.specialState` of the original: `{phaseWindup: 0, pendingAttack: null, pendingWindup: 0, activeTierAttack: null}`.
## Only elites and bosses use it (updateSpecialEnemyAbilities returns at its first line for every other enemy); the
## attacks are not ported (M2), so the two attack fields are plain Variants that stay null.

var phase_windup: float = 0.0
## null in the original; the pending attack object of an elite/boss ability (M2).
var pending_attack: Variant = null
var pending_windup: float = 0.0
## null in the original; the telegraphed tier attack of an elite/boss (M2).
var active_tier_attack: Variant = null
