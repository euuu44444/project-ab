class_name FxRng
extends RefCounted
## The effects generator: fxRandom() / randFx / randiFx / chanceFx of the original (all Math.random there).
##
## # port: fxRandom, randFx, randiFx, chanceFx
##   function fxRandom(){return Math.random();}   function randFx(a,b){return a+fxRandom()*(b-a);}
##   function randiFx(a,b){return Math.floor(randFx(a,b+1));}   function chanceFx(p){return fxRandom()<p;}
##
## Effects (particles, bursts) must never influence the simulation, so they use their own generator, separate from GameRng:
## drawing from it never changes GameRng.draws. The original is not deterministic here (Math.random); this port is seedable so
## that headless runs and tests are reproducible. The stream is NOT the original's (there is none).

var _rng: SeededRng = SeededRng.new(0x9E3779B9)


func _init(new_seed: int = 0x9E3779B9) -> void:
	set_seed(new_seed)


func set_seed(new_seed: int) -> void:
	_rng.set_seed(new_seed)


## fxRandom(): a float in [0, 1).
func random() -> float:
	return _rng.next_float()


## randFx: a + fxRandom() * (b - a).
func rand_fx(a: float, b: float) -> float:
	return a + _rng.next_float() * (b - a)


## randiFx: Math.floor(randFx(a, b + 1)); both bounds inclusive.
func randi_fx(a: int, b: int) -> int:
	return int(floorf(float(a) + _rng.next_float() * (float(b + 1) - float(a))))


## chanceFx: fxRandom() < p.
func chance_fx(p: float) -> bool:
	return _rng.next_float() < p
