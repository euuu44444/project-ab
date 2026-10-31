extends "res://tests/test_case.gd"
## Smoke tests for the scene files. A scene whose script does not compile still loads, and
## Godot exits with 0 in that case, so nothing else in the toolchain would notice. Errors logged
## while a scene loads or runs are collected by run_tests.gd and fail the test that caused them.

const MAIN_SCENE: String = "res://main.tscn"
const MAIN_SCRIPT: String = "res://main.gd"
const STEP: float = 1.0 / 60.0


func test_main_scene_loads_and_runs_one_frame() -> void:
	var scene: PackedScene = load(MAIN_SCENE) as PackedScene
	assert_true(scene != null, "main.tscn loads as a PackedScene")
	if scene == null:
		return
	var main: Node = scene.instantiate()
	assert_true(main != null, "main.tscn instantiates")
	if main == null:
		return
	var script: Script = main.get_script() as Script
	assert_true(script != null, "the root node has a script")
	if script != null:
		assert_eq(script.resource_path, MAIN_SCRIPT, "root script")

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	tree.root.add_child(main)
	assert_true(main.is_node_ready(), "the scene is ready once it is in the tree")
	var label: Label = main.get_node_or_null("HUD/Label") as Label
	assert_true(label != null, "HUD/Label exists")
	if label != null:
		# One simulated fixed step and one rendered frame, as the engine would call them.
		main.call("_physics_process", STEP)
		main.call("_process", STEP)
		assert_eq(main.get("tick_count"), 1, "one fixed step counted")
		assert_true(label.text.contains("ticks: 1 (60 Hz)"), "HUD shows the tick count: %s" % label.text)
	tree.root.remove_child(main)
	main.free()


func test_scene_nodes_carry_unique_ids() -> void:
	# Hand-written .tscn files without unique_id= make Godot invent random node ids on every clean
	# import, so two exports of the same commit would differ. Saving the scene in the editor adds
	# them; so does the PackedScene.pack() round trip.
	var scenes: PackedStringArray = PackedStringArray()
	_find_scenes("res://", scenes)
	assert_true(scenes.has(MAIN_SCENE), "found the scene files: %s" % [scenes])
	for scene_path: String in scenes:
		var lines: PackedStringArray = FileAccess.get_file_as_string(scene_path).split("\n")
		for line: String in lines:
			if line.begins_with("[node ") and not line.contains(" unique_id="):
				fail("%s has a node without unique_id: %s" % [scene_path, line])


func _find_scenes(dir_path: String, found: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		fail("cannot open %s" % dir_path)
		return
	for sub: String in dir.get_directories():
		if not sub.begins_with("."):
			_find_scenes(dir_path.path_join(sub), found)
	for file_name: String in dir.get_files():
		if file_name.ends_with(".tscn"):
			found.append(dir_path.path_join(file_name))
