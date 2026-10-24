#!/usr/bin/env node
// Checks that the node:vm harness of the enemy golden (tools/golden/defs_enemies.mjs) is the original game: its director, driven by the
// player of a REFERENCE TRACE (recorded in Chromium 141 by tools/reference-trace/capture.mjs), draws the same numbers and spawns the same
// enemies as the trace, step by step. If this holds, the golden vectors of the enemy director are the original's, not a model of it.
//
//   node --test tools/test_golden_enemies.mjs
//
// How the harness is driven: for step n of the trace, the player (x, y, vx, vy) is the one of the trace's row n (movement runs before
// wave/progress; the player's push by a contact hit happens after it and is in the row too, so a spawn position can differ from the
// recorded enemy's by that push - positions are compared loosely, draws, ids and kinds exactly), game.t advances, updateWave(1/60) runs; the
// draws that the trace credits to the other slots (enemy/update, projectile/player, enemy/cleanup-2: all after wave/progress) are
// burned from the generator, and the enemies that the trace removed are removed from the harness's list by the swap-pop of killEnemy,
// so that the next step starts from the same generator position and the same enemy list as the original.
import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { readTrace, hexToDouble } from './lib/trace_io.mjs';
import { directorGame, DT } from './golden/defs_enemies.mjs';

const REFERENCE_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'godot', 'tests', 'reference');

function fieldIndex(header, group, name) {
  return header.fields[group].findIndex((s) => s.split(':')[0] === name);
}

function replayDirector(file, { maxSteps = Infinity } = {}) {
  const trace = readTrace(path.join(REFERENCE_DIR, file));
  const { header, steps } = trace;
  const { sandbox, game } = directorGame(header.seed);
  const slotWave = `main:${header.slots.main.indexOf('wave/progress')}`;
  const px = ['x', 'y', 'vx', 'vy'].map((n) => fieldIndex(header, 'player', n));
  const wave = (n) => fieldIndex(header, 'wave', n);
  const idIndex = fieldIndex(header, 'enemy', 'id');
  const kindIndex = fieldIndex(header, 'enemy', 'kind');
  const waveFields = ['waveClock', 'directorClock', 'spawnBudget'].map(wave);
  assert.equal(sandbox.gameRandomDraws, header.new_game_draws, 'the harness draws as newGame did');
  if (header.variant === 'long_run') {
    // the long run only changes the player's hp / xpNext, which the director does not read
    assert.ok(header.overrides['player.hp']);
  }
  const count = Math.min(steps.length, maxSteps);
  let spawnedTotal = 0;
  let assassins = 0;
  const wavesSeen = new Set();
  for (let i = 0; i < count; i++) {
    const s = steps[i];
    const p = game.player;
    [p.x, p.y, p.vx, p.vy] = px.map((k) => hexToDouble(s.player[k]));
    game.t += DT;
    const drawsBefore = sandbox.gameRandomDraws;
    const knownBefore = game.enemies.length;
    sandbox.updateWave(DT);
    const made = sandbox.gameRandomDraws - drawsBefore;
    assert.equal(made, s.slot_draws[slotWave] || 0, `step ${s.n}: draws of wave/progress`);
    // the new enemies are the trace's new ids, in order, of the same kinds
    const traceIds = s.enemies.map((e) => e[idIndex]);
    const newOnes = game.enemies.slice(knownBefore);
    for (const e of newOnes) {
      const at = s.enemies.findIndex((row) => row[idIndex] === e.id);
      assert.ok(at >= 0, `step ${s.n}: enemy ${e.id} appears in the trace`);
      assert.equal(s.enemies[at][kindIndex], e.kind, `step ${s.n}: kind of enemy ${e.id}`);
      if (e.kind === 'assassin') assassins++;
      spawnedTotal++;
    }
    // everything else that the trace credits to later slots: burn it, then remove the enemies that the trace removed (swap-pop from the end)
    let other = 0;
    for (const [key, n] of Object.entries(s.slot_draws)) if (key !== slotWave) other += n;
    for (let k = 0; k < other; k++) sandbox.gameRandom();
    const previous = new Set(game.enemies.map((e) => e.id));
    const stay = new Set(traceIds);
    for (let k = game.enemies.length - 1; k >= 0; k--) {
      if (!stay.has(game.enemies[k].id)) {
        const last = game.enemies.pop();
        if (k < game.enemies.length) game.enemies[k] = last;
      }
    }
    assert.deepEqual(Array.from(game.enemies, (e) => e.id), traceIds, `step ${s.n}: the enemy list`);
    assert.ok(previous.size >= traceIds.length - newOnes.length, 'ids only leave through kills');
    assert.equal(sandbox.gameRandomDraws, s.draws, `step ${s.n}: gameRandomDraws`);
    // the director's scalars (bit-identical doubles)
    for (const [name, k] of [['waveClock', waveFields[0]], ['directorClock', waveFields[1]], ['spawnBudget', waveFields[2]]]) {
      assert.ok(Object.is(game[name], hexToDouble(s.wave[k])), `step ${s.n}: ${name} ${game[name]} vs ${hexToDouble(s.wave[k])}`);
    }
    assert.equal(game.wave, s.wave[wave('wave')], `step ${s.n}: wave`);
    assert.equal(game.nextEnemyId, s.wave[wave('nextEnemyId')], `step ${s.n}: nextEnemyId`);
    wavesSeen.add(game.wave);
  }
  return { count, spawnedTotal, assassins, wavesSeen };
}

test('the harness reproduces the director of the original on idle_424242 (wave 1 and 2, every draw)', () => {
  const r = replayDirector('idle_424242.jsonl.gz');
  assert.ok(r.count > 2000 && r.spawnedTotal > 40, `${r.count} steps, ${r.spawnedTotal} spawns`);
});

test('the harness reproduces the director of the original on dirs8_424242 (the player moves)', () => {
  const r = replayDirector('dirs8_424242.jsonl.gz');
  assert.ok(r.count > 800 && r.spawnedTotal > 15, `${r.count} steps, ${r.spawnedTotal} spawns`);
});

test('the harness reproduces the director through waves 2, 3 (assassins and the theme draw) on the long run', () => {
  const r = replayDirector('zigzag_424242_longrun.jsonl.gz');
  assert.ok(r.count === 5400, `${r.count} steps`);
  assert.ok(r.wavesSeen.has(3) && r.assassins > 5, `waves ${[...r.wavesSeen]}, ${r.assassins} assassins`);
});
