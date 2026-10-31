class_name GameState
extends RefCounted
## The `game` object of the original: everything a run is made of (design section 5). create() is newGame(); the
## systems in sim/systems/ read and write these fields during Sim.step().
##
## Field names are the original's, camelCase -> snake_case, so `game.waveClock` is `game.wave_clock`; tests/test_new_game.gd
## compares every field of newGame's object literal with tests/golden/new_game.json by that rule and lists the ones that are
## deliberately not part of the port. Entity lists are untyped Arrays until the step that ports their entities (S5 enemies,
## S6 projectiles, XP orbs, particles); `enemies` and `weapons` are typed already.
##
## The first block is NOT in the original's object: it is the environment that the original keeps in globals (the seeded
## random generators, the movement input, viewW/viewH, the pointer-dependent caps and the `state` variable).

enum RunState { MENU, PLAYING, PAUSED, LEVELUP, CHEST, SPECIAL, ABILITY, ABILITY_INTRO, ENDED }

## The abilities of the catalyst's loadout in the M1 configuration, as seen in the original running in Chromium
## (analyst A, section 3.3: prepareMetaRunConfig on a fresh profile). All ranks are 0 in M1.
const CATALYST_ABILITY_IDS: PackedStringArray = ["cat_chain", "cat_overload", "cat_residue", "cat_core", "cat_haste"]

# --- environment (the original's globals) --------------------------------------------------------
var rng: GameRng = null
var fx_rng: FxRng = null
## The enemy spatial grid (the original keeps it in game.enemySeparationGrid and friends; rebuilt by the index/separation slots).
var enemy_grid: EnemyGrid = null
var input: SimInput = SimInput.new()
var view_w: float = 390.0
var view_h: float = 844.0
var limits: SimLimits = null
var state: RunState = RunState.PLAYING

# --- clock, wave, mode ---------------------------------------------------------------------------
var t: float = 0.0
var wave: int = 1
var wave_clock: float = 0.0
var wave_spawn_clock: float = 0.0
var day_phase: float = 0.18
var mode: String = "normal"
var difficulty: String = "normal"
var difficulty_locked: bool = true
var progress_eligible: bool = false
var endless_clears: int = 0
var enemy_stat_mult: float = 1.0
var enemy_speed_mult: float = 1.0
var spawn_pace_mult: float = 1.0
var elite_spawn_budget: float = 0.0
var enemy_ai_tier: int = 0
var enemy_ai_skill: float = 0.0
var run_unlocks_weapons: PackedStringArray = PackedStringArray()
var run_unlocks_elements: PackedStringArray = PackedStringArray()
var awaiting_choice: bool = false
var ended: bool = false
var run_won: bool = false

# --- player, camera, character ---------------------------------------------------------------------
var camera: CameraState = CameraState.new()
var player: PlayerState = null
var char_id: String = ""
var char_def: CharacterDef = null

# --- entities ----------------------------------------------------------------------------------------
var enemies: Array[EnemyState] = []
## Bumped whenever an enemy is added or removed (spawnEnemy, killEnemy).
var enemies_version: int = 0
## Bumped at the start of every updateEnemies (`game.projectileAvoidanceEpoch = (game.projectileAvoidanceEpoch || 0) + 1`). The original's cache of
## projectile avoidance candidates (>= 64 projectiles) is rebuilt when it changes; the port scans the projectile list instead (same result, see
## EnemySteering.projectile_avoidance), so only the counter exists.
var projectile_avoidance_epoch: int = 0
## The player's projectiles. Step S6 owns them; step S5 only has what the enemy AI reads (see ProjectileState).
var projectiles: Array[ProjectileState] = []
var enemy_projectiles: Array = []
var enemy_beams: Array = []
var enemy_ground_attacks: Array = []
var xp_orbs: Array[XpOrbState] = []
var xp_merge_cursor: int = 0
var loot_drops: Array = []
var particles: Array = []
var sprite_fx: Array = []
var signature_fx: Array = []
var signature_actions: Array = []
var hazards: Array = []
var turrets: Array = []
var saplings: Array = []
var range_circle_reaction_cooldowns: Dictionary = {}
var wood_death_grove_cd_until: float = 0.0
var weapons: Array[WeaponState] = []

# --- effects, boss and elite bookkeeping ---------------------------------------------------------------
var screen_flash: float = 0.0
var damage_flash: float = 0.0
var boss_defeated_this_wave: bool = false
var boss_clear_timer: float = 0.0
var reaction_event_seq: int = 0
var elite_defeated_this_wave: bool = false
var elite_clear_timer: float = 0.0
var elite_gate_total: int = 0
## id -> enemy, a snapshot taken by index/enemy-by-id (rebuildEnemyIndex); an enemy that dies later in the step stays in it until the next rebuild.
var enemy_by_id: Dictionary[int, EnemyState] = {}
var root_link_damage_queue: Dictionary = {}
var frame_solid_hazards: Array = []
var direct_damage_result: Dictionary = {}
var archivist_records: Dictionary = {}
var signature_metrics: Dictionary = {}
var passives: Dictionary = {}
var equipment: Dictionary = {}

# --- level-up choices ------------------------------------------------------------------------------------
var rerolls: int = 0
var choice_count: int = 3
var treasure_choice_count: int = 3
var banker_charges: int = 0
var banked_level_ups: int = 0
var banked_levels: Array = []
## "" is the original's null.
var forced_next_category: String = ""
var last_choices: Array = []
var pending_special_choices: Array = []
var blueprint_next: bool = false
var double_pick_next: bool = false
var current_level_forced_category: String = ""
var current_level_pick_target: int = 1
var current_level_picks_made: int = 0
var current_level_choices: Array = []
## A Set in the original; the keys are the members.
var current_level_selected: Dictionary = {}
var current_level_from_bank: bool = false
var weapon_slot_max: int = 6
var contracts: Dictionary = {}
var contract_enemy_stat_mul: float = 1.0
var arena_wave: int = 0
var banned_element: String = ""
var affliction_duration_mul: float = 1.0
var timed_contract: Variant = null

# --- score and level-up queue ------------------------------------------------------------------------------
var kills: int = 0
var boss_kills: int = 0
var raw_score: float = 0.0
var final_score: float = 0.0
var scored_waves: Dictionary = {}
var pending_level_ups: int = 0
var pending_chests: int = 0
var level_up_choice_ready_at: float = 0.0
var pending_level_numbers: Array[int] = []
var current_level_number: int = 0
var character_upgrade_stacks: int = 0
var weapon_overflow_by_id: Dictionary = {}
var specials: SpecialsState = null

# --- enemy director --------------------------------------------------------------------------------------------
var next_enemy_id: int = 1
var squads: Dictionary = {}
var next_squad_id: int = 1
var open_squad_id: int = 0
var squad_director_clock: float = 0.0
var high_threat_lock_until: float = 0.0
var support_reservations: Dictionary = {}
var ai_metrics: Dictionary = {}
var new_unlocks: Array = []
var message_until: float = 0.0
var spawn_budget: float = 2.5
var director_clock: float = 0.0
var wave_featured_change_chance: float = 0.0
var wave_spawn_theme: EnemyWaveTheme = null
var featured_enemy_history: PackedStringArray = PackedStringArray()
## "" is the original's null.
var pending_director_enemy_kind: String = ""
var pending_director_composition: Variant = null
var spawn_composition_history: Array = []
var special_escort_seq: int = 0

# --- character states (null unless the character is that one) ------------------------------------------------
var miko: RefCounted = null
var berserker: RefCounted = null
var sentinel: RefCounted = null
var striker: RefCounted = null
var harmonizer: RefCounted = null
var pathfinder: RefCounted = null
var overhaul_hud_at: Dictionary = {}


## # port: newGame (the part that is game state; the screens, audio, tutorial and save bookkeeping around it are UI).
## Draws from rng exactly as the original does: one value for the starting weapon (makeWeapon), none for the wave
## theme of wave 1. Returns null (with push_error) for an unknown character or an unsupported one.
static func create(config: SimConfig, p_rng: GameRng, p_fx_rng: FxRng) -> GameState:
	var c: CharacterDef = Defs.character(config.character_id) if Defs.has_character(config.character_id) else Defs.character("catalyst")
	if c == null:
		return null
	if c.id != "catalyst" and not config.allow_unported_character:
		push_error("GameState.create: character '%s' is not supported in M1 (catalyst only)" % c.id)
		return null
	var rules: SimRules = Defs.rules()
	var g: GameState = GameState.new()
	g.rng = p_rng
	g.fx_rng = p_fx_rng
	g.view_w = config.view_w
	g.view_h = config.view_h
	g.limits = Defs.limits(config.coarse_pointer)
	g.enemy_grid = EnemyGrid.new(g.limits)
	g.state = RunState.PLAYING

	g.t = 0.0
	g.wave = 1
	g.wave_clock = rules.wave_duration
	g.wave_spawn_clock = 0.0
	g.day_phase = 0.18
	g.mode = config.mode
	g.difficulty = config.difficulty if Defs.has_difficulty(config.difficulty) else "normal"
	g.difficulty_locked = true
	g.progress_eligible = false
	if config.mode == "endless":
		_fill_endless_unlocks(g)
	else:
		g.run_unlocks_weapons = _default_unlock_list("weapons")
		g.run_unlocks_elements = _default_unlock_list("elements")
	g.camera.x = g.limits.map_w / 2.0
	g.camera.y = g.limits.map_h / 2.0
	g.player = PlayerState.from_character(c, g.limits)
	g.char_id = c.id
	g.char_def = c
	# makeWeapon(signatureWeaponIdForCharacter(c.id)): the only gameRandom draw of the literal
	g.weapons.append(WeaponState.make(Defs.signature_weapon_id(c.id), p_rng))
	g.weapon_slot_max = 6
	g.specials = SpecialsState.new(c.id, CATALYST_ABILITY_IDS if c.id == "catalyst" else PackedStringArray())
	g.equipment = {"head": null, "chest": null, "hands": null, "feet": null}
	g.signature_metrics = {"catalystHits": [], "recordReleases": 0, "recordReleaseHits": 0, "kidanHits": 0}
	g.ai_metrics = {
		"individualUpdates": 0, "decisionUpdates": 0, "squadUpdates": 0, "cpuMs": 0, "lastCpuMs": 0, "windowAt": 0,
	}
	g.wave_featured_change_chance = rules.featured_initial_change_chance

	# newGame also filters the weapons' elements through characterAllowsElement when the character has an element
	# restriction (allowedElements); a new weapon has no elements, so there is nothing to filter yet.

	# initializeMetaRunRuntime: `progressEligible = mode === "normal" && !DEBUG_ENABLED && !cheatActive && !testForced`
	g.progress_eligible = g.mode == "normal"
	WaveRules.prepare_enemy_wave_theme(g, 1)
	# showMessage(`${difficulty} ／ ウェーブ 1`, 1.6)
	g.message_until = g.t + 1.6
	return g


## # port: makeEndlessUnlocks. Every weapon that is not a signature weapon, and every element.
static func _fill_endless_unlocks(g: GameState) -> void:
	g.run_unlocks_weapons = PackedStringArray()
	for id: String in Defs.weapon_ids():
		if Defs.weapon(id).signature_for == "":  # !isSignatureWeaponId(id)
			g.run_unlocks_weapons.append(id)
	g.run_unlocks_elements = PackedStringArray()
	for id: Variant in Defs.value("weapons.json", "ELEMENT_ID_LIST"):
		g.run_unlocks_elements.append(String(id))


static func _default_unlock_list(key: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var defaults: Dictionary = Defs.value("weapons.json", "DEFAULT_UNLOCKS")
	for id: Variant in defaults[key] as Array:
		out.append(String(id))
	return out


# --- queries and small state changes shared by several systems ----------------------------------------------------

## # port: isPlayerAlive. `!!(game && !game.ended && game.player.hp > 0 && !(game.player.koTimer > 0))`
func is_player_alive() -> bool:
	return not ended and player.hp > 0.0 and not (player.ko_timer > 0.0)


## # port: abilitiesActive. `!!(game?.specials && currentAbilityList().length)`
func abilities_active() -> bool:
	return specials != null and specials.ability_count() > 0


## # port: currentDifficulty. DIFFICULTY_CONFIG[game.difficulty].
func current_difficulty() -> DifficultyDef:
	return Defs.difficulty(difficulty)


## # port: currentDifficultyKey. `DIFFICULTY_CONFIG[game.difficulty] ? game.difficulty : ... : "normal"` (create() already turns an unknown
## key into "normal", so the stored key is always valid; the original's selectedDifficulty fallback is a menu setting).
func current_difficulty_key() -> String:
	return difficulty if Defs.has_difficulty(difficulty) else "normal"


## # port: isDifficulty
func is_difficulty(key: String) -> bool:
	return current_difficulty_key() == key


## # port: enterKnockOutIfDead
func enter_knock_out_if_dead() -> void:
	var p: PlayerState = player
	if p.hp <= 0.0 and not (p.ko_timer > 0.0):
		input.clear()  # clearTransientInput
		level_up_choice_ready_at = 0.0
		p.hp = 0.0
		p.ko_timer = p.ko_anim_max if p.ko_anim_max != 0.0 else 0.96
		p.attack_anim = 0.0
		if char_id == "berserker":
			push_error("GameState: the berserker's convergence knock-out art is not ported yet (M2)")
		p.ko_art_id = char_id
		p.vx = 0.0
		p.vy = 0.0
		p.ax = 0.0
		p.ay = 0.0


## # port: gainXp (the experience bookkeeping; the trailing `openNextPendingChoice()` is the hud/pending-choice system,
## S6/S8). Levels up while xp >= xpNext: the requirement grows by Math.floor(base * 1.18 + 18), rounded after * 0.85.
func gain_xp(amount: float) -> void:
	if not is_finite(amount):
		push_error("GameState.gain_xp: the amount must be finite, got %s" % amount)
		return
	var p: PlayerState = player
	p.xp += amount
	while p.xp >= p.xp_next:
		p.xp -= p.xp_next
		p.level += 1
		p.xp_base_next = Formulas.next_xp_base(p.xp_base_next)
		p.xp_next = Formulas.xp_next_for(p.xp_base_next)
		pending_level_ups += 1
		pending_level_numbers.append(p.level)


## # port: collectXp. `gainXp(value * xpMul * currentDifficulty().xp * anomalyXp)` with xpMul = `p.xpMul || 1` (the
## archivist's own multiplier and the af_xp factor are outside M1; anomalyXp is 1).
func collect_xp(value: float) -> void:
	if char_id == "archivist":
		push_error("GameState.collect_xp: the archivist's xp multiplier is not ported yet (M2)")
	var xp_multiplier: float = player.xp_mul
	if xp_multiplier == 0.0 or is_nan(xp_multiplier):
		xp_multiplier = 1.0
	gain_xp(value * xp_multiplier * current_difficulty().xp * 1.0)


## # port: capturePreviousTransforms. Remembers where the player, the enemies and the camera were before the step.
func capture_previous_transforms() -> void:
	player.prev_x = player.x
	player.prev_y = player.y
	for e: EnemyState in enemies:
		e.prev_x = e.x
		e.prev_y = e.y
	camera.prev_x = camera.x
	camera.prev_y = camera.y


# --- the enemy grid, on this game's enemies -----------------------------------------------------------------------------

## # port: queryEnemiesAabb (see EnemyGrid). The grid is the snapshot of the last rebuild; the enemies are the live list.
func query_enemies_aabb(min_x: float, min_y: float, max_x: float, max_y: float, out: Array[EnemyState], cell_margin: int = 0) -> Array[EnemyState]:
	return enemy_grid.query_aabb(enemies, min_x, min_y, max_x, max_y, out, cell_margin)


## # port: queryEnemiesCircleBroad
func query_enemies_circle_broad(x: float, y: float, r: float, out: Array[EnemyState], cell_margin: int = 0) -> Array[EnemyState]:
	return enemy_grid.query_circle_broad(enemies, x, y, r, out, cell_margin)


## # port: nearestEnemy
func nearest_enemy(x: float, y: float, range_limit: float) -> EnemyState:
	return enemy_grid.nearest_enemy(enemies, x, y, range_limit)
