// Golden vectors for newGame() (topic "new_game" -> godot/tests/golden/new_game.json). The state is what the ORIGINAL
// object literal of newGame() produces (cut out of the function body by bracket matching and evaluated with the game's real
// constants, see tools/golden/_defs_vm.mjs), the system lists are the ORIGINAL UPDATE_*_SYSTEMS arrays. The Godot side is
// tests/test_new_game.gd.
//
// Real: the literal itself, CHARACTERS, MAP_W/MAP_H, WAVE_DURATION, XP_CURVE, FEATURED_WAVE_CONFIG, DIFFICULTY_CONFIG,
//       signatureWeaponIdForCharacter, metaWeaponSlotMax; with a seed also makeWeapon, rand, setGameSeed, makeSeededRandom and
//       prepareEnemyWaveTheme(1) (the two calls of newGame that touch gameRandom).
//       makeEndlessUnlocks (with isSignatureWeaponId, WEAPONS and ELEMENTS) for the endless mode.
// Replaced by markers: makeSpecialsState and the *InitState functions of the other characters (their results are recorded as
//       {"@marker": name}); metaRun is a stub carrying the catalyst loadout that Chromium shows (analyst A, section 3.3).
// Not part of this golden (they follow the literal in newGame and are UI/audio/meta): initializeMetaRunRuntime (sets
//       progressEligible to true for mode "normal"), showMessage (messageUntil = 1.6), adaptiveReset, updateHud, ...
import { hex64 } from './_codec.mjs';
import { evaluateNewGame, original, snapshot } from './_defs_vm.mjs';
import { listedFunctions } from './defs_sim_scripts.mjs';

export const name = 'new_game';

const CHARACTERS = ['catalyst', 'arcanist', 'ranger', 'archivist', 'sentinel', 'striker', 'harmonizer', 'pathfinder', 'miko', 'berserker'];
// Fields of the snapshot that are not game state of the port (see the header).
const DROPPED = ['char', 'metaRun'];

const json = (v) => JSON.stringify(v);

function snapshotOf(options) {
  const { game } = evaluateNewGame(options);
  const snap = snapshot(game);
  for (const key of DROPPED) delete snap[key];
  snap.char_id = game.char.id;
  return snap;
}

/** Keys (of the top level, and of "player") whose snapshot differs from the baseline. */
function diffAgainst(baseline, snap) {
  const diff = {};
  for (const key of Object.keys(snap)) {
    if (key === 'player') {
      const playerDiff = {};
      for (const pk of Object.keys(snap.player)) if (json(snap.player[pk]) !== json(baseline.player[pk])) playerDiff[pk] = snap.player[pk];
      for (const pk of Object.keys(baseline.player)) if (!(pk in snap.player)) throw new Error(`player.${pk} missing in a variant`);
      if (Object.keys(playerDiff).length) diff.player = playerDiff;
    } else if (json(snap[key]) !== json(baseline[key])) {
      diff[key] = snap[key];
    }
  }
  for (const key of Object.keys(baseline)) if (!(key in snap)) throw new Error(`${key} missing in a variant`);
  return diff;
}

function buildCases() {
  const baseline = snapshotOf({ character: 'catalyst', mode: 'normal', difficulty: 'normal' });
  const variants = [
    ...CHARACTERS.filter((c) => c !== 'catalyst').map((character) => ({ character, mode: 'normal', difficulty: 'normal' })),
    ...['easy', 'hard', 'nightmare', 'bogus'].map((difficulty) => ({ character: 'catalyst', mode: 'normal', difficulty })),
    { character: 'catalyst', mode: 'endless', difficulty: 'normal' },
    { character: 'ranger', mode: 'endless', difficulty: 'hard' },
  ];
  return {
    baseline,
    variants: variants.map((v) => ({ ...v, diff: diffAgainst(baseline, snapshotOf(v)) })),
  };
}

function buildSeeded() {
  return [424242, 24681357, 0, 1, 2147483648, 2654435769, 4294967295, 123456789].map((seed) => {
    const { sandbox, game } = evaluateNewGame({ character: 'catalyst', mode: 'normal', difficulty: 'normal', seed });
    const draws = sandbox.gameRandomDraws;
    const weapon = snapshot(game.weapons[0]);
    const theme = snapshot(game.waveSpawnTheme);
    const history = snapshot(game.featuredEnemyHistory);
    const pending = snapshot(game.pendingDirectorEnemyKind);
    // the next three values the generator yields after newGame: the port's stream must be at the same position
    const next = [sandbox.gameRandom(), sandbox.gameRandom(), sandbox.gameRandom()].map(hex64);
    return { seed, draws, weapon, theme, featuredEnemyHistory: history, pendingDirectorEnemyKind: pending, next };
  });
}

function buildSystemLists() {
  const { lists } = listedFunctions();
  const out = {};
  for (const [key, list] of Object.entries(lists)) {
    out[key] = list.map((slot) => `${slot.id} ${slot.phase} ${slot.fn} ${slot.when === null ? '-' : slot.when}`);
  }
  return out;
}

export function generate(_extract) {
  return {
    format: 1,
    generated_by: 'tools/golden/defs_new_game.mjs',
    source: 'webview-fg4/tests/fixtures/original.html',
    source_sha256: original().sha256,
    snapshot_encoding: 'integer -> JSON number; other numbers -> {"f64": bits}; array -> {"@array": n, "items": [...] (n <= 32)}; Map/Set -> {"@map"|"@set": size}; marker -> {"@marker": name, ...}; plain object -> object',
    dropped_fields: DROPPED,
    cases: buildCases(),
    seeded: buildSeeded(),
    system_lists_columns: ['id', 'phase', 'function called by run()', 'when predicate source or -'],
    system_lists: buildSystemLists(),
  };
}
