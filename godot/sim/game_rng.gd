class_name GameRng
extends RefCounted
## The game's gameRandom() with its draw counter and the helpers built on it (rand, randi, chance, shuffle, the index idiom).
##
## # port: setGameSeed, rand, randi, chance, shuffle (original.html)
##   function setGameSeed(seed){gameRandomSeed=seed==null?null:seed>>>0;gameRandomDraws=0;const base=seed==null?Math.random:makeSeededRandom(seed>>>0);
##     gameRandom=()=>{gameRandomDraws++;return base();};}
##   function rand(a,b){return a+gameRandom()*(b-a);}   function randi(a,b){return Math.floor(rand(a,b+1));}
##   function chance(p){return gameRandom()<p;}
##   function shuffle(a){for(let i=a.length-1;i>0;i--){const j=gameRandom()*(i+1)|0;[a[i],a[j]]=[a[j],a[i]];}return a;}
##
## The ORDER and the NUMBER of draws are what the reference traces compare (gameRandomDraws), so every helper draws exactly
## as often as its JavaScript original: rand, randi, chance and index() draw once, shuffle() draws once per swap position
## (a.length - 1 times), random() draws once. Arguments are evaluated before the draw, as in JavaScript.
##
## The null-seed path of setGameSeed (an unseeded Math.random) does not exist here: the simulation always runs from a seed.
## Effects that the original draws from Math.random (fxRandom) use FxRng, a separate generator that never changes `draws`.

## The number of gameRandom() calls since the last set_seed (gameRandomDraws).
var draws: int = 0
## The seed as the game keeps it (`seed>>>0`, gameRandomSeed).
var seed_value: int = 0

var _rng: SeededRng = SeededRng.new(0)


## `new_seed` can be any int; like setGameSeed it is reduced with `seed>>>0` (and 0 means the same stream as 2654435769).
func _init(new_seed: int = 0) -> void:
	set_seed(new_seed)


## # port: setGameSeed (seeded path). Restarts the stream and the draw counter.
func set_seed(new_seed: int) -> void:
	seed_value = JsMath.to_uint32(float(new_seed))
	draws = 0
	_rng.set_seed(new_seed)


## gameRandom(): a float in [0, 1); counts one draw.
func random() -> float:
	draws += 1
	return _rng.next_float()


## # port: rand. a + gameRandom() * (b - a); one draw.
func rand(a: float, b: float) -> float:
	draws += 1
	return a + _rng.next_float() * (b - a)


## # port: randi. Math.floor(rand(a, b + 1)); one draw. The bounds are integers; both are inclusive.
func randi(a: int, b: int) -> int:
	draws += 1
	return int(floorf(float(a) + _rng.next_float() * (float(b + 1) - float(a))))


## # port: chance. gameRandom() < p; one draw, also for p <= 0, p >= 1 and NaN.
func chance(p: float) -> bool:
	draws += 1
	return _rng.next_float() < p


## The idiom `gameRandom() * length | 0` (for example `pool[gameRandom() * pool.length | 0]`): an index in [0, length). One draw.
func index(length: int) -> int:
	draws += 1
	return JsMath.to_int32(_rng.next_float() * float(length))


## # port: shuffle. Fisher-Yates in place from the end, like the original; returns the array. Draws a.size() - 1 times
## (not at all for arrays of 0 or 1 elements).
func shuffle(a: Array) -> Array:
	var i: int = a.size() - 1
	while i > 0:
		draws += 1
		var j: int = int(_rng.next_float() * float(i + 1))  # in [0, i], so int() is the same as `| 0`
		var tmp: Variant = a[i]
		a[i] = a[j]
		a[j] = tmp
		i -= 1
	return a
