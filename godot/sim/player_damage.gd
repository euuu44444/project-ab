class_name PlayerDamage
extends RefCounted
## What happens to the player when something hurts it: hurtPlayer with calculateIncomingPlayerDamage, the hit effect (spawnPlayerHitFx) and
## the floating damage number (showDamageNumber). Used by the contact damage of enemy/update (step S5); hazards and enemy projectiles (M2) go
## through the same function.
##
## Two things in here touch the simulation beyond the player's hp: the damage flash (`game.damageFlash`), and the floating number, which
## draws THREE values from gameRandom (its jitter) - those draws are why enemy/update shows up in slot_draws. The particles themselves (the number,
## the hit ring and spokes) belong to the effects layer (step S7) and use FxRng only; see show_damage_number.
##
## Left out, because the catalyst of M1 has nothing there (each reports with push_error if a configuration could reach it):
##   the miko's barrier and shield, the sentinel's guard, the berserker's frenzy and defense, the striker's brace, the arcanist's stacks, the
##   archivist's defense, takenDamageBonus (the striker, harmonizer and pathfinder), contract burn and poison.
##   metaAbilityOnPlayerDamage / metaTrialEvent: trial bookkeeping and meta abilities (specials.metaActive is empty in M1); no simulation effect.
##   audio.playerHit: sound only.

## damageLabelParticleLimit(): `ecoVisuals() ? 560 : 1100`. The reference traces are not eco; the port has no quality tiers yet (S7).
const DAMAGE_LABEL_PARTICLE_LIMIT: int = 1100
## spawnPlayerHitFx: `game.damageFlash = Math.max(game.damageFlash || 0, 0.34)`
const HIT_FLASH: float = 0.34


## # port: hurtPlayer (for `opts = {enemyHit, enemyDamageMultiplier}`, the contact hit). `enemy_damage_multiplier` NAN stands for an absent
## option (the multiplier is then 1). Returns the hp the player actually lost.
static func hurt_player(game: GameState, raw_amount: float, enemy_hit: bool, enemy_damage_multiplier: float) -> float:
	var p: PlayerState = game.player
	var incoming: float = calculate_incoming_player_damage(game, raw_amount, enemy_damage_multiplier)
	_guard_other_characters(game)
	if SimUtil.or_zero(p.miko_shield) > 0.0:
		push_error("PlayerDamage.hurt_player: the miko's shield is not ported (M2)")
	var hp_before: float = JsMath.js_max(0.0, p.hp)
	var dealt: float = JsMath.js_min(JsMath.js_max(0.0, incoming), hp_before)
	if dealt > 0.0:
		p.hp = JsMath.js_max(0.0, hp_before - dealt)
	var actual_hp_damage: float = JsMath.js_max(0.0, hp_before - p.hp)
	if game.specials.meta_active.size() > 0:
		push_error("PlayerDamage.hurt_player: meta abilities that react to damage taken (metaAbilityOnPlayerDamage) are not ported (M2)")
	if actual_hp_damage <= 0.0:
		return 0.0
	if enemy_hit:
		spawn_player_hit_fx(game)
	show_damage_number(game, actual_hp_damage, false)  # the returned jitter belongs to the effects layer (S7)
	if SimUtil.truthy(game.contracts.get("unquenchableFire", false)):
		push_error("PlayerDamage.hurt_player: the unquenchable fire contract (burn and poison on the player) is not ported (M2)")
	return actual_hp_damage


## # port: calculateIncomingPlayerDamage. `base * enemyMul * abilityMul * takenMul * defenseMul * finalTakenMul`, left to right, with the
## multipliers of the catalyst: the enemy's (absent -> 1), 1 for the ability, 1 + takenBonus (0), 1 - defense, 1 for the berserker's cut.
## Returns calculatedDamage (the other fields of the original's result object are for the HUD and the metrics).
static func calculate_incoming_player_damage(game: GameState, raw_amount: float, enemy_damage_multiplier: float) -> float:
	var safe_base: float = JsMath.js_max(0.0, raw_amount) if is_finite(raw_amount) else 0.0
	var source_mul: float = JsMath.js_max(0.0, enemy_damage_multiplier) if is_finite(enemy_damage_multiplier) else 1.0
	var ability_mul: float = 1.0
	var taken_bonus: float = 0.0  # finiteDamageBonus(player.takenDamageBonus) + finiteDamageBonus(opts.takenDamageBonus): neither exists for the catalyst
	if game.striker != null or game.harmonizer != null or game.pathfinder != null or (game.char_id == "miko" and game.miko != null):
		push_error("PlayerDamage.calculate_incoming_player_damage: the damage taken bonuses of the miko, striker, harmonizer and pathfinder are not ported (M2)")
	var taken_mul: float = JsMath.js_max(0.0, 1.0 + taken_bonus)
	var defense: float = effective_player_defense(game)
	var defense_mul: float = JsMath.js_max(0.0, 1.0 - defense)
	var final_taken_mul: float = 1.0  # berserkerFinalDamageTakenMul(): 1 unless the berserker is active
	var calculated: float = safe_base * source_mul * ability_mul * taken_mul * defense_mul * final_taken_mul
	if not is_finite(calculated) or calculated < 0.0:
		calculated = 0.0
	return calculated


## # port: effectivePlayerDefense. `clamp((p.defense || 0) + (p.hazardDefenseBonus || 0), PLAYER_DEFENSE_MIN, PLAYER_DEFENSE_MAX)` (not finite -> 0).
static func effective_player_defense(game: GameState) -> float:
	var p: PlayerState = game.player
	var rules: SimRules = Defs.rules()
	var defense: float = SimUtil.or_zero(p.defense) + SimUtil.or_zero(p.hazard_defense_bonus)
	return JsMath.clamp(defense if is_finite(defense) else 0.0, rules.player_defense_min, rules.player_defense_max)


## # port: spawnPlayerHitFx. The hit ring and the spokes are particles (FxRng draws, effects layer, step S7); the one simulation state it writes is
## the damage flash that the screen shows.
static func spawn_player_hit_fx(game: GameState) -> void:
	# TODO(S7): ringFx(p.x, p.y, "#ff7582", 5, 34, 0.16, 3) and spokesFx(p.x, p.y, "#ff8c96", 6, 3, 28, 0.12, 2): two and one FxRng values
	game.damage_flash = JsMath.js_max(SimUtil.or_zero(game.damage_flash), HIT_FLASH)


## # port: showDamageNumber (the part that touches gameRandom). A number is shown for a finite amount above 0.04 while the particle list is
## below damageLabelParticleLimit(); its jitter then draws, in the order of the original's object literal, `x: x + side + rand(-3, 3)`,
## `vx: targetId != null ? rand(-2.5, 2.5) : rand(-5, 5)` and `vy: -31 - rand(0, 7)`: three values. `has_target` is `targetId != null` (a number
## above an enemy, step S6; the player's own number has no target). A reaction text (merging, lanes) never occurs for these numbers.
##
## The number is a particle (damageText) of the effects layer (step S7); this function only makes the draws, and returns the three values the
## particle takes from them, [x jitter, vx, vy] (an empty array when no number is shown), so that the effects layer has them and the tests can
## check the order and the ranges.
##
## The gate and the port's particles. The gate reads game.particles.size(), which is 0 in the port until the effects layer exists (step S7), so
## the gate is open and the number always draws its three values. That is also what the original does in every reference trace: its particle
## count stays below 560 (the eco limit; the normal limit is 1100) at every step of every trace, which test_reference_trace.gd asserts for each
## committed trace (counts.particles), so a limit that closes never shows up in them. When the effects layer fills game.particles, its count has
## to be the original's whenever it comes near the limit, because a gate that closes changes the draws of gameRandom.
static func show_damage_number(game: GameState, amount: float, has_target: bool) -> PackedFloat64Array:
	var drawn: PackedFloat64Array = PackedFloat64Array()
	if not is_finite(amount) or amount <= 0.04 or game.particles.size() >= DAMAGE_LABEL_PARTICLE_LIMIT:
		return drawn
	drawn.append(game.rng.rand(-3.0, 3.0))
	if has_target:
		drawn.append(game.rng.rand(-2.5, 2.5))
	else:
		drawn.append(game.rng.rand(-5.0, 5.0))
	drawn.append(-31.0 - game.rng.rand(0.0, 7.0))
	return drawn


## The parts of hurtPlayer that only the other characters have: reported when a configuration reaches them.
static func _guard_other_characters(game: GameState) -> void:
	if game.char_id != "catalyst":
		push_error("PlayerDamage.hurt_player: the damage hooks of '%s' (miko barrier, sentinel guard, berserker frenzy, striker brace, arcanist stacks, archivist defense) are not ported (M2)" % game.char_id)
