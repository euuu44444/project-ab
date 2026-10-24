class_name SeededRng
extends RefCounted
## Port of the game's makeSeededRandom(seed) (a mulberry32 variant), bit for bit.
##
## # port: makeSeededRandom
##   function makeSeededRandom(seed){let a=seed>>>0||2654435769;return function(){a|=0;a=a+1831565813|0;
##     let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296;};}
##
## Every output is exactly k / 2^32 for an integer k in [0, 2^32), so next_u32() gives the exact k and
## next_float() = k / 4294967296.0 (a division by a power of two: exact in 64-bit floats).
##
## Integer arithmetic. JavaScript keeps `a` and `t` as int32 values; here they are ints holding the sign-extended int32.
## `a + 1831565813 | 0` is a wrap to 32 bits, `Math.imul` is a 32-bit multiplication (the product of two int32 values fits in
## 64 bits), `x >>> n` is a shift of the unsigned 32-bit value, and XOR / OR of two sign-extended int32 values is again a
## sign-extended int32. The wrap ((v & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000 is written out inline: this is the hot
## path of the simulation (about thirty draws per step).

const DEFAULT_SEED_FALLBACK: int = 2654435769

## The generator state `a` as a sign-extended int32. Readable and writable, e.g. to snapshot a stream.
var state: int = 0


## `new_seed` follows `seed>>>0||2654435769`: it is reduced modulo 2^32 and 0 is replaced by 2654435769.
func _init(new_seed: int = 0) -> void:
	state = i32_of(normalize_seed(float(new_seed)))


## `seed>>>0||2654435769` for a JavaScript number: truncate toward zero, wrap modulo 2^32 (NaN and the infinities give 0),
## and replace 0 by 2654435769. Result in [1, 2^32).
static func normalize_seed(js_seed: float) -> int:
	var n: int = JsMath.to_uint32(js_seed)
	return n if n != 0 else DEFAULT_SEED_FALLBACK


static func i32_of(v: int) -> int:
	return ((v & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000


## Re-seeds the stream like makeSeededRandom(seed) does (the state restarts).
func set_seed(new_seed: int) -> void:
	state = i32_of(normalize_seed(float(new_seed)))


## The next output as the integer k in [0, 2^32): the value of makeSeededRandom's function is k / 4294967296.
func next_u32() -> int:
	var a: int = ((state + 1831565813) & 0xFFFFFFFF) ^ 0x80000000
	a -= 0x80000000
	state = a
	# t = Math.imul(a ^ a >>> 15, 1 | a)
	var x: int = a ^ ((a & 0xFFFFFFFF) >> 15)
	var t: int = (((x * (1 | a)) & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000
	# t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t
	var y: int = t ^ ((t & 0xFFFFFFFF) >> 7)
	var m: int = (((y * (61 | t)) & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000
	t = ((((t + m) & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000) ^ t
	# ((t ^ t >>> 14) >>> 0)
	return (t ^ ((t & 0xFFFFFFFF) >> 14)) & 0xFFFFFFFF


## The function returned by makeSeededRandom: a float in [0, 1).
func next_float() -> float:
	var a: int = ((state + 1831565813) & 0xFFFFFFFF) ^ 0x80000000
	a -= 0x80000000
	state = a
	var x: int = a ^ ((a & 0xFFFFFFFF) >> 15)
	var t: int = (((x * (1 | a)) & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000
	var y: int = t ^ ((t & 0xFFFFFFFF) >> 7)
	var m: int = (((y * (61 | t)) & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000
	t = ((((t + m) & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000) ^ t
	return float((t ^ ((t & 0xFFFFFFFF) >> 14)) & 0xFFFFFFFF) / 4294967296.0
