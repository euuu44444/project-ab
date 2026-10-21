#!/usr/bin/env node
// Counts, in a real Chromium, which slot of the original's update lists draws from gameRandom in the M1 configuration, and
// compares the answer with the slots that godot/sim/system_runner.gd marks as consuming random numbers (consumes_rng_in_m1).
//
//   node tools/census_rng_slots_chromium.mjs            print the census and check the flags; exit 1 if they disagree
//   node tools/census_rng_slots_chromium.mjs --frames N cap each run at N fixed steps (default 5000)
//
// Why: the port's draw count (GameRng.draws) can only match the original's once every slot that draws is ported, so the
// placeholders that draw have to be known exactly. A static call-graph reading is not enough (it over- and under-reports); this
// tool wraps gameRandom, credits every draw to the UPDATE_*_SYSTEMS slot that is running, and records the call stack of the
// draws of every slot. The original is loaded from webview-fg4/tests/fixtures/original.html and served from memory with a
// hook appended before the end of its closure; nothing is written and the file is not changed.
//
// M1 configuration: catalyst, normal difficulty, standard mode, 390x844 with touch (IS_COARSE_POINTER = true), the input of
// design 9.2 (stick held in each of 8 directions for 60 steps in turn) or no input at all, seeds 424242 and 24681357.
// Frames are counted from 1 (the first update() call). The output is deterministic and is committed as
// verification/godot/s3/rng_slots.txt.
//
// Playwright and Chromium are found by tools/lib/chromium.mjs, which also starts the Android emulation (390x844,
// deviceScaleFactor 3, touch, fresh profile) and asserts the coarse pointer:
//   Playwright   tools/reference-trace/node_modules, then $PLAYWRIGHT_DIR, then the global npm root
//   Chromium     $SWARM_CHROME_BINARY (or the older $CHROMIUM_PATH), default /opt/pw-browsers/chromium-1194/chrome-linux/chrome
// (tools/reference-trace/capture.mjs records the per-step reference traces; this tool is the older, coarser census.)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { launchAndroidChromium, serveFromMemory } from './lib/chromium.mjs';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ORIGINAL = path.join(REPO_ROOT, 'webview-fg4/tests/fixtures/original.html');
const RUNNER = path.join(REPO_ROOT, 'godot/sim/system_runner.gd');
const RUNS = [
  { seed: 424242, idle: false },
  { seed: 424242, idle: true },
  { seed: 24681357, idle: false },
  { seed: 24681357, idle: true },
];

// Appended inside the original's closure, so that it sees its functions and bindings (gameRandom is reassigned: every
// caller reads the binding, so the wrapper sees every draw).
const HOOK = `
window.__census = {
  run(a) {
    Error.stackTraceLimit = 40;
    suspendGameLoop();
    selectedCharacter = "catalyst"; selectedDifficulty = "normal"; selectedGameMode = "normal";
    setGameSeed(a.seed);
    let slot = "newGame", frame = 0;
    const base = gameRandom;
    const bySlot = {}, firstFrame = {}, stacks = {};
    gameRandom = () => {
      const v = base();
      bySlot[slot] = (bySlot[slot] || 0) + 1;
      if (!(slot in firstFrame)) firstFrame[slot] = frame;
      const names = new Error().stack.split("\\n").slice(2, 40).map((s) => {
        s = s.trim().replace(/^at /, "");
        const m = s.match(/^(\\S+) \\(/);
        return m ? m[1] : "<anon>";
      });
      // the draw's own function chain: from rand/chance up to the slot's closure
      const stop = names.findIndex((n) => n === "<anon>" || /^s\\.run$/.test(n));
      const chain = names.slice(0, stop < 0 ? 4 : Math.min(stop, 4)).join("<");
      const key = slot + " :: " + chain;
      stacks[key] = (stacks[key] || 0) + 1;
      return v;
    };
    newGame(); suspendGameLoop();
    for (const list of [UPDATE_INTRO_SYSTEMS, UPDATE_MAIN_SYSTEMS, UPDATE_KO_SYSTEMS]) {
      for (const s of list) {
        const r = s.run, id = s.id;
        s.run = (dt) => { const prev = slot; slot = id; try { return r(dt); } finally { slot = prev; } };
      }
    }
    const dirs = [[1, 0], [0.7071, 0.7071], [0, 1], [-0.7071, 0.7071], [-1, 0], [-0.7071, -0.7071], [0, -1], [0.7071, -0.7071]];
    let levelUp = null, firstHitFrame = null;
    for (frame = 1; frame <= a.frames; frame++) {
      const d = a.idle ? [0, 0] : dirs[Math.floor((frame - 1) / 60) % 8];
      input.moveX = d[0]; input.moveY = d[1];
      capturePreviousTransforms(); update(FIXED_DT);
      if (game.player.hp < 100 && firstHitFrame === null) firstHitFrame = frame;
      if (levelUp === null && game.pendingLevelUps > 0) {
        levelUp = { frame, wave: game.wave, draws: gameRandomDraws, bySlot: JSON.parse(JSON.stringify(bySlot)) };
      }
      if (state !== "playing") break;
    }
    return { frames: Math.min(frame, a.frames), wave: game.wave, state, firstHitFrame, levelUp, draws: gameRandomDraws, bySlot, firstFrame, stacks };
  },
};
`;

// The slots that system_runner.gd marks as drawing: the _stub(...) calls whose consumes_rng argument is true.
function flaggedSlots() {
  const text = fs.readFileSync(RUNNER, 'utf8');
  const statements = text.split(/\n(?=\t_(?:stub|slot)\()/);
  const out = [];
  for (const st of statements) {
    const head = /^\t_stub\(\w+, "([^"]+)"/.exec(st);
    if (!head) continue;
    const tail = /,\s*(true|false)\s*(?:,\s*(true|false))?\s*\)\s*$/.exec(st.split('\n\n')[0].trimEnd());
    if (tail && tail[1] === 'true') out.push(head[1]);
  }
  return out;
}

// The slots that system_runner.gd has ported: the _slot(...) calls (real systems). A slot that draws in the original and is ported is
// accounted for by its own draws (the reference traces compare them), so it needs no mark.
function portedSlots() {
  const text = fs.readFileSync(RUNNER, 'utf8');
  return [...text.matchAll(/^\t_slot\(\w+, "([^"]+)"/gm)].map((m) => m[1]);
}

async function main(argv) {
  let frames = 5000;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--frames') frames = Number(argv[++i]);
    else throw new Error(`unknown option: ${argv[i]}`);
  }
  const source = fs.readFileSync(ORIGINAL, 'utf8');
  const anchor = source.lastIndexOf('})();\n</script>');
  if (anchor < 0) throw new Error('anchor for the hook not found in the original');
  const html = source.slice(0, anchor) + '\n' + HOOK + '\n' + source.slice(anchor);

  const { browser, page } = await launchAndroidChromium();
  const everDrew = new Set();
  try {
    page.on('pageerror', (e) => { throw new Error(`page error: ${e.message}`); });
    await page.goto(await serveFromMemory(page, 'http://census.local', html), { waitUntil: 'load' });
    await page.waitForFunction(() => window.__census);
    console.log(`census of gameRandom draws per update slot: Chromium ${browser.version()}`);
    console.log('M1: catalyst / normal / standard, 390x844, touch (IS_COARSE_POINTER = true); frames count from 1; slots that drew nothing are not listed');
    for (const run of RUNS) {
      const r = await page.evaluate((x) => window.__census.run(x), { ...run, frames });
      console.log('');
      console.log(`run seed ${run.seed}, ${run.idle ? 'no input' : 'design 9.2 input (8 directions, 60 steps each)'}: ${r.frames} steps, wave ${r.wave}, state ${r.state}, ${r.draws} draws in all`);
      console.log(`  first hit on the player: ${r.firstHitFrame === null ? 'none' : 'frame ' + r.firstHitFrame}; first level-up: ${r.levelUp ? `frame ${r.levelUp.frame} (wave ${r.levelUp.wave}, ${r.levelUp.draws} draws)` : 'not reached'}`);
      console.log('  slot                 first frame   draws to level-up   draws in the run');
      const slots = Object.keys(r.bySlot).filter((s) => s !== 'newGame');
      if (!slots.includes('weapon/update')) slots.push('weapon/update');
      for (const s of slots) {
        const total = r.bySlot[s] ?? 0;
        if (total > 0) everDrew.add(s);
        const toLevelUp = r.levelUp ? (r.levelUp.bySlot[s] ?? 0) : '-';
        console.log(`  ${s.padEnd(20)} ${String(r.firstFrame[s] ?? '-').padStart(11)} ${String(toLevelUp).padStart(19)} ${String(total).padStart(18)}`);
      }
      console.log(`  newGame itself: ${r.bySlot.newGame ?? 0} draw(s)`);
      for (const key of Object.keys(r.stacks).sort()) {
        if (key.startsWith('newGame') || key.startsWith('wave/progress')) continue;
        console.log(`    ${r.stacks[key].toString().padStart(5)} x ${key}`);
      }
    }
    const observed = [...everDrew].sort();
    const flagged = flaggedSlots().sort();
    const ported = portedSlots();
    // a slot that drew is either still a placeholder (and marked) or ported (a real system: _slot); a marked slot must have drawn
    const stillPlaceholders = observed.filter((s) => !ported.includes(s));
    console.log('');
    console.log(`slots that drew in at least one run: ${observed.join(', ')}`);
    console.log(`  ported since (real systems in godot/sim/system_runner.gd): ${observed.filter((s) => ported.includes(s)).join(', ') || 'none'}`);
    console.log(`slots marked consumes_rng_in_m1 in godot/sim/system_runner.gd: ${flagged.join(', ')}`);
    const same = stillPlaceholders.length === flagged.length && stillPlaceholders.every((s, i) => s === flagged[i]);
    console.log(same ? 'check OK: the marked slots are exactly the slots that drew and are still placeholders' : 'check FAILED: the marked slots differ from the slots that drew and are still placeholders');
    return same ? 0 : 1;
  } finally {
    await browser.close();
  }
}

try {
  process.exitCode = await main(process.argv.slice(2));
} catch (error) {
  console.error(`census_rng_slots: ERROR: ${error.message}`);
  process.exitCode = 2;
}
