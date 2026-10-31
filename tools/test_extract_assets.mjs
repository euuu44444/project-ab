// Tests of tools/extract_assets.mjs (Node 22 `node:test`, no dependencies):
//
//   node --test tools/test_extract_assets.mjs
//
// tools/check_assets.sh runs them (and tools/run_godot_tests.sh runs check_assets.sh), next to
// `extract_assets.mjs --check`, which compares the committed Godot assets with a fresh extraction.
//
// Covers:
//   * the 14 images and the layout are extracted from original.html, and the output is deterministic;
//   * the draw geometry equals the result of the game's OWN buildAtlasDrawGeometry (its source text is
//     cut out of original.html and run in an empty vm context with fake images), for the real data and
//     for synthetic frame insets, which exercise the clamping code that the real data (insets = {}) never reaches;
//   * the tool fails loudly (exit code 2) when a data URI is missing, duplicated, of another MIME type,
//     corrupted or renamed, and when a "pure" declaration touches the DOM;
//   * `--check` exits 1 for a changed, missing or stray file.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { buildArtSheets, findImages, generate, IMAGES, readConstants } from './extract_assets.mjs';

const TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOLS_DIR, '..');
const TOOL = path.join(TOOLS_DIR, 'extract_assets.mjs');
const SOURCE = path.join(REPO_ROOT, 'webview-fg4/tests/fixtures/original.html');
const html = fs.readFileSync(SOURCE, 'utf8');
const scratch = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'extract-assets-test-'));
test.after(() => fs.rmSync(scratch, { recursive: true, force: true }));

function runTool(args) {
  const result = spawnSync(process.execPath, [TOOL, ...args], { encoding: 'utf8' });
  return { code: result.status, out: result.stdout, err: result.stderr };
}

/** Runs the tool on a modified copy of the game; returns the result with the fresh output directory. */
function runOnModified(name, modify, extraArgs = []) {
  const dir = path.join(scratch, name);
  fs.mkdirSync(dir, { recursive: true });
  const source = path.join(dir, 'game.html');
  fs.writeFileSync(source, modify(html));
  return { ...runTool(['--source', source, '--out', path.join(dir, 'out'), ...extraArgs]), dir };
}

const firstUri = (text) => /data:image\/webp;base64,[A-Za-z0-9+/=]+/.exec(text);

// ------------------------------------------------------------------------------------------------
// The game's own geometry code (oracle)
// ------------------------------------------------------------------------------------------------

/**
 * Cuts the declarations that ART_LAYOUTS needs, the ART_CELL_CACHE loop and buildAtlasDrawGeometry
 * (plus clamp) out of the game and runs buildAtlasDrawGeometry(sheet, {naturalWidth, naturalHeight})
 * for every sheet in an empty vm context. `insets` replaces CHARACTER_FRAME_SOURCE_INSETS when given.
 */
function gameGeometry(imageSizes, insets) {
  const a = html.indexOf('var CHARACTER_ANIMATION_FRAMES=');
  const b = html.indexOf('var EMPTY_DRAW_OPTS=');
  const c = html.indexOf('var ART_INDEX=Object.create(null);');
  const d = html.indexOf('function buildFlashAtlas(');
  const clampAt = html.indexOf('function clamp(');
  assert.ok(a > 0 && b > a && c > b && d > c && clampAt > 0, 'markers found in the game source');
  let declarations = html.slice(a, b);
  if (insets !== undefined) {
    const original = 'var CHARACTER_FRAME_SOURCE_INSETS=Object.freeze({});';
    assert.ok(declarations.includes(original));
    declarations = declarations.replace(original, `var CHARACTER_FRAME_SOURCE_INSETS=${JSON.stringify(insets)};`);
  }
  const clampSource = html.slice(clampAt, html.indexOf('}', clampAt) + 1);
  const code = `${clampSource}\n${declarations}\n${html.slice(c, d)}\n`
    + `var sizes=${JSON.stringify(imageSizes)};var result={};`
    + 'for(const s of Object.keys(sizes)){const g=buildAtlasDrawGeometry(s,{naturalWidth:sizes[s][0],naturalHeight:sizes[s][1]});'
    + 'result[s]=[...g];}JSON.stringify(result);';
  return JSON.parse(vm.runInNewContext(code, {}, { timeout: 5000, contextCodeGeneration: { strings: false, wasm: false } }));
}

/** The tool's geometry as [[id, geometry], ...] per sheet, comparable with gameGeometry(). */
function toolGeometry(values, sizes) {
  const imagesByKey = new Map();
  for (const sheet of Object.keys(sizes)) {
    imagesByKey.set(`art_${sheet}`, { key: `art_${sheet}`, width: sizes[sheet][0], height: sizes[sheet][1] });
  }
  const sheets = buildArtSheets(values, imagesByKey);
  return Object.fromEntries(Object.entries(sheets).map(([sheet, s]) => [sheet, Object.entries(s.geometry)]));
}

const REAL_SIZES = {
  projectiles: [128, 96], hits: [128, 96], characters: [896, 704], enemies: [320, 288],
  weapons: [128, 128], elements: [160, 64], effects: [128, 96],
};

// ------------------------------------------------------------------------------------------------

test('finds the 14 images under the expected expressions with the pinned hashes', () => {
  const images = findImages(html);
  assert.equal(images.length, 14);
  assert.deepEqual(images.map((i) => i.expression), IMAGES.map((i) => i.expression));
  assert.equal(new Set(images.map((i) => i.key)).size, 14);
  for (const image of images) {
    assert.equal(image.info.width, image.width, image.key);
    assert.equal(image.info.height, image.height, image.key);
    assert.ok(image.info.lossless, `${image.key} is lossless`);
  }
  assert.deepEqual(images.find((i) => i.key === 'art_characters').info.chunks, ['VP8X', 'ICCP', 'VP8L']);
});

test('geometry equals the game\'s buildAtlasDrawGeometry (real data: no insets)', () => {
  const { values } = readConstants(html);
  assert.deepEqual(values.CHARACTER_FRAME_SOURCE_INSETS, {});
  const expected = gameGeometry(REAL_SIZES);
  const actual = toolGeometry(values, REAL_SIZES);
  assert.deepEqual(Object.keys(actual), Object.keys(expected));
  let cells = 0;
  for (const sheet of Object.keys(expected)) {
    // JSON.stringify keeps the key order and prints the exact double: this is an exact comparison.
    assert.equal(JSON.stringify(actual[sheet]), JSON.stringify(expected[sheet]), sheet);
    cells += expected[sheet].length;
  }
  assert.equal(cells, 12 + 12 + 165 + 99 + 14 + 10 + 12);
});

test('geometry equals the game\'s function for synthetic insets and fractional cell sizes', () => {
  const { values } = readConstants(html);
  const insets = {
    catalyst_idle1: { left: 2, right: 3, top: 1, bottom: 4 },
    catalyst_walk2: { left: 100, right: 100, top: 100, bottom: 100 }, // larger than the cell: clamped
    arcanist_idle1: { left: -5, right: -1, top: -2, bottom: -3 }, // negative: 0
    ranger: { left: '3', right: '2', top: '1', bottom: '0' }, // the alias key is looked up as well; numeric strings
    archivist_ko4: { left: 0.5, right: 1.25, top: 0.75, bottom: 2.5 }, // fractional
    sentinel_idle2: { left: NaN, right: 'x', top: null }, // NaN, text, null: 0
    miko_attack1: { left: 63, right: 63, top: 0, bottom: 63 }, // right limited by what is left of the width
    striker_idle1: { left: 10 }, // partial
    swarm_idle1: { left: 7, right: 7, top: 7, bottom: 7 }, // not a characters id: ignored for enemies
    harmonizer_walk1: { left: 1e9, right: 1e9, top: 1e9, bottom: 1e9 },
  };
  const sizeSets = [
    REAL_SIZES,
    // sizes that do not divide by the grid: cell sizes are fractional (float division, like the game)
    { projectiles: [100, 70], hits: [101, 97], characters: [900, 700], enemies: [321, 290], weapons: [129, 127], elements: [161, 65], effects: [99, 95] },
  ];
  for (const sizes of sizeSets) {
    const expected = gameGeometry(sizes, insets);
    const actual = toolGeometry({ ...values, CHARACTER_FRAME_SOURCE_INSETS: JSON.parse(JSON.stringify(insets)) }, sizes);
    // JSON turns NaN and null into null, which Number(null) maps to 0 like the game's Number(NaN)||0.
    for (const sheet of Object.keys(expected)) {
      assert.equal(JSON.stringify(actual[sheet]), JSON.stringify(expected[sheet]), `${sheet} @ ${JSON.stringify(sizes[sheet])}`);
    }
    // The insets really changed something (the comparison is not vacuous).
    const catalyst = Object.fromEntries(expected.characters).catalyst_idle1;
    assert.equal(catalyst.sx, 2);
    assert.notEqual(Object.fromEntries(expected.characters).catalyst_walk2.sourceW, sizes.characters[0] / 14);
  }
});

test('the output is deterministic and complete', () => {
  const first = generate(SOURCE).files;
  const second = generate(SOURCE).files;
  assert.deepEqual([...first.keys()], [...second.keys()]);
  assert.equal(first.size, 16);
  for (const [name, data] of first) assert.ok(data.equals(second.get(name)), name);
  const dir = path.join(scratch, 'twice');
  for (const sub of ['a', 'b']) assert.equal(runTool(['--out', path.join(dir, sub)]).code, 0);
  for (const name of first.keys()) {
    assert.ok(fs.readFileSync(path.join(dir, 'a', name)).equals(fs.readFileSync(path.join(dir, 'b', name))), name);
    assert.ok(fs.readFileSync(path.join(dir, 'a', name)).equals(first.get(name)), name);
  }
  const second_run = runTool(['--out', path.join(dir, 'a')]);
  assert.match(second_run.out, /16 files, 0 written/);
});

test('the layout holds the numbers the renderers need', () => {
  const layout = JSON.parse(generate(SOURCE).files.get('atlas_layout.json'));
  assert.equal(layout.sheets.characters.geometry.miko_attack2.sx, 448);
  assert.equal(Object.keys(layout.sheets.characters.geometry).length, 165);
  assert.equal(Object.keys(layout.sheets.enemies.geometry).length, 99);
  assert.equal(layout.raster.coarse.FX_RASTER_RES, 18);
  assert.equal(layout.raster.fine.FX_RASTER_RES, 22);
  assert.equal(layout.signature_fx.meta.record_mark_loop.y, 33 * 64);
  assert.equal(layout.overhaul_fx.content_ratio, 64 / 52);
  assert.deepEqual(layout.art_maps.SPINNING_HAZARD_TYPES, ['cyclone', 'wildfirewhirl', 'blackfire']);
  assert.equal(layout.range_fx.style_cells[3].outerRatio, 0.43);
  assert.equal(layout.runtime_derived.range_fx_tint.ring_outer_radius, 0.492);
  assert.equal(layout.runtime_derived.enemy_hit_flash.flash_decay_per_second, 5);
  // The hit-flash pass exists only while flash > 0 (k is 0 at rest, not 0.32); enemies are drawn with baseAlpha 1.
  const flash = layout.runtime_derived.enemy_hit_flash;
  assert.match(flash.applies_when, /^flash > 0 only/);
  assert.match(flash.draw, /only while flash > 0/);
  assert.match(flash.shader_equivalent, /if flash == 0: rgb unchanged \(k = 0, NOT 0\.32\)/);
  assert.equal(flash.base_alpha, 1);
  // The low-resolution effect cache notes carry the verified scope and the full grid / snap rule.
  const lowres = layout.runtime_derived.lowres_effect_cache;
  assert.match(lowres.measured_index_formula_scope, /NOT a general rule/);
  assert.match(lowres.draw_size_in_drawSpriteFx, /1 at ultra quality, otherwise REACTION_FX_GEOMETRY_GRID if fx\.reactionFx, otherwise FX_GEOMETRY_GRID if fx\.fxLowRes, otherwise 1/);
  assert.match(lowres.position_snap_in_drawSpriteFx, /round\(v \/ grid\) \* grid when grid > 1, otherwise Math\.round\(v\)/);
});

// ------------------------------------------------------------------------------------------------
// Failure modes: the tool must stop (exit code 2) instead of writing something plausible
// ------------------------------------------------------------------------------------------------
const FAILURES = [
  ['a data URI of another MIME type', (text) => text.replace('data:image/webp;base64,', 'data:image/png;base64,'), /not a plain image\/webp/],
  ['a missing image', (text) => text.replace('data:image/webp;base64,', 'data:text/plain;base64,'), /expected 14 image\/webp data URIs, found 13/],
  ['a duplicated image', (text) => `${text}\nvar DUPLICATE_ART="${firstUri(text)[0]}";`, /expected 14 image\/webp data URIs, found 15/],
  ['an image under another expression', (text) => text.replace('hits:"data:image/webp', 'hitz:"data:image/webp'), /unexpected data URI "ART_SOURCES.hitz"/],
  ['a corrupted image', (text) => {
    const uri = firstUri(text)[0];
    const at = uri.length - 200;
    return text.replace(uri, `${uri.slice(0, at)}${uri[at] === 'A' ? 'B' : 'A'}${uri.slice(at + 1)}`);
  }, /eliteShockwave: sha256 [0-9a-f]{64}, expected 45cd9c81/],
  ['a truncated image', (text) => {
    const uri = firstUri(text)[0];
    return text.replace(uri, uri.slice(0, uri.length - 400));
  }, /eliteShockwave: RIFF size \d+ \+ 8 does not match the file length \d+/],
  ['a pure declaration that touches the DOM', (text) => text.replace('var CHARACTER_ATLAS_CELL_SIZE=64;', 'var CHARACTER_ATLAS_CELL_SIZE=document.body.clientWidth;'), /CHARACTER_ATLAS_CELL_SIZE references "document"/],
  ['a pure declaration that calls a game function', (text) => text.replace('var MIKO_ATLAS_ROW=8;', 'var MIKO_ATLAS_ROW=someGameFunction();'), /evaluating the pure declarations failed.*someGameFunction/],
  ['a changed run-time image parameter (range ring radius)', (text) => text.replace('res*0.492', 'res*0.5'), /no longer has exactly one occurrence of "g\.arc\(res\*0\.5,res\*0\.5,res\*0\.492/],
  ['a changed run-time image parameter (flash decay)', (text) => text.replace('e.flash=Math.max(0,e.flash-dt*5)', 'e.flash=Math.max(0,e.flash-dt*4)'), /no longer has exactly one occurrence of "e\.flash=Math\.max/],
  ['a changed hit-flash guard', (text) => text.replace('if(opts.flash){const strength', 'if(opts.flash>=0){const strength'), /no longer has exactly one occurrence of "if\(opts\.flash\)\{const strength/],
  ['a changed effect position snap', (text) => text.replace('const x=visualFxSnap(s.x,fx)', 'const x=px(s.x)'), /no longer has exactly one occurrence of "const x=visualFxSnap\(s\.x,fx\)/],
  ['a changed effect grid rule', (text) => text.replace('if(ultraVisuals())return 1;return p?.reactionFx', 'return p?.reactionFx'), /no longer has exactly one occurrence of "function visualFxGrid\(p\)\{if\(ultraVisuals\(\)\)return 1/],
  ['a removed declaration', (text) => text.replace('var MIKO_ATLAS_ROW=8;', ''), /declaration of MIKO_ATLAS_ROW: expected exactly 1 match, found 0/],
  ['a doubled declaration', (text) => `${text}\nvar MIKO_ATLAS_ROW=9;`, /declaration of MIKO_ATLAS_ROW: expected exactly 1 match, found 2/],
];
for (const [name, modify, pattern] of FAILURES) {
  test(`fails loudly for ${name}`, () => {
    const slug = name.replace(/\W+/g, '_');
    const result = runOnModified(slug, modify);
    assert.equal(result.code, 2, `exit code (stderr: ${result.err})`);
    assert.match(result.err, /extract_assets: ERROR:/);
    assert.match(result.err, pattern);
    assert.equal(fs.existsSync(path.join(result.dir, 'out')), false, 'nothing is written after a failure');
  });
}

test('--compare-fg4 reports a missing or changed image in the shipped file', () => {
  const dir = path.join(scratch, 'fg4');
  fs.mkdirSync(dir, { recursive: true });
  const good = path.join(dir, 'good.html');
  fs.writeFileSync(good, html);
  const ok = runTool(['--source', SOURCE, '--out', path.join(dir, 'out'), '--compare-fg4', '--fg4', good]);
  assert.equal(ok.code, 0, ok.err);
  assert.match(ok.out, /compare-fg4 OK: all 14 data URIs occur exactly once, byte for byte/);

  const bad = path.join(dir, 'bad.html');
  const uri = firstUri(html)[0];
  fs.writeFileSync(bad, html.replace(uri, `${uri.slice(0, 100)}A${uri.slice(101)}`));
  const changed = runTool(['--source', SOURCE, '--out', path.join(dir, 'out'), '--compare-fg4', '--fg4', bad]);
  assert.equal(changed.code, 1);
  assert.match(changed.out, /MISSING/);
  assert.match(changed.out, /compare-fg4 FAILED/);

  const twice = path.join(dir, 'twice.html');
  fs.writeFileSync(twice, `${html}\nvar ONE_MORE="${uri}";`);
  const doubled = runTool(['--source', SOURCE, '--out', path.join(dir, 'out'), '--compare-fg4', '--fg4', twice]);
  assert.equal(doubled.code, 1);
  assert.match(doubled.out, /DUPLICATED x2/);
});

test('--check passes for fresh output and exits 1 for drift', () => {
  const out = path.join(scratch, 'check');
  assert.equal(runTool(['--out', out]).code, 0);
  const pass = runTool(['--check', '--out', out]);
  assert.equal(pass.code, 0, pass.err);
  assert.match(pass.out, /check OK: 16 files/);

  const flip = (file) => {
    const target = path.join(out, file);
    const bytes = fs.readFileSync(target);
    bytes[bytes.length >> 1] ^= 1;
    fs.writeFileSync(target, bytes);
    return () => { bytes[bytes.length >> 1] ^= 1; fs.writeFileSync(target, bytes); };
  };
  for (const file of ['art_hits.webp', 'atlas_layout.json', 'atlas_manifest.json']) {
    const restore = flip(file);
    const drift = runTool(['--check', '--out', out]);
    assert.equal(drift.code, 1, `${file} changed`);
    assert.match(drift.err, new RegExp(`differs:\\s+${file}`));
    restore();
  }
  fs.rmSync(path.join(out, 'range_fx.webp'));
  const missing = runTool(['--check', '--out', out]);
  assert.equal(missing.code, 1);
  assert.match(missing.err, /missing:\s+range_fx\.webp/);
  assert.equal(runTool(['--out', out]).code, 0, 'a normal run repairs it');

  fs.writeFileSync(path.join(out, 'extra.webp'), 'x');
  const stray = runTool(['--check', '--out', out]);
  assert.equal(stray.code, 1);
  assert.match(stray.err, /unexpected:\s+extra\.webp/);
  // --check never writes
  assert.equal(fs.existsSync(path.join(out, 'range_fx.webp')), true);
  fs.rmSync(path.join(out, 'art_hits.webp'));
  runTool(['--check', '--out', out]);
  assert.equal(fs.existsSync(path.join(out, 'art_hits.webp')), false, '--check leaves a missing file missing');
});

test('usage errors exit with code 2', () => {
  assert.equal(runTool(['--bogus']).code, 2);
  assert.equal(runTool(['--source']).code, 2);
  assert.equal(runTool(['--source', path.join(scratch, 'no_such_file.html')]).code, 2);
  assert.equal(runTool(['--help']).code, 0);
});
