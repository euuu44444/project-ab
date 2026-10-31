#!/usr/bin/env node
// Generates the golden test vectors of the Godot port from the ORIGINAL game (design section 9.1, step S3).
// Node 22, standard library only (no npm dependencies).
//
//   node tools/gen_golden.mjs                 write godot/tests/golden/<topic>.json for every topic module
//   node tools/gen_golden.mjs --check         write nothing; exit 1 if a file on disk differs from a fresh generation
//   node tools/gen_golden.mjs --list          list the topic modules
//
// Options:
//   --only NAME     handle only the topic NAME (repeatable; --check then ignores files of other topics)
//   --source PATH   game HTML to read (default: webview-fg4/tests/fixtures/original.html)
//   --out DIR       output directory (default: godot/tests/golden)
//   -h, --help
//
// Exit codes: 0 success, 1 drift (--check), 2 generation failed or bad usage.
//
// How it works. Every topic is a module tools/golden/<topic>.mjs (files starting with "_" are helpers and are not
// loaded) with two exports:
//
//   export const name = 'math';                    // output file godot/tests/golden/math.json
//   export function generate(extract, info) {...}  // returns a JSON-serialisable value (the file body)
//
// `extract(names, options)` hands the module the game's own code. Each name is cut out of the game's JavaScript by
// name (a `var|let|const NAME=...` declaration or a `function NAME(...){...}`, exactly one of them must exist), the
// pieces are put in source order and evaluated in a new node:vm context with an EMPTY sandbox and code generation
// disabled. A piece that touches the DOM, the clock, storage or any game function it was not given throws a
// ReferenceError instead of running, and Math.random inside the context throws. options:
//   prelude   JavaScript run before the pieces (declare the game globals the pieces need, e.g. `var game=null;`)
//   expose    {key: 'JS expression'} evaluated after the pieces, to read or drive state of the context
//   allow     identifiers or patterns of FORBIDDEN_IDENTIFIERS that the cut text may contain (e.g. 'Math.random' for a
//             function that only reads it on a path the module never takes)
// and returns {name: value, ..., key: value}: functions stay callable and keep their closure over the context.
// `info` carries {sourcePath, sourceSha256, sourceText}. The result of generate() is written as stable JSON (fixed key order, no
// timestamps), so the same game and the same Node give byte-identical files.
//
// The expected values of the tests must never be typed by hand: they come from the game's code through `extract`, or
// from a JavaScript reference whose faithfulness to the pinned Chromium 141 is verified by
// tools/verify_golden_chromium.mjs (see tools/golden/math.mjs for the one case, Math.sin and Math.cos).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath, pathToFileURL } from 'node:url';

const TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOLS_DIR, '..');
const SOURCE_REL = 'webview-fg4/tests/fixtures/original.html';
const DEFAULT_SOURCE = path.join(REPO_ROOT, SOURCE_REL);
const DEFAULT_OUT = path.join(REPO_ROOT, 'godot/tests/golden');
const MODULE_DIR = path.join(TOOLS_DIR, 'golden');
const TOPIC_NAME = /^[a-z][a-z0-9_]*$/;

// Identifiers that a cut-out piece must never contain (belt and braces: the empty sandbox already makes any of
// them a ReferenceError, except Math.random, which exists in every context and is replaced by a throwing stub).
// Same list as tools/extract_assets.mjs.
const FORBIDDEN_WORDS = ['document', 'window', 'navigator', 'matchMedia', 'localStorage', 'sessionStorage', 'fetch', 'XMLHttpRequest',
  'Image', 'Audio', 'eval', 'Function', 'import', 'require', 'process', 'globalThis', 'self', 'setTimeout', 'Date'];
const FORBIDDEN_MATH_RANDOM = 'Math.random';

/** The pattern a piece is checked against; `allow` lists forbidden words (or 'Math.random') that are reviewed exceptions. */
function forbiddenPattern(allow) {
  for (const entry of allow) {
    if (entry !== FORBIDDEN_MATH_RANDOM && !FORBIDDEN_WORDS.includes(entry)) fail(`options.allow: "${entry}" is not a forbidden identifier`);
  }
  const words = FORBIDDEN_WORDS.filter((w) => !allow.includes(w));
  const parts = [];
  if (words.length > 0) parts.push(`\\b(?:${words.join('|')})\\b`);
  if (!allow.includes(FORBIDDEN_MATH_RANDOM)) parts.push('Math\\.random');
  return new RegExp(parts.length > 0 ? parts.join('|') : '(?!)');
}
const MAX_PIECE_CHARS = 20000;

export class GoldenError extends Error {}
const fail = (message) => { throw new GoldenError(message); };

// ---------------------------------------------------------------------------------------------------
// 1. Cutting declarations and functions out of the game's JavaScript
// ---------------------------------------------------------------------------------------------------
const CLOSER = { '{': '}', '[': ']', '(': ')' };

function skipQuoted(src, i) {
  const quote = src[i];
  for (let j = i + 1; j < src.length; j++) {
    const c = src[j];
    if (c === '\\') j++;
    else if (c === quote) return j + 1;
    else if (c === '\n') break;
  }
  return fail(`unterminated string literal at char ${i}`);
}

function skipTemplate(src, i) {
  for (let j = i + 1; j < src.length; j++) {
    const c = src[j];
    if (c === '\\') j++;
    else if (c === '`') return j + 1;
    else if (c === '$' && src[j + 1] === '{') j = skipBalanced(src, j + 1) - 1;
  }
  return fail(`unterminated template literal at char ${i}`);
}

function skipComment(src, i) {
  if (src[i + 1] === '/') {
    const end = src.indexOf('\n', i);
    return end < 0 ? src.length : end;
  }
  const end = src.indexOf('*/', i + 2);
  return end < 0 ? fail(`unterminated comment at char ${i}`) : end + 2;
}

/** src[i] is an opening bracket; returns the index just after its matching closer. */
function skipBalanced(src, i) {
  const stack = [CLOSER[src[i]]];
  let j = i + 1;
  while (j < src.length) {
    const c = src[j];
    if (c === '"' || c === "'") j = skipQuoted(src, j);
    else if (c === '`') j = skipTemplate(src, j);
    else if (c === '/' && (src[j + 1] === '/' || src[j + 1] === '*')) j = skipComment(src, j);
    else {
      if (CLOSER[c]) stack.push(CLOSER[c]);
      else if (c === ')' || c === ']' || c === '}') {
        if (stack.pop() !== c) fail(`mismatched ${c} at char ${j}`);
        if (stack.length === 0) return j + 1;
      }
      j++;
    }
  }
  return fail(`unbalanced bracket opened at char ${i}`);
}

/** Index of the `;` that ends the statement whose expression starts at i (or of an unmatched closer). */
function statementEnd(src, i) {
  let j = i;
  while (j < src.length) {
    const c = src[j];
    if (c === ';') return j;
    if (c === '"' || c === "'") j = skipQuoted(src, j);
    else if (c === '`') j = skipTemplate(src, j);
    else if (c === '/' && (src[j + 1] === '/' || src[j + 1] === '*')) j = skipComment(src, j);
    else if (CLOSER[c]) j = skipBalanced(src, j);
    else if (c === ')' || c === ']' || c === '}') return j;
    else j++;
  }
  return src.length;
}

const escapeRegex = (name) => name.replace(/[$]/g, '\\$&');

/**
 * Cuts `name` out of the game: a `var|let|const NAME=...` declaration (without the trailing `;`) or a
 * `function NAME(...){...}`. Exactly one of the two must exist, exactly once.
 */
export function cutByName(src, name, allow = []) {
  if (!/^[A-Za-z_$][\w$]*$/.test(name)) fail(`not an identifier: ${JSON.stringify(name)}`);
  const declarationRe = new RegExp(`(?<![\\w$.])(?:var|let|const)\\s+${escapeRegex(name)}\\s*=`, 'g');
  const functionRe = new RegExp(`(?<![\\w$.])function\\s+${escapeRegex(name)}\\s*\\(`, 'g');
  const declarations = [...src.matchAll(declarationRe)];
  const functions = [...src.matchAll(functionRe)];
  if (declarations.length + functions.length !== 1) {
    fail(`${name}: expected exactly 1 declaration or function in the game, found ${declarations.length} declaration(s) and ${functions.length} function(s)`);
  }
  let start;
  let end;
  let kind;
  if (declarations.length === 1) {
    kind = 'declaration';
    start = declarations[0].index;
    end = statementEnd(src, start + declarations[0][0].length);
  } else {
    kind = 'function';
    start = functions[0].index;
    const parametersStart = src.indexOf('(', start);
    const bodyStart = src.indexOf('{', skipBalanced(src, parametersStart));
    end = skipBalanced(src, bodyStart);
  }
  const text = src.slice(start, end);
  if (text.length > MAX_PIECE_CHARS) fail(`${name} is suspiciously long (${text.length} chars): the end was not found correctly`);
  const pattern = forbiddenPattern(allow);
  const forbidden = pattern.exec(text);
  if (forbidden) fail(`${name} references "${forbidden[0]}"; only pure pieces of the game may be evaluated (use options.allow for a reviewed exception)`);
  return { name, kind, start, end, text };
}

/** Builds extract(names, options) for one game source text. */
export function makeExtractor(src) {
  return function extract(names, options = {}) {
    const { prelude = '', expose = {}, allow = [] } = options;
    if (!Array.isArray(names) || names.some((n) => typeof n !== 'string')) fail('extract: names must be an array of strings');
    if (new Set(names).size !== names.length) fail(`extract: duplicate names in ${JSON.stringify(names)}`);
    const pieces = names.map((n) => cutByName(src, n, allow)).sort((a, b) => a.start - b.start);
    const exposed = [...names.map((n) => [n, n]), ...Object.entries(expose)];
    const code = `${prelude}\n${pieces.map((p) => p.text).join(';\n')};\n`
      + `({${exposed.map(([key, expression]) => `${JSON.stringify(key)}:(${expression})`).join(',\n')}});`;
    const context = vm.createContext({}, { codeGeneration: { strings: false, wasm: false } });
    // The game's random numbers must come from its seeded generator only; make any other source loud.
    vm.runInContext('Math.random = function () { throw new Error("Math.random was called inside a cut-out piece of the game"); };', context);
    try {
      return vm.runInContext(code, context, { filename: 'cut-pieces.js', timeout: 10000 });
    } catch (error) {
      return fail(`evaluating ${JSON.stringify(names)} failed: ${error.message}`);
    }
  };
}

// ---------------------------------------------------------------------------------------------------
// 2. Output
// ---------------------------------------------------------------------------------------------------

/** JSON with one-space indentation; short values stay on one line, long strings stay unbroken. */
export function format(value, indent = '') {
  const flat = JSON.stringify(value);
  if (flat === undefined) fail('cannot serialise an undefined value');
  if (typeof value !== 'object' || value === null || flat.length <= 100) return flat;
  const next = `${indent} `;
  if (Array.isArray(value)) {
    if (value.every((v) => typeof v !== 'object' || v === null)) {
      const lines = [];
      let line = '';
      for (const item of value.map((v) => JSON.stringify(v))) {
        if (line && next.length + line.length + item.length + 2 > 110) { lines.push(line); line = ''; }
        line += line ? `, ${item}` : item;
      }
      lines.push(line);
      return `[\n${lines.map((l) => next + l).join(',\n')}\n${indent}]`;
    }
    return `[\n${value.map((v) => next + format(v, next)).join(',\n')}\n${indent}]`;
  }
  return `{\n${Object.entries(value).map(([k, v]) => `${next}${JSON.stringify(k)}: ${format(v, next)}`).join(',\n')}\n${indent}}`;
}

async function loadModules() {
  const files = fs.readdirSync(MODULE_DIR).filter((f) => f.endsWith('.mjs') && !f.startsWith('_')).sort();
  const modules = [];
  const seen = new Map();
  for (const file of files) {
    const module = await import(pathToFileURL(path.join(MODULE_DIR, file)).href);
    if (typeof module.name !== 'string' || !TOPIC_NAME.test(module.name)) fail(`tools/golden/${file}: export "name" must be a string matching ${TOPIC_NAME}`);
    if (typeof module.generate !== 'function') fail(`tools/golden/${file}: export "generate" must be a function`);
    if (seen.has(module.name)) fail(`tools/golden/${file}: topic ${module.name} is also produced by tools/golden/${seen.get(module.name)}`);
    seen.set(module.name, file);
    modules.push({ file, name: module.name, generate: module.generate });
  }
  return modules;
}

function readIfExists(file) {
  try { return fs.readFileSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');

function usage() {
  const text = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n');
  console.log(text.slice(1).filter((l, i) => i < 36 && l.startsWith('//')).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
}

async function main(argv) {
  const options = { check: false, list: false, only: [], source: DEFAULT_SOURCE, out: DEFAULT_OUT };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => { if (i + 1 >= argv.length) fail(`${arg} needs a value`); return argv[++i]; };
    if (arg === '--check') options.check = true;
    else if (arg === '--list') options.list = true;
    else if (arg === '--only') options.only.push(value());
    else if (arg === '--source') options.source = path.resolve(value());
    else if (arg === '--out') options.out = path.resolve(value());
    else if (arg === '-h' || arg === '--help') { usage(); return 0; }
    else fail(`unknown argument: ${arg} (see --help)`);
  }
  const nodeMajor = Number(process.versions.node.split('.')[0]);
  if (nodeMajor < 22) fail(`Node 22 or newer is required (found ${process.version})`);

  const modules = await loadModules();
  if (options.list) {
    for (const m of modules) console.log(`${m.name.padEnd(12)} tools/golden/${m.file}`);
    return 0;
  }
  for (const name of options.only) if (!modules.some((m) => m.name === name)) fail(`--only ${name}: no such topic (see --list)`);
  const selected = options.only.length > 0 ? modules.filter((m) => options.only.includes(m.name)) : modules;

  const sourceBytes = fs.readFileSync(options.source);
  const html = sourceBytes.toString('utf8');
  if (html.includes('�')) fail('the source is not valid UTF-8');
  const extract = makeExtractor(html);
  const info = { sourcePath: path.relative(REPO_ROOT, options.source), sourceSha256: sha256(sourceBytes), sourceText: html };

  const files = new Map();
  for (const m of selected) {
    const started = Date.now();
    const body = m.generate(extract, info);
    if (body === undefined || body === null || typeof body !== 'object') fail(`topic ${m.name}: generate() must return an object`);
    files.set(`${m.name}.json`, Buffer.from(`${format(body)}\n`));
    console.log(`generated ${m.name}.json (${files.get(`${m.name}.json`).length} bytes, ${Date.now() - started} ms)`);
  }

  const problems = [];
  if (options.check) {
    for (const [name, data] of files) {
      const existing = readIfExists(path.join(options.out, name));
      if (existing === null) problems.push(`missing:    ${name}`);
      else if (!existing.equals(data)) problems.push(`differs:    ${name} (${existing.length} bytes on disk, ${data.length} expected; sha256 ${sha256(existing).slice(0, 16)} vs ${sha256(data).slice(0, 16)})`);
    }
    if (options.only.length === 0 && fs.existsSync(options.out)) {
      for (const name of fs.readdirSync(options.out).filter((f) => f.endsWith('.json')).sort()) {
        if (!files.has(name)) problems.push(`unexpected: ${name} (no topic module produces it)`);
      }
    }
    if (problems.length === 0) {
      console.log(`check OK: ${files.size} golden file(s) in ${path.relative(REPO_ROOT, options.out) || '.'} are identical to a fresh generation`);
      return 0;
    }
    console.error(`check FAILED: ${problems.length} problem(s) in ${path.relative(REPO_ROOT, options.out) || '.'} (run: node tools/gen_golden.mjs)`);
    for (const problem of problems) console.error(`  ${problem}`);
    return 1;
  }

  fs.mkdirSync(options.out, { recursive: true });
  let changed = 0;
  for (const [name, data] of files) {
    const target = path.join(options.out, name);
    const existing = readIfExists(target);
    const same = existing !== null && existing.equals(data);
    if (!same) { fs.writeFileSync(target, data); changed++; }
    console.log(`${same ? 'unchanged' : existing === null ? 'created  ' : 'updated  '} ${path.relative(REPO_ROOT, target)} (${data.length} bytes)`);
  }
  if (options.only.length === 0) {
    for (const name of fs.readdirSync(options.out).filter((f) => f.endsWith('.json')).sort()) {
      if (!files.has(name)) console.log(`WARNING: ${path.relative(REPO_ROOT, path.join(options.out, name))} is not produced by any topic module (delete it if it is stale)`);
    }
  }
  console.log(`${files.size} file(s), ${changed} written`);
  return 0;
}

const isMain = process.argv[1] !== undefined && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  try {
    process.exitCode = await main(process.argv.slice(2));
  } catch (error) {
    if (error instanceof GoldenError) {
      console.error(`gen_golden: ERROR: ${error.message}`);
      process.exitCode = 2;
    } else if (error?.code === 'ENOENT') {
      console.error(`gen_golden: ERROR: cannot read ${error.path}`);
      process.exitCode = 2;
    } else {
      throw error;
    }
  }
}
