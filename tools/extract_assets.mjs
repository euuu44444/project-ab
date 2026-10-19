#!/usr/bin/env node
// Extracts the 14 WebP atlases embedded as data URIs in the ORIGINAL game and their layouts into the
// Godot project (design section 4 / step S2). Node 22, standard library only (no npm dependencies).
//
//   node tools/extract_assets.mjs                 write godot/assets/atlas/*.webp, atlas_manifest.json, atlas_layout.json
//   node tools/extract_assets.mjs --check         write nothing; exit 1 if the files on disk differ from what would be written
//   node tools/extract_assets.mjs --compare-fg4   also confirm that every data URI occurs exactly once, byte for byte,
//                                                 in the shipped fg.4 index.html (can be combined with --check)
//
// Options:
//   --source PATH   game HTML to read (default: webview-fg4/tests/fixtures/original.html)
//   --fg4 PATH      shipped HTML for --compare-fg4 (default: webview-fg4/app/src/main/assets/index.html)
//   --out DIR       output directory (default: godot/assets/atlas)
//   -h, --help
//
// Exit codes: 0 success, 1 drift (--check) or mismatch (--compare-fg4), 2 extraction failed or bad usage.
//
// What it does, and what it never does:
//   * The images are found by the pattern data:image/webp;base64,... Exactly 14 must exist, each under the
//     expected JS expression, none duplicated, none of another MIME type. Their bytes are written unchanged
//     (the decoded data URI) after the RIFF/WebP structure, the size and the SHA-256 have been checked.
//   * The layouts come from SELECTED constant declarations of the game. They are cut out of the source by
//     name (a small scanner that understands strings, templates and brackets) and evaluated in an isolated
//     node:vm context with an EMPTY sandbox and code generation disabled, so a declaration that touches
//     the DOM or any game function throws a ReferenceError instead of running. Nothing else is evaluated.
//   * The atlas cell geometry is computed exactly like the game's buildAtlasDrawGeometry (float division,
//     CHARACTER_FRAME_SOURCE_INSETS clamping). The result is deterministic: the same input gives
//     byte-identical output (stable key order, JSON.stringify number formatting, no timestamps).
//   * Images the game derives at run time (hit-flash atlas, low-resolution caches, range-ring tints,
//     validation canvases) are NOT extracted; the render step (S7) rebuilds them.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOLS_DIR, '..');
const SOURCE_REL = 'webview-fg4/tests/fixtures/original.html';
const DEFAULT_SOURCE = path.join(REPO_ROOT, SOURCE_REL);
const DEFAULT_FG4 = path.join(REPO_ROOT, 'webview-fg4/app/src/main/assets/index.html');
const DEFAULT_OUT = path.join(REPO_ROOT, 'godot/assets/atlas');
const FORMAT_VERSION = 1;

// ---------------------------------------------------------------------------------------------------
// The 14 images, in source order. `expression` is where the data URI sits in the game's JavaScript,
// `sha256` is the SHA-256 of the decoded .webp file and `rgba_sha256` that of its decoded straight-alpha
// RGBA8 pixels, row-major. Both pins come from the S2 analysis (libwebp through PIL, cross-checked
// against Chromium 141 canvas decoding) and were re-derived independently for this tool. The tool cannot
// decode WebP itself; tests/test_atlas_assets.gd checks the pixel pins against Godot's own decoder.
// ---------------------------------------------------------------------------------------------------
const IMAGES = [
  { key: 'enemy_fx_elite_shockwave', expression: 'GENERATED_ENEMY_FX_SOURCES.eliteShockwave', width: 256, height: 256,
    sha256: '45cd9c81c4b0e7a894ccf7481b08894479f0c357dd2c66b033d81b75d1cb6298',
    rgba_sha256: '89d0797917302a984da7abc18dbe8d2db01bda4a6db4915f3a0671e36835a15d' },
  { key: 'enemy_fx_boss_charge', expression: 'GENERATED_ENEMY_FX_SOURCES.bossCharge', width: 384, height: 192,
    sha256: '5d061d83fbe70f04e08dd512ff59f9f41fccd66c717f217bd5634abfa3eb73a8',
    rgba_sha256: '330bfac87290d2d2e39fa321a8f6e7fd659f6724fd9a779c6207189cff175eb6' },
  { key: 'overhaul_characters', expression: 'OVERHAUL_CHAR_ATLAS_SOURCE', width: 896, height: 256,
    sha256: '24e2be597e91deb0044e4c5dceee9b3291b963d39f26bf4efa2d68996a0e7bb6',
    rgba_sha256: 'a7c97faf319481364eba7df6f0e01d0d7576df09b387cbbe41cd7a0191979e37' },
  { key: 'overhaul_fx', expression: 'OVERHAUL_FX_SOURCE', width: 512, height: 1280,
    sha256: '2ff76ba4f6a1a291e6d3c95b2080546b9f591bc41891c80173b892fc95bb6a3a',
    rgba_sha256: '85175ae3eeb1c98976c9f8ead8ab8f4f01087cf3424290992f539a20cbbc274c' },
  { key: 'overhaul_weapon_icons', expression: 'OVERHAUL_ICON_SOURCE', width: 256, height: 64,
    sha256: 'a64b0a486c865bd20e9aa542266f1a1e1f6aa4ffec240bbde447d885621e29cd',
    rgba_sha256: '3eadcefd74067136b361a2e652284dccd56da05a835df4dcec40ca3ffeae05d3' },
  { key: 'art_hits', expression: 'ART_SOURCES.hits', width: 128, height: 96,
    sha256: '1f4af781ce9c8f3b4f8a7e8743468436f344a43274b420d9b42c210d891e2bb1',
    rgba_sha256: '36a4e55ab9d88aedd8cdf91b1540a2301089f6e6d08c6f974a4d34dfc06faa90' },
  { key: 'art_projectiles', expression: 'ART_SOURCES.projectiles', width: 128, height: 96,
    sha256: '8cf1ef47ef36bf3e16a18ec1d5fb8b4f43b663e3663e919d363976b75771deb7',
    rgba_sha256: 'bb2bb99fb5ddd6c04a71f78b942271751106da741d45308a5610c1e632743d44' },
  { key: 'art_characters', expression: 'ART_SOURCES.characters', width: 896, height: 704,
    sha256: '81e6996fc573d9d046cc01f87303b7faa460096b1b6e4099c380468e6ecbb09d',
    rgba_sha256: 'd353c874f9b624e6d33a988bd5f8d03be1f5dd31f66d2dae9934f822e60713dc' },
  { key: 'art_enemies', expression: 'ART_SOURCES.enemies', width: 320, height: 288,
    sha256: 'afeb11b5b7306169f1b51741dc189d44442fc0af238873788aa6d80d171feaec',
    rgba_sha256: '25c8cc58b8acfb8fe7274b070a15d195f7443307efecca8ce1e93a575f6172c9' },
  { key: 'art_weapons', expression: 'ART_SOURCES.weapons', width: 128, height: 128,
    sha256: '4ce32f0d23c45a9abd35a5e00ca256c2192f380c04dc2b8b6294ffa1943bfbe0',
    rgba_sha256: 'dcb08f22f0ab3f11c369a06459aad1c38d8bb893a88f98bce8443c5a91cf881f' },
  { key: 'art_elements', expression: 'ART_SOURCES.elements', width: 160, height: 64,
    sha256: 'f67220670be8483ef785a11df8b631916b1e386b013e64f6caa742aa9f2fe263',
    rgba_sha256: 'b315c6019dab495c810014a57b4efdd4f4c573bb38c525c451110d0d6d508bc0' },
  { key: 'art_effects', expression: 'ART_SOURCES.effects', width: 128, height: 96,
    sha256: 'f193b29bf54d24687c2b7208a1fed4c009c833ca5f03deb589a8e487b67b3163',
    rgba_sha256: 'c3bd3c0168f95fd52eb783c8c938d2062868180c6a8d2651f42c2fa4015c7533' },
  { key: 'signature_fx', expression: 'SIGNATURE_FX_SOURCE', width: 512, height: 2944,
    sha256: 'e89f541c351bf22f40e97840d79063f96d64a8360ca41ca25f07c55599b1c738',
    rgba_sha256: '159e2382900a97581723c7dadb7485d9ca6401558a3fe42c0922f6c3fe55ade0' },
  { key: 'range_fx', expression: 'RANGE_FX_SOURCE', width: 512, height: 512,
    sha256: 'fa63ca53443f1d1b94a59941d5a26d6163d79a64e2ac097d0429b6d332fd604d',
    rgba_sha256: '430e8be8011b222f61fca5d9c3a8ad2b3d12bb3daa8712121119c960804a652a' },
];

// ART_SOURCES key -> image key (the game's sheet names are the ART_LAYOUTS keys).
const ART_SHEET_IMAGE = (sheet) => `art_${sheet}`;

// ---------------------------------------------------------------------------------------------------
// Pure constant declarations that are evaluated (names only; the source text is cut out of the game).
// ---------------------------------------------------------------------------------------------------
const PURE_DECLARATIONS = [
  // animation and art ids
  'CHARACTER_ANIMATION_FRAMES', 'ENEMY_ANIMATION_FRAMES', 'CHARACTER_ANIMATION_FPS',
  'IDLE_ANIMATION_FRAMES', 'WALK_ANIMATION_FRAMES', 'ATTACK_ANIMATION_FRAMES', 'KO_ANIMATION_FRAMES',
  'CHARACTER_ANIMATION_DEFINITIONS', 'CHARACTER_ATLAS_CELL_SIZE', 'MIKO_ATLAS_ROW',
  'CHARACTER_FRAME_SOURCE_INSETS', 'CHARACTER_ART_IDS', 'ENEMY_ART_IDS', 'CHARACTER_FRAME_IDS',
  'ENEMY_FRAME_IDS', 'ART_LAYOUTS',
  // other atlases
  'GENERATED_ENEMY_FX_EXPECTED',
  'OVERHAUL_CHAR_ROWS', 'OVERHAUL_FX_META', 'OVERHAUL_FX_ROWS', 'OVERHAUL_WEAPON_ICON_INDEX',
  'OVERHAUL_PALETTE_MAX', 'OVERHAUL_FX_CONTENT_RATIO',
  'SIGNATURE_FX_META', 'SIGNATURE_WEAPON_ICON', 'MAX_SIGNATURE_FX',
  'RANGE_FX_STYLE', 'RANGE_FX_STYLE_CELLS',
  // sprite lookup maps
  'PROJECTILE_ART_BY_WEAPON', 'PROJECTILE_ART_BY_SHAPE', 'HAZARD_OVERLAY_ART', 'SPINNING_HAZARD_TYPES',
];

// Constants of the form `var NAME=IS_COARSE_POINTER?A:B;`. IS_COARSE_POINTER is
// matchMedia("(pointer:coarse)").matches: true on Android, false for a mouse. Both values are evaluated.
const POINTER_DEPENDENT = [
  'FX_RASTER_RES', 'REACTION_FX_RASTER_RES', 'FX_GEOMETRY_GRID', 'REACTION_FX_GEOMETRY_GRID',
  'RANGE_FX_CACHE_RESOLUTION', 'BASE_MAX_PIXEL_FX', 'BASE_RANGE_AURA_GLYPHS',
  'BASE_TRANSIENT_RANGE_FX_DRAW_BUDGET',
];

// Parameters of the images the game builds at run time with canvases (hit-flash atlas, low-resolution
// effect cache, range-ring tint cache). They cannot be extracted; step S7 rebuilds them in shaders. The numbers
// sit inside function bodies, not in constant declarations, so each is pinned by a literal piece of the game's
// source (RUNTIME_DERIVED_SOURCE): it must occur exactly once, otherwise extraction fails and the numbers
// below have to be reviewed. Fields named measured_* come from Chromium 141 (the S2 analysis), not from source.
const RUNTIME_DERIVED_SOURCE = [
  // buildFlashAtlas
  'flashCtx.globalCompositeOperation="source-in";flashCtx.fillStyle="#ffffff"',
  // drawAtlasSprite flash pass (runs only inside `if(opts.flash)`, baseAlpha is 1 without opts.alpha), the
  // enemy draw that passes e.flash (and no alpha), and the flash decay in tickEnemyTimersAndStatus
  'if(opts.flash){const strength=opts.flash===true?1:clamp(Number(opts.flash)||0,0,1)',
  'const baseAlpha=opts.alpha==null?1:opts.alpha',
  'ctx.globalAlpha=baseAlpha*(flashAtlas?.width?0.32+0.46*strength:0.24*strength)',
  'const artOpts={flipX:false,flash:0}',
  'artOpts.flash=e.flash;const drewEnemyArt=drawAtlasSprite("enemies"',
  'e.flash=Math.max(0,e.flash-dt*5)',
  // lowResAtlasSource and drawSpriteFx (grid, position snap), spawnAtlasFx (the only producer of game.spriteFx)
  'const res=Math.max(6,Math.round(resolution||16))',
  'const res=ultraVisuals()?64:sheet==="hits"?32:fx.reactionFx?REACTION_FX_RASTER_RES:FX_RASTER_RES;const drawSize=Math.max(sheet==="hits"?1:res,Math.round(size/visualFxGrid(fx))*visualFxGrid(fx))',
  'const x=visualFxSnap(s.x,fx),y=visualFxSnap(s.y,fx)',
  'function visualFxGrid(p){if(ultraVisuals())return 1;return p?.reactionFx?REACTION_FX_GEOMETRY_GRID:p?.fxLowRes?FX_GEOMETRY_GRID:1;}function visualFxSnap(v,p){const g=visualFxGrid(p);return g>1?Math.round(v/g)*g:px(v);}',
  'function px(v){return Math.round(v);}',
  'fxLowRes:true,reactionFx:opts.reactionFx==null?reactionFxScope>0:!!opts.reactionFx',
  // rangeFxTintSource
  'g.arc(res*0.5,res*0.5,res*0.492,0,Math.PI*2);g.arc(res*0.5,res*0.5,res*0.185,0,Math.PI*2,true)',
  'rgba[i]=a<26?0:Math.min(255,Math.round(a/32)*32)',
  'RANGE_FX_TINT_CACHE.size>36',
];

const RUNTIME_DERIVED = {
  note: 'Images the game builds at run time with canvases. They are not stored; step S7 rebuilds them in shaders.',
  enemy_hit_flash: {
    sheet: 'enemies',
    image: 'white silhouette of the sheet: a copy filled with #ffffff using source-in (alpha kept, RGB white)',
    applies_when: 'flash > 0 only: drawAtlasSprite wraps the pass in if(opts.flash){...}; drawEnemies passes artOpts.flash = e.flash; e.flash is set to 1 by a hit and decays by flash_decay_per_second down to 0',
    draw: 'only while flash > 0: drawn over the sprite with composite "lighter" at alpha = baseAlpha * (alpha_base + alpha_per_strength * s) with s = clamp(flash, 0, 1); when flash == 0 nothing is drawn',
    alpha_base: 0.32,
    alpha_per_strength: 0.46,
    base_alpha: 1,
    base_alpha_note: 'baseAlpha = opts.alpha == null ? 1 : opts.alpha; drawEnemies passes no alpha, so baseAlpha is always 1 for enemies',
    flash_decay_per_second: 5,
    shader_equivalent: 'if flash > 0: rgb = min(rgb + k, 1) with k = baseAlpha * (0.32 + 0.46 * s), s = clamp(flash, 0, 1), baseAlpha = 1; if flash == 0: rgb unchanged (k = 0, NOT 0.32). k jumps from 0 to at least 0.32 as soon as flash > 0, so a shader must test flash > 0 before adding the 0.32 base. Exact up to 8-bit rounding because enemy alpha is binary',
  },
  lowres_effect_cache: {
    min_resolution: 6,
    default_resolution: 16,
    resolution_in_drawSpriteFx: { ultra_quality: 64, hits_sheet: 32, reaction_fx: 'raster.<mode>.REACTION_FX_RASTER_RES', other: 'raster.<mode>.FX_RASTER_RES' },
    draw_size_in_drawSpriteFx: 'max(hits ? 1 : res, round(size / grid) * grid) with size = fx.size * (1 + fx.grow * progress) and grid = visualFxGrid(fx): 1 at ultra quality, otherwise REACTION_FX_GEOMETRY_GRID if fx.reactionFx, otherwise FX_GEOMETRY_GRID if fx.fxLowRes, otherwise 1 (spawnAtlasFx is the only producer of game.spriteFx and always sets fxLowRes: true)',
    position_snap_in_drawSpriteFx: 'the screen position x and y is snapped with visualFxSnap before drawing: round(v / grid) * grid when grid > 1, otherwise Math.round(v) (px)',
    sampling: 'nearest, both when scaling the cell down to res x res and when drawing it at the final size',
    measured_index_formula: 'source texel = cell_origin + ceil((i + 0.5) * cell_size / res) - 1 for destination pixel i. Measured in Chromium 141, not derived from the source, and valid only inside measured_index_formula_scope (floor((i + 0.5) * cell_size / res) is wrong on 7-26 percent of the pixels)',
    measured_index_formula_scope: 'exact (0 mismatches) for 32 px cells (effects, hits, enemies) and 64 px cells (characters) at every res from 6 to 72, and for the 256 px range cells at res 32, 64, 96 and 128. NOT a general rule (Skia steps in fixed point): it fails for some 256 px cell resolutions, for example res 28, 30, 52, 56, 60, 104, 112, 120, 126 and 190 (122 of 50176 pixels at res 112). Every resolution the game uses is inside the scope; re-measure in Chromium if RANGE_FX_CACHE_RESOLUTION, FX_RASTER_RES, REACTION_FX_RASTER_RES or a cell size changes',
  },
  range_fx_tint: {
    cell_downscale: 'the 256 px style cell is scaled down to raster.<mode>.RANGE_FX_CACHE_RESOLUTION (96 coarse, 128 fine; both inside the verified measured_index_formula_scope of lowres_effect_cache, which is not valid for every resolution) with the index formula of lowres_effect_cache',
    ring_centre: 0.5,
    ring_outer_radius: 0.492,
    ring_inner_radius: 0.185,
    ring_unit: 'fraction of the resolution',
    alpha_cut: 26,
    alpha_step: 32,
    alpha_rule: 'a < alpha_cut -> 0, otherwise min(255, round(a / alpha_step) * alpha_step)',
    order: 'ring mask (destination-in, anti-aliased), tint colour (source-in), alpha quantisation',
    cache_entries: 36,
  },
};

// Identifiers that a pure declaration must never contain (belt and braces: the empty sandbox already
// makes any of them a ReferenceError).
const FORBIDDEN_IDENTIFIERS = /\b(document|window|navigator|matchMedia|localStorage|sessionStorage|fetch|XMLHttpRequest|Image|Audio|eval|Function|import|require|process|globalThis|self|setTimeout|Date)\b|Math\.random/;

class ExtractionError extends Error {}
const fail = (message) => { throw new ExtractionError(message); };
const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');

// ---------------------------------------------------------------------------------------------------
// 1. Data URIs and WebP validation
// ---------------------------------------------------------------------------------------------------

/** Finds every data:image URI in the game. Exactly the 14 expected image/webp ones must exist. */
function findImages(html) {
  const anyImage = [...html.matchAll(/data:image\//g)];
  const webp = [...html.matchAll(/data:image\/webp;base64,([A-Za-z0-9+/]*={0,2})(?=["'])/g)];
  if (anyImage.length !== webp.length) {
    const known = new Set(webp.map((m) => m.index));
    const bad = anyImage.find((m) => !known.has(m.index));
    fail(`data:image URI at char ${bad.index} is not a plain image/webp base64 string: ${JSON.stringify(html.slice(bad.index, bad.index + 48))}`);
  }
  if (webp.length !== IMAGES.length) fail(`expected ${IMAGES.length} image/webp data URIs, found ${webp.length}`);

  // Position of every declaration, to name the object literal that holds a property-style URI.
  const declarations = [...html.matchAll(/(?<![\w$.])(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=/g)]
    .map((m) => ({ index: m.index, name: m[1] }));

  const found = new Map();
  for (const m of webp) {
    const start = m.index;
    const end = start + m[0].length;
    const quote = html[start - 1];
    if (!(quote === '"' || quote === "'") || html[end] !== quote) fail(`data URI at char ${start} is not a plain quoted string`);
    const before = html.slice(Math.max(0, start - 200), start - 1);
    const named = /([A-Za-z_$][\w$]*)\s*([:=])\s*$/.exec(before);
    if (!named) fail(`cannot find the name of the data URI at char ${start}: ${JSON.stringify(before.slice(-60))}`);
    const [, key, separator] = named;
    let expression;
    if (separator === '=') {
      if (!new RegExp(`(?:var|let|const)\\s+${key}\\s*=\\s*$`).test(before)) fail(`data URI at char ${start}: "${key}=" is not a declaration`);
      expression = key;
    } else {
      let owner = null;
      for (const d of declarations) {
        if (d.index >= start) break;
        owner = d.name;
      }
      if (owner === null) fail(`data URI at char ${start} (${key}) is not inside a declaration`);
      expression = `${owner}.${key}`;
    }
    const spec = IMAGES.find((image) => image.expression === expression);
    if (!spec) fail(`unexpected data URI "${expression}" at char ${start}`);
    if (found.has(spec.key)) fail(`data URI "${expression}" is duplicated (chars ${found.get(spec.key).start} and ${start})`);
    const base64 = m[1];
    const bytes = Buffer.from(base64, 'base64');
    if (bytes.toString('base64') !== base64) fail(`${expression}: the base64 text is not canonical (bad padding or stray bits)`);
    const info = parseWebp(bytes, expression);
    found.set(spec.key, { ...spec, start, end, uri: m[0], bytes, info });
  }
  for (const spec of IMAGES) if (!found.has(spec.key)) fail(`data URI "${spec.expression}" not found`);

  for (const image of found.values()) {
    if (image.info.width !== image.width || image.info.height !== image.height) {
      fail(`${image.expression}: size ${image.info.width}x${image.info.height}, expected ${image.width}x${image.height}`);
    }
    const digest = sha256(image.bytes);
    if (digest !== image.sha256) fail(`${image.expression}: sha256 ${digest}, expected ${image.sha256}`);
  }
  return IMAGES.map((spec) => found.get(spec.key));
}

/** Validates the RIFF/WebP container and returns the canvas size and the chunk list. */
function parseWebp(bytes, label) {
  if (bytes.length < 20) fail(`${label}: too short for a WebP file (${bytes.length} bytes)`);
  if (bytes.toString('latin1', 0, 4) !== 'RIFF' || bytes.toString('latin1', 8, 12) !== 'WEBP') fail(`${label}: not a RIFF/WEBP file`);
  const riffSize = bytes.readUInt32LE(4);
  if (riffSize + 8 !== bytes.length) fail(`${label}: RIFF size ${riffSize} + 8 does not match the file length ${bytes.length}`);
  const chunks = [];
  let canvas = null;
  let image = null;
  let offset = 12;
  while (offset < bytes.length) {
    if (offset + 8 > bytes.length) fail(`${label}: truncated chunk header at ${offset}`);
    const fourcc = bytes.toString('latin1', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (body + size > bytes.length) fail(`${label}: chunk ${fourcc} runs past the end of the file`);
    chunks.push(fourcc.trim());
    if (fourcc === 'VP8X') {
      if (size < 10) fail(`${label}: VP8X chunk too short`);
      if (bytes[body] & 0x02) fail(`${label}: animated WebP is not supported`);
      canvas = { width: 1 + bytes.readUIntLE(body + 4, 3), height: 1 + bytes.readUIntLE(body + 7, 3) };
    } else if (fourcc === 'VP8L') {
      if (size < 5 || bytes[body] !== 0x2f) fail(`${label}: bad VP8L signature`);
      const bits = bytes.readUInt32LE(body + 1);
      image = { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1, lossless: true };
    } else if (fourcc === 'VP8 ') {
      if (size < 10 || bytes[body + 3] !== 0x9d || bytes[body + 4] !== 0x01 || bytes[body + 5] !== 0x2a) fail(`${label}: bad VP8 start code`);
      image = { width: bytes.readUInt16LE(body + 6) & 0x3fff, height: bytes.readUInt16LE(body + 8) & 0x3fff, lossless: false };
    } else if (fourcc === 'ANIM' || fourcc === 'ANMF') {
      fail(`${label}: animated WebP is not supported`);
    }
    offset = body + size + (size & 1);
  }
  if (offset !== bytes.length) fail(`${label}: chunks do not end at the end of the file (${offset} vs ${bytes.length})`);
  if (!image) fail(`${label}: no VP8/VP8L image chunk`);
  if (canvas && (canvas.width !== image.width || canvas.height !== image.height)) {
    fail(`${label}: VP8X canvas ${canvas.width}x${canvas.height} differs from the image ${image.width}x${image.height}`);
  }
  return { width: image.width, height: image.height, lossless: image.lossless, chunks };
}

/** Every piece of source that pins a RUNTIME_DERIVED number must still occur exactly once in the game. */
function checkRuntimeDerivedSource(html) {
  for (const literal of RUNTIME_DERIVED_SOURCE) {
    const first = html.indexOf(literal);
    if (first < 0 || html.indexOf(literal, first + 1) >= 0) {
      fail(`the game source no longer has exactly one occurrence of ${JSON.stringify(literal.slice(0, 70))}: review RUNTIME_DERIVED in tools/extract_assets.mjs`);
    }
  }
}

// ---------------------------------------------------------------------------------------------------
// 2. Cutting constant declarations out of the JavaScript and evaluating them in an empty vm context
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

/** Cuts `var|let|const NAME=...` (without the trailing `;`) out of the game; NAME must be declared once. */
function findDeclaration(src, name) {
  const re = new RegExp(`(?<![\\w$.])(?:var|let|const)\\s+${name.replace(/[$]/g, '\\$&')}\\s*=`, 'g');
  const hits = [...src.matchAll(re)];
  if (hits.length !== 1) fail(`declaration of ${name}: expected exactly 1 match, found ${hits.length}`);
  const start = hits[0].index;
  const end = statementEnd(src, start + hits[0][0].length);
  const text = src.slice(start, end);
  if (text.length > 20000) fail(`declaration of ${name} is suspiciously long (${text.length} chars): statement end not found`);
  const forbidden = FORBIDDEN_IDENTIFIERS.exec(text);
  if (forbidden) fail(`declaration of ${name} references "${forbidden[0]}"; only pure constant declarations may be evaluated`);
  return { name, start, end, text };
}

/** Runs the declarations (in the game's source order) in a new context with an empty sandbox. */
function evaluateDeclarations(declarations, names, prelude = '') {
  const ordered = [...declarations].sort((a, b) => a.start - b.start);
  const code = `${prelude}${ordered.map((d) => d.text).join(';\n')};\n`
    + `JSON.stringify({${names.map((n) => `${JSON.stringify(n)}:${n}`).join(',')}},`
    + '(key, value) => (value instanceof Set ? [...value] : value));';
  let json;
  try {
    json = vm.runInNewContext(code, {}, {
      filename: 'pure-declarations.js',
      timeout: 5000,
      contextCodeGeneration: { strings: false, wasm: false },
    });
  } catch (error) {
    fail(`evaluating the pure declarations failed: ${error.message}`);
  }
  if (typeof json !== 'string') fail('evaluating the pure declarations did not produce a JSON string');
  return JSON.parse(json);
}

function readConstants(html) {
  const declarations = PURE_DECLARATIONS.map((name) => findDeclaration(html, name));
  const values = evaluateDeclarations(declarations, PURE_DECLARATIONS);

  // Pointer-dependent constants: evaluated once with a coarse pointer (Android) and once with a fine one.
  const pointer = POINTER_DEPENDENT.map((name) => findDeclaration(html, name));
  for (const d of pointer) {
    if (!new RegExp(`^var ${d.name}=IS_COARSE_POINTER\\?\\d+:\\d+$`).test(d.text)) {
      fail(`declaration of ${d.name} is not of the form IS_COARSE_POINTER?A:B: ${JSON.stringify(d.text)}`);
    }
  }
  const raster = {};
  for (const [mode, coarse] of [['coarse', true], ['fine', false]]) {
    raster[mode] = evaluateDeclarations(pointer, POINTER_DEPENDENT, `var IS_COARSE_POINTER=${coarse};\n`);
  }
  return { values, raster };
}

// ---------------------------------------------------------------------------------------------------
// 3. Layout
// ---------------------------------------------------------------------------------------------------
const clamp = (v, a, b) => Math.max(a, Math.min(b, v)); // the game's clamp(v,a,b)
const isInteger = (v) => Number.isInteger(v);
const keysOf = (object) => Object.keys(object);

/**
 * ART_CELL_CACHE and buildAtlasDrawGeometry of the game, for every sheet of ART_LAYOUTS.
 * The geometry map holds every id of the layout, then (characters, enemies) the art-id aliases that point
 * to the idle1 cell; insets are looked up by the key of the map entry, like the game does.
 */
function buildArtSheets(values, imagesByKey) {
  const { ART_LAYOUTS, CHARACTER_ART_IDS, ENEMY_ART_IDS, CHARACTER_FRAME_IDS, ENEMY_FRAME_IDS,
    CHARACTER_FRAME_SOURCE_INSETS } = values;
  const sheets = {};
  const sheetNames = keysOf(ART_LAYOUTS);
  const artImageKeys = IMAGES.filter((i) => i.expression.startsWith('ART_SOURCES.')).map((i) => i.key).sort();
  if (JSON.stringify(sheetNames.map(ART_SHEET_IMAGE).sort()) !== JSON.stringify(artImageKeys)) {
    fail(`ART_LAYOUTS sheets (${sheetNames.join(',')}) do not match the ART_SOURCES images (${artImageKeys.join(',')})`);
  }
  for (const sheet of sheetNames) {
    const layout = ART_LAYOUTS[sheet];
    const image = imagesByKey.get(ART_SHEET_IMAGE(sheet));
    const { cols, rows, ids } = layout;
    if (!isInteger(cols) || !isInteger(rows) || cols < 1 || rows < 1) fail(`${sheet}: bad grid ${cols}x${rows}`);
    if (new Set(ids).size !== ids.length) fail(`${sheet}: duplicate ids`);
    if (ids.length > cols * rows) fail(`${sheet}: ${ids.length} ids do not fit into ${cols}x${rows} cells`);

    const cells = new Map();
    ids.forEach((id, index) => cells.set(id, { index, col: index % cols, row: Math.floor(index / cols) }));
    const aliases = {};
    const aliasSource = sheet === 'characters' ? [CHARACTER_ART_IDS, CHARACTER_FRAME_IDS]
      : sheet === 'enemies' ? [ENEMY_ART_IDS, ENEMY_FRAME_IDS] : null;
    if (aliasSource) {
      for (const artId of aliasSource[0]) {
        const target = aliasSource[1][artId].idle1;
        if (!cells.has(target)) fail(`${sheet}: alias ${artId} points to the missing cell ${target}`);
        if (cells.has(artId)) fail(`${sheet}: alias ${artId} collides with a cell id`);
        cells.set(artId, cells.get(target));
        aliases[artId] = target;
      }
    }

    const sw = image.width / cols;
    const sh = image.height / rows;
    const geometry = {};
    for (const [id, cell] of cells) {
      const inset = sheet === 'characters' ? CHARACTER_FRAME_SOURCE_INSETS[id] : null;
      const insetL = clamp(Number(inset?.left) || 0, 0, Math.max(0, sw - 1));
      const insetR = clamp(Number(inset?.right) || 0, 0, Math.max(0, sw - insetL - 1));
      const insetT = clamp(Number(inset?.top) || 0, 0, Math.max(0, sh - 1));
      const insetB = clamp(Number(inset?.bottom) || 0, 0, Math.max(0, sh - insetT - 1));
      const sourceW = sw - insetL - insetR;
      const sourceH = sh - insetT - insetB;
      geometry[id] = {
        sx: cell.col * sw + insetL,
        sy: cell.row * sh + insetT,
        sourceW,
        sourceH,
        dxMul: -0.5 + insetL / sw,
        dyMul: -0.5 + insetT / sh,
        dwMul: sourceW / sw,
        dhMul: sourceH / sh,
      };
    }
    sheets[sheet] = { image: image.key, file: `${image.key}.webp`, width: image.width, height: image.height,
      cols, rows, cell_w: sw, cell_h: sh, ids, aliases, geometry };
  }
  return sheets;
}

/** Checks that a regular grid of `cols` x `rows` cells of `cell` pixels exactly covers the image. */
function expectGrid(image, cols, rows, cellW, cellH) {
  if (image.width !== cols * cellW || image.height !== rows * cellH) {
    fail(`${image.key}: ${image.width}x${image.height} is not ${cols}x${rows} cells of ${cellW}x${cellH}`);
  }
  return { image: image.key, file: `${image.key}.webp`, width: image.width, height: image.height,
    cols, rows, cell_w: cellW, cell_h: cellH };
}

/** Rows of a meta sheet are stacked vertically in key order: x = 0, y = row * height. */
function expectStackedMeta(name, meta, cellW, cellH) {
  keysOf(meta).forEach((id, row) => {
    const m = meta[id];
    if (m.x !== 0 || m.y !== row * cellH || m.width !== cellW || m.height !== cellH) {
      fail(`${name}.${id}: expected x=0 y=${row * cellH} ${cellW}x${cellH}, got x=${m.x} y=${m.y} ${m.width}x${m.height}`);
    }
    if (!isInteger(m.frames) || m.frames < 1) fail(`${name}.${id}: bad frame count ${m.frames}`);
  });
}

function buildLayout(values, raster, imagesByKey) {
  const V = values;
  const get = (key) => imagesByKey.get(key);
  const cell = V.CHARACTER_ATLAS_CELL_SIZE;

  const sheets = buildArtSheets(V, imagesByKey);

  // OVERHAUL_CHAR_ATLAS_SOURCE: column = CHARACTER_ANIMATION_FRAMES.indexOf(frame), row = OVERHAUL_CHAR_ROWS.indexOf(artId).
  const overhaulCharacters = {
    ...expectGrid(get('overhaul_characters'), V.CHARACTER_ANIMATION_FRAMES.length, V.OVERHAUL_CHAR_ROWS.length, cell, cell),
    row_ids: V.OVERHAUL_CHAR_ROWS,
    frame_ids: V.CHARACTER_ANIMATION_FRAMES,
    palette_max: V.OVERHAUL_PALETTE_MAX,
  };

  // OVERHAUL_FX_SOURCE: one row per OVERHAUL_FX_ROWS entry, `frames` columns of 64x64 each.
  const overhaulMetaIds = keysOf(V.OVERHAUL_FX_META);
  if (JSON.stringify(overhaulMetaIds) !== JSON.stringify(V.OVERHAUL_FX_ROWS)) fail('OVERHAUL_FX_ROWS differs from the keys of OVERHAUL_FX_META');
  expectStackedMeta('OVERHAUL_FX_META', V.OVERHAUL_FX_META, 64, 64);
  const overhaulFxCols = Math.max(...overhaulMetaIds.map((id) => V.OVERHAUL_FX_META[id].frames));
  const overhaulFx = {
    ...expectGrid(get('overhaul_fx'), overhaulFxCols, overhaulMetaIds.length, 64, 64),
    row_ids: V.OVERHAUL_FX_ROWS,
    content_ratio: V.OVERHAUL_FX_CONTENT_RATIO,
    palette_max: V.OVERHAUL_PALETTE_MAX,
    meta: V.OVERHAUL_FX_META,
  };

  // OVERHAUL_ICON_SOURCE: one 64x64 icon per OVERHAUL_WEAPON_ICON_INDEX entry, column = index.
  const iconIds = keysOf(V.OVERHAUL_WEAPON_ICON_INDEX);
  iconIds.forEach((id, i) => { if (V.OVERHAUL_WEAPON_ICON_INDEX[id] !== i) fail(`OVERHAUL_WEAPON_ICON_INDEX.${id} is not ${i}`); });
  const overhaulIcons = {
    ...expectGrid(get('overhaul_weapon_icons'), iconIds.length, 1, 64, 64),
    icon_index: V.OVERHAUL_WEAPON_ICON_INDEX,
  };

  // SIGNATURE_FX_SOURCE: row i of SIGNATURE_FX_META (keys in alphabetical source order), `frames` columns.
  const signatureIds = keysOf(V.SIGNATURE_FX_META);
  signatureIds.forEach((id) => { if (V.SIGNATURE_FX_META[id].effectId !== id) fail(`SIGNATURE_FX_META.${id}.effectId differs from its key`); });
  expectStackedMeta('SIGNATURE_FX_META', V.SIGNATURE_FX_META, 64, 64);
  const signatureCols = Math.max(...signatureIds.map((id) => V.SIGNATURE_FX_META[id].frames));
  const signatureFx = {
    ...expectGrid(get('signature_fx'), signatureCols, signatureIds.length, 64, 64),
    max_active: V.MAX_SIGNATURE_FX,
    weapon_icon: V.SIGNATURE_WEAPON_ICON,
    meta: V.SIGNATURE_FX_META,
  };
  for (const [weapon, effect] of Object.entries(V.SIGNATURE_WEAPON_ICON)) {
    if (!V.SIGNATURE_FX_META[effect]) fail(`SIGNATURE_WEAPON_ICON.${weapon} points to the unknown effect ${effect}`);
  }

  // RANGE_FX_SOURCE: 2x2 cells of 256x256, one per RANGE_FX_STYLE value.
  const rangeCells = V.RANGE_FX_STYLE_CELLS;
  const rangeCols = Math.max(...rangeCells.map((c) => c.col)) + 1;
  const rangeRows = Math.max(...rangeCells.map((c) => c.row)) + 1;
  const rangeImage = get('range_fx');
  const rangeFx = {
    ...expectGrid(rangeImage, rangeCols, rangeRows, rangeImage.width / rangeCols, rangeImage.height / rangeRows),
    style: V.RANGE_FX_STYLE,
    style_cells: rangeCells,
  };
  Object.entries(V.RANGE_FX_STYLE).forEach(([name, index]) => { if (!rangeCells[index]) fail(`RANGE_FX_STYLE.${name} has no cell`); });

  // GENERATED_ENEMY_FX_SOURCES: whole images, no slicing; the game accepts them only at the expected size.
  const generatedKeys = { eliteShockwave: 'enemy_fx_elite_shockwave', bossCharge: 'enemy_fx_boss_charge' };
  const generatedEnemyFx = {};
  for (const [name, expected] of Object.entries(V.GENERATED_ENEMY_FX_EXPECTED)) {
    if (!generatedKeys[name]) fail(`GENERATED_ENEMY_FX_EXPECTED.${name} has no image`);
    const image = get(generatedKeys[name]);
    if (image.width !== expected.width || image.height !== expected.height) {
      fail(`${name}: ${image.width}x${image.height} differs from GENERATED_ENEMY_FX_EXPECTED ${expected.width}x${expected.height}`);
    }
    generatedEnemyFx[name] = { image: image.key, file: `${image.key}.webp`, width: image.width, height: image.height };
  }
  if (keysOf(generatedEnemyFx).length !== keysOf(generatedKeys).length) fail('GENERATED_ENEMY_FX_EXPECTED lacks an image');

  return {
    format: FORMAT_VERSION,
    generated_by: 'tools/extract_assets.mjs',
    source: SOURCE_REL,
    notes: [
      'sheets.<sheet>.geometry is buildAtlasDrawGeometry(sheet, image) of the game (ART_DRAW_GEOMETRY), including the art-id aliases.',
      'Cells are row-major: index = row * cols + col. Source rect of a geometry entry: (sx, sy, sourceW, sourceH); the sprite is drawn at (x + dxMul*w, y + dyMul*h) with size (dwMul*w, dhMul*h).',
      'Images are drawn without smoothing. Runtime-derived images (hit-flash atlas, low-resolution caches, range ring tints) are not stored; runtime_derived holds their parameters for step S7.',
    ],
    sheets,
    overhaul_characters: overhaulCharacters,
    overhaul_fx: overhaulFx,
    overhaul_weapon_icons: overhaulIcons,
    signature_fx: signatureFx,
    range_fx: rangeFx,
    generated_enemy_fx: generatedEnemyFx,
    art_maps: {
      PROJECTILE_ART_BY_WEAPON: V.PROJECTILE_ART_BY_WEAPON,
      PROJECTILE_ART_BY_SHAPE: V.PROJECTILE_ART_BY_SHAPE,
      HAZARD_OVERLAY_ART: V.HAZARD_OVERLAY_ART,
      SPINNING_HAZARD_TYPES: V.SPINNING_HAZARD_TYPES,
    },
    animation: {
      CHARACTER_ART_IDS: V.CHARACTER_ART_IDS,
      ENEMY_ART_IDS: V.ENEMY_ART_IDS,
      CHARACTER_ANIMATION_FRAMES: V.CHARACTER_ANIMATION_FRAMES,
      ENEMY_ANIMATION_FRAMES: V.ENEMY_ANIMATION_FRAMES,
      IDLE_ANIMATION_FRAMES: V.IDLE_ANIMATION_FRAMES,
      WALK_ANIMATION_FRAMES: V.WALK_ANIMATION_FRAMES,
      ATTACK_ANIMATION_FRAMES: V.ATTACK_ANIMATION_FRAMES,
      KO_ANIMATION_FRAMES: V.KO_ANIMATION_FRAMES,
      CHARACTER_ANIMATION_FPS: V.CHARACTER_ANIMATION_FPS,
      CHARACTER_ANIMATION_DEFINITIONS: V.CHARACTER_ANIMATION_DEFINITIONS,
      CHARACTER_ATLAS_CELL_SIZE: V.CHARACTER_ATLAS_CELL_SIZE,
      MIKO_ATLAS_ROW: V.MIKO_ATLAS_ROW,
      CHARACTER_FRAME_SOURCE_INSETS: V.CHARACTER_FRAME_SOURCE_INSETS,
    },
    raster,
    runtime_derived: RUNTIME_DERIVED,
  };
}

// ---------------------------------------------------------------------------------------------------
// 4. Output
// ---------------------------------------------------------------------------------------------------

/** JSON with two-space indentation; short values stay on one line, long primitive arrays are wrapped. */
function format(value, indent = '') {
  const flat = JSON.stringify(value);
  if (flat === undefined) fail('cannot serialise an undefined value');
  if (typeof value !== 'object' || value === null || flat.length <= 100) return flat;
  const next = `${indent}  `;
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

function buildManifest(images) {
  const entries = {};
  for (const image of images) {
    entries[image.key] = {
      file: `${image.key}.webp`,
      source_expression: image.expression,
      bytes: image.bytes.length,
      sha256: image.sha256,
      width: image.width,
      height: image.height,
      format: image.info.lossless ? 'lossless' : 'lossy',
      chunks: image.info.chunks,
      rgba_sha256: image.rgba_sha256,
    };
  }
  return {
    format: FORMAT_VERSION,
    generated_by: 'tools/extract_assets.mjs',
    source: SOURCE_REL,
    images: entries,
  };
}

/** Everything the tool writes: relative file name -> Buffer. */
function generate(sourcePath) {
  const sourceBytes = fs.readFileSync(sourcePath);
  if (sourceBytes[0] === 0xef && sourceBytes[1] === 0xbb && sourceBytes[2] === 0xbf) fail('the source starts with a UTF-8 BOM');
  const html = sourceBytes.toString('utf8');
  if (html.includes('�')) fail('the source is not valid UTF-8');
  const images = findImages(html);
  const imagesByKey = new Map(images.map((i) => [i.key, i]));
  checkRuntimeDerivedSource(html);
  const { values, raster } = readConstants(html);
  const layout = buildLayout(values, raster, imagesByKey);
  const manifest = buildManifest(images);
  const files = new Map();
  for (const image of images) files.set(`${image.key}.webp`, image.bytes);
  files.set('atlas_manifest.json', Buffer.from(`${format(manifest)}\n`));
  files.set('atlas_layout.json', Buffer.from(`${format(layout)}\n`));
  return { files, images, html };
}

// ---------------------------------------------------------------------------------------------------
// 5. Modes
// ---------------------------------------------------------------------------------------------------
function readIfExists(file) {
  try { return fs.readFileSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

function writeFiles(files, outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  let changed = 0;
  for (const [name, data] of files) {
    const target = path.join(outDir, name);
    const existing = readIfExists(target);
    const same = existing !== null && existing.equals(data);
    if (!same) { fs.writeFileSync(target, data); changed++; }
    console.log(`${same ? 'unchanged' : existing === null ? 'created  ' : 'updated  '} ${path.relative(REPO_ROOT, target)} (${data.length} bytes)`);
  }
  const stray = strayFiles(files, outDir);
  for (const name of stray) console.log(`WARNING: ${path.relative(REPO_ROOT, path.join(outDir, name))} is not produced by this tool (delete it if it is stale)`);
  console.log(`${files.size} files, ${changed} written`);
  return 0;
}

/** .webp / atlas_*.json files in the output directory that this tool does not produce. */
function strayFiles(files, outDir) {
  if (!fs.existsSync(outDir)) return [];
  return fs.readdirSync(outDir).filter((name) => (name.endsWith('.webp') || /^atlas_.*\.json$/.test(name)) && !files.has(name)).sort();
}

function checkFiles(files, outDir) {
  const problems = [];
  for (const [name, data] of files) {
    const existing = readIfExists(path.join(outDir, name));
    if (existing === null) problems.push(`missing:   ${name}`);
    else if (!existing.equals(data)) problems.push(`differs:   ${name} (${existing.length} bytes on disk, ${data.length} expected; sha256 ${sha256(existing).slice(0, 16)} vs ${sha256(data).slice(0, 16)})`);
  }
  for (const name of strayFiles(files, outDir)) problems.push(`unexpected: ${name}`);
  if (problems.length === 0) {
    console.log(`check OK: ${files.size} files in ${path.relative(REPO_ROOT, outDir) || '.'} are identical to a fresh extraction`);
    return 0;
  }
  console.error(`check FAILED: ${problems.length} problem(s) in ${path.relative(REPO_ROOT, outDir) || '.'} (run: node tools/extract_assets.mjs)`);
  for (const problem of problems) console.error(`  ${problem}`);
  return 1;
}

function compareFg4(images, fg4Path) {
  const shipped = fs.readFileSync(fg4Path, 'utf8');
  const total = [...shipped.matchAll(/data:image\//g)].length;
  console.log(`compare-fg4: ${path.relative(REPO_ROOT, fg4Path)} (${shipped.length} chars), ${total} data:image URIs`);
  let bad = 0;
  for (const image of images) {
    let count = 0;
    let first = -1;
    for (let at = shipped.indexOf(image.uri); at >= 0; at = shipped.indexOf(image.uri, at + 1)) {
      if (count++ === 0) first = at;
    }
    const verdict = count === 1 ? 'identical' : count === 0 ? 'MISSING' : `DUPLICATED x${count}`;
    if (count !== 1) bad++;
    console.log(`  ${image.key.padEnd(26)} ${verdict.padEnd(9)} ${count === 1 ? `at char ${first}` : ''} ${image.sha256.slice(0, 12)}`);
  }
  if (total !== images.length) { bad++; console.error(`  the shipped file has ${total} data:image URIs, expected ${images.length}`); }
  console.log(bad === 0 ? `compare-fg4 OK: all ${images.length} data URIs occur exactly once, byte for byte` : `compare-fg4 FAILED: ${bad} problem(s)`);
  return bad === 0 ? 0 : 1;
}

function usage() {
  const text = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n');
  console.log(text.slice(1).filter((l, i) => i < 22 && l.startsWith('//')).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
}

function main(argv) {
  const options = { check: false, compareFg4: false, source: DEFAULT_SOURCE, fg4: DEFAULT_FG4, out: DEFAULT_OUT };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => { if (i + 1 >= argv.length) fail(`${arg} needs a value`); return path.resolve(argv[++i]); };
    if (arg === '--check') options.check = true;
    else if (arg === '--compare-fg4') options.compareFg4 = true;
    else if (arg === '--source') options.source = value();
    else if (arg === '--fg4') options.fg4 = value();
    else if (arg === '--out') options.out = value();
    else if (arg === '-h' || arg === '--help') { usage(); return 0; }
    else fail(`unknown argument: ${arg} (see --help)`);
  }
  const { files, images } = generate(options.source);
  console.log(`extracted ${images.length} images from ${path.relative(REPO_ROOT, options.source)}`);
  for (const image of images) {
    console.log(`  ${image.key.padEnd(26)} ${String(image.width).padStart(4)}x${String(image.height).padEnd(4)} ${String(image.bytes.length).padStart(6)} bytes  ${image.sha256.slice(0, 12)}  ${image.expression}`);
  }
  let status = options.check ? checkFiles(files, options.out) : writeFiles(files, options.out);
  if (options.compareFg4) status = Math.max(status, compareFg4(images, options.fg4));
  return status;
}

export { IMAGES, ExtractionError, findImages, readConstants, buildArtSheets, buildLayout, generate };

const isMain = process.argv[1] !== undefined && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    if (error instanceof ExtractionError) {
      console.error(`extract_assets: ERROR: ${error.message}`);
      process.exitCode = 2;
    } else if (error?.code === 'ENOENT') {
      console.error(`extract_assets: ERROR: cannot read ${error.path}`);
      process.exitCode = 2;
    } else {
      throw error;
    }
  }
}
