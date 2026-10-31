class_name SystemSlot
extends RefCounted
## An entry of an update list: `sys(id, phase, run, note, when)` of the original.

var id: String = ""
var phase: String = ""
var system: SimSystem = null
## True when the original's entry has a `when` predicate.
var has_when: bool = false


func _init(p_id: String, p_phase: String, p_system: SimSystem, p_has_when: bool = false) -> void:
	id = p_id
	phase = p_phase
	system = p_system
	has_when = p_has_when
