class_name SystemRunner
extends RefCounted
## The ordered update lists of the original (UPDATE_INTRO_SYSTEMS 5 slots, UPDATE_MAIN_SYSTEMS 43, UPDATE_KO_SYSTEMS 5) and
## the loop that runs them (update, runSystems). The ids, phases and order are the original's; tests/test_new_game.gd compares
## them with tests/golden/new_game.json, which lists the original's own arrays.
##
## Slots of step S3 are real (clock, day cycle, reaction buffs, movement, camera, screen flash, regen guard, KO motion, end
## of run). All other slots are StubSystem placeholders that say which step ports them and why doing nothing is right for
## the M1 configuration until then. Stubs that draw from gameRandom in the original are marked (consumes_rng_in_m1), because
## the port's draw count only matches the original's after their step.
##
## Which slots draw in M1 (catalyst, normal, standard, 390x844, IS_COARSE_POINTER), measured in Chromium 141 with a wrapper
## around gameRandom that credits each draw to the running slot (tools/census_rng_slots_chromium.mjs; evidence in
## verification/godot/s3/rng_slots.txt). Draws up to the first level-up (frame 834) for seed 424242 with the design 9.2 input
## (stick held in 8 directions, 60 steps each): wave/progress 588, projectile/player 210, enemy/cleanup-2 26, enemy/update 6,
## weapon/update 0:
##   wave/progress     S5  the director: 3-4 values per 0.1 s tick, 9 per spawned enemy
##   enemy/update      S5  contact damage: hurtPlayer -> showDamageNumber draws 3 values per hit (x rand(-3,3), vx rand(-5,5),
##                         vy rand(0,7), in that order; skipped when game.particles.length >= damageLabelParticleLimit()). The same
##                         code pushes the player 22 px away (writes player.x/y), lowers hp and sets the damage flash. First hit:
##                         frame 586 for seed 424242 (moving), which is where the port's player position leaves the original's.
##                         All 6 / 33 / 33 / 30 / 33 draws of the measured runs are showDamageNumber's triples; a static reading
##                         of updateEnemies also reaches killEnemy and enemyAiThinkDelay, which no measured run exercised.
##   projectile/player S6  hits: showDamageNumber (3 per hit), calculateDamage -> chance (crit), handleSignatureProjectileHit -> chance
##   enemy/cleanup-2   S5  killEnemy -> spawnXp (the XP orb); other draws of killEnemy (the drop chance) were not observed
## weapon/update drew NOTHING in any measured run, and reading fireWeapon shows why for the M1 weapons (catalytic ring, pulse,
## blades, wand): its own rand call is in the shotgun branch only and createWeaponHazard is reached from the mine / mortar
## branches only; those weapons only spawn projectiles (the ring's hits draw in projectile/player). So it is not marked. Other
## weapon styles (shotgun, mine, mortar, melee arcs, other characters' signature weapons) can draw; the M1 trace does not use them.
##
## Consequence for the trace comparison (S5 before S6): projectile/player (S6) and enemy/cleanup-2 start to draw at frame 63-75
## and 109-154 (four measured runs), long before the first level-up (frames 786-2266), and every later director tick would read
## shifted values. Rule: S4's trace tool records the draws per slot per step (a gameRandom wrapper keyed by the running slot id);
## S5 makes the placeholders of projectile/player and enemy/cleanup-2 consume the recorded number of draws at each step (so the
## stream stays aligned) and ports showDamageNumber's three draws together with updateEnemies' contact path. S5's bit-exact
## acceptance then holds up to the first level-up; the stub replay is removed when S6 ports those slots.

const PHASE_FRAME: String = "frame"
const PHASE_PLAYER: String = "player"
const PHASE_CHARACTER: String = "character"
const PHASE_WAVE: String = "wave"
const PHASE_INDEX: String = "index"
const PHASE_ENEMY: String = "enemy"
const PHASE_ABILITY: String = "ability"
const PHASE_WEAPON: String = "weapon"
const PHASE_PROJECTILE: String = "projectile"
const PHASE_DAMAGE: String = "damage"
const PHASE_PICKUP: String = "pickup"
const PHASE_FX: String = "fx"
const PHASE_HUD: String = "hud"

## dt is clamped to this in update(): `Math.min(dt, 1/30)`.
const MAX_UPDATE_DT: float = 1.0 / 30.0

var game: GameState = null
var intro: Array[SystemSlot] = []
var main: Array[SystemSlot] = []
var ko: Array[SystemSlot] = []


func _init(p_game: GameState) -> void:
	game = p_game
	_build_intro()
	_build_ko()
	_build_main()


## # port: update(dt). Runs the intro list, then the knock-out list (while the KO timer runs) or the main list.
func update(dt: float) -> void:
	if game == null or game.state != GameState.RunState.PLAYING:
		return
	dt = JsMath.js_max(0.0, JsMath.js_min(dt, MAX_UPDATE_DT)) if is_finite(dt) else 0.0
	run_systems(intro, dt, false)
	if game.player.ko_timer > 0.0:
		run_systems(ko, dt, false)
		return
	run_systems(main, dt, true)


## # port: runSystems. With stop_on_combat_exit (the main list) the loop stops before a slot when the state is no longer
## "playing", and a dead player is knocked out and ends the step.
func run_systems(list: Array[SystemSlot], dt: float, stop_on_combat_exit: bool = false) -> void:
	for slot: SystemSlot in list:
		if stop_on_combat_exit:
			if game.state != GameState.RunState.PLAYING:
				break
			if not game.is_player_alive():
				game.enter_knock_out_if_dead()
				break
		if slot.has_when and not slot.system.when():
			continue
		slot.system.run(dt)


## The slots of all three lists that are still placeholders.
func stub_slots() -> Array[SystemSlot]:
	var out: Array[SystemSlot] = []
	for list: Array[SystemSlot] in [intro, main, ko]:
		for slot: SystemSlot in list:
			if not slot.system.is_implemented():
				out.append(slot)
	return out


# --- list construction ----------------------------------------------------------------------------------------------

func _slot(list: Array[SystemSlot], id: String, phase: String, system: SimSystem, has_when: bool = false) -> void:
	list.append(SystemSlot.new(id, phase, system, has_when))


func _stub(list: Array[SystemSlot], id: String, phase: String, original_function: String, owner_step: String,
		reason: String, consumes_rng: bool = false, miko_when: bool = false) -> void:
	var stub: StubSystem = StubSystem.new(game, original_function, owner_step, reason, consumes_rng)
	stub.when_miko_active = miko_when
	list.append(SystemSlot.new(id, phase, stub, miko_when))


func _build_intro() -> void:
	_slot(intro, "frame/clock", PHASE_FRAME, FrameClockSystem.new(game))
	_slot(intro, "frame/day-cycle", PHASE_FRAME, DayCycleSystem.new(game))
	_stub(intro, "frame/ambient", PHASE_FRAME, "refreshAmbientState", "S7",
		"derives the ambient tint from the day phase into render-only state (ambientState); no game state")
	_stub(intro, "hud/hp-ghost", PHASE_HUD, "updateHudGhostState", "S8",
		"the HP bar's trailing ghost (game.hpGhost); HUD only")
	_stub(intro, "hud/message-expiry", PHASE_HUD, "expireHudMessage", "S8",
		"fades the centre message when game.messageUntil has passed; UI only")


func _build_ko() -> void:
	_slot(ko, "player/ko-motion", PHASE_PLAYER, KoMotionSystem.new(game))
	_stub(ko, "fx/particles", PHASE_FX, "updateParticles", "S6",
		"moves and expires particles; there are none before S6")
	_slot(ko, "fx/screen-flash", PHASE_FX, ScreenFlashSystem.new(game))
	_stub(ko, "hud/update", PHASE_HUD, "updateHud", "S8", "writes the HUD from the settled state; no game state")
	_slot(ko, "frame/end-run", PHASE_FRAME, EndRunSystem.new(game), true)


func _build_main() -> void:
	var m: Array[SystemSlot] = main
	_stub(m, "character/berserker", PHASE_CHARACTER, "updateBerserker", "none", "returns at once unless the character is the berserker")
	_stub(m, "character/sentinel", PHASE_CHARACTER, "updateSentinel", "none", "returns at once unless the character is the sentinel")
	_slot(m, "player/reaction-buffs", PHASE_PLAYER, ReactionBuffsSystem.new(game))
	_slot(m, "player/movement", PHASE_PLAYER, PlayerMovementSystem.new(game))
	_slot(m, "player/camera", PHASE_PLAYER, CameraFollowSystem.new(game))
	_stub(m, "wave/progress", PHASE_WAVE, "updateWave", "S5",
		"wave clock, spawn budget and the director (createEnemyFieldSpawnPlan draws 3-4 values on every 0.1 s tick, spawnEnemy 9 per enemy)", true)
	_stub(m, "index/enemy-by-id", PHASE_INDEX, "rebuildEnemyIndex", "S5", "id index of the enemies")
	_stub(m, "index/separation-1", PHASE_INDEX, "rebuildEnemySeparationGrid", "S5", "broad phase 1 of the enemy spatial grid")
	_stub(m, "damage/root-link-reset", PHASE_DAMAGE, "resetRootLinkDamageQueue", "none", "clears a queue that nothing fills in M1 (ranger root links)")
	_stub(m, "weapon/hazards", PHASE_WEAPON, "updateHazards", "none", "loops game.hazards, which stays empty in M1 (no element hazards)")
	_stub(m, "enemy/cleanup-1", PHASE_ENEMY, "cleanupDeadEnemies", "S5",
		"removes enemies killed by hazards; with no hazards nothing is killed here (killEnemy would draw)")
	_stub(m, "character/archivist-records", PHASE_CHARACTER, "updateArchivistRecords", "none", "returns at once without archivist records")
	_stub(m, "character/archivist-bank", PHASE_CHARACTER, "syncArchivistBankMaxHp", "none", "returns at once unless the character is the archivist")
	_stub(m, "character/miko-barrier", PHASE_CHARACTER, "updateMikoBarrier", "none", "runs only for the miko (its `when` is mikoActive())", false, true)
	_stub(m, "enemy/squads", PHASE_ENEMY, "updateNightmareSquads", "S5", "returns at once unless the difficulty is nightmare")
	_stub(m, "enemy/update", PHASE_ENEMY, "updateEnemies", "S5",
		"individual AI, steering, movement and contact damage: hurtPlayer -> showDamageNumber draws 3 values per hit, and the hit pushes the player 22 px (writes player x/y), lowers hp and sets damageFlash", true)
	_stub(m, "enemy/ground-attacks", PHASE_ENEMY, "updateEnemyGroundAttacks", "S5", "returns at once while the list of ground attacks is empty")
	_stub(m, "index/separation-2", PHASE_INDEX, "rebuildEnemySeparationGrid", "S5", "broad phase 2: the enemies' final positions")
	_stub(m, "character/striker", PHASE_CHARACTER, "updateStriker", "none", "returns at once unless the character is the striker")
	_stub(m, "character/harmonizer", PHASE_CHARACTER, "updateHarmonizer", "none", "returns at once unless the character is the harmonizer")
	_stub(m, "character/harmony-fields", PHASE_CHARACTER, "updateHarmonyResonanceFields", "none", "returns at once unless the character is the harmonizer")
	_stub(m, "character/pathfinder", PHASE_CHARACTER, "updatePathfinder", "none", "returns at once unless the character is the pathfinder")
	_stub(m, "character/ranger-catalyst", PHASE_CHARACTER, "rangerAutoCatalystUpdate", "none", "returns at once unless the character is the ranger")
	_stub(m, "ability/update", PHASE_ABILITY, "abilityUpdate", "none",
		"the catalyst's abilities (cat_haste decay, cat_core) all have rank 0 in M1, so nothing happens")
	_stub(m, "ability/meta-progression", PHASE_ABILITY, "updateMetaProgression", "none",
		"trial timers and notifications only (specials.metaActive is empty); no game state, no gameRandom")
	_stub(m, "weapon/update", PHASE_WEAPON, "updateWeapons", "S6",
		"weapon cooldowns and firing; the M1 weapons (pulse, blades, wand, catalytic ring) only spawn projectiles and draw nothing here (rand is in fireWeapon's shotgun branch only, createWeaponHazard in mine and mortar)")
	_stub(m, "weapon/signature-actions", PHASE_WEAPON, "updateSignatureActions", "S6",
		"queued signature actions; whether the catalytic ring queues any is still to be checked in S6")
	_stub(m, "weapon/turrets", PHASE_WEAPON, "updateTurrets", "S6", "no turrets in M1; it also trims the projectile list to its cap")
	_stub(m, "weapon/saplings", PHASE_WEAPON, "updateSaplings", "none", "the list of saplings stays empty in M1 (ranger/wood)")
	_stub(m, "projectile/player", PHASE_PROJECTILE, "updateProjectiles", "S6", "player projectile movement and hits (damage numbers and crits draw)", true)
	_stub(m, "damage/root-link-flush", PHASE_DAMAGE, "flushRootLinkDamage", "none", "returns at once while the root-link queue is empty")
	_stub(m, "enemy/cleanup-2", PHASE_ENEMY, "cleanupDeadEnemies", "S5",
		"removes the enemies that weapons and projectiles killed (killEnemy -> spawnXp draws for the XP orb)", true)
	_stub(m, "projectile/enemy", PHASE_PROJECTILE, "updateEnemyProjectiles", "S5",
		"swarm and assassin fire nothing (still to be confirmed for the assassin in S5)")
	_stub(m, "projectile/enemy-beams", PHASE_PROJECTILE, "updateEnemyBeams", "none", "the list of enemy beams stays empty in M1")
	_stub(m, "pickup/loot", PHASE_PICKUP, "updateLootDrops", "S6", "loot drops (spawned by kills)")
	_stub(m, "pickup/xp", PHASE_PICKUP, "updateXp", "S6", "XP orbs: magnet, merge, collection (collectXp -> gain_xp)")
	_stub(m, "player/contract-dots", PHASE_PLAYER, "updatePlayerContractDots", "none", "contract burn and poison are 0 in M1 (no contracts)")
	_stub(m, "fx/particles", PHASE_FX, "updateParticles", "S6", "moves and expires particles, including damage numbers")
	_stub(m, "hud/pending-choice", PHASE_HUD, "openNextPendingChoice", "S6",
		"opens the level-up choice (sets levelUpChoiceReadyAt = t + 2) when pendingLevelUps > 0")
	_slot(m, "fx/screen-flash", PHASE_FX, ScreenFlashSystem.new(game))
	_slot(m, "player/regen", PHASE_PLAYER, PlayerRegenSystem.new(game))
	_stub(m, "hud/tutorial", PHASE_HUD, "updateTutorial", "none", "the first-run tutorial; UI only, never touches game state")
	_stub(m, "hud/update", PHASE_HUD, "updateHud", "S8", "writes the HUD from the settled state; no game state")
