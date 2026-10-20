#!/usr/bin/env node
// Checks the committed math golden vectors (godot/tests/golden/math.json) against the Math of a real Chromium, and the
// random-number vectors (rng.json) against the game's own makeSeededRandom run in that Chromium.
//
//   node tools/verify_golden_chromium.mjs               compare every vector and named case with Chromium; exit 1 on any difference
//   node tools/verify_golden_chromium.mjs --canaries    print the CANARIES table of tools/golden/_canaries.mjs as Chromium computes it
//
// The generator (tools/gen_golden.mjs) cannot depend on a browser, so it takes most expected values from the Math of
// the Node it runs on and sin/cos from a JavaScript transcription of V8's glibc code. This script closes the loop: it
// feeds the SAME inputs to the Math functions inside Chromium (via Playwright) and compares the results bit for bit with
// the committed expected values. Run it after changing tools/golden/math.mjs or when the golden vectors are in doubt.
// It is not part of tools/check_generated.sh (it needs Playwright and a Chromium).
//
// The reference browser is Chromium 141.0.7390.37 (V8 14.1.146.11), the one the reference traces are recorded with.
// Playwright and Chromium are found by tools/lib/chromium.mjs (also used by the census and the reference-trace tools):
//   Playwright   tools/reference-trace/node_modules, then $PLAYWRIGHT_DIR, then the global npm root
//   Chromium     $SWARM_CHROME_BINARY (or the older $CHROMIUM_PATH), default /opt/pw-browsers/chromium-1194/chrome-linux/chrome
// The page is the Android emulation of that helper (390x844, deviceScaleFactor 3, touch); Math does not depend on it.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CANARIES } from './golden/_canaries.mjs';
import { cutByName } from './gen_golden.mjs';
import { launchAndroidChromium, EXPECTED_CHROMIUM_MAJOR } from './lib/chromium.mjs';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const GOLDEN = path.join(REPO_ROOT, 'godot/tests/golden/math.json');
const GOLDEN_RNG = path.join(REPO_ROOT, 'godot/tests/golden/rng.json');
const ORIGINAL = path.join(REPO_ROOT, 'webview-fg4/tests/fixtures/original.html');

// Runs inside the page. `golden` is the parsed math.json; returns per-vector mismatch counts.
function pageProgram(golden, canaries, rngGolden, makeSeededRandomSource) {
  const dv = new DataView(new ArrayBuffer(8));
  const hex = (x) => {
    if (Number.isNaN(x)) return '7ff8000000000000';
    dv.setFloat64(0, x);
    return dv.getBigUint64(0).toString(16).padStart(16, '0');
  };
  const fromHex = (h) => { dv.setBigUint64(0, BigInt(`0x${h}`)); return dv.getFloat64(0); };
  const bytes = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const decode = (b64, type) => {
    const u = bytes(b64);
    const view = new DataView(u.buffer);
    const n = u.length / (type === 'f64' ? 8 : 4);
    const out = new Array(n);
    for (let i = 0; i < n; i++) {
      out[i] = type === 'f64' ? view.getFloat64(8 * i, true) : type === 'i32' ? view.getInt32(4 * i, true) : view.getUint32(4 * i, true);
    }
    return out;
  };
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const FUNCS = {
    sin: Math.sin, cos: Math.cos, atan: Math.atan, exp: Math.exp, log: Math.log, atan2: Math.atan2, hypot: Math.hypot,
    mod: (a, b) => a % b, max: Math.max, min: Math.min, round: Math.round, trunc: Math.trunc, floor: Math.floor, ceil: Math.ceil,
    sqrt: Math.sqrt, abs: Math.abs, to_int32: (x) => x | 0, to_uint32: (x) => x >>> 0, imul: Math.imul,
    shl: (a, n) => a << n, sar: (a, n) => a >> n, shr_u: (a, n) => a >>> n,
    max3: (a, b, c) => Math.max(a, b, c), min3: (a, b, c) => Math.min(a, b, c),
    max5: (a, b, c, d, e) => Math.max(a, b, c, d, e), min5: (a, b, c, d, e) => Math.min(a, b, c, d, e),
    clamp, pow: Math.pow,
  };
  const sameDouble = (x, y) => (Number.isNaN(x) && Number.isNaN(y)) || hex(x) === hex(y);
  const report = { engine: navigator.userAgent, vectors: {}, named: [], canaries: [] };
  const inputs = {};
  for (const [key, set] of Object.entries(golden.inputs)) inputs[key] = set.columns.map((c) => decode(c, set.type));
  for (const [fn, vec] of Object.entries(golden.vectors)) {
    const f = FUNCS[fn];
    if (!f) { report.vectors[fn] = { error: 'no Chromium function for this vector' }; continue; }
    const columns = inputs[vec.input];
    const expected = decode(vec.output, vec.output_type);
    let bad = 0;
    const examples = [];
    for (let i = 0; i < vec.rows; i++) {
      const args = columns.map((c) => c[i]);
      const got = f(...args);
      // i32 / u32 outputs are exact integers; the double outputs compare by bit pattern
      const ok = vec.output_type === 'f64' ? sameDouble(got, expected[i]) : got === expected[i];
      if (!ok) { bad++; if (examples.length < 5) examples.push({ row: i, args: args.map(hex), expected: String(expected[i]), got: String(got) }); }
    }
    report.vectors[fn] = { rows: vec.rows, mismatches: bad, examples };
  }
  for (const [label, fn, args, expectedHex] of golden.named) {
    const got = hex(Number(FUNCS[fn](...args.map(fromHex))));
    report.named.push({ label, ok: got === expectedHex, got, expected: expectedHex });
  }
  for (const [fn, args] of canaries) report.canaries.push([fn, args, hex(FUNCS[fn](...args))]);
  // makeSeededRandom of the game, run in this Chromium: the streams and the seed normalisation of rng.json
  const makeSeededRandom = new Function(`${makeSeededRandomSource}; return makeSeededRandom;`)();
  let rngBad = 0;
  for (const entry of rngGolden.seeds) {
    const expected = new DataView(bytes(entry.first).buffer);
    const next = makeSeededRandom(entry.seed);
    for (let i = 0; i < rngGolden.stream_length; i++) if (next() * 4294967296 !== expected.getUint32(4 * i, true)) rngBad++;
  }
  for (const entry of rngGolden.normalization) {
    const next = makeSeededRandom(fromHex(entry.input));
    for (const k of entry.first) if (next() * 4294967296 !== k) rngBad++;
  }
  report.rng = { streams: rngGolden.seeds.length, normalization: rngGolden.normalization.length, mismatches: rngBad };
  return report;
}

async function main(argv) {
  const canariesOnly = argv.includes('--canaries');
  const golden = JSON.parse(fs.readFileSync(GOLDEN, 'utf8'));
  const rngGolden = JSON.parse(fs.readFileSync(GOLDEN_RNG, 'utf8'));
  const makeSeededRandomSource = cutByName(fs.readFileSync(ORIGINAL, 'utf8'), 'makeSeededRandom').text;
  const { browser, page } = await launchAndroidChromium();
  try {
    await page.setContent('<!doctype html><title>verify</title>');
    const report = await page.evaluate(`(${pageProgram.toString()})(${JSON.stringify(golden)}, ${JSON.stringify(CANARIES.map(([fn, args]) => [fn, args]))}, ${JSON.stringify(rngGolden)}, ${JSON.stringify(makeSeededRandomSource)})`);
    const major = Number((/Chrome\/(\d+)/.exec(report.engine) || [])[1]);
    console.log(report.engine);
    if (major !== EXPECTED_CHROMIUM_MAJOR) console.log(`WARNING: expected Chromium ${EXPECTED_CHROMIUM_MAJOR}, running ${major}; the sin/cos reference (glibc code) is specific to the V8 version`);

    if (canariesOnly) {
      console.log('export const CANARIES = [');
      for (const [fn, args, result] of report.canaries) console.log(`  ['${fn}', [${args.map((a) => (Object.is(a, -0) ? '-0' : String(a))).join(', ')}], '${result}'],`);
      console.log('];');
      const stale = CANARIES.filter(([fn, args, expected], i) => expected !== report.canaries[i][2]);
      console.log(stale.length === 0 ? 'canaries in tools/golden/_canaries.mjs are current' : `${stale.length} canary value(s) in tools/golden/_canaries.mjs differ from Chromium (paste the table above)`);
      return stale.length === 0 ? 0 : 1;
    }

    let failed = 0;
    for (const [fn, r] of Object.entries(report.vectors)) {
      if (r.error) { failed++; console.log(`FAIL  ${fn}: ${r.error}`); continue; }
      console.log(`${r.mismatches === 0 ? 'ok   ' : 'FAIL '} ${fn.padEnd(10)} ${String(r.rows).padStart(6)} rows  ${r.mismatches} mismatch(es)`);
      for (const e of r.examples) console.log(`        row ${e.row} args ${e.args.join(' ')} expected ${e.expected} Chromium ${e.got}`);
      if (r.mismatches > 0) failed++;
    }
    for (const n of report.named) {
      if (!n.ok) { failed++; console.log(`FAIL  named: ${n.label}: Chromium ${n.got}, expected ${n.expected}`); }
    }
    console.log(`named cases: ${report.named.filter((n) => n.ok).length}/${report.named.length} agree with Chromium`);
    console.log(`${report.rng.mismatches === 0 ? 'ok   ' : 'FAIL '} rng        ${report.rng.streams} streams x 1000 outputs and ${report.rng.normalization} seed normalisations: ${report.rng.mismatches} mismatch(es)`);
    if (report.rng.mismatches > 0) failed++;
    const stale = CANARIES.filter(([, , expected], i) => expected !== report.canaries[i][2]);
    if (stale.length > 0) { failed++; console.log(`FAIL  ${stale.length} canary value(s) in tools/golden/_canaries.mjs differ from Chromium (run with --canaries)`); }
    console.log(failed === 0 ? 'verify OK: the golden vectors equal the results of Chromium' : `verify FAILED: ${failed} problem(s)`);
    return failed === 0 ? 0 : 1;
  } finally {
    await browser.close();
  }
}

try {
  process.exitCode = await main(process.argv.slice(2));
} catch (error) {
  console.error(`verify_chromium: ERROR: ${error.message}`);
  process.exitCode = 2;
}
