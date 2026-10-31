class_name Sim
extends RefCounted
## The deterministic simulation (design sections 3 and 5): a `game` state plus the ordered systems that advance it by
## fixed steps. No Node, no scene tree, no engine clock: the same config and the same input sequence give the same
## state, and the headless tests and the reference traces drive it directly.
##
##   var sim: Sim = Sim.new()
##   sim.new_game(config)            # newGame(), after setGameSeed(config.rng_seed)
##   sim.game.input.key_right = true # the host sets the input ...
##   sim.step(Sim.FIXED_DT)          # ... and steps: capturePreviousTransforms(); update(FIXED_DT)
##
## Step S3 implements the clock, the day cycle, the player's movement and the camera, the knock-out sequence and the
## structure of all 53 system slots; the rest are documented placeholders (see SystemRunner).

## The original's FIXED_DT = 1 / 60.
const FIXED_DT: float = 1.0 / 60.0

var game: GameState = null
var runner: SystemRunner = null
var config: SimConfig = null
## The number of steps executed since new_game().
var steps: int = 0


## # port: setGameSeed(seed); newGame(). Builds a fresh game from the config. Returns false (after push_error) if the
## config cannot be played.
func new_game(p_config: SimConfig) -> bool:
	config = p_config
	var rng: GameRng = GameRng.new(p_config.rng_seed)
	var fx_rng: FxRng = FxRng.new(p_config.fx_seed)
	var created: GameState = GameState.create(p_config, rng, fx_rng)
	if created == null:
		return false
	game = created
	runner = SystemRunner.new(game)
	steps = 0
	return true


## One fixed step: capturePreviousTransforms(); update(dt). `dt` is clamped like the original does (0 to 1/30; a value
## that is not finite counts as 0).
func step(dt: float = FIXED_DT) -> void:
	if game == null:
		push_error("Sim.step: no game; call new_game first")
		return
	game.capture_previous_transforms()
	runner.update(dt)
	steps += 1


## gameRandomDraws.
func draws() -> int:
	return game.rng.draws


## viewW / viewH: the size of the visible area; an input of the simulation (spawn distances depend on it).
func set_view_size(width: float, height: float) -> void:
	game.view_w = width
	game.view_h = height
