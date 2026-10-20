class_name GoldenCodec
extends RefCounted
## Reads the golden JSON files of res://tests/golden (written by tools/gen_golden.mjs) and compares doubles bit for bit.
##
## Numbers never travel as JSON numbers (Godot's JSON parser and float literals are not correctly rounded, and JSON has no
## NaN, Infinity or -0): arrays are the base64 of little-endian bytes, single doubles are 16 hex digits of the bit pattern.

const GOLDEN_DIR: String = "res://tests/golden"

static var _cache: Dictionary = {}
static var _bb: PackedByteArray = _make_buffer()


static func _make_buffer() -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.resize(8)
	return b


## Parses res://tests/golden/<name>.json (cached). Returns an empty Dictionary and records an engine error if it fails.
static func load_json(name: String) -> Dictionary:
	if _cache.has(name):
		return _cache[name]
	var path: String = "%s/%s.json" % [GOLDEN_DIR, name]
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("cannot read %s (run: node tools/gen_golden.mjs)" % path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("%s is not a JSON object" % path)
		return {}
	var result: Dictionary = parsed
	_cache[name] = result
	return result


static func decode_f64(base64: String) -> PackedFloat64Array:
	return Marshalls.base64_to_raw(base64).to_float64_array()


static func decode_i32(base64: String) -> PackedInt32Array:
	return Marshalls.base64_to_raw(base64).to_int32_array()


## uint32 values as ints in [0, 2^32).
static func decode_u32(base64: String) -> PackedInt64Array:
	var signed: PackedInt32Array = Marshalls.base64_to_raw(base64).to_int32_array()
	var out: PackedInt64Array = PackedInt64Array()
	out.resize(signed.size())
	for i: int in range(signed.size()):
		out[i] = signed[i] & 0xFFFFFFFF
	return out


## Two uint32 halves of a double's bit pattern, formatted like the golden files: 16 lowercase hex digits.
static func hex_of(x: float) -> String:
	_bb.encode_double(0, x)
	return "%08x%08x" % [_bb.decode_u32(4), _bb.decode_u32(0)]


## The double that 16 hex digits of a bit pattern stand for.
static func from_hex(hex: String) -> float:
	_bb.encode_u32(4, hex.substr(0, 8).hex_to_int())
	_bb.encode_u32(0, hex.substr(8, 8).hex_to_int())
	return _bb.decode_double(0)


## Equal bit patterns, except that any NaN equals any NaN (the files store NaN canonically; engines differ in the payload).
static func same_double(a: float, b: float) -> bool:
	if is_nan(a):
		return is_nan(b)
	if is_nan(b):
		return false
	_bb.encode_double(0, a)
	var a_bits: int = _bb.decode_s64(0)
	_bb.encode_double(0, b)
	return a_bits == _bb.decode_s64(0)


## The input columns (doubles) of the input set that a vector of math.json names.
static func input_columns(golden: Dictionary, vector_name: String) -> Array[PackedFloat64Array]:
	var vector: Dictionary = (golden["vectors"] as Dictionary)[vector_name]
	var input_set: Dictionary = (golden["inputs"] as Dictionary)[vector["input"]]
	var columns: Array[PackedFloat64Array] = []
	if input_set["type"] != "f64":
		push_error("input set %s: only f64 columns are supported (type %s)" % [vector["input"], input_set["type"]])
		return columns
	for encoded: String in input_set["columns"]:
		columns.append(decode_f64(encoded))
	return columns
