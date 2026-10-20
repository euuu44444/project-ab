// A JavaScript transcription of the sin/cos that Chromium 141 (V8 14.1.146.11) uses for Math.sin / Math.cos.
//
// Why this file exists: Node 22 (V8 12.4) is built with gcc and computes Math.sin/Math.cos with fdlibm, which
// differs from Chromium's result in the last bit for about 3% of the inputs. Chromium is built with clang, where V8
// sets use_libm_trig_functions and calls glibc_sin / glibc_cos, a copy of the IBM Accurate Mathematical Library
// (glibc s_sin.c, branred.c, sincostab.c, usncs.h, branred.h; V8 third_party/glibc at glibc revision 985ff73a). The
// golden vectors of sin and cos must follow Chromium (the reference of the port, design section 9.2), so they are
// computed by this port instead of by the Math.sin of the Node that happens to run the generator.
//
// The port is arithmetic on doubles only (no Math.* function but abs/floor), which is exact IEEE arithmetic in every
// JavaScript engine, so it gives the same bits everywhere. tools/verify_golden_chromium.mjs compares it (and the
// committed math.json) with the real Math.sin / Math.cos of a Chromium through Playwright.
//
// The table below is __sincostab (440 doubles, 4 per 1/128 step) as IEEE-754 bit patterns, and TOVERP is 2/pi in
// base 2^24 (branred.h). Both come from the V8 sources.

import { pow2 } from './_codec.mjs';

const dv = new DataView(new ArrayBuffer(8));
const hiWord = (x) => { dv.setFloat64(0, x); return dv.getInt32(0); };
const loWord = (x) => { dv.setFloat64(0, x); return dv.getInt32(4); };
const fromWords = (hi, lo) => { dv.setInt32(0, hi); dv.setInt32(4, lo); return dv.getFloat64(0); };
const fromBits = (hex) => { dv.setBigUint64(0, BigInt('0x' + hex)); return dv.getFloat64(0); };

// C hexadecimal floating constant, e.g. -0x1.5555555555555p-3 (exact: mantissa and 2^exponent are both exact).
function hexFloat(text) {
  const m = /^(-?)0x([0-9a-f]+)\.?([0-9a-f]*)p([+-]?\d+)$/i.exec(text);
  if (!m) throw new Error(`bad hex float ${text}`);
  const mant = BigInt('0x' + m[2] + m[3]);
  if (BigInt(Number(mant)) !== mant) throw new Error(`mantissa too wide ${text}`);
  const v = Number(mant) * pow2(Number(m[4]) - 4 * m[3].length);
  return m[1] ? -v : v;
}

// usncs.h
const s1 = hexFloat('-0x1.5555555555555p-3');
const s2 = hexFloat('0x1.1111111110ECEp-7');
const s3 = hexFloat('-0x1.A01A019DB08B8p-13');
const s4 = hexFloat('0x1.71DE27B9A7ED9p-19');
const s5 = hexFloat('-0x1.ADDFFC2FCDF59p-26');
const big = hexFloat('0x1.8000000000000p45');
const hp0 = hexFloat('0x1.921FB54442D18p0');
const hp1 = hexFloat('0x1.1A62633145C07p-54');
const mp1 = hexFloat('0x1.921FB58000000p0');
const mp2 = hexFloat('-0x1.DDE973C000000p-27');
const pp3 = hexFloat('-0x1.CB3B398000000p-55');
const pp4 = hexFloat('-0x1.d747f23e32ed7p-83');
const hpinv = hexFloat('0x1.45F306DC9C883p-1');
const toint = hexFloat('0x1.8000000000000p52');
// s_sin.c
const sn3 = Number('-1.66666666666664880952546298448555E-01');
const sn5 = Number('8.33333214285722277379541354343671E-03');
const cs2 = Number('4.99999999999999999999950396842453E-01');
const cs4 = Number('-4.16666666666664434524222570944589E-02');
const cs6 = Number('1.38888874007937613028114285595617E-03');
// branred.h (note: mp1/mp2/hp0/hp1 of branred.h are not those of usncs.h)
const t576 = fromWords(0x63f00000, 0);
const tm600 = fromWords(0x1a700000, 0);
const tm24 = fromWords(0x3e700000, 0);
const bbig = fromWords(0x43380000, 0);
const bbig1 = fromWords(0x43580000, 0);
const bhp0 = fromWords(0x3FF921FB, 0x54442D18);
const bhp1 = fromWords(0x3C91A626, 0x33145C07);
const bmp1 = fromWords(0x3FF921FB, 0x58000000);
const bmp2 = fromWords(0xBE4DDE97, 0x40000000);
const split = 134217729; // 2^27 + 1

const SINCOSTAB_BITS = [
  '0000000000000000', '0000000000000000', '3ff0000000000000', '0000000000000000',
  '3f7fffeaaaaeeeef', 'bc1e45e2ec67b77c', '3fefffc000155552', '3c8f4a01a0196dae',
  '3f8fffaaaaeeeed5', 'bc02ab639a9f0777', '3fefff000155549f', '3c828a28a03a5ef3',
  '3f97ff7001033255', '3bfefe2b51527336', '3feffdc006bff7e6', '3c8ae6dae86977bd',
  '3f9ffeaaaeeee86f', 'bc3cd406fb224ae2', '3feffc00155527d3', 'bc83b54492d89b5b',
  '3fa3feb2b12d45d5', '3c34ec54203d1c11', '3feff9c03414a7ba', '3c6991f4be6c59bf',
  '3fa7fdc01032fba9', 'bc4599bdf46e997a', '3feff7006bfdf99f', 'bc78b3b560648d5f',
  '3fabfc6d78586dac', '3c18e4fd03dbf236', '3feff3c0c8103a31', '3c74856dbddc0e66',
  '3faffaaaeeed4edb', 'bc42d16d32684b69', '3feff0015549f4d3', '3c8328387b99426f',
  '3fb1fc343d808bef', 'bc5f3d32e6f3be4f', '3fefebc222a8ef9f', '3c57934934f54c77',
  '3fb3facb12d1755b', 'bc5921915299468c', '3fefe7034129ef6f', 'bc6cbf4337c96f97',
  '3fb5f911fd10b737', 'bc50184f02be9102', '3fefe1c4c3c873eb', 'bc35a9c9057c4a02',
  '3fb7f701032550e4', '3c3afc2d1800501a', '3fefdc06bf7e6b9b', '3c831902b535f8db',
  '3fb9f4902d55d1f9', '3c52696d7eac1dc1', '3fefd5c94b43e000', 'bc62e768cb4f92f9',
  '3fbbf1b78568391d', '3c5e91841dea4cc8', '3fefcf0c800e99b1', '3c6ea3d786d186ac',
  '3fbdee6f16c1cce6', 'bc450f8e2fb71673', '3fefc7d078d1bc88', '3c8075d2447db685',
  '3fbfeaaeee86ee36', 'bc4afcb2bcc6f03b', '3fefc015527d5bd3', '3c8b68f35094efb8',
  '3fc0f3378ddd71d1', '3c6d8468724f0f9e', '3fefb7db2bfe0695', '3c821dadf4f65ab1',
  '3fc1f0d3d7afceaf', 'bc66ef95099769a5', '3fefaf22263c4bd3', 'bc552ace133a2769',
  '3fc2ee285e4ab88f', 'bc6e4d0f05dee058', '3fefa5ea641c36f2', '3c404da6ed17cc7c',
  '3fc3eb312c5d66cb', '3c647d666b66cb91', '3fef9c340a7cc428', '3c8c5b6b063b7462',
  '3fc4e7ea4dc5f27b', '3c5949db2ac072fc', '3fef91ff40374d01', 'bc67d03f4d3a9e4c',
  '3fc5e44fcfa126f3', 'bc66f443063f89b6', '3fef874c2e1eecf6', 'bc8c6514e1332b16',
  '3fc6e05dc05a4d4c', 'bbd32c5c8b81c940', '3fef7c1afeffde24', 'bc78f55bc47540b1',
  '3fc7dc102fbaf2b5', '3c45ab50e23c97c3', '3fef706bdf9ece1c', 'bc8698c80c36dcb4',
  '3fc8d7632efaa944', 'bc620fa262cbb953', '3fef643efeb82acd', '3c76b00ac1fe28ac',
  '3fc9d252d0cec312', '3c59c43d80b1137d', '3fef57948cff6797', '3c6e3a0d3e03b1d5',
  '3fcaccdb297a0765', 'bc59883b57d6cdeb', '3fef4a6cbd1e3a79', '3c813df0edaebb57',
  '3fcbc6f84edc6199', '3c69c1a56a7b0cab', '3fef3cc7c3b3d16e', 'bc621a3ad28a3494',
  '3fccc0a6588289a3', 'bc6868d09bc87c6b', '3fef2ea5d753ffed', '3c8cc4215f56d583',
  '3fcdb9e15fb5a5d0', 'bc632e20d6cc6fc2', '3fef20073086649f', '3c7b940416c1984b',
  '3fceb2a57f8ae5a3', 'bc60be06af572ceb', '3fef10ec09c5873b', '3c8d9072762c1283',
  '3fcfaaeed4f31577', 'bc615d88508e32b8', '3fef01549f7deea1', '3c8d3c1e99e5cafd',
  '3fd0515cbf65155c', 'bc79b8c29dfd8ec8', '3feef141300d2f26', 'bc82aa1b08ded372',
  '3fd0cd00cef36436', 'bc79fb0a0c93e2b5', '3feee0b1fbc0f11c', 'bc4bfd2380bbc3b1',
  '3fd14861aa94ddeb', 'bc6be881b5b615a4', '3feecfa744d5efa1', 'bc556d0a4af541d0',
  '3fd1c37d64c6b876', '3c746076fe0dcff5', '3feebe214f76efa8', 'bc802f9f12ba543e',
  '3fd23e52111aaf36', 'bc74f080334eff18', '3feeac2061bbaf4f', '3c62c1d53e94658d',
  '3fd2b8ddc43eb49f', '3c61553899f2d807', '3fee99a4c3a7cd83', 'bc82264b1bc53ce8',
  '3fd3331e94049f87', '3c7e0cb6b40c302c', '3fee86aebf29a9ed', '3c89397afdbb58a7',
  '3fd3ad129769d3d8', '3c003d5504878398', '3fee733ea0193d40', 'bc86428b3546ce13',
  '3fd426b7e69ee697', 'bc7f09c75705c59f', '3fee5f54b436e9d0', '3c87eb0fd02fc8bc',
  '3fd4a00c9b0f3d20', '3c7823ba6bb08ead', '3fee4af14b2a449c', 'bc868ca02e8a6833',
  '3fd5190ecf68a77a', '3c7b357155eef0f3', '3fee3614b680d6a5', 'bc727793aa015237',
  '3fd591bc9fa2f597', '3c67c74bac3fe0cb', '3fee20bf49acd6c1', 'bc5660aec7ef636c',
  '3fd60a1429078775', '3c5b1fd80ba89133', '3fee0af15a03dbce', '3c5fe8e702771ae6',
  '3fd682138a38d7f7', 'bc7d889202444aad', '3fedf4ab3ebd875e', 'bc8e2d8a7e6736c4',
  '3fd6f9b8e33a0255', '3c742bc14ee9da0d', '3feddded50f228d6', 'bc6e80c8d42ba2bf',
  '3fd7710255764214', 'bc66ead7314bb6ce', '3fedc6b7eb995912', '3c54b364776dcd35',
  '3fd7e7ee03c86d4e', 'bc7b63bcdabf5af2', '3fedaf0b6b888e83', '3c8a249e2b5e5cea',
  '3fd85e7a12826949', '3c78a40e9b5face0', '3fed96e82f71a9dc', '3c8ff61bd5d2039d',
  '3fd8d4a4a774992f', '3c744a02ea766326', '3fed7e4e97e17b4a', 'bc63b770352bed94',
  '3fd94a6be9f546c5', 'bc769ce13e683f58', '3fed653f073e4040', 'bc876236434bec37',
  '3fd9bfce02e80510', '3c709e39a320b0a4', '3fed4bb9e1c619e0', '3c8f34bb77858f61',
  '3fda34c91cc50cca', 'bc5a310e3b50cecd', '3fed31bf8d8d7c06', '3c7e60dd3089cbdd',
  '3fdaa95b63a09277', 'bc66293eb13c0381', '3fed1750727d94f0', '3c80d52b1ec1a48e',
  '3fdb1d8305321617', 'bc7ae242cb99f519', '3fecfc6cfa52ad9f', '3c88b5b5508f2a0d',
  '3fdb913e30dbac43', 'bc7e38ad2f6c3ff1', '3fece115909a82e5', '3c81f139bb31109a',
  '3fdc048b17b140a3', '3c619fe6757e9fa7', '3fecc54aa2b2972e', '3c64ee162ba83a98',
  '3fdc7767ec7fd19e', 'bc5eb14d1a3d5826', '3feca90c9fc67d0b', 'bc646a81485e3462',
  '3fdce9d2e3d4a51f', 'bc62fc8a12dae298', '3fec8c5bf8ce1a84', '3c7ab3d1a1590123',
  '3fdd5bca34047661', '3c728a44a75fc29c', '3fec6f39208be53b', 'bc8741dbfbaadb42',
  '3fddcd4c15329c9a', '3c70d4c6e171fd9a', '3fec51a48b8b175e', 'bc61bbb43b9aa880',
  '3fde3e56c1582a69', 'bc50a4821099f88f', '3fec339eb01ddd81', 'bc8caaf5ee82c5c0',
  '3fdeaee8744b05f0', 'bc5789b43c9b027d', '3fec1528065b7d50', 'bc8892111312e828',
  '3fdf1eff6bc4f97b', '3c717212f8a7525c', '3febf641081e7536', '3c8b7bd71628a9a1',
  '3fdf8e99e76abc97', '3c59d950af2d00a3', '3febd6ea310294f5', '3c731bbcc88c109d',
  '3fdffdb628d2f57a', '3c6f4a992e905b6a', '3febb723fe630f32', '3c772bd2452d0a39',
  '3fe0362939c69955', 'bc82d8cd78397b01', '3feb96eeef58840e', '3c545a3cc78fade0',
  '3fe06d3686946e5b', '3c83f5ae4538ff1b', '3feb764b84b704c2', 'bc8f5848c21b389b',
  '3fe0a4021e9e1001', 'bc86f643a13914f6', '3feb553a410c104e', '3c58ff7947027a16',
  '3fe0da8b26b5672e', 'bc8a58def0bee909', '3feb33bba89c8948', '3c8ea6a51d1f6ca9',
  '3fe110d0c4b69c3b', '3c8d918998809981', '3feb11d04162a4c6', '3c71dd561efbc0c2',
  '3fe146d21f8b7f82', '3c7bf9535e2739a8', '3feaef78930bd275', 'bc7f836279746f94',
  '3fe17c8e5f2eedb0', '3c635e57102e2488', '3feaccb526f69de5', '3c88fb6a8dd6b6cc',
  '3fe1b204acb02fdd', 'bc5f190c70cbb5ff', '3feaa98688308913', 'bc0b83d607cd5070',
  '3fe1e7343236574c', '3c722a3fa4f41d5a', '3fea85ed4373e02d', '3c69be06385ec792',
  '3fe21c1c1b0394cf', '3c5e5b324b23aa31', '3fea61e9e72586af', '3c858330e2fd453f',
  '3fe250bb93788bbb', '3c7ea3d02457bcce', '3fea3d7d0352bdcf', 'bc868dbaeca19669',
  '3fe28511c917a067', 'bc801df1d9a16b70', '3fea18a729aee445', '3c395e25736c0358',
  '3fe2b91dea88421e', 'bc8fa371db216ab0', '3fe9f368ed912f85', 'bc81d200c5791606',
  '3fe2ecdf279a3082', '3c8d3557e0e7e37e', '3fe9cdc2e3f25e5c', '3c83f99112993f62',
  '3fe32054b148bc4f', '3c8f6b42095a135b', '3fe9a7b5a36a6514', '3c8722cfcc9fa7a9',
  '3fe3537db9be0367', '3c6b327e7af040f0', '3fe98141c42e1310', '3c8d1ff80488f08d',
  '3fe386597456282b', 'bc710fada93b07a8', '3fe95a67e00cb1fd', 'bc80befda21f862d',
  '3fe3b8e715a2840a', 'bc797653a7d2f07b', '3fe93328926d9e92', 'bc8bb77003600cda',
  '3fe3eb25d36cd53a', 'bc5be570e1570fc0', '3fe90b84784ddaf7', 'bc70feb10ab93b87',
  '3fe41d14e4ba6790', '3c84608fd287ecf5', '3fe8e37c303d9ad1', 'bc6463a4b53d4bf8',
  '3fe44eb381cf386b', 'bc83ed6c1e6a5505', '3fe8bb105a5dc900', '3c8863e03e9474c1',
  '3fe48000e431159f', 'bc8b194a7463ed10', '3fe89241985d871f', '3c8c48d9c413ed84',
  '3fe4b0fc46aab761', '3c20da05738cc59a', '3fe869108d77a6c6', '3c7338ffe2bfe9dd',
  '3fe4e1a4e54ed51b', 'bc8a492f89b7c76a', '3fe83f7dde701ca0', 'bc4152cf609bc6e8',
  '3fe511f9fd7b351c', 'bc85c0e861c48831', '3fe8158a31916d5d', 'bc6de8b90b8228de',
  '3fe541facddbb724', '3c7232c28520d391', '3fe7eb362eaa1488', '3c5a1d65a4a5959f',
  '3fe571a6966d59b3', '3c5c843b4d0fb198', '3fe7c0827f09e54f', 'bc6c73d6d72aee68',
  '3fe5a0fc98813a12', 'bc8d82e2b7d4227b', '3fe7956fcd7f6543', 'bc8ab276e9d45ae4',
  '3fe5cffc16bf8f0d', '3c896cb370eb578a', '3fe769fec655211f', 'bc6827d5cf8c68c5',
  '3fe5fea4552a9e57', '3c80b6cef7ee20b7', '3fe73e30174efba1', 'bc65d3ae3d94ad5f',
  '3fe62cf49921ac79', 'bc8edd9855b6241a', '3fe712046fa77678', '3c8425b0a5029c81',
  '3fe65aec2963e755', '3c8126f96b71053c', '3fe6e57c800cf55e', '3c860286dedbd0a6',
  '3fe6888a4e134b2f', 'bc86b7d37644d5e6', '3fe6b898fa9efb5d', '3c715ac786ccf4b2',
  '3fe6b5ce50b7821a', 'bc65d5158f702e0f', '3fe68b5a92eb6253', 'bc89a91ad985f89c',
  '3fe6e2b77c40bde1', 'bc70e729857fad53', '3fe65dc1fdeb8cba', 'bc597c1b47337c77',
  '3fe70f451d0a8c40', '3c697ede3885770d', '3fe62fcff20191c7', '3c6d9143895756ef',
  '3fe73b7680dea578', 'bc72248306dc12a2', '3fe6018526f563df', '3c846ca5e0e432d0',
  '3fe7674af6f7b524', '3c7e9d3f94ac84a8', '3fe5d2e255f1f17a', '3c80314104c8892b',
  '3fe792c1d0041d52', 'bc8abf05eeb354eb', '3fe5a3e839824077', '3c8428aa2759be62',
  '3fe7bdda5e28b3c2', '3c4ad1197ccd0393', '3fe574978d8e83f2', '3c8f4714af282d23',
  '3fe7e893f5037959', '3c80eefbaa650c4c', '3fe544f10f592ca5', 'bc8e7ae8e6c7a62f',
  '3fe812ede9ae4ba4', 'bc87830adf402dda', '3fe514f57d7bf3da', '3c747a108073c259',
];
const SINCOSTAB = SINCOSTAB_BITS.map(fromBits);
const TOVERP = [10680707, 7228996, 1387004, 2578385, 16069853, 12639074, 9804092, 4427841, 16666979, 11263675,
  12935607, 2387514, 4345298, 14681673, 3074569, 13734428, 16653803, 1880361, 10960616, 8533493, 3062596, 8710556,
  7349940, 6258241, 3772886, 3769171, 3798172, 8675211, 12450088, 3874808, 9961438, 366607, 15675153, 9132554,
  7151469, 3571407, 2607881, 12013382, 4155038, 6285869, 7677882, 13102053, 15825725, 473591, 9065106, 15363067,
  6271263, 9264392, 5636912, 4652155, 7056368, 13614112, 10155062, 1944035, 9527646, 15080200, 6658437, 6231200,
  6832269, 16767104, 5075751, 3212806, 1398474, 7579849, 6349435, 12618859, 4703257, 12806093, 14477321, 2786137,
  12875403, 9837734, 14528324, 13719321, 343717];

function doCos(x, dx) {
  if (x < 0) dx = -dx;
  const ux = big + Math.abs(x);
  x = Math.abs(x) - (ux - big) + dx;
  const xx = x * x;
  const s = x + x * xx * (sn3 + xx * sn5);
  const c = xx * (cs2 + xx * (cs4 + xx * cs6));
  const k = (loWord(ux) << 2) | 0;
  const sn = SINCOSTAB[k], ssn = SINCOSTAB[k + 1], cs = SINCOSTAB[k + 2], ccs = SINCOSTAB[k + 3];
  const cor = (ccs - s * ssn - cs * c) - sn * s;
  return cs + cor;
}

const copysign = (mag, sign) => {
  // sign bit of `sign` (including -0) applied to |mag|
  const neg = sign < 0 || Object.is(sign, -0);
  return neg ? -Math.abs(mag) : Math.abs(mag);
};

function doSin(x, dx) {
  const xold = x;
  if (Math.abs(x) < 0.126) {
    const xx = x * x;
    const t = ((((((s5 * xx + s4) * xx + s3) * xx + s2) * xx) + s1) * x - 0.5 * dx) * xx + dx;
    return x + t;
  }
  if (x <= 0) dx = -dx;
  const ux = big + Math.abs(x);
  x = Math.abs(x) - (ux - big);
  const xx = x * x;
  const s = x + (dx + x * xx * (sn3 + xx * sn5));
  const c = x * dx + xx * (cs2 + xx * (cs4 + xx * cs6));
  const k = (loWord(ux) << 2) | 0;
  const sn = SINCOSTAB[k], ssn = SINCOSTAB[k + 1], cs = SINCOSTAB[k + 2], ccs = SINCOSTAB[k + 3];
  const cor = (ssn + s * ccs - sn * c) + cs * s;
  return copysign(sn + cor, xold);
}

function reduceSincos(x) {
  const t = x * hpinv + toint;
  const xn = t - toint;
  const y = (x - xn * mp1) - xn * mp2;
  const n = loWord(t) & 3;
  let t1 = xn * pp3;
  const t2 = y - t1;
  let db = (y - t2) - t1;
  t1 = xn * pp4;
  const b = t2 - t1;
  db += (t2 - b) - t1;
  return { n, a: b, da: db };
}

function doSincos(a, da, n) {
  const retval = (n & 1) ? doCos(a, da) : doSin(a, da);
  return (n & 2) ? -retval : retval;
}

function branredPart(xp) {
  const r = new Array(6);
  let sum = 0;
  let k = (hiWord(xp) >> 20) & 2047;
  k = Math.trunc((k - 450) / 24);
  if (k < 0) k = 0;
  let gor = fromWords(hiWord(t576) - ((k * 24) << 20), loWord(t576));
  for (let i = 0; i < 6; i++) { r[i] = xp * TOVERP[k + i] * gor; gor *= tm24; }
  for (let i = 0; i < 3; i++) {
    const s = (r[i] + bbig) - bbig;
    sum += s;
    r[i] -= s;
  }
  let t = 0;
  for (let i = 0; i < 6; i++) t += r[5 - i];
  let bb = (((((r[0] - t) + r[1]) + r[2]) + r[3]) + r[4]) + r[5];
  let s = (t + bbig) - bbig;
  sum += s;
  t -= s;
  const b = t + bb;
  bb = (t - b) + bb;
  s = (sum + bbig1) - bbig1;
  sum -= s;
  return { b, bb, sum };
}

function branred(x) {
  x *= tm600;
  let t = x * split;
  const x1 = t - (t - x);
  const x2 = x - x1;
  const p1 = branredPart(x1);
  const p2 = branredPart(x2);
  let sum = p1.sum + p2.sum;
  let b = p1.b + p2.b;
  const bb = (Math.abs(p1.b) > Math.abs(p2.b)) ? (p1.b - b) + p2.b : (p2.b - b) + p1.b;
  if (b > 0.5) { b -= 1.0; sum += 1.0; } else if (b < -0.5) { b += 1.0; sum -= 1.0; }
  let s = b + (bb + p1.bb + p2.bb);
  t = ((b - s) + bb) + (p1.bb + p2.bb);
  b = s * split;
  const t1 = b - (b - s);
  const t2 = s - t1;
  b = s * bhp0;
  const bb3 = (((t1 * bmp1 - b) + t1 * bmp2) + t2 * bmp1) + (t2 * bmp2 + s * bhp1 + t * bhp0);
  s = b + bb3;
  t = (b - s) + bb3;
  return { n: Math.trunc(sum) & 3, a: s, da: t };
}

export function glibcSin(x) {
  const k = hiWord(x) & 0x7fffffff;
  if (k < 0x3e500000) return x;
  if (k < 0x3feb6000) return doSin(x, 0);
  if (k < 0x400368fd) return copysign(doCos(hp0 - Math.abs(x), hp1), x);
  if (k < 0x419921FB) { const r = reduceSincos(x); return doSincos(r.a, r.da, r.n); }
  if (k < 0x7ff00000) { const r = branred(x); return doSincos(r.a, r.da, r.n); }
  return NaN;
}

export function glibcCos(x) {
  const k = hiWord(x) & 0x7fffffff;
  if (k < 0x3e400000) return 1.0;
  if (k < 0x3feb6000) return doCos(x, 0);
  if (k < 0x400368fd) {
    const y = hp0 - Math.abs(x);
    const a = y + hp1;
    const da = (y - a) + hp1;
    return doSin(a, da);
  }
  if (k < 0x419921FB) { const r = reduceSincos(x); return doSincos(r.a, r.da, r.n + 1); }
  if (k < 0x7ff00000) { const r = branred(x); return doSincos(r.a, r.da, r.n + 1); }
  return NaN;
}
