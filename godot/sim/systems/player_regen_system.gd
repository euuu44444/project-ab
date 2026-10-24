class_name PlayerRegenSystem
extends SimSystem
## player/regen: applyPlayerRegen(dt). Natural regeneration plus the archivist bank's.


func _init(p_game: GameState) -> void:
	super(p_game, "applyPlayerRegen")


## # port: applyPlayerRegen. `totalRegen = (p.regen || 0) + archivistBankRegenPerSecond()`; the bank part is 0 for every
## character but the archivist (its bank count is 0), and the catalyst has no regen of its own. Healing itself
## (applyPlayerHealing with the meta recovery multiplier) is not ported: a positive total reports an error instead of
## being ignored.
func run(_dt: float) -> void:
	var p: PlayerState = game.player
	var bank_regen: float = 0.0
	if game.char_id == "archivist":
		push_error("PlayerRegenSystem: the archivist bank regeneration is not ported yet (M2)")
	var total_regen: float = (p.regen if p.regen != 0.0 else 0.0) + bank_regen
	if total_regen > 0.0 and p.hp > 0.0:
		push_error("PlayerRegenSystem: applyPlayerHealing is not ported yet (a regen source appeared)")
