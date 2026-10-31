#!/usr/bin/env node
// Extracts the simulation's definition data (CHARACTERS, WEAPONS, ENEMY_ARCHETYPES, DIFFICULTY_CONFIG, XP_CURVE,
// limits, ...) from the ORIGINAL game into godot/sim/defs/*.json (design step S3). Node 22, standard library only.
//
//   node tools/extract_defs.mjs           write godot/sim/defs/*.json
//   node tools/extract_defs.mjs --check   write nothing; exit 1 if the files on disk differ from a fresh extraction
//
// Options:
//   --source PATH   game HTML to read (default: webview-fg4/tests/fixtures/original.html)
//   --out DIR       output directory (default: godot/sim/defs)
//   -h, --help
//
// Exit codes: 0 success, 1 drift (--check), 2 extraction failed or bad usage.
//
// How: every constant is a PURE declaration of the game (`var NAME=...`). Its source text is cut out BY NAME
// (tools/lib/js_source.mjs: unique match, bracket scanner, compile check, FORBIDDEN_IDENTIFIERS screen) and all
// of them are evaluated together, in source order, in one node:vm context with an EMPTY sandbox. A declaration
// that needs anything outside the list (a DOM object, another game constant that is not listed) is a
// ReferenceError, never a silent default. The three constants of the original that depend on the device
// (`var X=IS_COARSE_POINTER?A:B`; true on Android/touch, false for a mouse) are evaluated for BOTH variants and
// stored as "pointer": {"coarse": ..., "fine": ...}; the simulation uses "coarse" (design: M1 targets Android).
//
// Output format (deterministic: fixed file list, game order of keys, no timestamps):
//   { "format": 1, "generated_by": ..., "source": ..., "source_sha256": ...,
//     "values": { NAME: value, ... }, "pointer": { "coarse": { NAME: value }, "fine": { NAME: value } } }
// JSON has no Infinity, NaN or -0, so those numbers are written as {"$num": "Infinity" | "-Infinity" | "NaN" | "-0"};
// godot/sim/defs.gd turns them back. Godot's JSON parser is not correctly rounded for long decimals (1/60 = 0.016666666666666666
// comes back one ulp off), so a non-integer with more than 15 significant digits is written as {"$num": "f64:<16 hex digits>"},
// its IEEE-754 bits. All other numbers are the shortest decimal that round-trips in JS (JSON.stringify); the Godot side checks
// every non-integer it loaded bit for bit against tests/golden/defs_bits.json (taken from the original).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  ORIGINAL_PATH, ORIGINAL_REL, REPO_ROOT, SourceError, cutNames, evaluateCuts, fail, findDeclaration, readOriginal, toPlain,
} from './lib/js_source.mjs';

const DEFAULT_OUT = path.join(REPO_ROOT, 'godot/sim/defs');
export const FORMAT_VERSION = 1;

// File -> the constants it holds, in the order they are written. Every constant appears in exactly one file.
export const GROUPS = {
  'characters.json': [
    'CHARACTERS', 'SIGNATURE_WEAPON_BY_CHARACTER', 'SIGNATURE_WEAPON_IDS', 'CHARACTER_ANIMATION_FPS', 'BERSERKER_CONFIG',
  ],
  'weapons.json': ['WEAPONS', 'ELEMENTS', 'ELEMENT_ID_LIST', 'DEFAULT_UNLOCKS', 'CAT_CHAIN'],
  'enemies.json': [
    'ENEMY_ARCHETYPES', 'ENEMY_KIND_ORDER', 'FEATURED_WAVE_CONFIG', 'DIRECTOR_BUDGET_CAP',
    'ENEMY_FIELD_SPAWN_PATTERNS', 'HIGH_DIFFICULTY_FIELD_SPAWN_PATTERNS', 'HIGH_DIFFICULTY_SPAWN_CONFIG',
    'ENEMY_BULLET_TIER', 'BOSS_PROJECTILE_SCALE', 'ENEMY_ARMOR_MIN', 'ENEMY_ARMOR_MAX',
    'ENDLESS_ENEMY_STAT_STEP', 'ENDLESS_ENEMY_STAT_CAP', 'ENDLESS_ENEMY_SPEED_STEP', 'ENDLESS_ENEMY_SPEED_CAP',
    'ENDLESS_SPAWN_PACE_STEP', 'ENDLESS_SPAWN_PACE_CAP', 'ENDLESS_ACTION_COOLDOWN_MIN',
    'ENDLESS_ARMOR_PER_50_WAVES', 'ENDLESS_EVASION_PER_50_WAVES',
    'ENEMY_STEERING_CONFIG', 'ENEMY_AI_RANK_TUNING', 'ENEMY_TACTICAL_ACTIONS',
    'ELITE_CLEAR_DELAY', 'WORLD_TREE_THREAT_RATE_MULTIPLIER',
  ],
  'rules.json': [
    'DIFFICULTY_CONFIG', 'DIFFICULTY_KEYS', 'XP_CURVE', 'SCORE_RULES',
    'MAX_WAVE', 'WAVE_DURATION', 'DAY_CYCLE_SECONDS', 'LEVEL_UP_CHOICE_DELAY_SECONDS',
    'FIXED_DT', 'MAX_STEPS_PER_FRAME', 'MAX_ACCUMULATED_SECONDS', 'MOVE_STICK_MAX',
    'PLAYER_DEFENSE_MIN', 'PLAYER_DEFENSE_MAX', 'DAMAGE_TYPE', 'DAMAGE_LAYER', 'DAMAGE_TYPE_RULES',
    'SAFE_ATTACK_INTERVAL', 'FINAL_BONUS_STEP', 'MAX_OVERFLOW_DAMAGE_MUL',
    'ELEMENT_AFFLICTION_DURATION', 'ELEMENT_REACTION_DAMAGE_MULTIPLIER',
  ],
  'limits.json': [
    'MAP_W', 'MAP_H', 'BASE_MAX_ENEMIES', 'MAX_HAZARDS', 'MAX_ENEMY_COLLISION_RADIUS',
    'NOVA_PROJECTILE_RADIUS', 'NOVA_PROJECTILE_ART_SIZE',
    'ENEMY_SEPARATION_GRID_SIZE', 'ENEMY_SEPARATION_GRID_STRIDE', 'ENEMY_GRID_MAX_CX', 'ENEMY_GRID_MAX_CY',
    'PROJECTILE_AVOID_GRID_SIZE', 'PROJECTILE_AVOID_GRID_STRIDE', 'PROJECTILE_AVOID_GRID_MAX_CY',
  ],
};

// Constants of the form `var NAME=IS_COARSE_POINTER?A:B;` (A and B are numeric expressions such as 520 or 1/15),
// and the file whose "pointer" section holds them.
export const POINTER_DEPENDENT = {
  'limits.json': [
    'MAX_PROJECTILES', 'MAX_XP_ORBS', 'MAX_ENEMY_PROJECTILES', 'HUD_UPDATE_INTERVAL',
    'WORLD_CHUNK_CACHE_MIN', 'WORLD_CHUNK_CACHE_MAX',
  ],
};

const POINTER_FORM = /^var ([A-Z_0-9]+)=IS_COARSE_POINTER\?[\d./]+:[\d./]+$/;

// ---------------------------------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------------------------------

/** Evaluates `cuts` (exposing `names`) with a fresh empty sandbox and returns the plain values by name. */
function evaluateNames(cuts, names, prelude = '') {
  const sandbox = evaluateCuts(cuts, { prelude, expose: names, filename: 'defs-declarations.js' });
  const api = sandbox.__api;
  const values = {};
  for (const name of names) {
    if (api[name] === undefined) fail(`${name} evaluated to undefined`);
    values[name] = toPlain(api[name], name);
  }
  return values;
}

/**
 * Returns { sourceSha256, files: Map(fileName -> data object), cutOffsets: {NAME: charOffset} } for the game
 * text. `data` is the object that is written as JSON (see the header for the layout).
 */
export function extractDefs(original = readOriginal()) {
  const src = original.text;
  const plainNames = Object.values(GROUPS).flat();
  const pointerNames = Object.values(POINTER_DEPENDENT).flat();
  const all = [...plainNames, ...pointerNames];
  if (new Set(all).size !== all.length) fail('a constant is listed twice in GROUPS/POINTER_DEPENDENT');

  const cuts = cutNames(src, plainNames);
  const values = evaluateNames(cuts, plainNames);

  const pointerCuts = pointerNames.map((name) => findDeclaration(src, name));
  for (const cut of pointerCuts) {
    if (!POINTER_FORM.test(cut.text) || cut.text.match(POINTER_FORM)[1] !== cut.name) {
      fail(`${cut.name} is not of the form IS_COARSE_POINTER?A:B: ${JSON.stringify(cut.text)}`);
    }
  }
  const pointer = {
    coarse: evaluateNames(pointerCuts, pointerNames, 'var IS_COARSE_POINTER=true;\n'),
    fine: evaluateNames(pointerCuts, pointerNames, 'var IS_COARSE_POINTER=false;\n'),
  };

  const files = new Map();
  for (const [file, names] of Object.entries(GROUPS)) {
    const data = {
      format: FORMAT_VERSION,
      generated_by: 'tools/extract_defs.mjs',
      source: ORIGINAL_REL,
      source_sha256: original.sha256,
      values: Object.fromEntries(names.map((n) => [n, values[n]])),
    };
    const pointerNamesOfFile = POINTER_DEPENDENT[file];
    if (pointerNamesOfFile) {
      data.pointer = {
        coarse: Object.fromEntries(pointerNamesOfFile.map((n) => [n, pointer.coarse[n]])),
        fine: Object.fromEntries(pointerNamesOfFile.map((n) => [n, pointer.fine[n]])),
      };
    }
    files.set(file, data);
  }
  return { sourceSha256: original.sha256, files };
}

// ---------------------------------------------------------------------------------------------------
// JSON text (deterministic, readable; non-finite numbers and -0 are wrapped, see the header)
// ---------------------------------------------------------------------------------------------------
/** Longest decimal (significant digits) that Godot's JSON parser reads back to the same double: tested on this data. */
const SAFE_SIGNIFICANT_DIGITS = 15;

const bitsView = new DataView(new ArrayBuffer(8));
function bitsHex(n) {
  bitsView.setFloat64(0, n);
  return bitsView.getBigUint64(0).toString(16).padStart(16, '0');
}

function significantDigits(n) {
  const [mantissa] = Math.abs(n).toExponential().split('e');
  return mantissa.replace('.', '').length;
}

function encodeNumber(n) {
  if (Number.isNaN(n)) return '{"$num": "NaN"}';
  if (n === Infinity) return '{"$num": "Infinity"}';
  if (n === -Infinity) return '{"$num": "-Infinity"}';
  if (Object.is(n, -0)) return '{"$num": "-0"}';
  // 16 and 17 digit decimals (1/60 is 0.016666666666666666) are where Godot's parser lands one ulp away; they travel as bits.
  if (!Number.isInteger(n) && significantDigits(n) > SAFE_SIGNIFICANT_DIGITS) return `{"$num": "f64:${bitsHex(n)}"}`;
  return JSON.stringify(n);
}

function inline(value) {
  if (value === null) return 'null';
  if (typeof value === 'number') return encodeNumber(value);
  if (typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(inline).join(', ')}]`;
  return `{${Object.entries(value).map(([k, v]) => `${JSON.stringify(k)}: ${inline(v)}`).join(', ')}}`;
}

const INLINE_LIMIT = 110;

function format(value, indent = '') {
  const flat = inline(value);
  const isContainer = value !== null && typeof value === 'object';
  if (!isContainer || flat.length + indent.length <= INLINE_LIMIT) return flat;
  const next = `${indent}  `;
  if (Array.isArray(value)) return `[\n${value.map((v) => `${next}${format(v, next)}`).join(',\n')}\n${indent}]`;
  return `{\n${Object.entries(value).map(([k, v]) => `${next}${JSON.stringify(k)}: ${format(v, next)}`).join(',\n')}\n${indent}}`;
}

/** The exact bytes of one output file. */
export function fileText(data) {
  return `${format(data)}\n`;
}

// ---------------------------------------------------------------------------------------------------
// Writing / checking
// ---------------------------------------------------------------------------------------------------
function expectedFiles(result) {
  return new Map([...result.files].map(([name, data]) => [name, Buffer.from(fileText(data), 'utf8')]));
}

function writeFiles(files, outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  let changed = 0;
  for (const [name, bytes] of files) {
    const target = path.join(outDir, name);
    const same = fs.existsSync(target) && Buffer.compare(fs.readFileSync(target), bytes) === 0;
    if (!same) { fs.writeFileSync(target, bytes); changed++; }
  }
  console.log(`wrote ${files.size} files to ${path.relative(REPO_ROOT, outDir) || '.'} (${changed} changed)`);
  return 0;
}

function checkFiles(files, outDir) {
  const problems = [];
  for (const [name, bytes] of files) {
    const target = path.join(outDir, name);
    if (!fs.existsSync(target)) problems.push(`missing: ${name}`);
    else if (Buffer.compare(fs.readFileSync(target), bytes) !== 0) problems.push(`differs from a fresh extraction: ${name}`);
  }
  if (fs.existsSync(outDir)) {
    for (const name of fs.readdirSync(outDir).sort()) {
      if (name.endsWith('.json') && !files.has(name)) problems.push(`unexpected file (not produced by the tool): ${name}`);
    }
  }
  const rel = path.relative(REPO_ROOT, outDir) || '.';
  if (problems.length === 0) {
    console.log(`check OK: ${files.size} files in ${rel} are identical to a fresh extraction`);
    return 0;
  }
  for (const p of problems) console.error(`  ${p}`);
  console.error(`check FAILED: ${problems.length} problem(s) in ${rel} (run: node tools/extract_defs.mjs)`);
  return 1;
}

function usage() {
  const header = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n');
  const lines = [];
  for (const line of header.slice(1)) {
    if (!line.startsWith('//')) break;
    lines.push(line.replace(/^\/\/ ?/, ''));
  }
  console.log(lines.join('\n'));
}

function main(argv) {
  const options = { check: false, source: ORIGINAL_PATH, out: DEFAULT_OUT };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => { if (i + 1 >= argv.length) fail(`${arg} needs a value`); return path.resolve(argv[++i]); };
    if (arg === '--check') options.check = true;
    else if (arg === '--source') options.source = value();
    else if (arg === '--out') options.out = value();
    else if (arg === '-h' || arg === '--help') { usage(); return 0; }
    else fail(`unknown option: ${arg} (see --help)`);
  }
  const files = expectedFiles(extractDefs(readOriginal(options.source)));
  return options.check ? checkFiles(files, options.out) : writeFiles(files, options.out);
}

const isMain = process.argv[1] !== undefined && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    if (error instanceof SourceError) {
      console.error(`extract_defs: ${error.message}`);
      process.exitCode = 2;
    } else {
      throw error;
    }
  }
}
