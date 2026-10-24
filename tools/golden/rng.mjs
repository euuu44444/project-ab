// Golden vectors for godot/sim/rng.gd (SeededRng), godot/sim/game_rng.gd (GameRng) and the seed handling of the game:
// makeSeededRandom, setGameSeed, rand, randi, chance and shuffle, all CUT OUT OF THE ORIGINAL GAME (original.html) and run
// in an empty node:vm context. Nothing here is typed by hand.
//
//   * seeds[]: the first 1000 outputs of makeSeededRandom(seed) for each seed, as the uint32 k with value = k / 2^32
//     (every output of the generator is exactly k / 4294967296), plus checkpoints further down the stream.
//   * normalization[]: what makeSeededRandom does with unusual seeds (`seed>>>0||2654435769`: negative, fractional, NaN,
//     above 2^32 ...), with the first three outputs of each.
//   * game_rng[]: scripted sequences of the game's gameRandom helpers (rand, randi, chance, shuffle, the `gameRandom()*n|0`
//     index idiom, re-seeding) after setGameSeed(seed), with the result of every call and the draw counter gameRandomDraws
//     after it. This pins the exact number of generator draws of each helper.
import { encodeU32, hex64, makeRng } from './_codec.mjs';

export const name = 'rng';

// 424242 and 24681357 are the seeds of the reference traces (design section 9.2); the others are edge cases of
// `seed>>>0||2654435769`: 0 and 2654435769 map to the same stream, 4294967295 is -1 >>> 0.
const STREAM_SEEDS = [424242, 24681357, 0, 1, 4294967295, 2147483648, 2654435769, 123456789];
const STREAM_LENGTH = 1000;
// Checkpoints (output numbers, counted from 0) of every stream, and one longer stream for the first reference seed.
const CHECKPOINTS = [9999, 99999];
const LONG_CHECKPOINT = { seed: 424242, index: 999999 };
const NORMALIZATION_INPUTS = [-1, -1.9, 1.9, 0, -0, 4294967296, 4294967297, 4294967295.5, 2 ** 53, 1e20, -(2 ** 31), 2147483648, 0.5, 2654435769, NaN, Infinity, -Infinity];
const GAME_RNG_SEEDS = [424242, 24681357, 0, 1, 4294967295];
const OPS_PER_SEED = 400;

export function generate(extract, info) {
  const { makeSeededRandom } = extract(['makeSeededRandom']);
  // The Godot port reproduces this line; make the generator fail if the game's seed handling ever changes.
  for (const piece of ['let a=seed>>>0||2654435769', 'a|=0;a=a+1831565813|0;let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296']) {
    if (!makeSeededRandom.toString().includes(piece)) throw new Error(`makeSeededRandom no longer contains ${JSON.stringify(piece)}`);
  }
  const k = (value) => {
    const scaled = value * 4294967296;
    if (!Number.isInteger(scaled) || scaled < 0 || scaled > 4294967295) throw new Error(`generator output ${value} is not k / 2^32`);
    return scaled;
  };

  const seeds = STREAM_SEEDS.map((seed) => {
    const next = makeSeededRandom(seed);
    const first = [];
    const checkpoints = {};
    const last = seed === LONG_CHECKPOINT.seed ? LONG_CHECKPOINT.index : Math.max(...CHECKPOINTS);
    for (let i = 0; i <= last; i++) {
      const value = k(next());
      if (i < STREAM_LENGTH) first.push(value);
      if (CHECKPOINTS.includes(i) || (seed === LONG_CHECKPOINT.seed && i === LONG_CHECKPOINT.index)) checkpoints[String(i)] = value;
    }
    return { seed, normalized: (seed >>> 0) || 2654435769, first: encodeU32(first), checkpoints };
  });

  const normalization = NORMALIZATION_INPUTS.map((input) => {
    const next = makeSeededRandom(input);
    return { input: hex64(input), normalized: (input >>> 0) || 2654435769, first: [k(next()), k(next()), k(next())] };
  });

  return {
    format: 'elemental-swarm-golden-rng/1',
    generated_by: 'tools/gen_golden.mjs (tools/golden/rng.mjs)',
    source: info.sourcePath,
    source_sha256: info.sourceSha256,
    encoding: 'first: base64 of little-endian uint32 k (value = k / 4294967296); hex fields are IEEE-754 binary64 bit patterns of an input or result',
    stream_length: STREAM_LENGTH,
    seeds,
    normalization,
    game_rng: GAME_RNG_SEEDS.map((seed) => gameRngSequence(extract, info, seed)),
  };
}

/** One scripted run of the game's gameRandom helpers after setGameSeed(seed). */
function gameRngSequence(extract, info, seed) {
  // The game declares `var gameRandom=Math.random;var gameRandomDraws=0;var gameRandomSeed=null;` and calls setGameSeed(null)
  // at start-up; both mention Math.random, which a cut-out piece may not use. The prelude declares the same three globals
  // with a gameRandom that fails loudly, and setGameSeed (whose Math.random is only on the seed == null path, never
  // taken here) is cut with that one exception allowed.
  if (!info.sourceText.includes('var gameRandom=Math.random;var gameRandomDraws=0;var gameRandomSeed=null;')) {
    throw new Error('the declaration of gameRandom in the game changed; review tools/golden/rng.mjs');
  }
  const game = extract(['makeSeededRandom', 'setGameSeed', 'rand', 'randi', 'chance', 'shuffle'], {
    prelude: 'var gameRandom=function(){throw new Error("gameRandom used before setGameSeed");};var gameRandomDraws=0;var gameRandomSeed=null;',
    allow: ['Math.random'],
    expose: { random: '() => gameRandom()', draws: '() => gameRandomDraws', seedValue: '() => gameRandomSeed' },
  });
  if (!game.setGameSeed.toString().includes('const base=seed==null?Math.random:makeSeededRandom(seed>>>0)')) {
    throw new Error('setGameSeed changed; review tools/golden/rng.mjs');
  }
  const rng = makeRng(0x5eed0000 ^ seed);
  const pick = (list) => list[Math.floor(rng() * list.length)];
  const floats = [0, 1, -1, 0.3, 2.5, -2.5, 1e-9, 100, -100, 7.75, 1e6, 0.5, -0.25, 3.14159];
  const ints = [0, 1, -1, 2, 3, 5, 10, -10, 100, 1000, 7];
  const chances = [0, 0.05, 0.12, 0.5, 0.95, 1, -1, 2, NaN];
  const sizes = [0, 1, 2, 3, 4, 7, 16, 100];

  game.setGameSeed(seed);
  const initial = { seed_value: game.seedValue(), draws: game.draws() };
  const ops = [];
  for (let i = 0; i < OPS_PER_SEED; i++) {
    const r = rng();
    let record;
    if (r < 0.2) {
      record = ['random', [], hex64(game.random())];
    } else if (r < 0.4) {
      const a = pick(floats);
      const b = pick(floats);
      record = ['rand', [hex64(a), hex64(b)], hex64(game.rand(a, b))];
    } else if (r < 0.55) {
      const a = pick(ints);
      const b = pick(ints);
      record = ['randi', [a, b], game.randi(a, b)];
    } else if (r < 0.7) {
      const p = pick(chances);
      record = ['chance', [hex64(p)], game.chance(p)];
    } else if (r < 0.85) {
      const size = pick(sizes);
      record = ['shuffle', [size], game.shuffle(Array.from({ length: size }, (_, j) => j))];
    } else if (r < 0.97) {
      const length = pick(sizes);
      // the idiom `pool[gameRandom()*pool.length|0]`
      record = ['index', [length], (game.random() * length) | 0];
    } else {
      const reseed = pick(GAME_RNG_SEEDS);
      game.setGameSeed(reseed);
      record = ['reseed', [reseed], game.seedValue()];
    }
    ops.push([...record, game.draws()]);
  }
  // Plain arrays of numbers/booleans/strings only; the shuffle results are small integer arrays.
  return { seed, initial, ops };
}
