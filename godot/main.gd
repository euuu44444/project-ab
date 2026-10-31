extends Node2D
## Engine loop (design section 3): the fixed 60 Hz step drives the deterministic simulation (sim/), the render step reads it.
##
## _physics_process() is the fixed simulation step (physics_ticks_per_second = 60, max_physics_steps_per_frame = 5), the
## equivalent of the original's loop calling capturePreviousTransforms(); update(FIXED_DT). _process() runs once per displayed
## frame and reads the interpolation fraction that the renderer (step S7) uses to blend the previous and the current state.
##
## Step S3 has no rendering yet: the label shows the player's and the camera's position and the draw count of gameRandom, which
## is what the reference traces compare. Keyboard input: WASD or the arrow keys.

const TITLE: String = "Elemental Swarm Engine — S3 simulation"
## Seed of gameRandom for this scaffold: the reference traces use 424242 (design section 9.2). A different seed can be passed
## on the command line: godot --path godot -- --seed=123
const DEFAULT_SEED: int = 424242
const SEED_ARGUMENT: String = "--seed="

## Number of fixed simulation steps executed so far.
var tick_count: int = 0
## Fraction of the current fixed step already elapsed, in [0, 1).
var alpha: float = 0.0
## The deterministic simulation; created in _ready().
var sim: Sim = null

@onready var _label: Label = $HUD/Label


func _ready() -> void:
	var config: SimConfig = SimConfig.new()
	config.rng_seed = _seed_from_arguments()
	config.character_id = "catalyst"
	var view: Vector2 = get_viewport_rect().size
	config.view_w = view.x
	config.view_h = view.y
	sim = Sim.new()
	if not sim.new_game(config):
		sim = null


func _physics_process(_delta: float) -> void:
	tick_count += 1
	if sim == null or sim.game.state != GameState.RunState.PLAYING:
		return
	_read_keyboard(sim.game.input)
	var view: Vector2 = get_viewport_rect().size
	sim.set_view_size(view.x, view.y)
	sim.step(Sim.FIXED_DT)


func _process(_delta: float) -> void:
	alpha = Engine.get_physics_interpolation_fraction()
	var view: Vector2 = get_viewport_rect().size
	var text: String = "%s\nticks: %d (%d Hz)\nalpha: %.3f\nview: %d x %d\nfps: %d" % [
		TITLE,
		tick_count,
		Engine.physics_ticks_per_second,
		alpha,
		int(view.x),
		int(view.y),
		int(Engine.get_frames_per_second()),
	]
	if sim != null:
		var g: GameState = sim.game
		text += "\nplayer: %.1f, %.1f   v: %.1f, %.1f" % [g.player.x, g.player.y, g.player.vx, g.player.vy]
		text += "\ncamera: %.1f, %.1f" % [g.camera.x, g.camera.y]
		text += "\nt: %.2f s   draws: %d   hp: %d" % [g.t, sim.draws(), int(g.player.hp)]
	else:
		text += "\nsimulation failed to start (see the log)"
	_label.text = text


## WASD and the arrow keys (the physical key positions, so they work on any keyboard layout). The sim resolves the vector.
func _read_keyboard(input: SimInput) -> void:
	input.key_left = Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)
	input.key_right = Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT)
	input.key_up = Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)
	input.key_down = Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)


func _seed_from_arguments() -> int:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(SEED_ARGUMENT) and argument.substr(SEED_ARGUMENT.length()).is_valid_int():
			return argument.substr(SEED_ARGUMENT.length()).to_int()
	return DEFAULT_SEED
