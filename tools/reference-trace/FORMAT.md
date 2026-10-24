# swarm-trace/1

A trace records a run of the simulation step by step, in a form that two implementations can be compared on: the original game
(`webview-fg4/tests/fixtures/original.html`, run in Chromium 141) and the Godot port (`godot/sim`). Design section 9.2.

```
node tools/reference-trace/capture.mjs --all            # the 6 standard traces -> godot/tests/reference/<script>_<seed>.jsonl.gz
node tools/reference-trace/capture.mjs --script zigzag --seed 424242 --long-run --max-steps 5400   # the non-standard long run (below)
tools/emit_port_trace.sh REF.jsonl.gz OUT.jsonl.gz [--oracle]   # the port's trace for the same run (replays REF's inputs through Sim; --oracle: see below)
node tools/compare_trace.mjs REF.jsonl.gz OUT.jsonl.gz  # first diverging step per field group, with both values
```

## File

* JSON Lines, UTF-8, `\n` line ends, gzip-compressed (`.jsonl.gz`; a plain `.jsonl` is accepted by every reader).
  Node's `zlib.gzipSync(level 9)` writes it deterministically (no timestamp): the same capture gives the same bytes.
  Godot reads it with `PackedByteArray.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)` and writes it with
  `PackedByteArray.compress(FileAccess.COMPRESSION_GZIP)`; both are standard gzip (checked against Node and `gunzip`).
* Line 1 is the header, every further line is one fixed step, recorded after that step's `update(FIXED_DT)`.
* Floats are **16 lowercase hex digits: the big-endian IEEE-754 bit pattern** (`"3ff0000000000000"` is 1.0). No decimal text is
  ever parsed, so no bit can change in transit (Godot's JSON parser and float literals are not correctly rounded). NaN is the
  canonical `7ff8000000000000`; `-0` is `8000000000000000`. A float the game has not written yet (`undefined`, for example the
  `prevX` of an enemy spawned in this very step) is recorded as `0000000000000000`, which is the port's default too.
* Integers are JSON integers, strings are JSON strings. (Godot's parser returns integers as floats; use `int()`.)

## Header (line 1)

| key | meaning |
| --- | --- |
| `format` | `"swarm-trace/1"` |
| `producer` | `"original-chromium"` (reference) or `"godot-port"` |
| `source` | reference: `{path, sha256}` of original.html as served (the file on disk is never modified; the hook is added to the HTTP response); port: `{path: "godot/sim", engine}` |
| `chromium_version`, `playwright_version` | reference only. The reference math (`sin`, `cos`, `atan2`) is V8 14.1's |
| `seed` | seed of `gameRandom` (`setGameSeed(seed)`); the standard seeds are 424242 and 24681357 |
| `fx_seed` | seed of `Math.random` (particles, sound variation), so the capture is repeatable; the port's `SimConfig.fx_seed` |
| `character`, `difficulty`, `mode` | `catalyst`, `normal`, `normal` (the standard mode) |
| `view`, `coarse`, `device_scale_factor` | `[390, 844]` (viewW, viewH), `true` (IS_COARSE_POINTER), 3. The viewport sets the enemy spawn radius, `coarse` the entity caps |
| `fixed_dt` | hex of `FIXED_DT = 1/60` |
| `new_game_draws` | `gameRandomDraws` right after `newGame()` (1: the starting weapon's cooldown) |
| `input_script` | `{name, definition}`: the script that produced the inputs (below); a port trace copies it from the reference |
| `slots` | `{intro: [5 ids], main: [43 ids], ko: [5 ids]}`: the ids of `UPDATE_*_SYSTEMS` in order. The index is the slot number used in `slot_draws` |
| `fields` | the schema: group -> list of `"name:type"`; rows are positional arrays in this order. Types: `f` float (hex), `i` integer, `s` string, `b` boolean (`hook.js` writes all four) |
| `count_fields` | the keys of `counts` |
| `unported` | port traces only: the reference fields the port has no property for (they are not in `fields` and not in the rows) |
| `environment`, `stats`, `emulate_loop` | reference only: what the page reported (pointer, view, quality, adaptive tier, entity caps), the maxima of the run, and the validation flag. `stats.never_defined` lists the fields that were read at least once and never found defined in the game's objects (empty in every committed trace; `capture.mjs` refuses to write a trace where it is not: see "Undefined values") |
| `boundaries` | reference only: `{fire, pickup, steps}`, the first steps with an effect the port does not have yet (see "Using the traces"): `fire` the first weapon shot, `pickup` the first experience orb collected (player `xp` changes); computed by `tools/lib/trace_io.mjs` `firstEffects`; `test_reference_trace.gd` computes them again and fails if the two differ. (Until step S5 there was a third key, `contact`, the first contact hit on the player; `enemy/update` is ported now, so the port reproduces the hits and no comparison is bounded by them) |
| `variant`, `overrides` | only in a non-standard trace (`"long_run"`, below): which deviation from the game was applied and the values (`{"player.xpNext": hex, ...}`). A port trace copies both from the reference it replays |
| `replayed_from` | port traces only: the reference file the inputs came from |
| `stop` | `{reason, step}`: `level_up` (first step with `pendingLevelUps > 0`), `state:<state>`, `wave:<n>` (`--until-wave`), `max_steps` (4000, or `--max-steps`) for the reference; `replayed` for the port |

## Step lines

```
{"n": 1-based step number,
 "input": {"moveX": hex, "moveY": hex, "keys": ["KeyD", ...sorted]},    // what the game's input state was for this step
 "state": "playing",                                                    // the game's `state` after the step
 "draws": cumulative gameRandomDraws after the step (includes new_game_draws),
 "slot_draws": {"main:5": 27, ...},   // draws of this step per slot, key = list name + index; only non-zero counts
 "outside_draws": draws of this step that no slot made (0 in every trace),
 "player": [...], "camera": [...], "wave": [...],     // positional arrays, order from header.fields
 "counts": {"enemies", "projectiles", "xp_orbs", "particles", "enemy_projectiles", "hazards"},
 "enemies": [[...], ...], "projectiles": [[...], ...], "xp_orbs": [[...], ...]}   // one array per entity, in the game's array order
```

`draws` and the per-slot counts come from the game's own counter `gameRandomDraws` (incremented by the wrapper that
`setGameSeed` installs on every `gameRandom()` call), read around the `run` of each slot. A slot is `UPDATE_INTRO_SYSTEMS[i]`
(`intro:i`), `UPDATE_MAIN_SYSTEMS[i]` (`main:i`) or `UPDATE_KO_SYSTEMS[i]` (`ko:i`).

### Fields (reference schema; `tools/reference-trace/hook.js` `SCHEMA`, mirrored in `godot/tests/trace/sim_trace.gd`)

| group | source object | fields |
| --- | --- | --- |
| `player` | `game.player` | x, y, vx, vy, ax, ay, prevX, prevY, hp, maxHp, xp, level (i), xpNext, xpBaseNext, lastFacing, attackAnim, attackAngle, koTimer, walkPhase, controlSlow, lastHit |
| `camera` | `game.camera` | x, y, prevX, prevY |
| `wave` | `game` | t, wave (i), waveClock, directorClock, spawnBudget, dayPhase, pendingLevelUps (i), nextEnemyId (i), damageFlash, screenFlash, kills (i), levelUpChoiceReadyAt; the enemy director (step S5): pendingDirectorEnemyKind (s), waveFeaturedChangeChance, enemyAiTier (i), enemyAiSkill, enemiesVersion (i); `game.waveSpawnTheme` flattened: themeWave (i), themeBaseKind (s), themeFeaturedKind (s), themeChanged (b), themeChangeChance, themeTotalSpawned (i), themeCounts (s: `kind=n,kind=n` in insertion order), themeRecentMixed (s: comma separated); featuredEnemyHistory (s: comma separated). The theme fields are 0 / `""` / false while `waveSpawnTheme` is null |
| `enemy` | each of `game.enemies` | id (i), kind (s), x, y, vx, vy, hp, maxHp, prevX, prevY, r, speed, facing, aiState (s), then the nine values `spawnEnemy` draws from gameRandom as they stand after the step: shootCd, aiTimer, abilityCd, strafeDir (i), aiSeed, thinkCd, animPhase, tacticCd, dotNumberTimer; then damage, spawnWave (i) and the timers that `updateEnemies` / `tickEnemyTimersAndStatus` write every step: flash (also set by damage, step S6), telegraph, attackAnim, tacticPulse |
| `projectile` | each of `game.projectiles` | x, y, vx, vy, life, age, r, damage, weapon (s: the weapon id) |
| `xp_orb` | each of `game.xpOrbs` | x, y, value, r |

`prevX`/`prevY` are the values `capturePreviousTransforms()` stored at the start of the step.

Matching by name: the port looks a field up as the property of the snake_case name (`prevX` -> `prev_x`) on `PlayerState`,
`CameraState`, `GameState` or the entity class (`EnemyState`); fields it lacks are left out and listed under `unported`. A value
that is no plain property of that name (the nested `waveSpawnTheme`, an array that the reference flattens to a string) comes from
the getter table `SimTrace.port_getters()` (group -> field -> `Callable(object)`); a field with a getter counts as ported.
`tools/compare_trace.mjs` compares the fields both headers carry.

### Undefined values

`undefined` is recorded as 0 / `""` / false, which is right for a value the game has not written yet (the `prevX` of an enemy
spawned in this very step) and wrong for a misspelt field name. So `hook.js` counts, per field, how often it was read and how
often the game had it defined; a field that was read and never defined is listed in `stats.never_defined`, and `capture.mjs`
prints it, exits 1 and does not write the trace. The Godot test asserts the list is empty in every committed trace.

### Extending the schema (steps S5/S6)

Add a line to `SCHEMA` in `hook.js` (a third element is a getter, `(o) => ...`; return `undefined` when the value does not
exist) and to `SimTrace.REFERENCE_FIELDS`, then run `capture.mjs --all` again. Readers take the field list from the header, so
nothing else changes; `godot/tests/test_reference_trace.gd` fails when the two lists differ. Register a new entity class in
`SimTrace.entity_sample()` to have the port carry its fields; add a getter to `SimTrace.port_getters()` for a value that is not a
plain property.

## Input scripts (`tools/reference-trace/scripts/*.json`)

```
{"name": "dirs8", "repeat": true,
 "segments": [{"label": "east", "steps": 60, "stick": [42, 0]}, {"steps": 7, "keys": ["KeyD", "KeyW"]}, {"steps": 3}]}
```

Each segment holds its input for `steps` steps; `repeat` cycles the segments, otherwise the input is released after the last one.
`stick: [dx, dy]` is the finger's displacement in CSS pixels from where the touch began (the game limits it to 42 px);
`keys` are held movement keys (`KeyW/A/S/D`, `ArrowUp/Left/Down/Right`); both can be combined; a segment with neither is idle.
The driver applies them with the game's real handlers (`touchStart`, `touchMove`, `touchEnd`, the keydown/keyup effect on
`input.keys`), so `moveX`/`moveY` are what the game computes (`updateTouchStick`); the trace records the result. Scripts:
`dirs8` (design 9.2: 8 directions, 60 steps each, repeating), `idle`, `zigzag` (a new stick vector every 7 steps, diagonals and
magnitudes below 1). `move: [mx, my]` sets `input.moveX/moveY` directly; it only exists to cross-check older tools.

## The long-run variant (non-standard)

The standard traces stop at the first level-up, 13-38 s into the run, because choosing an upgrade is not part of M1's
reproducible range (design 9.2). So they hold only `swarm` enemies in waves 1 and 2 (wave 2 only in `idle_424242`), and the
starting weapon alone lets the player die about 55-65 s in, before wave 3 (72 s, assassins). To have a reference for wave 3
(the director's theme draws, assassin spawns and AI) there is one explicitly **non-standard** mode:

```
node tools/reference-trace/capture.mjs --script zigzag --seed 424242 --long-run --max-steps 5400 [--until-wave N] [--verify-repro]
```

`--long-run` sets `player.xpNext`, `player.hp` and `player.maxHp` to 1e9 right after `newGame()`: no level-up is ever queued and
the player does not die. Nothing else differs; the header says `"variant": "long_run"` and lists the `overrides` (hex), and
`SimTrace.replay` applies the same three values to the port after its `new_game` (`SimTrace.apply_overrides`; any other key in a
header is an error). `godot/tests/reference/zigzag_424242_longrun.jsonl.gz` is 5400 steps (90 s: wave 3 from step 4320, with
assassins; 5.4 MB, byte-reproducible) and goes through the same tests as the standard traces; `--until-wave 5` records waves 1-4
(8644 steps, about 9 MB, too large to commit). Design 9.3 does not ask for a match after the first level-up; this trace is the
reference for the director and the enemy AI of wave 3, not an acceptance criterion by itself. What the traces cover:

| | standard traces (6) | long run (1) |
| --- | --- | --- |
| enemy kinds | swarm | swarm, assassin |
| waves | 1 (2 in `idle_424242`, 106 steps) | 1, 2, 3 (to 90 s) |
| first enemy damaged / first kill | step 63-75 / 109-161 | step 73 / 118 (same start as `zigzag_424242`) |
| first contact hit on the player | `dirs8_424242` only (step 586) | step 2835; hits go on, the player cannot die |
| enemy projectiles, hazards, knock-out | none (counts 0 at every step) | none (counts 0 at every step, also with assassins on screen in 1074 steps) |

Enemy projectiles, hazards, the KO list and waves 4 and later have **no** reference in the committed files; verify them with
unit/golden tests, or record them with `--until-wave`. (That the assassins of wave 3 fire no enemy projectile and make no
hazard is an observation of the long run: both counts stay 0 in all 1074 steps in which an assassin is on screen.)

## What is pinned, and why

The original reads its environment, so the capture fixes or asserts every input that can change gameplay:

* viewport 390x844 and `isMobile` + `hasTouch` (`IS_COARSE_POINTER` true: caps 520 projectiles, 480 XP orbs, 420 enemy
  projectiles; the viewport sets the spawn ring radius `max(viewW, viewH) * 0.62`); asserted in the page;
* a fresh browser context per capture (no `localStorage`: default difficulty, unlocks, tutorial, meta progress); the page's own
  boot records are allowed, anything else aborts the capture; no `#debug` in the URL;
* visual quality is not `eco`; the render loop is suspended, so `adaptive.tier` stays 0 (`visualFxCount` scale 1);
  the number of particles is in every row and the capture aborts if it reaches 560, because `showDamageNumber` draws three
  `gameRandom` values per number unless `particles.length >= damageLabelParticleLimit()` (1100, eco 560);
* `Math.random` (effects, sound variation) is replaced by the game's seeded generator, and the whole run is one synchronous
  call: no timer, `requestAnimationFrame` or audio callback can interleave; audio is never unlocked;
* time: the driver steps `update(FIXED_DT)` itself, so the frame loop's accumulator, `document.hidden` and the
  once-per-frame `revealDelayedLevelUpChoice` do not exist; the capture stops at the first `pendingLevelUps > 0`.
  `hook.js` explains why `render()`/`adaptiveSample()` are not needed; `capture.mjs --emulate-loop` runs them after every step
  and the step lines come out identical.

## Using the traces in the next steps

* `godot/tests/test_reference_trace.gd` replays every committed trace through `Sim` and compares what the port has ported with the
  reference, bit for bit. Since step S5 the replay runs with the test-only replay oracle (below), so the director, the enemy list with
  every enemy field but `hp` and `flash` (position, velocity, facing, AI state and timers), the draws of every slot (the contact hits'
  three draws included: `enemy/update` is ported), the kills, and the player (position, velocity, `hp`, `lastHit`), the camera and the
  damage flash are compared from step 1 to the end of every trace. What the port still lacks bounds only the fields it writes (the
  boundaries are computed from the trace itself, printed per trace and stored in the header as `boundaries`, where the test checks that
  the Node and the GDScript computations agree): the experience fields are compared up to the first `pickup`, and the animation fields
  (`attackAnim`, `attackAngle`, `lastFacing`) on every step in which the reference shows no shot, **teacher-forced**: the port's three
  values are set to the reference's values of the step before, so the countdown and the `atan2` facing rule are checked against hundreds
  of reference values although the port cannot shoot. As S6 ports more, move a boundary by editing the field sets in the test and the
  boundary rules there (in `trace_io.mjs` `firstEffects` too), not by loosening a comparison. The test also counts what the traces
  exercise (contact hits, steps in which an assassin dodges a projectile, the assassin's states) from the reference rows, and fails when
  they hold less than the long run is known to.
* The draws per slot are in `slot_draws`: `TraceReader.slot_key("main", "projectile/player")` gives the key and
  `TraceReader.slot_draws(step_index, key)` the count. The replay oracle (`godot/tests/trace/replay_oracle.gd`, step S5) uses them to make
  the placeholders (`projectile/player` until S6 ports it) draw the recorded number of values (design section 11); an implemented slot is
  never topped up, so the comparison of the slot draws checks the port's own draws.
* `tools/emit_port_trace.sh` + `tools/compare_trace.mjs` give the first diverging step per group and per field with both values:
  `node tools/compare_trace.mjs REF PORT --fields player,camera --until 585`. The comparator fails (exit 1) when the traces do not
  have the steps that `--until` asks for, when no step is compared, and (without `--until`) when their lengths differ, whatever is
  selected; selecting a field of an entity list (`enemies.x`) also compares `enemies.length`; `counts.particles` depends on
  effects (`fxRandom` is shared with audio and rendering) and is only compared when named.
* The standard reference traces stop at the first level-up (`pendingLevelUps > 0`), the limit of what M1 can reproduce (design 9.2).

### Following the reference past the first kill (step S5, before S6): the replay oracle

Kills come from `projectile/player` (main:29) and `enemy/cleanup-2` (main:31); the damage is S6's. The trace records the state at the
end of each step only, but the enemy list follows a rule that holds at **every step of every committed trace** (checked by
`test_the_enemy_list_follows_the_spawn_and_removal_rule_in_every_committed_trace`): `wave/progress` appends the new enemies
(`spawnEnemy`, ascending ids), then `cleanupDeadEnemies` walks the list from the last index and removes each dead enemy by
swap-pop (`last = list.pop(); if (i < list.length) list[i] = last`); every removal is a kill (`wave.kills` grows by the number of
removed ids; no despawns), at most one enemy goes per step in these traces.

* `TraceReader.removed_enemy_ids(step_index)` / `spawned_enemy_ids(step_index)` / `enemy_ids(step_index)` give the ids that left,
  arrived and are present, and `TraceReader.next_enemy_order(before, spawned, removed)` is the rule as a function.
* The **replay oracle** (`godot/tests/trace/replay_oracle.gd` and `oracle_system.gd`, TEST ONLY) follows the reference with three
  actions, installed from outside by replacing `SystemSlot.system` (`SimTrace.replay(reference, until, true)`, `tools/emit_port_trace.sh ... --oracle`):
  (a) a placeholder slot (`SimSystem.is_implemented()` false) draws from `gameRandom` as many values as the reference's slot drew in that step
  (`slot_draws`), after it ran; an implemented slot is never topped up, so the comparison of the slot draws checks its own draws;
  (b) before `enemy/cleanup-2`, `hp = 0` is set on the enemies of `removed_enemy_ids(n)` and the port's own `cleanupDeadEnemies` removes them
  (swap-pop from the end, `killEnemy`: kills, score, the experience orb and its two draws); the order comes out as the reference's;
  (c) at the start of step n, `game.projectiles` is rebuilt from the reference's projectile rows of step n - 1 (the assassin dodges player
  projectiles; nothing before `enemy/update` changes the list).
  It counts what it injects (`injected`, `forced_kills`), so the debt of step S6 stays visible. It cannot be enabled in the exported game:
  `godot/tests/` is excluded from the export, and nothing the export includes mentions it (`tests/test_replay_oracle.gd` checks both).
* Fields that only damage changes (`hp`, `flash`, afflictions, knockback) differ in the port after the first hit even then; they are left
  out of the comparison until S6, as are the experience orbs after the first pickup and the player's experience.

What the committed files cannot check, by design (see "The long-run variant"): enemy projectiles, hazards, the KO list, waves 4
and later; assassin spawns and wave 3's theme draws are covered by the long-run trace only.
