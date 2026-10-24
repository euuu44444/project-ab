// Results that Chromium 141 produced for these arguments, as IEEE-754 bit patterns (hex), or null while not recorded.
// Record or re-check them with `node tools/verify_golden_chromium.mjs --canaries`.
//
// tools/golden/math.mjs takes the Math.exp, Math.atan2, Math.atan, Math.log and Math.hypot of the Node that runs the
// generator as the reference. V8 12.4 (Node 22) and V8 14.1 (Chromium 141) agree on them bit for bit, but a newer V8
// sends exp, atan2 and log to other libm code. The generator therefore refuses to run when the Node it runs on
// disagrees with Chromium on these arguments.
export const CANARIES = [
  ['exp', [-0.3], '3fe7b4c869c37c05'],
  ['exp', [0.7], '40001c2a61268987'],
  ['exp', [-12.5], '3ecf42ed3f68e690'],
  ['exp', [100.1], '48f5508d07df81bb'],
  ['exp', [-700.3], '00c9a5615b10648a'],
  ['atan2', [-143.99999999997817, 107.99999999995634], 'bfedac670561bf93'],
  ['atan2', [0.2, 0.5], '3fd85a376b677dc0'],
  ['atan2', [-3, -4], 'c003fc176b7a8560'],
  ['atan2', [0.00001, 1], '3ee4f8b588e06854'],
  ['atan', [0.5], '3fddac670561bb4f'],
  ['atan', [1.3], '3fed488143ad8c44'],
  ['atan', [3.7], '3ff4e8c94dbf54e5'],
  ['atan', [100000], '3ff921f0d7e968a8'],
  ['log', [2], '3fe62e42fefa39ef'],
  ['log', [0.3], 'bff34378fcbda721'],
  ['log', [1234.5], '401c79436f818745'],
  ['log', [1e-10], 'c037069e2aa2aa5b'],
  ['hypot', [3, 4], '4014000000000000'],
  ['hypot', [1.1, 2.2], '4003ad69f7f3f386'],
  ['hypot', [10000000000, 3], '4202a05f20000000'],
];
