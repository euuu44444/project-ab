class_name OracleSystem
extends SimSystem
## One slot of the test-only replay oracle (see ReplayOracle): wraps the slot's real system and lets the oracle act around it. SimTrace.attach()
## puts its TracedSystem OUTSIDE this wrapper, so the draws that the oracle adds for a placeholder are credited to the slot like real ones.
##
## run(): oracle.before_slot() (forced kills, in front of enemy/cleanup-2), the inner system, oracle.after_slot() (dry draws for a placeholder).
## when() and is_implemented() pass through, so the wrapper is invisible to SystemRunner.stub_slots() and the slot's `when` predicate.

var inner: SimSystem = null
var oracle: ReplayOracle = null
var slot_id: String = ""
var key: String = ""


func _init(p_inner: SimSystem, p_oracle: ReplayOracle, p_slot_id: String, p_key: String) -> void:
	super(p_inner.game, p_inner.original_function)
	inner = p_inner
	oracle = p_oracle
	slot_id = p_slot_id
	key = p_key


func run(dt: float) -> void:
	oracle.before_slot(slot_id)
	var before: int = game.rng.draws
	inner.run(dt)
	oracle.after_slot(slot_id, key, inner.is_implemented(), game.rng.draws - before)


func when() -> bool:
	return inner.when()


func is_implemented() -> bool:
	return inner.is_implemented()
