class_name EndRunSystem
extends SimSystem
## frame/end-run: endRun(false) once the knock-out animation is over (the slot's `when` is `koTimer <= 0`).
##
## Ported here: the state change and the squad bookkeeping of endRun - `game.ended = true`, `game.runWon = false`, `state = "ended"`,
## and the reset of the squad director (squads, supportReservations, openSquadId, squadDirectorClock, highThreatLockUntil). The
## per-enemy part of that reset (squadId, squadRole, squadTargetUntil, squadAttackAt, preferredSpecial) belongs to step S5, which
## adds those fields to the enemy. The rest of the original (best-score record, meta-progress result, audio, the result screen)
## is save/UI/meta bookkeeping that belongs to step S8.


func _init(p_game: GameState) -> void:
	super(p_game, "endRun")


## # port: endRun(win) with win = false
func run(_dt: float) -> void:
	if game.ended:
		return
	game.ended = true
	game.run_won = false
	game.state = GameState.RunState.ENDED
	game.squads.clear()
	game.support_reservations.clear()
	game.open_squad_id = 0
	game.squad_director_clock = 0.0
	game.high_threat_lock_until = 0.0


## The slot's predicate: `() => game.player.koTimer <= 0`
func when() -> bool:
	return game.player.ko_timer <= 0.0
