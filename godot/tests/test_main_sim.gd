extends "res://tests/test_case.gd"
## main.gd drives the simulation: one Sim per scene, stepped by the fixed step, fed by the keyboard, shown in the label.
## (test_scenes.gd checks that the scene loads and counts ticks; this file checks the wiring to sim/.)

const MAIN_SCENE: String = "res://main.tscn"
const STEP: float = 1.0 / 60.0


func _start_main() -> Node:
	var scene: PackedScene = load(MAIN_SCENE) as PackedScene
	var main: Node = scene.instantiate()
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	tree.root.add_child(main)
	return main


func _stop_main(main: Node) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	tree.root.remove_child(main)
	main.free()


func _press(keycode: Key, pressed: bool) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func test_ready_creates_a_catalyst_run_with_the_view_size() -> void:
	var main: Node = _start_main()
	var sim: Sim = main.get("sim") as Sim
	assert_true(sim != null, "main creates a Sim in _ready")
	if sim != null:
		assert_eq(sim.game.char_id, "catalyst", "catalyst")
		assert_eq(sim.game.difficulty, "normal", "normal difficulty")
		assert_eq(sim.game.mode, "normal", "standard mode")
		assert_eq(sim.game.rng.seed_value, 424242, "the reference seed by default")
		assert_eq(sim.draws(), 1, "newGame drew once")
		var view: Vector2 = (main as Node2D).get_viewport_rect().size
		assert_eq(sim.game.view_w, view.x, "viewW is the viewport width")
		assert_eq(sim.game.view_h, view.y, "viewH is the viewport height")
	_stop_main(main)


func test_each_fixed_step_steps_the_simulation_and_the_label_shows_it() -> void:
	var main: Node = _start_main()
	var sim: Sim = main.get("sim") as Sim
	assert_true(sim != null, "sim")
	if sim == null:
		_stop_main(main)
		return
	for i: int in 60:
		main.call("_physics_process", STEP)
	main.call("_process", STEP)
	assert_eq(main.get("tick_count"), 60, "60 ticks")
	assert_eq(sim.steps, 60, "60 simulation steps")
	assert_true(GoldenCodec.same_double(sim.game.t, _sum_of_steps(60)), "the game clock is the sum of 60 steps of 1/60")
	assert_eq(sim.game.player.x, sim.game.limits.map_w / 2.0, "no input: the player stands still")
	var label: Label = main.get_node("HUD/Label") as Label
	assert_true(label.text.contains("ticks: 60 (60 Hz)"), "tick count in the label: %s" % label.text)
	assert_true(label.text.contains("player: 13000.0, 13000.0"), "player position in the label: %s" % label.text)
	assert_true(label.text.contains("camera: 13000.0, 13000.0"), "camera position in the label: %s" % label.text)
	assert_true(label.text.contains("draws: 1"), "draw count in the label: %s" % label.text)
	_stop_main(main)


func test_keyboard_moves_the_player() -> void:
	var main: Node = _start_main()
	var sim: Sim = main.get("sim") as Sim
	assert_true(sim != null, "sim")
	if sim == null:
		_stop_main(main)
		return
	_press(KEY_D, true)
	_press(KEY_S, true)
	for i: int in 30:
		main.call("_physics_process", STEP)
	_press(KEY_D, false)
	_press(KEY_S, false)
	var g: GameState = sim.game
	# the diagonal is normalised: 180 px/s * (1/sqrt(2)) on each axis for half a second
	assert_true(g.player.x > 13063.0 and g.player.x < 13064.0, "moved right: %s" % g.player.x)
	assert_true(g.player.y > 13063.0 and g.player.y < 13064.0, "moved down: %s" % g.player.y)
	assert_true(absf((g.player.x - 13000.0) - (g.player.y - 13000.0)) < 1e-6, "equal speed on both axes")
	assert_true(g.camera.x > 13000.0 and g.camera.x < g.player.x, "the camera follows with a lag")
	var x_after: float = g.player.x
	for i: int in 10:
		main.call("_physics_process", STEP)
	assert_eq(g.player.x, x_after, "released keys: the player stops")
	_stop_main(main)


func test_arrow_keys_work_too() -> void:
	var main: Node = _start_main()
	var sim: Sim = main.get("sim") as Sim
	assert_true(sim != null, "sim")
	if sim == null:
		_stop_main(main)
		return
	_press(KEY_LEFT, true)
	for i: int in 6:
		main.call("_physics_process", STEP)
	_press(KEY_LEFT, false)
	assert_true(sim.game.player.x < 13000.0, "left arrow moves left: %s" % sim.game.player.x)
	assert_eq(sim.game.player.y, 13000.0, "no vertical movement")
	_stop_main(main)


func _sum_of_steps(count: int) -> float:
	var t: float = 0.0
	for i: int in count:
		t += STEP
	return t
