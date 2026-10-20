class_name StubSystem
extends SimSystem
## A slot that does nothing yet. Every one of them is documented: which step ports it, and why doing nothing is right
## (or at least harmless) for the M1 configuration until then.
##
## consumes_rng_in_m1 marks the stubs whose original draws from gameRandom in the M1 configuration (catalyst, normal
## difficulty, standard mode, waves 1-4): wave/progress, enemy/update (contact damage), projectile/player and
## enemy/cleanup-2. Until their step lands the port's draw count differs from the original's; the other stubs consume
## nothing in M1, so leaving them out keeps the count exact. The set is not hand-typed knowledge: tools/census_rng_slots_chromium.mjs
## runs the original in Chromium, credits every draw to the running slot and fails when the marked slots and the slots that
## drew differ (output: verification/godot/s3/rng_slots.txt; the per-slot numbers are in the header of system_runner.gd).

## The step that ports it ("S5", "S6", "S8"), or "none" for slots that cannot matter in M1.
var owner_step: String = "none"
var reason: String = ""
var consumes_rng_in_m1: bool = false
## True for the one slot whose `when` is mikoActive() (character/miko-barrier).
var when_miko_active: bool = false


func _init(p_game: GameState, p_original_function: String, p_owner_step: String, p_reason: String, p_consumes_rng_in_m1: bool = false) -> void:
	super(p_game, p_original_function)
	owner_step = p_owner_step
	reason = p_reason
	consumes_rng_in_m1 = p_consumes_rng_in_m1


func is_implemented() -> bool:
	return false


## # port: mikoActive (the only `when` of a placeholder): `!!(game && game.char?.id === "miko" && game.miko)`
func when() -> bool:
	if when_miko_active:
		return game.char_id == "miko" and game.miko != null
	return true
