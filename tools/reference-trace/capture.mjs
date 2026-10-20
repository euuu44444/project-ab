#!/usr/bin/env node
// Records a reference trace of the ORIGINAL game (design section 9.2): runs webview-fg4/tests/fixtures/original.html in
// Chromium 141 with the Android emulation of tools/lib/chromium.mjs (390x844, touch, fresh profile), steps update(FIXED_DT)
// one fixed step at a time under a scripted input, and writes one JSON line per step (format swarm-trace/1, see FORMAT.md).
//
//   node tools/reference-trace/capture.mjs --script dirs8 --seed 424242            one trace -> godot/tests/reference/dirs8_424242.jsonl.gz
//   node tools/reference-trace/capture.mjs --all                                   the 6 standard traces (3 scripts x 2 seeds)
//   node tools/reference-trace/capture.mjs --info FILE...                          summary of existing traces (no browser)
//
// Options:
//   --script NAME|PATH    input script: tools/reference-trace/scripts/NAME.json or a path (default dirs8)
//   --seed N              seed of gameRandom (default 424242); the standard seeds are 424242 and 24681357
//   --fx-seed N           seed of Math.random, i.e. of the effects and sound variation (default 2654435769); recorded in the header
//   --out FILE            output file (default godot/tests/reference/<script>_<seed>.jsonl.gz); a name ending in .jsonl stays uncompressed
//   --out-dir DIR         with --all: output directory (default godot/tests/reference)
//   --max-steps N         step cap (default 4000)
//   --character ID --difficulty ID --mode ID     defaults catalyst / normal / normal (the standard mode)
//   --long-run            NON-STANDARD variant: player.xpNext, hp and maxHp are set to 1e9 right after newGame(), so that no level-up is
//                         queued (the standard traces stop at the first one, 13-38 s into the run) and the player does not die (with
//                         the starting weapon only it dies about 55-65 s in): the run can go on through waves 3 and 4 (assassins, the
//                         director's theme draws). The default step cap (4000 = 66 s) ends before wave 3 (step 4320): pass --max-steps
//                         (the committed trace uses 5400) or --until-wave. Recorded in the header ("variant": "long_run", "overrides");
//                         the port applies the same values (SimTrace.replay). Default name: <script>_<seed>_longrun.jsonl.gz
//   --until-wave N        stop at the first step in which game.wave >= N (reason "wave:N"); with --long-run, N = 5 covers waves 1-4
//   --emulate-loop        also run render() and adaptiveSample() after every step, as loop() does (validation of hook.js, see there)
//   --verify-repro        capture each trace twice and fail unless both are byte-identical
//
// The original is served from memory with tools/reference-trace/hook.js inserted before the end of its script; the file on
// disk is not modified and its sha256 goes into the header. Exit code 0 on success, 1 on a failed check, 2 on a usage or
// environment error. Environment: see tools/lib/chromium.mjs (SWARM_CHROME_BINARY, PLAYWRIGHT_DIR).
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { launchChromium, newAndroidPage, serveFromMemory, EXPECTED_CHROMIUM_MAJOR } from '../lib/chromium.mjs';
import { readTrace, writeTrace, firstEffects, TRACE_FORMAT } from '../lib/trace_io.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..', '..');
const ORIGINAL_REL = 'webview-fg4/tests/fixtures/original.html';
const ORIGINAL = path.join(REPO_ROOT, ORIGINAL_REL);
const HOOK = path.join(HERE, 'hook.js');
const SCRIPTS_DIR = path.join(HERE, 'scripts');
const DEFAULT_OUT_DIR = path.join(REPO_ROOT, 'godot', 'tests', 'reference');
const STANDARD_SCRIPTS = ['dirs8', 'idle', 'zigzag'];
const STANDARD_SEEDS = [424242, 24681357];
const DEFAULT_FX_SEED = 2654435769; // 0x9E3779B9, the default of the port's SimConfig.fx_seed
const COUNT_FIELDS = ['enemies', 'projectiles', 'xp_orbs', 'particles', 'enemy_projectiles', 'hazards'];
const LONG_RUN_OVERRIDES = { 'player.xpNext': 1e9, 'player.hp': 1e9, 'player.maxHp': 1e9 };

class UsageError extends Error {}

function parseArgs(argv) {
  const o = { script: 'dirs8', seed: 424242, fxSeed: DEFAULT_FX_SEED, out: null, outDir: DEFAULT_OUT_DIR, maxSteps: 4000,
    character: 'catalyst', difficulty: 'normal', mode: 'normal', emulateLoop: false, verifyRepro: false, all: false, info: [],
    longRun: false, untilWave: null };
  const takes = new Set(['--script', '--seed', '--fx-seed', '--out', '--out-dir', '--max-steps', '--until-wave', '--character', '--difficulty', '--mode']);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--all') o.all = true;
    else if (a === '--emulate-loop') o.emulateLoop = true;
    else if (a === '--verify-repro') o.verifyRepro = true;
    else if (a === '--long-run') o.longRun = true;
    else if (a === '--info') { o.info = argv.slice(i + 1); break; }
    else if (a === '-h' || a === '--help') { o.help = true; }
    else if (takes.has(a)) {
      if (i + 1 >= argv.length) throw new UsageError(`${a} needs a value`);
      const v = argv[++i];
      if (a === '--script') o.script = v;
      else if (a === '--seed') o.seed = integer(a, v);
      else if (a === '--fx-seed') o.fxSeed = integer(a, v);
      else if (a === '--out') o.out = v;
      else if (a === '--out-dir') o.outDir = v;
      else if (a === '--max-steps') o.maxSteps = integer(a, v);
      else if (a === '--until-wave') o.untilWave = integer(a, v);
      else if (a === '--character') o.character = v;
      else if (a === '--difficulty') o.difficulty = v;
      else o.mode = v;
    } else throw new UsageError(`unknown option ${a}`);
  }
  return o;
}

function integer(name, text) {
  const n = Number(text);
  if (!Number.isInteger(n) || n < 0) throw new UsageError(`${name} needs a non-negative integer, got ${text}`);
  return n;
}

function loadScript(nameOrPath) {
  const file = fs.existsSync(nameOrPath) ? nameOrPath : path.join(SCRIPTS_DIR, `${nameOrPath}.json`);
  if (!fs.existsSync(file)) throw new UsageError(`no input script ${nameOrPath} (looked for ${file})`);
  const definition = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (typeof definition.name !== 'string') throw new UsageError(`${file}: "name" is missing`);
  return definition;
}

/** The original's source with the hook inserted before the closing `})();` of its one script. */
function hookedHtml(source) {
  const anchor = source.lastIndexOf('})();\n</script>');
  if (anchor < 0) throw new Error('anchor for the hook (the end of the closure) not found in the original');
  return `${source.slice(0, anchor)}\n${fs.readFileSync(HOOK, 'utf8')}\n${source.slice(anchor)}`;
}

/** One capture in an open page. Returns { header, body } (the body is the step lines, not yet written). */
async function captureOnce(page, opts, script, source) {
  const result = await page.evaluate((args) => window.__trace.run(args), {
    seed: opts.seed, fxSeed: opts.fxSeed, character: opts.character, difficulty: opts.difficulty, mode: opts.mode,
    script, maxSteps: opts.maxSteps, emulateLoop: opts.emulateLoop,
    overrides: opts.longRun ? LONG_RUN_OVERRIDES : {}, untilWave: opts.untilWave,
  });
  const fields = await page.evaluate(() => window.__trace.schema());
  const overrides = result.env.overrides ?? {};
  delete result.env.overrides;
  const header = {
    format: TRACE_FORMAT,
    producer: 'original-chromium',
    source: { path: ORIGINAL_REL, sha256: source.sha256 },
    chromium_version: source.chromiumVersion,
    playwright_version: source.playwrightVersion,
    seed: opts.seed,
    fx_seed: opts.fxSeed,
    character: opts.character,
    difficulty: opts.difficulty,
    mode: opts.mode,
    view: [result.env.view_w, result.env.view_h],
    coarse: result.env.is_coarse_pointer,
    device_scale_factor: result.env.device_pixel_ratio,
    fixed_dt: result.fixedDt,
    new_game_draws: result.newGameDraws,
    input_script: { name: script.name, definition: script },
    slots: result.slots,
    fields,
    count_fields: COUNT_FIELDS,
    environment: result.env,
    ...(opts.emulateLoop ? { emulate_loop: true } : {}),
    ...(opts.longRun ? { variant: 'long_run', overrides } : {}),
    stats: result.stats,
    stop: result.stop,
  };
  // The first steps with an effect that the port does not have yet (the two boundaries of the port comparison). The Godot test
  // (godot/tests/test_reference_trace.gd first_effects) computes them again from the rows and fails if the two disagree.
  const steps = result.body.length > 0 ? result.body.split('\n').map((line) => JSON.parse(line)) : [];
  header.boundaries = firstEffects({ header, steps });
  return { header, body: result.body };
}

function sha256(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function outputPath(opts, scriptName) {
  const file = opts.out ?? path.join(opts.outDir, `${scriptName}_${opts.seed}${opts.longRun ? '_longrun' : ''}.jsonl.gz`);
  return path.resolve(file);
}

/** The text summary of a trace file: steps, stop, draws, busiest slots, first events, sizes. */
export function summarizeTrace(file) {
  const { header, steps, fileBytes, rawBytes } = readTrace(file);
  const slotName = (key) => {
    const [list, index] = key.split(':');
    return `${key} ${header.slots?.[list]?.[Number(index)] ?? '?'}`;
  };
  const perSlot = {};
  let outside = 0; let maxEnemies = 0; let maxParticles = 0; let maxProjectiles = 0; let maxOrbs = 0;
  let firstHit = null; let firstDraw = {}; let firstAttack = null; let firstEnemy = null;
  const playerFields = header.fields.player.map((s) => s.split(':')[0]);
  const attackIndex = playerFields.indexOf('attackAnim');
  const hpIndex = playerFields.indexOf('hp');
  for (const step of steps) {
    for (const [key, drawn] of Object.entries(step.slot_draws)) {
      perSlot[key] = (perSlot[key] || 0) + drawn;
      if (!(key in firstDraw)) firstDraw[key] = step.n;
    }
    outside += step.outside_draws;
    maxEnemies = Math.max(maxEnemies, step.counts.enemies);
    maxParticles = Math.max(maxParticles, step.counts.particles);
    maxProjectiles = Math.max(maxProjectiles, step.counts.projectiles);
    maxOrbs = Math.max(maxOrbs, step.counts.xp_orbs);
    if (firstEnemy === null && step.counts.enemies > 0) firstEnemy = step.n;
    if (firstAttack === null && attackIndex >= 0 && step.player[attackIndex] !== steps[0].player[attackIndex]) firstAttack = step.n;
    if (firstHit === null && hpIndex >= 0 && step.player[hpIndex] !== steps[0].player[hpIndex]) firstHit = step.n;
  }
  const last = steps[steps.length - 1];
  const total = last ? last.draws : header.new_game_draws;
  const top = Object.entries(perSlot).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 6);
  const lines = [];
  lines.push(`${path.basename(file)}`);
  lines.push(`  script ${header.input_script.name}, seed ${header.seed}, fx seed ${header.fx_seed}, ${header.character} / ${header.difficulty} / ${header.mode}, view ${header.view.join('x')}, coarse ${header.coarse}`);
  lines.push(`  steps ${steps.length}, stop ${header.stop.reason} at step ${header.stop.step}${header.variant ? `; NON-STANDARD variant ${header.variant}: ${JSON.stringify(header.overrides)}` : ''}`);
  lines.push(`  gameRandom draws: ${total} in all (${header.new_game_draws} in newGame, ${total - header.new_game_draws} in steps, ${outside} outside any slot)`);
  lines.push(`  top slots by draws: ${top.map(([key, n]) => `${slotName(key)} ${n} (${(100 * n / Math.max(1, total - header.new_game_draws)).toFixed(1)}%)`).join('; ') || 'none'}`);
  lines.push(`  first events: enemy ${firstEnemy ?? '-'}; player hp changes ${firstHit ?? '-'}; player attackAnim changes ${firstAttack ?? '-'}; first draw per slot: ${Object.entries(firstDraw).sort((a, b) => a[1] - b[1]).map(([k, n]) => `${k}@${n}`).join(' ') || '-'}`);
  const effects = firstEffects({ header, steps });
  const at = (n) => (n > steps.length ? 'none' : `step ${n}`);
  lines.push(`  first effects the port lacks (design 9.2 boundaries): contact hit ${at(effects.contact)}, weapon shot ${at(effects.fire)}`);
  lines.push(`  maxima: enemies ${maxEnemies}, projectiles ${maxProjectiles}, xp orbs ${maxOrbs}, particles ${maxParticles}`);
  lines.push(`  size: ${fileBytes} bytes on disk, ${rawBytes} bytes uncompressed, sha256 of the file ${sha256(fs.readFileSync(file))}`);
  lines.push(`  source ${header.source.path} sha256 ${header.source.sha256}; ${header.chromium_version}; playwright ${header.playwright_version}`);
  return { text: lines.join('\n'), fileBytes, steps: steps.length, header };
}

async function main(argv) {
  const opts = parseArgs(argv);
  if (opts.help) {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1).filter((l) => l.startsWith('//')).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
    return 0;
  }
  if (opts.info.length > 0) {
    for (const file of opts.info) console.log(summarizeTrace(file).text);
    return 0;
  }

  const sourceBytes = fs.readFileSync(ORIGINAL);
  const html = hookedHtml(sourceBytes.toString('utf8'));
  const jobs = opts.all
    ? STANDARD_SCRIPTS.flatMap((script) => STANDARD_SEEDS.map((seed) => ({ ...opts, script, seed, out: null })))
    : [opts];

  const launched = await launchChromium();
  const { browser } = launched;
  let failed = 0;
  // Every capture gets a fresh browser context: an empty profile (no localStorage, no cookies) and a page that has not run a game.
  const captureInFreshContext = async (job, script, source) => {
    const { context, page } = await newAndroidPage(browser); // asserts (pointer:coarse)
    // Errors of the page that no evaluate() call reports (a failed image load, a timer, an unhandled rejection) are collected, not
    // thrown from the listener (that would kill the process outside this tool's error path), and checked after the capture.
    const pageErrors = [];
    page.on('pageerror', (e) => { pageErrors.push(e.message); });
    try {
      await page.goto(await serveFromMemory(page, 'http://trace.local', html), { waitUntil: 'load' });
      await page.waitForFunction(() => window.__trace);
      // IS_COARSE_POINTER, the viewport and the empty profile are asserted once more inside the page (hook.js, checkEnvironment).
      const captured = await captureOnce(page, job, script, source);
      if (pageErrors.length > 0) throw new Error(`the page reported ${pageErrors.length} error(s) during the capture: ${pageErrors.slice(0, 3).join(' | ')}`);
      return captured;
    } finally {
      await context.close();
    }
  };
  try {
    if (launched.chromiumMajor !== EXPECTED_CHROMIUM_MAJOR) {
      console.log(`WARNING: expected Chromium ${EXPECTED_CHROMIUM_MAJOR}, running ${launched.chromiumVersion}; the recorded math (sin, cos, atan2) is specific to the V8 version`);
    }
    const source = { sha256: sha256(sourceBytes), chromiumVersion: launched.chromiumVersion, playwrightVersion: launched.playwrightVersion };
    let totalBytes = 0;
    for (const job of jobs) {
      const script = loadScript(job.script);
      const { header, body } = await captureInFreshContext(job, script, source);
      const file = outputPath(job, script.name);
      if (header.stats.never_defined.length !== 0) { // nothing is written: a trace with silent zeros must not replace a good one
        failed++;
        console.log(`FAIL ${path.basename(file)}: field(s) that the game never defined during the run (a misspelt name in SCHEMA records silent zeros): ${header.stats.never_defined.join(', ')}; the trace was not written`);
        continue;
      }
      fs.mkdirSync(path.dirname(file), { recursive: true });
      writeTrace(file, header, body);
      if (job.verifyRepro) {
        const again = await captureInFreshContext(job, script, source);
        const same = again.body === body && JSON.stringify(again.header) === JSON.stringify(header);
        console.log(`reproducibility ${path.basename(file)}: ${same ? 'a second capture in a fresh context is byte-identical' : 'DIFFERENT'} (${sha256(body).slice(0, 16)} / ${sha256(again.body).slice(0, 16)})`);
        if (!same) failed++;
      }
      const summary = summarizeTrace(file);
      totalBytes += summary.fileBytes;
      console.log(summary.text);
      if (header.stats.draws_outside_slots !== 0) {
        failed++;
        console.log(`  FAIL: ${header.stats.draws_outside_slots} draw(s) outside any slot`);
      }

    }
    if (jobs.length > 1) console.log(`total size of ${jobs.length} traces: ${totalBytes} bytes (${(totalBytes / 1048576).toFixed(2)} MiB)`);
  } finally {
    await browser.close();
  }
  return failed === 0 ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = await main(process.argv.slice(2));
  } catch (error) {
    console.error(`capture: ${error instanceof UsageError ? 'usage: ' : 'ERROR: '}${error.message}`);
    process.exitCode = 2;
  }
}
