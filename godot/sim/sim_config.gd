class_name SimConfig
extends RefCounted
## Inputs of Sim.new_game: everything the original takes from its environment when a run starts.

## Seed of gameRandom (setGameSeed). Reduced like `seed>>>0`; 0 gives the same stream as 2654435769.
var rng_seed: int = 0
## Seed of the separate effects generator (FxRng). Effects never change the simulation, so any value will do.
var fx_seed: int = 0x9E3779B9
var character_id: String = "catalyst"
## "easy", "normal", "hard" or "nightmare"; anything else becomes "normal" like newGame does.
var difficulty: String = "normal"
## "normal" (the original calls it the standard mode) or "endless".
var mode: String = "normal"
## Size of the visible area in logical pixels (viewW / viewH). The original derives spawn distances from it; the
## reference traces use 390 x 844.
var view_w: float = 390.0
var view_h: float = 844.0
## IS_COARSE_POINTER: true on Android (touch) and selects the smaller entity caps.
var coarse_pointer: bool = true
## M1 supports the catalyst only; the state tests build every character with this set (stepping them is not supported).
var allow_unported_character: bool = false
