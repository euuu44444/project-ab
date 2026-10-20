extends SceneTree
## Writes the port's trace for the run of a reference trace: same seed, character, difficulty, mode and view, and the reference's
## input of every step replayed through Sim (SimTrace.replay). Run it with tools/emit_port_trace.sh, which prepares the
## toolchain; by hand:
##
##   godot --headless --path godot -s res://tests/trace/emit_port_trace.gd -- <reference.jsonl.gz> <out.jsonl.gz> [until-step]
##
## The output is a swarm-trace/1 file whose header lists the fields the port has ("fields") and the ones it has not ("unported");
## tools/compare_trace.mjs compares it with the reference. A reference of the long-run variant is replayed with the overrides of
## its header (SimTrace.apply_overrides). Exit code 0 on success, 1 on a usage or file error.


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2 or args.size() > 3:
		printerr("usage: emit_port_trace.gd -- <reference.jsonl.gz> <out.jsonl[.gz]> [until-step]")
		quit(1)
		return
	var until_step: int = int(args[2]) if args.size() == 3 else 0
	var reference: TraceReader = TraceReader.load_file(args[0])
	if reference == null:
		quit(1)
		return
	var started: int = Time.get_ticks_msec()
	var result: Dictionary = SimTrace.replay(reference, until_step)
	if result.is_empty():
		printerr("emit_port_trace: the sim could not start the run of %s" % args[0])
		quit(1)
		return
	var rows: Array = result["rows"]
	if not SimTrace.write_file(args[1], result["header"], rows):
		quit(1)
		return
	print("emit_port_trace: %d steps of %s (seed %d, %s) -> %s in %d ms" % [
		rows.size(), args[0].get_file(), int(reference.header["seed"]), String(reference.header["input_script"]["name"]),
		args[1], Time.get_ticks_msec() - started,
	])
	quit(0)
