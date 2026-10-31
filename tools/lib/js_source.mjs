// Cuts named declarations and functions out of the ORIGINAL game's JavaScript and evaluates them in an
// isolated node:vm context (design step S3; the technique of tools/extract_assets.mjs, shared by
// tools/extract_defs.mjs and the golden-vector generators under tools/golden/).
//
// Node 22, standard library only. Nothing here reads a file other than the original game, and nothing
// writes anywhere.
//
// Guarantees:
//   * The source text of a declaration or function is found BY NAME and must be unique in the game
//     (`var|let|const NAME=` exactly once, `function NAME(` exactly once). The bracket scanner understands
//     strings, template literals, comments and (heuristically) regular-expression literals; every cut is
//     additionally compiled with `new vm.Script` so that a wrong boundary is a SyntaxError here and not
//     a silently different program.
//   * Pure declarations (constants) are screened against FORBIDDEN_IDENTIFIERS (DOM, storage, time, random,
//     dynamic code). Functions are cut with the same screen unless the caller passes `allowImpure`.
//   * Evaluation happens in a NEW context whose global object is the caller's sandbox (empty by default),
//     with string code generation and WebAssembly disabled and a time limit. A cut that touches anything
//     the caller did not provide throws a ReferenceError instead of running.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const LIB_DIR = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(LIB_DIR, '..', '..');
export const ORIGINAL_REL = 'webview-fg4/tests/fixtures/original.html';
export const ORIGINAL_PATH = path.join(REPO_ROOT, ORIGINAL_REL);

// Extends the S2 list with the environment readers that must never end up in the simulation data.
export const FORBIDDEN_IDENTIFIERS = /\b(document|window|navigator|matchMedia|localStorage|sessionStorage|fetch|XMLHttpRequest|Image|Audio|eval|Function|import|require|process|globalThis|self|setTimeout|Date|performance|location|innerWidth|innerHeight)\b|Math\.random/;

export class SourceError extends Error {}
export const fail = (message) => { throw new SourceError(message); };

export const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');

/** Reads the original game; returns { text, sha256 }. */
export function readOriginal(file = ORIGINAL_PATH) {
  const bytes = fs.readFileSync(file);
  return { text: bytes.toString('utf8'), sha256: sha256(bytes) };
}

// ---------------------------------------------------------------------------------------------------
// Bracket scanner
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

/** Heuristic: does the `/` at src[j] start a regular-expression literal (and not a division)? */
function isRegexStart(src, j) {
  let k = j - 1;
  while (k >= 0 && /\s/.test(src[k])) k--;
  const p = src[k];
  if (p === undefined) return true;
  if (/[(,=:[!&|?{};+\-*%<>~^]/.test(p)) return true;
  return /(?:return|typeof|case|in|of|void)$/.test(src.slice(Math.max(0, k - 6), k + 1));
}

function skipRegex(src, i) {
  let inClass = false;
  for (let j = i + 1; j < src.length; j++) {
    const c = src[j];
    if (c === '\\') { j++; continue; }
    if (c === '[') inClass = true;
    else if (c === ']') inClass = false;
    else if (c === '/' && !inClass) {
      j++;
      while (/[a-z]/.test(src[j])) j++;
      return j;
    } else if (c === '\n') break;
  }
  return fail(`unterminated regular expression literal at char ${i}`);
}

/** src[i] is an opening bracket; returns the index just after its matching closer. */
export function skipBalanced(src, i) {
  const stack = [CLOSER[src[i]]];
  let j = i + 1;
  while (j < src.length) {
    const c = src[j];
    if (c === '"' || c === "'") j = skipQuoted(src, j);
    else if (c === '`') j = skipTemplate(src, j);
    else if (c === '/' && (src[j + 1] === '/' || src[j + 1] === '*')) j = skipComment(src, j);
    else if (c === '/' && isRegexStart(src, j)) j = skipRegex(src, j);
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
    else if (c === '/' && isRegexStart(src, j)) j = skipRegex(src, j);
    else if (CLOSER[c]) j = skipBalanced(src, j);
    else if (c === ')' || c === ']' || c === '}') return j;
    else j++;
  }
  return src.length;
}

const escapeRegex = (name) => name.replace(/[$]/g, '\\$&');

function checkCompiles(cut) {
  try {
    new vm.Script(cut.text, { filename: `cut-${cut.name}.js` });
  } catch (error) {
    fail(`the text cut out for ${cut.name} (chars ${cut.start}-${cut.end}) does not compile: ${error.message}`);
  }
}

function screen(cut, allowImpure) {
  if (cut.text.length > 60000) fail(`${cut.name} is suspiciously long (${cut.text.length} chars): end not found`);
  if (!allowImpure) {
    const forbidden = FORBIDDEN_IDENTIFIERS.exec(cut.text);
    if (forbidden) fail(`${cut.name} references "${forbidden[0]}"; only pure code may be evaluated`);
  }
}

/** Cuts `var|let|const NAME=...` (without the trailing `;`); NAME must be declared exactly once. */
export function findDeclaration(src, name, { allowImpure = false } = {}) {
  const re = new RegExp(`(?<![\\w$.])(?:var|let|const)\\s+${escapeRegex(name)}\\s*=`, 'g');
  const hits = [...src.matchAll(re)];
  if (hits.length !== 1) fail(`declaration of ${name}: expected exactly 1 match, found ${hits.length}`);
  const start = hits[0].index;
  const end = statementEnd(src, start + hits[0][0].length);
  const cut = { name, kind: 'declaration', start, end, text: src.slice(start, end) };
  screen(cut, allowImpure);
  checkCompiles(cut);
  return cut;
}

/** Cuts `function NAME(...){...}`; NAME must be declared exactly once. */
export function findFunction(src, name, { allowImpure = false } = {}) {
  const re = new RegExp(`(?<![\\w$.])function\\s+${escapeRegex(name)}\\s*\\(`, 'g');
  const hits = [...src.matchAll(re)];
  if (hits.length !== 1) fail(`function ${name}: expected exactly 1 match, found ${hits.length}`);
  const start = hits[0].index;
  const paramsStart = src.indexOf('(', start);
  const paramsEnd = skipBalanced(src, paramsStart);
  const bodyStart = src.indexOf('{', paramsEnd);
  const end = skipBalanced(src, bodyStart);
  const cut = { name, kind: 'function', start, end, text: src.slice(start, end) };
  screen(cut, allowImpure);
  checkCompiles(cut);
  return cut;
}

/** Declaration or function, whichever the name is (a name that is both is an error). */
export function findNamed(src, name, options = {}) {
  const decl = new RegExp(`(?<![\\w$.])(?:var|let|const)\\s+${escapeRegex(name)}\\s*=`).test(src);
  const func = new RegExp(`(?<![\\w$.])function\\s+${escapeRegex(name)}\\s*\\(`).test(src);
  if (decl && func) fail(`${name} is both a declaration and a function`);
  if (!decl && !func) fail(`${name} is neither a declaration nor a function in the game`);
  return decl ? findDeclaration(src, name, options) : findFunction(src, name, options);
}

/** Cuts every name (declaration or function), each once, in the game's source order. */
export function cutNames(src, names, { allowImpure = false, impureNames = [] } = {}) {
  const unique = [...new Set(names)];
  if (unique.length !== names.length) fail(`duplicate names in the cut list: ${names.filter((n, i) => names.indexOf(n) !== i).join(', ')}`);
  return unique
    .map((name) => findNamed(src, name, { allowImpure: allowImpure || impureNames.includes(name) }))
    .sort((a, b) => a.start - b.start);
}

// ---------------------------------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------------------------------

/**
 * Evaluates the cuts (in source order) after `prelude`, in a new context whose global object is `sandbox`
 * (empty by default). Returns the sandbox: `var` and `function` declarations of the cuts are properties of it,
 * and everything listed in `expose` (also let/const) is in `sandbox.__api`.
 * Code in the context cannot create code from strings and cannot run longer than `timeout` ms.
 */
export function evaluateCuts(cuts, { prelude = '', epilogue = '', expose = [], sandbox = {}, timeout = 10000, filename = 'original-cuts.js' } = {}) {
  const ordered = [...cuts].sort((a, b) => a.start - b.start);
  const api = expose.length ? `\nglobalThis.__api={${expose.map((n) => `${JSON.stringify(n)}:${n}`).join(',')}};` : '';
  const code = `${prelude}\n${ordered.map((c) => c.text).join(';\n')};\n${epilogue}${api}\n`;
  const context = vm.createContext(sandbox, { codeGeneration: { strings: false, wasm: false } });
  // The game's random numbers must come from its seeded generator only: any other source is made loud.
  vm.runInContext('Math.random=function(){throw new Error("Math.random was called inside cut-out game code");};', context);
  try {
    vm.runInContext(code, context, { filename, timeout });
  } catch (error) {
    fail(`evaluating the cut-out code failed: ${error.message}`);
  }
  return sandbox;
}

/** Converts a value from a vm context into plain JSON-able data (cross-realm safe); rejects the rest. */
export function toPlain(value, where = 'value') {
  if (value === null) return null;
  switch (typeof value) {
    case 'number': case 'string': case 'boolean': return value;
    case 'object': {
      if (Array.isArray(value)) return value.map((v, i) => toPlain(v, `${where}[${i}]`));
      const out = {};
      for (const key of Object.keys(value)) out[key] = toPlain(value[key], `${where}.${key}`);
      return out;
    }
    default: return fail(`${where} is of type ${typeof value}, which is not plain data`);
  }
}
