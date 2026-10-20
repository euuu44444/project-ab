#!/usr/bin/env node
// Compares two swarm-trace/1 files step by step: the reference (the original game in Chromium, tools/reference-trace/capture.mjs)
// and the port (the Godot sim, tools/emit_port_trace.sh). Design section 9.2.
//
//   node tools/compare_trace.mjs REFERENCE PORT [--fields LIST] [--ignore LIST] [--until N] [--from N] [--tolerance T] [--json]
//
//   REFERENCE, PORT   trace files (.jsonl.gz or .jsonl; the gzip layer is detected by its magic bytes)
//   --fields LIST     what to compare, comma separated; default: everything both traces carry. A selector is a group or
//                     group.field:  player  camera  wave  enemies  projectiles  xp_orbs  counts  draws  slot_draws  outside_draws
//                     state  input  steps          e.g. player.x   wave.t   enemies.hp   counts.enemies   slot_draws.main:5
//                     (enemy, projectile, xp_orb are accepted for the lists; an entity group also has the pseudo-field `length`,
//                     the number of entities, and `steps` is the number of steps in the files)
//   --ignore LIST     selectors to leave out of the selection
//   --until N         compare steps 1..N only          --from N   compare steps N.. only
//                     Both traces must have the requested steps: --until beyond the end of the shorter trace, an empty
//                     range (an empty trace, --from past the end) and, without --until, traces of different length are
//                     reported as a divergence of the group `steps` (exit 1), whatever is selected. `--ignore steps` skips
//                     only the different-length check. --from after --until is a usage error.
//   --tolerance T     floats are equal when they differ by at most T absolutely or relatively (default 0: the bit patterns
//                     must be identical; design 9.2 allows 1e-6 for coordinates and hp)
//   --json            print the result as JSON instead of the text report
//
// Selecting a field of an entity list (`enemies.x`) also compares the list's length (`enemies.length`) unless that is ignored
// explicitly. counts.particles depends on effects (fxRandom is shared with audio and rendering), not on gameplay: it is left out
// of the default selection and of `--fields counts`; name it (`--fields counts.particles`) to compare it.
//
// Fields are matched by name through the "fields" lists of the two headers, so a port trace that carries fewer fields (its
// header lists them under "unported") compares on the fields it has; a selector that names a field one of the files lacks is an
// error. Entity lists are compared by position, the order of the original's arrays. For every group the report gives the
// first diverging step with both values (decoded double and hex bit pattern, and the distance in ulps), and how many compared
// steps differ.
//
// Exit code: 0 no divergence in the selected fields over the compared steps; 1 at least one divergence; 2 usage or file error.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readTrace, parseFieldSpec, hexToDouble, formatDouble } from './lib/trace_io.mjs';

class UsageError extends Error {}

const LIST_GROUPS = { enemies: 'enemy', projectiles: 'projectile', xp_orbs: 'xp_orb' };
const FIELD_GROUPS = ['player', 'camera', 'wave'];
const ALIASES = { enemy: 'enemies', projectile: 'projectiles', xp_orb: 'xp_orbs', slots: 'slot_draws', step: 'steps' };
const GROUP_ORDER = ['steps', 'state', 'input', 'draws', 'slot_draws', 'outside_draws', 'counts', 'player', 'camera', 'wave', 'enemies', 'projectiles', 'xp_orbs'];
// Fields that depend on effects (particles are created from fxRandom, which audio and rendering also read) and not on gameplay:
// left out of the default selection and of a group selector, compared only when named (`--fields counts.particles`).
const EFFECT_ONLY = new Set(['counts\u0000particles']);

// ---- values ----------------------------------------------------------------------------------------------------------------

const orderedKey = (hex) => {
  const bits = BigInt(`0x${hex}`);
  return bits >> 63n ? -(bits & 0x7fffffffffffffffn) : bits;
};

function floatsEqual(a, b, tolerance) {
  if (a === b) return true;
  const x = hexToDouble(a); const y = hexToDouble(b);
  if (Number.isNaN(x) || Number.isNaN(y)) return Number.isNaN(x) && Number.isNaN(y);
  if (tolerance <= 0 || !Number.isFinite(x) || !Number.isFinite(y)) return false;
  const diff = Math.abs(x - y);
  return diff <= tolerance || diff <= tolerance * Math.max(Math.abs(x), Math.abs(y));
}

function describeFloat(hex, other) {
  const x = hexToDouble(hex);
  const signOnly = other !== undefined && other !== hex && Number.isFinite(x) && Number.isFinite(hexToDouble(other)) && orderedKey(hex) === orderedKey(other);
  return `${formatDouble(x)} (${hex})${signOnly ? ' [differs only in the sign of zero]' : ''}`;
}

function floatDifference(refHex, portHex) {
  const x = hexToDouble(refHex); const y = hexToDouble(portHex);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return '';
  const ulps = orderedKey(portHex) - orderedKey(refHex);
  const delta = y - x;
  return `port - reference = ${formatDouble(delta)}, ${ulps < 0n ? -ulps : ulps} ulp`;
}

// ---- reading ---------------------------------------------------------------------------------------------------------------

function loadTrace(file) {
  try {
    return readTrace(file);
  } catch (error) {
    throw new UsageError(`${file}: ${error.message}`);
  }
}

/** The schema of a trace: group -> [{ name, type, index }], from the header's "fields". */
function schemaOf(trace) {
  const out = {};
  for (const [group, specs] of Object.entries(trace.header.fields || {})) {
    out[group] = parseFieldSpec(specs).map((f, index) => ({ ...f, index }));
  }
  return out;
}

// ---- selection -------------------------------------------------------------------------------------------------------------

/** The comparable (group, field) pairs: the fields both traces carry, with the type. */
function buildUniverse(ref, port) {
  const universe = new Map(); // group -> Map(field -> type)
  const add = (group, field, type) => {
    if (!universe.has(group)) universe.set(group, new Map());
    universe.get(group).set(field, type);
  };
  add('steps', 'count', 'i');
  add('state', 'state', 's');
  add('input', 'moveX', 'f'); add('input', 'moveY', 'f'); add('input', 'keys', 'j');
  add('draws', 'draws', 'i');
  add('outside_draws', 'outside_draws', 'i');
  const slotKeys = new Set();
  for (const trace of [ref, port]) for (const step of trace.steps) for (const key of Object.keys(step.slot_draws || {})) slotKeys.add(key);
  for (const trace of [ref, port]) {
    for (const [list, ids] of Object.entries(trace.header.slots || {})) ids.forEach((_, i) => slotKeys.add(`${list}:${i}`));
  }
  for (const key of [...slotKeys].sort()) add('slot_draws', key, 'i');
  const countFields = (ref.header.count_fields || []).filter((c) => (port.header.count_fields || []).includes(c));
  for (const c of countFields) add('counts', c, 'i');
  const refSchema = schemaOf(ref); const portSchema = schemaOf(port);
  const onlyInReference = {};
  const groupMap = { player: 'player', camera: 'camera', wave: 'wave', enemies: 'enemy', projectiles: 'projectile', xp_orbs: 'xp_orb' };
  for (const [group, schemaGroup] of Object.entries(groupMap)) {
    const have = new Set((portSchema[schemaGroup] || []).map((f) => f.name));
    for (const f of refSchema[schemaGroup] || []) {
      if (have.has(f.name)) add(group, f.name, f.type);
      else (onlyInReference[group] ||= []).push(f.name);
    }
    if (group in LIST_GROUPS) add(group, 'length', 'i');
    if (!universe.has(group)) universe.set(group, new Map());
  }
  return { universe, onlyInReference, refSchema, portSchema };
}

function parseSelectors(text) {
  return text.split(',').map((s) => s.trim()).filter(Boolean).map((token) => {
    const dot = token.indexOf('.');
    let group = dot < 0 ? token : token.slice(0, dot);
    const field = dot < 0 ? null : token.slice(dot + 1);
    group = ALIASES[group] || group;
    return { token, group, field };
  });
}

function expandSelectors(selectors, universe, label) {
  const out = new Set();
  for (const { token, group, field } of selectors) {
    if (!universe.has(group)) throw new UsageError(`${label}: unknown group in "${token}" (groups: ${GROUP_ORDER.join(', ')})`);
    const fields = universe.get(group);
    if (field === null) {
      for (const name of fields.keys()) if (!EFFECT_ONLY.has(`${group}\u0000${name}`)) out.add(`${group}\u0000${name}`);
    } else if (fields.has(field)) {
      out.add(`${group}\u0000${field}`);
    } else {
      throw new UsageError(`${label}: "${token}": no field "${field}" in group ${group} that both traces carry (available: ${[...fields.keys()].join(', ') || 'none'})`);
    }
  }
  return out;
}

// ---- comparing -------------------------------------------------------------------------------------------------------------

function newGroupResult() {
  return { compared: 0, differingSteps: 0, first: null, perField: new Map() };
}

/** Records a divergence: `first` is the earliest one of the group, `perField` the earliest one of every field. */
function note(result, step, diff) {
  if (result.first === null) result.first = { step, ...diff };
  const key = diff.field.replace(/^\[\d+\]( \(id \d+\))?\./, '');
  if (!result.perField.has(key)) result.perField.set(key, { step, ...diff });
}

function compare(ref, port, selected, universe, options) {
  const results = {};
  const result = (group) => (results[group] ||= newGroupResult());
  const refSchema = schemaOf(ref); const portSchema = schemaOf(port);
  const picked = (group) => [...universe.get(group).keys()].filter((f) => selected.has(`${group}\u0000${f}`));
  const equalTyped = (type, a, b) => {
    if (type === 'f') return floatsEqual(String(a), String(b), options.tolerance);
    if (type === 'j') return JSON.stringify(a) === JSON.stringify(b);
    return a === b;
  };
  const show = (type, value, other) => (type === 'f' ? describeFloat(String(value), other === undefined ? undefined : String(other)) : JSON.stringify(value));

  const lastRef = ref.steps.length; const lastPort = port.steps.length;
  const common = Math.min(lastRef, lastPort);
  const first = Math.max(1, options.from);
  const last = Math.min(common, options.until ?? Infinity);

  // The range check is not a field selection: it runs whatever is selected, so that a short or empty trace can never pass by
  // having had nothing compared. Three ways to fail, all reported as a divergence of the group `steps` (exit 1):
  //   * --until N asks for steps beyond the end of the shorter trace (an explicit request that cannot be met);
  //   * without --until, the traces have a different number of steps (skipped only by an explicit `--ignore steps`);
  //   * no step is compared at all (empty trace, or --from beyond the end).
  const countIgnored = options.countIgnored === true;
  const rangeProblems = [];
  const shorter = lastRef <= lastPort ? 'reference' : 'port';
  if (options.until !== null && options.until > common) {
    rangeProblems.push({
      step: common + 1,
      detail: `--until ${options.until} asks for steps ${common + 1}..${options.until}, which the ${shorter} trace does not have (reference ${lastRef} steps, port ${lastPort} steps)`,
    });
  } else if (options.until === null && lastRef !== lastPort && !countIgnored) {
    rangeProblems.push({
      step: common + 1,
      detail: `the traces have a different number of steps (reference ${lastRef}, port ${lastPort})${common > 0 ? `; --until ${common} compares the common prefix` : ''}`,
    });
  }
  if (first > last) {
    rangeProblems.push({
      step: first,
      detail: `no step is compared: steps ${first}..${last} (reference ${lastRef} steps, port ${lastPort} steps${options.until !== null ? `, --until ${options.until}` : ''})`,
    });
  }
  if (selected.has('steps\u0000count') || rangeProblems.length > 0) {
    const r = result('steps'); r.compared = 1;
    if (rangeProblems.length > 0) {
      r.differingSteps = 1;
      note(r, rangeProblems[0].step, { field: 'count', reference: `${lastRef} steps`, port: `${lastPort} steps`, detail: rangeProblems.map((p) => p.detail).join('; ') });
    }
  }

  const fieldIndexes = (group, schemaGroup) => {
    const out = [];
    for (const name of picked(group)) {
      if (name === 'length') continue;
      const type = universe.get(group).get(name);
      out.push({ name, type, refIndex: refSchema[schemaGroup].find((f) => f.name === name).index, portIndex: portSchema[schemaGroup].find((f) => f.name === name).index });
    }
    return out;
  };
  const plans = {
    player: fieldIndexes('player', 'player'), camera: fieldIndexes('camera', 'camera'), wave: fieldIndexes('wave', 'wave'),
    enemies: fieldIndexes('enemies', 'enemy'), projectiles: fieldIndexes('projectiles', 'projectile'), xp_orbs: fieldIndexes('xp_orbs', 'xp_orb'),
  };
  const slotFields = picked('slot_draws'); const countFields = picked('counts'); const inputFields = picked('input');
  const lengthSelected = (group) => selected.has(`${group}\u0000length`);

  for (let n = first; n <= last; n++) {
    const a = ref.steps[n - 1]; const b = port.steps[n - 1];
    const stepDiffs = new Set();
    const mark = (group, diff) => { note(result(group), n, diff); stepDiffs.add(group); };

    if (selected.has('state\u0000state')) {
      result('state').compared++;
      if (a.state !== b.state) mark('state', { field: 'state', reference: JSON.stringify(a.state), port: JSON.stringify(b.state) });
    }
    if (inputFields.length) {
      result('input').compared++;
      for (const f of inputFields) {
        const type = universe.get('input').get(f);
        if (!equalTyped(type, a.input[f], b.input[f])) mark('input', { field: f, reference: show(type, a.input[f], b.input[f]), port: show(type, b.input[f], a.input[f]) });
      }
    }
    if (selected.has('draws\u0000draws')) {
      result('draws').compared++;
      if (a.draws !== b.draws) mark('draws', { field: 'draws', reference: String(a.draws), port: String(b.draws), detail: `port - reference = ${b.draws - a.draws}` });
    }
    if (selected.has('outside_draws\u0000outside_draws')) {
      result('outside_draws').compared++;
      if (a.outside_draws !== b.outside_draws) mark('outside_draws', { field: 'outside_draws', reference: String(a.outside_draws), port: String(b.outside_draws) });
    }
    if (slotFields.length) {
      result('slot_draws').compared++;
      for (const key of slotFields) {
        const x = a.slot_draws[key] || 0; const y = b.slot_draws[key] || 0;
        if (x !== y) {
          const name = (trace) => { const [list, i] = key.split(':'); return trace.header.slots?.[list]?.[Number(i)] ?? '?'; };
          mark('slot_draws', { field: key, reference: String(x), port: String(y), detail: `slot ${name(ref)}` });
        }
      }
    }
    if (countFields.length) {
      result('counts').compared++;
      for (const key of countFields) {
        if (a.counts[key] !== b.counts[key]) mark('counts', { field: key, reference: String(a.counts[key]), port: String(b.counts[key]) });
      }
    }
    for (const group of FIELD_GROUPS) {
      const plan = plans[group];
      if (plan.length === 0) continue;
      result(group).compared++;
      for (const f of plan) {
        const x = a[group][f.refIndex]; const y = b[group][f.portIndex];
        if (!equalTyped(f.type, x, y)) {
          mark(group, { field: f.name, reference: show(f.type, x, y), port: show(f.type, y, x), detail: f.type === 'f' ? floatDifference(String(x), String(y)) : '' });
        }
      }
    }
    for (const group of Object.keys(LIST_GROUPS)) {
      const plan = plans[group];
      const withLength = lengthSelected(group);
      if (plan.length === 0 && !withLength) continue;
      result(group).compared++;
      const xs = a[group]; const ys = b[group];
      if (withLength && xs.length !== ys.length) {
        mark(group, { field: 'length', reference: String(xs.length), port: String(ys.length), detail: describeLists(ref, group, xs, port, ys) });
        continue;
      }
      for (let i = 0; i < Math.min(xs.length, ys.length); i++) {
        for (const f of plan) {
          if (!equalTyped(f.type, xs[i][f.refIndex], ys[i][f.portIndex])) {
            const idRef = entityId(ref, group, xs[i]);
            mark(group, {
              field: `[${i}]${idRef === null ? '' : ` (id ${idRef})`}.${f.name}`,
              reference: show(f.type, xs[i][f.refIndex], ys[i][f.portIndex]), port: show(f.type, ys[i][f.portIndex], xs[i][f.refIndex]),
              detail: f.type === 'f' ? floatDifference(String(xs[i][f.refIndex]), String(ys[i][f.portIndex])) : '',
            });
          }
        }
      }
    }
    for (const group of stepDiffs) result(group).differingSteps++;
  }
  return { results, firstStep: first, lastStep: last, refSteps: lastRef, portSteps: lastPort };
}

function entityId(trace, group, row) {
  const schema = trace.header.fields?.[LIST_GROUPS[group]] || [];
  const at = schema.findIndex((s) => s.startsWith('id:'));
  return at >= 0 ? row[at] : null;
}

function describeLists(ref, group, xs, port, ys) {
  const ids = (trace, rows) => rows.map((r) => entityId(trace, group, r)).filter((v) => v !== null);
  const a = ids(ref, xs); const b = ids(port, ys);
  if (a.length === 0 && b.length === 0) return '';
  return `ids reference [${a.join(',')}] port [${b.join(',')}]`;
}

// ---- reporting -------------------------------------------------------------------------------------------------------------

function report(refFile, portFile, ref, port, selection, outcome, options) {
  const lines = [];
  const label = (t, f) => `${f} (${t.header.producer ?? '?'}, ${t.steps.length} steps, seed ${t.header.seed}, script ${t.header.input_script?.name ?? '?'})`;
  lines.push(`reference ${label(ref, refFile)}`);
  lines.push(`port      ${label(port, portFile)}`);
  lines.push(`compared steps ${outcome.firstStep}..${outcome.lastStep}${options.tolerance > 0 ? `, tolerance ${options.tolerance}` : ', bit-exact'}`);
  for (const [group, names] of Object.entries(selection.onlyInReference)) {
    if (names.length) lines.push(`not carried by the port, not compared: ${group}: ${names.join(', ')}`);
  }
  lines.push('');
  lines.push(`${'group'.padEnd(14)}${'result'.padEnd(10)}${'first step'.padEnd(12)}${'differing steps'.padEnd(18)}detail`);
  let diverged = 0;
  const details = [];
  for (const group of GROUP_ORDER) {
    const r = outcome.results[group];
    if (!r || r.compared === 0 && r.first === null) continue;
    const differs = r.first !== null;
    if (differs) diverged++;
    lines.push(`${group.padEnd(14)}${(differs ? 'DIFFERS' : 'same').padEnd(10)}${(differs ? String(r.first.step) : '-').padEnd(12)}${(differs ? `${r.differingSteps} of ${r.compared}` : `0 of ${r.compared}`).padEnd(18)}${differs ? r.first.field : ''}`);
    if (differs) {
      details.push(`  ${group}, first at step ${r.first.step}, field ${r.first.field}`);
      details.push(`      reference: ${r.first.reference}`);
      details.push(`      port:      ${r.first.port}`);
      if (r.first.detail) details.push(`      ${r.first.detail}`);
      if (r.perField.size > 1) {
        const ordered = [...r.perField.entries()].sort((x, y) => x[1].step - y[1].step);
        details.push(`      every diverging field, with its first step: ${ordered.map(([name, d]) => `${name}@${d.step}`).join(' ')}`);
      }
    }
  }
  if (details.length) { lines.push(''); lines.push('first divergence per group:'); lines.push(...details); }
  lines.push('');
  lines.push(diverged === 0 ? 'RESULT: SAME in the selected fields' : `RESULT: DIFFERENT (${diverged} group${diverged === 1 ? '' : 's'} diverge)`);
  return { text: lines.join('\n'), diverged };
}

// ---- main ------------------------------------------------------------------------------------------------------------------

function parseArgs(argv) {
  const o = { files: [], fields: null, ignore: null, until: null, from: 1, tolerance: 0, json: false, help: false, countIgnored: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const value = () => { if (i + 1 >= argv.length) throw new UsageError(`${a} needs a value`); return argv[++i]; };
    if (a === '--fields') o.fields = value();
    else if (a === '--ignore') o.ignore = value();
    else if (a === '--until') o.until = integer(a, value());
    else if (a === '--from') o.from = integer(a, value());
    else if (a === '--tolerance') { o.tolerance = Number(value()); if (!(o.tolerance >= 0)) throw new UsageError('--tolerance needs a number >= 0'); }
    else if (a === '--json') o.json = true;
    else if (a === '-h' || a === '--help') o.help = true;
    else if (a.startsWith('--')) throw new UsageError(`unknown option ${a}`);
    else o.files.push(a);
  }
  return o;
}

function integer(name, text) {
  const n = Number(text);
  if (!Number.isInteger(n) || n < 0) throw new UsageError(`${name} needs a non-negative integer, got ${text}`);
  return n;
}

export function run(argv) {
  const options = parseArgs(argv);
  if (options.help) {
    const lines = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1);
    return { code: 0, text: lines.slice(0, lines.findIndex((l) => !l.startsWith('//'))).map((l) => l.replace(/^\/\/ ?/, '')).join('\n') };
  }
  if (options.files.length !== 2) throw new UsageError('expected two trace files: REFERENCE PORT');
  if (options.until !== null && options.from > options.until) throw new UsageError(`--from ${options.from} is after --until ${options.until}: no step would be compared`);
  const [refFile, portFile] = options.files;
  const ref = loadTrace(refFile); const port = loadTrace(portFile);
  const selection = buildUniverse(ref, port);
  const selected = options.fields === null
    ? new Set([...selection.universe].flatMap(([group, fields]) => [...fields.keys()].map((f) => `${group}\u0000${f}`)).filter((key) => !EFFECT_ONLY.has(key)))
    : expandSelectors(parseSelectors(options.fields), selection.universe, '--fields');
  // A selector for fields of an entity list always brings the list's length with it: comparing `enemies.x` by position while
  // one trace has an extra or a missing entity would otherwise pass. (An explicit `--ignore enemies.length` still removes it.)
  for (const group of Object.keys(LIST_GROUPS)) {
    if ([...selected].some((key) => key.startsWith(`${group}\u0000`))) selected.add(`${group}\u0000length`);
  }
  if (options.ignore !== null) {
    const ignored = expandSelectors(parseSelectors(options.ignore), selection.universe, '--ignore');
    for (const key of ignored) selected.delete(key);
    options.countIgnored = ignored.has('steps\u0000count');
  }
  if (selected.size === 0) throw new UsageError('no field is selected');
  for (const group of Object.keys(selection.onlyInReference)) { // only mention missing fields of groups that are being compared
    if (![...selected].some((key) => key.startsWith(`${group}\u0000`))) delete selection.onlyInReference[group];
  }
  const outcome = compare(ref, port, selected, selection.universe, options);
  const { text, diverged } = report(refFile, portFile, ref, port, selection, outcome, options);
  if (options.json) {
    const groups = {};
    for (const [group, r] of Object.entries(outcome.results)) {
      groups[group] = { compared: r.compared, differingSteps: r.differingSteps, first: r.first, perField: Object.fromEntries(r.perField) };
    }
    const json = JSON.stringify({ reference: refFile, port: portFile, firstStep: outcome.firstStep, lastStep: outcome.lastStep, groups, diverged }, null, 2);
    return { code: diverged === 0 ? 0 : 1, text: json };
  }
  return { code: diverged === 0 ? 0 : 1, text };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { code, text } = run(process.argv.slice(2));
    console.log(text);
    process.exitCode = code;
  } catch (error) {
    console.error(`compare_trace: ${error instanceof UsageError ? 'usage: ' : 'ERROR: '}${error.message}`);
    process.exitCode = 2;
  }
}
