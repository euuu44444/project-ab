extends Node2D
## S1 scaffold: skeleton of the engine loop (fixed 60 Hz step + interpolated render).
##
## _physics_process() is the fixed simulation step (physics_ticks_per_second = 60).
## _process() runs once per displayed frame and reads the interpolation fraction
## that later steps use to blend the previous and current simulation state.

const TITLE: String = "Elemental Swarm Engine — S1 scaffold"

## Number of fixed simulation steps executed so far.
var tick_count: int = 0
## Fraction of the current fixed step already elapsed, in [0, 1).
var alpha: float = 0.0

@onready var _label: Label = $HUD/Label


func _physics_process(_delta: float) -> void:
	tick_count += 1


func _process(_delta: float) -> void:
	alpha = Engine.get_physics_interpolation_fraction()
	var view: Vector2 = get_viewport_rect().size
	_label.text = "%s\nticks: %d (%d Hz)\nalpha: %.3f\nview: %d x %d\nfps: %d" % [
		TITLE,
		tick_count,
		Engine.physics_ticks_per_second,
		alpha,
		int(view.x),
		int(view.y),
		int(Engine.get_frames_per_second()),
	]
