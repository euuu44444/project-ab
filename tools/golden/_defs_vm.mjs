// Shared plumbing of the S3 golden modules (defs_formulas, defs_sim_scripts, defs_new_game, defs_bits): loads the
// ORIGINAL game once, cuts functions and declarations out BY NAME and evaluates them in a node:vm context with an
// empty sandbox (tools/lib/js_source.mjs). Files starting with "_" are helpers, not golden modules.
//
// Row format of the bulk tables (one string per row, tokens separated by single spaces) keeps the committed JSON
// compact and readable: double -> 16 lowercase hex digits of its IEEE-754 bits (Godot's float parsing is not correctly
// rounded, see tools/golden/_codec.mjs), integer -> decimal, boolean -> 0/1, string -> itself (no spaces).
import { hex64 } from './_codec.mjs';
import {
  cutNames, evaluateCuts, findFunction, readOriginal, skipBalanced,
} from '../lib/js_source.mjs';

let cachedOriginal = null;
/** The original game (text and SHA-256), read once. */
export function original() {
  if (cachedOriginal === null) cachedOriginal = readOriginal();
  return cachedOriginal;
}

/**
 * Cuts `names` (declarations and functions, source order) and evaluates them after `prelude` in a new context with an
 * empty sandbox. Returns the sandbox: the cut functions and `var` declarations are properties of it, so a script can
 * set `sandbox.game = ...` and call `sandbox.enemySpec(...)`.
 */
export function sandboxWith(names, { prelude = '', epilogue = '', expose = [], impureNames = [] } = {}) {
  const cuts = cutNamesCached(names, impureNames);
  return evaluateCuts(cuts, { prelude, epilogue, expose, filename: 'golden-cuts.js' });
}

const cutCache = new Map();
/** cutNames with a cache per (name, impure): every cut scans the 2 MB source, and the generators evaluate many sandboxes. */
function cutNamesCached(names, impureNames) {
  const missing = names.filter((n) => !cutCache.has(`${n}|${impureNames.includes(n)}`));
  for (const name of missing) {
    const impure = impureNames.includes(name);
    cutCache.set(`${name}|${impure}`, cutNames(original().text, [name], { impureNames: impure ? [name] : [] })[0]);
  }
  if (new Set(names).size !== names.length) throw new Error(`duplicate names in the cut list: ${names.join(', ')}`);
  return names.map((n) => cutCache.get(`${n}|${impureNames.includes(n)}`)).sort((a, b) => a.start - b.start);
}

// ---------------------------------------------------------------------------------------------------
// Row tokens
// ---------------------------------------------------------------------------------------------------
export function token(kind, value) {
  switch (kind) {
    case 'f': {
      if (typeof value !== 'number') throw new Error(`expected a number, got ${typeof value} (${value})`);
      return hex64(value);
    }
    case 'i': {
      if (!Number.isInteger(value)) throw new Error(`expected an integer, got ${value}`);
      return String(value);
    }
    case 'b': return value ? '1' : '0';
    case 's': {
      if (typeof value !== 'string' || /\s/.test(value) || value === '') throw new Error(`bad string token ${JSON.stringify(value)}`);
      return value;
    }
    default: throw new Error(`unknown token kind ${kind}`);
  }
}

/** A row from a list of [kind, value] pairs. */
export function row(...pairs) {
  return pairs.map(([kind, value]) => token(kind, value)).join(' ');
}

/** Describes the columns of a table so that a reader does not have to guess: "name:kind" per column. */
export const columns = (...specs) => specs;

// ---------------------------------------------------------------------------------------------------
// The newGame object literal
// ---------------------------------------------------------------------------------------------------

/** Names the literal of newGame needs for real (pure declarations and pure functions of the game). */
const NEW_GAME_REAL = [
  'CHARACTERS', 'MAP_W', 'MAP_H', 'WAVE_DURATION', 'XP_CURVE', 'FEATURED_WAVE_CONFIG', 'DIFFICULTY_CONFIG',
  'SIGNATURE_WEAPON_BY_CHARACTER', 'signatureWeaponIdForCharacter', 'metaWeaponSlotMax',
  'makeEndlessUnlocks', 'isSignatureWeaponId', 'WEAPONS', 'ELEMENTS',
];

/** Functions of newGame's literal that are replaced by markers; each is named in the golden file. */
export const NEW_GAME_MARKERS = [
  'makeWeapon', 'makeSpecialsState',
  'mikoInitState', 'berserkerInitState', 'sentinelInitState', 'strikerInitState', 'harmonizerInitState', 'pathfinderInitState',
];

/** The M1 loadout of the catalyst, as observed in Chromium (analyst A, section 3.3); only used as an input stub. */
export const CATALYST_ABILITY_IDS = ['cat_chain', 'cat_overload', 'cat_residue', 'cat_core', 'cat_haste'];

let cachedLiteral = null;
/** The text of the object literal that newGame passes to __set_game (cut out of the function by bracket matching). */
export function newGameLiteralText() {
  if (cachedLiteral === null) {
    const fn = findFunction(original().text, 'newGame', { allowImpure: true });
    const call = fn.text.indexOf('__set_game(');
    if (call < 0) throw new Error('newGame no longer calls __set_game(');
    const open = fn.text.indexOf('{', call);
    const close = skipBalanced(fn.text, open);
    cachedLiteral = fn.text.slice(open, close);
    if (/\b(document|window|navigator|localStorage|Date|performance|Math\.random)\b/.test(cachedLiteral)) {
      throw new Error('the newGame literal reads the environment; review tools/golden/_defs_vm.mjs');
    }
  }
  return cachedLiteral;
}

/** Real functions and declarations that a SEEDED newGame needs (makeWeapon draws once, prepareEnemyWaveTheme(1) draws not at all). */
const SEEDED_REAL = [
  'makeWeapon', 'rand', 'makeSeededRandom', 'setGameSeed', 'prepareEnemyWaveTheme', 'pickChangedFeaturedEnemyKind', 'isEliteWave', 'isBossWave',
  'isSpecialWave', 'isStandardEliteWave', 'isStandardBossWave', 'isEndlessEliteWave', 'isEndlessBossWave', 'enemyArchetypeUnlockWave',
  'progressionFeaturedEnemyKind', 'anomalyFactorActive', 'ENEMY_ARCHETYPES', 'ENEMY_KIND_ORDER', 'clamp',
];

/**
 * Evaluates the original newGame literal for one character/mode/difficulty with the real constants and these markers:
 * makeSpecialsState(charId, abilityIds) -> {__marker, charId, abilityIds}, the *InitState() functions and makeEndlessUnlocks()
 * -> {__marker}, and makeWeapon(id, opts) -> {__marker, id, opts}. The literal's order of evaluation is the game's.
 *
 * With `seed` (a number) the evaluation is the game's own sequence instead: setGameSeed(seed), then the literal with the REAL
 * makeWeapon (one gameRandom draw), then prepareEnemyWaveTheme(1) with the real functions; the sandbox's `gameRandomDraws` and
 * `gameRandom` are then the generator state a Godot Sim must reproduce.
 * Returns the sandbox together with the evaluated object (a vm-realm object; do not mutate across scenarios).
 */
export function evaluateNewGame({ character = 'catalyst', mode = 'normal', difficulty = 'normal', seed = null } = {}) {
  const seeded = seed !== null;
  const markerFns = NEW_GAME_MARKERS.filter((name) => !(seeded && name === 'makeWeapon')).map((name) => {
    if (name === 'makeWeapon') return 'function makeWeapon(id,opts){return{__marker:"makeWeapon",id,opts:opts||null};}';
    if (name === 'makeSpecialsState') return 'function makeSpecialsState(charId,abilityIds){return{__marker:"makeSpecialsState",charId,abilityIds:abilityIds||null};}';
    return `function ${name}(){return{__marker:${JSON.stringify(name)}};}`;
  }).join('\n');
  const prelude = `${markerFns}
var game=null,gameRandom=null,gameRandomDraws=0,gameRandomSeed=null;
var unlocks={weapons:[],elements:[]};
var __metaRun={abilityIds:${JSON.stringify(CATALYST_ABILITY_IDS)},trialIds:[],factorIds:[],factorSet:new Set(),factorMask:0,depth:0};`;
  // DEFAULT_UNLOCKS is a pure declaration; the fresh-profile `unlocks` of the game are a copy of it.
  const epilogue = `globalThis.__build=function(charId,selectedGameMode,selectedDifficulty,seed){
${seeded ? 'setGameSeed(seed);' : ''}
const c=CHARACTERS.find(x=>x.id===charId)||CHARACTERS[0];
const metaRun=__metaRun;
unlocks.weapons=[...DEFAULT_UNLOCKS.weapons];unlocks.elements=[...DEFAULT_UNLOCKS.elements];
const built=(${newGameLiteralText()});
${seeded ? 'game=built;prepareEnemyWaveTheme(1);' : ''}
return built;};`;
  const names = [...NEW_GAME_REAL, 'DEFAULT_UNLOCKS', ...(seeded ? SEEDED_REAL : [])];
  // setGameSeed names Math.random in its seedless branch, which is never taken here
  const sandbox = sandboxWith(names, { prelude, epilogue, impureNames: ['setGameSeed'] });
  const game = sandbox.__build(character, mode, difficulty, seed);
  return { sandbox, game };
}

// ---------------------------------------------------------------------------------------------------
// Snapshot of a game object as plain data (see tests/test_new_game.gd for the reader)
// ---------------------------------------------------------------------------------------------------

/**
 * Plain data of a vm-realm value:
 *   integer-valued finite number -> JSON number;  other number (fraction, -0, NaN, Infinity) -> {"f64": hex};
 *   string, boolean, null -> themselves;           undefined -> {"@undefined": true};
 *   plain object -> object of its snapshot (keys in the game's order); empty ones are still objects;
 *   array -> {"@array": n, "items": [...]} (items only if n <= 32);  Map/Set -> {"@map"|"@set": size};
 *   marker object (see NEW_GAME_MARKERS) -> {"@marker": name, ...its own fields}.
 */
export function snapshot(value) {
  if (value === undefined) return { '@undefined': true };
  if (value === null) return null;
  switch (typeof value) {
    case 'string': case 'boolean': return value;
    case 'number': return (Number.isInteger(value) && !Object.is(value, -0)) ? value : { f64: hex64(value) };
    case 'object': {
      const tag = Object.prototype.toString.call(value);
      if (Array.isArray(value)) {
        const out = { '@array': value.length };
        if (value.length <= 32) out.items = value.map(snapshot);
        return out;
      }
      if (tag === '[object Map]') return { '@map': value.size };
      if (tag === '[object Set]') return { '@set': value.size };
      if (value.__marker !== undefined) {
        const out = { '@marker': value.__marker };
        for (const key of Object.keys(value)) if (key !== '__marker') out[key] = snapshot(value[key]);
        return out;
      }
      const out = {};
      for (const key of Object.keys(value)) out[key] = snapshot(value[key]);
      return out;
    }
    default: throw new Error(`cannot snapshot a value of type ${typeof value}`);
  }
}
