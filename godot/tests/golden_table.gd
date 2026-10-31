class_name GoldenTable
extends RefCounted
## Helpers for the table-shaped golden files of step S3 (formulas.json, sim_scripts.json, new_game.json): rows are strings of
## space separated tokens; a double is 16 hex digits of its bit pattern (see tools/golden/_defs_vm.mjs). Reading the file
## itself and comparing doubles is GoldenCodec (golden_codec.gd).

## Collects mismatches of one table and reports only the first few, so that a wrong formula does not print 450 lines.
class Mismatches extends RefCounted:
	const SHOWN: int = 6
	var count: int = 0
	var checked: int = 0
	var _messages: PackedStringArray = PackedStringArray()

	func add(message: String) -> void:
		count += 1
		if _messages.size() < SHOWN:
			_messages.append(message)

	func summary(what: String) -> String:
		return "%s: %d of %d checks differ. First: %s" % [what, count, checked, " | ".join(_messages)]


static func tokens(row: String) -> PackedStringArray:
	return row.split(" ", false)


static func f(token: String) -> float:
	return GoldenCodec.from_hex(token)


## Decimal text of a double for messages (17 significant digits) together with its bits.
static func show(x: float) -> String:
	return "%s [%s]" % [str(x), GoldenCodec.hex_of(x)]


## "0"/"1" -> bool
static func b(token: String) -> bool:
	return token == "1"
