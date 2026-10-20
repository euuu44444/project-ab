class_name TracedSystem
extends SimSystem
## Wraps one slot of the update lists to credit the gameRandom draws that the slot makes: the port's counterpart of the wrapper
## that tools/reference-trace/hook.js puts around the run function of every slot of UPDATE_*_SYSTEMS in the original.
##
## SimTrace.attach() replaces `SystemSlot.system` of every slot by one of these, so the simulation code itself stays free of
## tracing. run(), when() and is_implemented() pass through; the draws (GameRng.draws before and after) are added to `sink`
## under the slot's key "<list>:<index>" ("intro:0", "main:15", "ko:4"), the key that the reference traces use.

var inner: SimSystem = null
var key: String = ""
## Shared by all wrappers of one SimTrace: key -> draws made by that slot since the sink was last cleared.
var sink: Dictionary = {}


func _init(p_inner: SimSystem, p_key: String, p_sink: Dictionary) -> void:
	super(p_inner.game, p_inner.original_function)
	inner = p_inner
	key = p_key
	sink = p_sink


func run(dt: float) -> void:
	var before: int = game.rng.draws
	inner.run(dt)
	var drawn: int = game.rng.draws - before
	if drawn != 0:
		sink[key] = int(sink.get(key, 0)) + drawn


func when() -> bool:
	return inner.when()


func is_implemented() -> bool:
	return inner.is_implemented()
