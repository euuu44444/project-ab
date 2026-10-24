class_name TraceReader
extends RefCounted
## Reads a swarm-trace/1 file (tools/reference-trace/FORMAT.md): JSON Lines, gzip-compressed (a plain .jsonl works too).
##
## load_file() decompresses with PackedByteArray.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP), which accepts the standard
## gzip stream that Node's zlib writes (checked on Godot 4.7.2 with the committed traces, and again by
## tests/test_reference_trace.gd, which also reads a stream written by SimTrace.write_file). Godot's JSON parser returns every number as a float, so integers (n, draws, level, ids, counts
## ...) are coerced with as_int() where they are used; floats never travel as JSON numbers (16 hex digits of the IEEE-754 bit
## pattern, see SimTrace.hex_of), so nothing is lost to the parser.

## The parsed first line.
var header: Dictionary = {}
## The parsed step lines, in order (steps[0] is step n = 1).
var steps: Array[Dictionary] = []
var path: String = ""
## Size of the file as read and after decompression.
var file_bytes: int = 0
var raw_bytes: int = 0


## Reads and parses a trace. Returns null (after push_error) when the file is missing, not a trace or damaged.
static func load_file(file_path: String) -> TraceReader:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(file_path)
	if bytes.is_empty():
		push_error("TraceReader: cannot read %s" % file_path)
		return null
	var reader: TraceReader = TraceReader.new()
	reader.path = file_path
	reader.file_bytes = bytes.size()
	var raw: PackedByteArray = bytes
	if bytes.size() >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b:
		raw = bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
		if raw.is_empty():
			push_error("TraceReader: %s is not a valid gzip stream" % file_path)
			return null
	reader.raw_bytes = raw.size()
	var lines: PackedStringArray = raw.get_string_from_utf8().split("\n", false)
	if lines.is_empty():
		push_error("TraceReader: %s is empty" % file_path)
		return null
	var head: Variant = JSON.parse_string(lines[0])
	if not (head is Dictionary):
		push_error("TraceReader: the first line of %s is not a JSON object" % file_path)
		return null
	reader.header = head
	if reader.header.get("format", "") != SimTrace.FORMAT:
		push_error("TraceReader: %s has format %s, expected %s" % [file_path, reader.header.get("format", "<none>"), SimTrace.FORMAT])
		return null
	reader.steps.resize(lines.size() - 1)
	for i: int in range(1, lines.size()):
		var row: Variant = JSON.parse_string(lines[i])
		if not (row is Dictionary):
			push_error("TraceReader: line %d of %s is not a JSON object" % [i + 1, file_path])
			return null
		reader.steps[i - 1] = row
	return reader


## The "name:type" entries of a group of the header, as parsed fields: Array of [name, type].
func field_specs(group: String) -> Array[PackedStringArray]:
	var out: Array[PackedStringArray] = []
	var entries: Array = (header.get("fields", {}) as Dictionary).get(group, [])
	for entry: Variant in entries:
		out.append(split_spec(String(entry)))
	return out


## Index of the field `field_name` in the rows of `group`, or -1 when the trace does not carry it.
func field_index(group: String, field_name: String) -> int:
	var entries: Array = (header.get("fields", {}) as Dictionary).get(group, [])
	for i: int in range(entries.size()):
		if split_spec(String(entries[i]))[0] == field_name:
			return i
	return -1


## The key of a slot in "slot_draws" ("main:29"), from the header's slot lists; "" when no slot of that list has that id.
## `list_name` is "intro", "main" or "ko"; `slot_id` is the original's id, for example "projectile/player".
func slot_key(list_name: String, slot_id: String) -> String:
	var ids: Array = (header.get("slots", {}) as Dictionary).get(list_name, [])
	for i: int in range(ids.size()):
		if String(ids[i]) == slot_id:
			return "%s:%d" % [list_name, i]
	return ""


## The gameRandom draws that the slot `key` made in the step with 0-based index `step_index` (0 when it made none).
## Step S5 uses this to make the placeholders of projectile/player and enemy/cleanup-2 draw the recorded number of values.
func slot_draws(step_index: int, key: String) -> int:
	return int((steps[step_index]["slot_draws"] as Dictionary).get(key, 0))


## The ids of the enemies at the end of the step with 0-based index `step_index`, in the game's array order.
func enemy_ids(step_index: int) -> Array[int]:
	var out: Array[int] = []
	if step_index < 0 or step_index >= steps.size():
		return out
	var id_i: int = field_index("enemy", "id")
	if id_i < 0:
		return out
	for row: Variant in (steps[step_index]["enemies"] as Array):
		out.append(int((row as Array)[id_i]))
	return out


## The ids that are in the enemy list at the end of step `step_index - 1` and not at the end of step `step_index`, in the order of
## the earlier list (nothing before the first step). In the committed traces every one of them is a kill: removals and the final
## wave.kills agree, and at most one enemy goes per step. Step S5 uses this to follow the reference past the first kill while the
## weapons and damage of step S6 are missing: mark these enemies dead in the port before its cleanup slot runs and let the port's
## own cleanupDeadEnemies remove them (the order of the list then comes out as the reference's, see next_enemy_order()).
func removed_enemy_ids(step_index: int) -> Array[int]:
	var out: Array[int] = []
	if step_index <= 0:
		return out
	var now: Array[int] = enemy_ids(step_index)
	for id: int in enemy_ids(step_index - 1):
		if not now.has(id):
			out.append(id)
	return out


## The ids at the end of step `step_index` that were not in the list at the end of the step before, in ascending order (the order
## in which spawnEnemy created them: ids come from the counter game.nextEnemyId). At step 0 every enemy is new.
func spawned_enemy_ids(step_index: int) -> Array[int]:
	var out: Array[int] = []
	var before: Array[int] = enemy_ids(step_index - 1)
	for id: int in enemy_ids(step_index):
		if not before.has(id):
			out.append(id)
	out.sort()
	return out


## The order of the enemy list after a step, from the order before it: the spawned enemies are appended at the end (ascending ids,
## spawnEnemy pushes), then cleanupDeadEnemies walks the list from the last index to the first and removes every dead enemy by the
## swap-pop of killEnemy (`last = list.pop(); if (i < list.length) list[i] = last`). That is the original's behaviour, and it
## reproduces the reference list at every step of every committed trace (tests/test_reference_trace.gd checks it), so a port that
## removes the same enemies by the same rule keeps the reference's order. `removed` is a set of ids; their order does not matter.
static func next_enemy_order(before: Array[int], spawned: Array[int], removed: Array[int]) -> Array[int]:
	var list: Array[int] = before.duplicate()
	list.append_array(spawned)
	var i: int = list.size() - 1
	while i >= 0:
		if removed.has(list[i]):
			var last: int = list.pop_back()
			if i < list.size():
				list[i] = last
		i -= 1
	return list


## "xpNext:f" -> ["xpNext", "f"].
static func split_spec(spec: String) -> PackedStringArray:
	var at: int = spec.rfind(":")
	return PackedStringArray([spec.substr(0, at), spec.substr(at + 1)])


## JSON numbers arrive as floats; this is the integer they stand for.
static func as_int(value: Variant) -> int:
	return int(value)
