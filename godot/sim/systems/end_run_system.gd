class_name EndRunSystem
extends SimSystem
## frame/end-run: endRun(false) once the knock-out animation is over (the slot's `when` is `koTimer <= 0`).
##
## Ported here: the state change and the squad bookkeeping of endRun - `game.ended = true`, `game.runWon = win`, `state = "ended"`,
## the reset of the squad director (squads, supportReservations, openSquadId, squadDirectorClock, highThreatLockUntil) and its per-enemy
## part (squadId, squadRole, squadTargetUntil, squadAttackAt, preferredSpecial of every enemy). The rest of the original (best-score
## record, meta-progress result, audio, the result screen) is save/UI/meta bookkeeping that belongs to step S8.
##
## The slot calls it with win = false (the knock-out animation is over); updateWave calls it with win = true when the milestone-1
## prototype's last wave is over (WaveRules.M1_LAST_WAVE).


func _init(p_game: GameState) -> void:
	super(p_game, "endRun")


## # port: endRun(false)
func run(_dt: float) -> void:
	end_run(game, false)


## # port: endRun(win) (without the score record, the meta result, the audio and the result screen: steps S8)
static func end_run(g: GameState, win: bool) -> void:
	if g.ended:
		return
	g.ended = true
	g.run_won = win
	g.state = GameState.RunState.ENDED
	g.squads.clear()
	g.support_reservations.clear()
	g.open_squad_id = 0
	g.squad_director_clock = 0.0
	g.high_threat_lock_until = 0.0
	for e: EnemyState in g.enemies:
		e.squad_id = 0
		e.squad_role = "INDIVIDUAL"
		e.squad_target_until = 0.0
		e.squad_attack_at = 0.0
		e.preferred_special = ""


## The slot's predicate: `() => game.player.koTimer <= 0`
func when() -> bool:
	return game.player.ko_timer <= 0.0
