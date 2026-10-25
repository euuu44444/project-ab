# C2 仕様書：数学関数と乱数の C++ 化

- 作成日：2026-10-25（手順1「分析」、Opus）
- 対象ブランチ：`claude/directx-game-engine-refactor-255pfv`（作成時点の最新コミット `79b59f0`）
- 上位文書：[`docs/godot-port-design.md`](../../../docs/godot-port-design.md) §5.2・§5.5・§10・§11、[`docs/HANDOVER.md`](../../../docs/HANDOVER.md) §7
- 本書は実装（Sonnet）と検証（Haiku）の作業指示を兼ねる。書いていないことを決める必要が出たら、実装を止めてオーケストレーターに確認する。

## 1. 目的と完了条件

GDScript 版の `JsMath`（`godot/sim/js_compat.gd`）と `SeededRng` / `GameRng` / `FxRng`（`godot/sim/rng.gd`、`game_rng.gd`、`fx_rng.gd`）を、Godot に依存しない C++17 に移す。C3 で戦闘処理全体を C++ に移すための土台である。GDScript の戦闘処理（`godot/sim/`）は C2 では変更しない。C3 まで GDScript 版を使い続ける。

完了条件（すべて満たすこと）：

1. C++ 単体のテストプログラムが、`godot/tests/golden/math.json`・`rng.json` の全項目とビット単位で一致する。対象は全6構成（linux x86_64、android arm64・armv7、それぞれ debug/release）で、ARM は qemu-user で動かす。
2. `tools/build_native.sh` が、構成ごとにビルドしたあと、そのテストプログラムを実行する。1つでも不一致があれば失敗する。
3. GDScript のテスト `test_js_math.gd`・`test_rng.gd` を、C++ 版（Godot との受け渡し層）を対象とするように書き換え、合格する（§9.2）。
4. 既存のテスト（210件）がすべて合格する。`tools/build_android.sh --skip-tests` が `RESULT: PASS` になる。
5. 次の検査がすべて合格する：ソース規則の検査（§9.3）、定数の照合（§9.4）、FMA の検査（既存）、コンパイラー設定の許可リスト（既存）。

## 2. 決定事項（ユーザーの判断、2026-10-25）

| 項目 | 決定 |
| --- | --- |
| qemu の導入 | Ubuntu の `qemu-user-static` を、版とハッシュを固定してキャッシュに展開する。**コミット `79b59f0` で済み**。`SWARM_QEMU_AARCH64` / `SWARM_QEMU_ARM` で参照する |
| LGPL の sin/cos の形 | 別ディレクトリに置き、静的ライブラリ（`.a`）として同じ `.so` にリンクする。S9 で共有ライブラリに切り替えられるようにしておく |
| GDScript テストの対象 | **C++ 版だけ**。`test_js_math.gd`・`test_rng.gd` は C++ 版を確かめる。GDScript 版 `JsMath` を正解値と直接照合するテストはなくなる（§12 の注記を参照） |
| 仕様書の置き場所 | リポジトリ（本書）。C2 のコミットに含める |
| 移植の書き方 | **GDScript 版の写し**。`js_compat.gd` と乱数3ファイルの式・分岐・演算順序をそのまま C++ に写す（§3） |
| `js_compat.gd` にライセンス表示がない件 | 記録だけ行う（C3 で GDScript 版を消す予定のため、C2 では変更しない） |
| 検証 | わざと誤りを入れて検出を確かめる作業は行わない。テストと検査の再実行だけを行う（§10） |

これまでの決定（設計書 §11）もそのまま適用する：

- C++ は `-ffp-contract=off -fno-fast-math -O2` だけを使う
- 禁止事項：`float`、`long double`、`long`、`std::sort`、`unordered_*` を順に走査すること、`<random>`、FP 関連の pragma、`fma`、スレッド、範囲外の double から整数へのキャスト
- NaN をビット列で比較しない
- デバッグ版では浮動小数の環境を検査する

## 3. 移植元（上流の原本）

**C++ 版は GDScript 版（`godot/sim/js_compat.gd`、`rng.gd`、`game_rng.gd`、`fx_rng.gd`）の写しとする**（ユーザーの判断）。次の点を GDScript 版と同じにする。

- 式の形、分岐の順序、演算の順序
- 中間変数の分け方
- しきい値を double で比べる書き方
- `do_sin` などを sin/cos の中に展開した形
- atan2 の速い経路と `_atan2_general` の分け方

上流の構造には戻さない。GDScript 特有の書き方は、C++ の同じ意味の書き方に置き換える。例：`_bb` の encode/decode は `memcpy`、`_red` は出力引数、PackedFloat64Array は配列、`int(x)` は範囲内であることが分かっている箇所に限ったキャスト。

GDScript 版は次の上流ソースを移植したものであり、C++ 版もその派生物である。ここに挙げる原本は、次の用途に使う。

- ライセンス本文と著作権表示の写し
- 定数の照合の根拠（既存の `check_js_compat_consts.mjs` の `UPSTREAM` 表は、これらのリテラルを写したもの）
- レビューで GDScript 版の対応箇所を確かめること

すべて V8 14.1.146.11（参照トレースを採った Chromium 141 の V8）のタグから取得した（2026-10-25）。取得 URL の形は `https://chromium.googlesource.com/v8/v8/+/refs/tags/14.1.146.11/<パス>?format=TEXT`（base64）である。

| パス | 用途 | ライセンス | SHA-256 |
| --- | --- | --- | --- |
| `third_party/glibc/LICENSE` | LGPL-2.1 本文（写しとして同梱する） | — | `b634ab5640e258563c536e658cad87080553df6f34f62269a21d554844e58bfe` |
| `third_party/glibc/README.v8` | 由来：glibc のコミット `4e21c2075193e406a92c0d1cb091a7c804fda4d9` | — | `2876e977d794d5e8c5cb3a8416ac7ee9bcb9c9ec9f5eca814616ccfe49f176de` |
| `third_party/glibc/METADATA` | 由来：最終更新 2022-11-07、version `985ff73ad29bc4cc4e15ce6d182ecd808b7b02d7` | — | `b87ba94e445c4c75d364a3913f2f84e528b4f0abe78c9ef1b1d91ef558b32ae2` |
| `third_party/glibc/src/sysdeps/ieee754/dbl-64/s_sin.c` | `glibc_sin` / `glibc_cos`、`do_sin`、`do_cos`、`reduce_sincos`、`do_sincos` | LGPL-2.1 以降 | `b05c66b322da8bde56fab4ef45bdb44c8e6178494648c89f1eb64272b749d4b4` |
| `.../dbl-64/branred.c` | `__branred`（大きな引数の還元） | LGPL-2.1 以降 | `8a21104b079e3d5bc42bc903fdaf9d93bf6dc8b0e0e3030c1b3c8261bf6577c3` |
| `.../dbl-64/branred.h` | `toverp` 表と定数 | LGPL-2.1 以降 | `7750d1665e454b94877020e0393f8b29e20d7ba51451a54f60a8ae2796354b9e` |
| `.../dbl-64/sincostab.c` | `__sincostab`（440個の double） | LGPL-2.1 以降 | `b0d85d1187a70beb14bf5b274c53706551e9ff29181c9a4a01dd019c8ccde2b7` |
| `.../dbl-64/usncs.h` | 定数（16進浮動小数） | LGPL-2.1 以降 | `c78fb520931e863618a60dc28206d5393f884ede9cbaffa3758b8dbc11553ee3` |
| `.../dbl-64/dla.h` | `CN`（= 2^27 + 1） | LGPL-2.1 以降 | `8d94c1212d955c5536ddb8f64ed4d2b01f8b04957f81ebf1d17422e9d74d5cb2` |
| `.../dbl-64/mydefs.h` | `int4`、`mynumber` | LGPL-2.1 以降 | `41a661cdcb78709a3f3ca149b7a66ddccec62fffd4131ca727a959207e9c8891` |
| `.../dbl-64/endian.h`・`trig.h` | エンディアンの定義、宣言（Chromium、BSD） | BSD（Chromium） | `10dbc22a…`・`5325957f…`（移植では使わない） |
| `src/base/ieee754.cc` | fdlibm の `atan`、`atan2`、`exp`、`log`（V8 が改変） | fdlibm の表示＋V8 の BSD-3 | `1bf999809d4c4c1d31ad5ff3578d32614796f159e08b9e7782560d017721a0c2` |
| `LICENSE`（V8 本体） | V8 の BSD-3 ライセンス本文 | — | `6ab33af8774a0f396ee3aeeb761e3229057682d6f9fa7f572e390c2cb3a6e509` |

- 実装担当は、作業の最初に上記ファイルを同じ URL から取得し、SHA-256 が一致することを確かめてから使う。取得物は一時領域に置き、リポジトリには入れない。ただし、ライセンス本文 2 つは §6 のとおり写しを同梱する。著作権表示は原本の先頭から一字一句写す。

## 4. 構成

```
native/
  SConstruct                    変更（§8.1）
  THIRD_PARTY_NOTICES.md        新規：同梱する第三者コードの一覧（fdlibm、V8、glibc）と、静的リンクの意味（§6）
  LICENSES/V8-BSD-3-Clause.txt  新規：V8 の LICENSE の写し
  src/                          ライブラリ本体（既存の *.cpp に加え、以下を追加）
    sim/                        Godot に依存しない C++17（namespace swarm::sim）
      js_math.h / js_math.cpp   JS 互換の数値処理（sin/cos は glibc_sincos を呼ぶ）
      fdlibm.cpp                atan、atan2、exp、log（js_compat.gd の写し。由来の V8 ieee754.cc の Sun と V8 の表示を残す）
      bits.h                    double とビット列の変換（memcpy）、上位・下位ワード
      seeded_rng.h              SeededRng（ヘッダーのみ、inline）
      game_rng.h                GameRng（ヘッダーのみ、inline）
      fx_rng.h                  FxRng（ヘッダーのみ、inline）
      fp_env.h / fp_env.cpp     浮動小数の環境の検査
    bindings/                   Godot との受け渡し（godot-cpp を使うのはここと既存のファイルだけ）
      js_math_binding.h / .cpp  クラス SwarmJsMath
      rng_binding.h / .cpp      クラス SwarmSeededRng、SwarmGameRng、SwarmFxRng
  third_party/
    glibc_sincos/               LGPL-2.1 以降。静的ライブラリ libswarm_glibc_sincos.a
      LICENSE                   V8 third_party/glibc/LICENSE の写し（一字一句そのまま）
      README.md                 由来、上流ファイルと SHA-256、変更点の一覧、ライセンスの注意（§6）
      glibc_sincos.h            公開 API：namespace swarm_glibc { double sin(double); double cos(double); }
      sincos.cpp                js_compat.gd の sin、cos、_branred の写し（定数 G_*・BR_* を含む）
      sincos_tables.cpp         SINCOSTAB_BITS（440個）と TOVERP（75個）の写し
  tests/                        C++ 単体テスト（ライブラリには入れない）
    golden_json.h / .cpp        テスト専用の最小 JSON 読み取りと base64 の解読
    sim_tests.cpp               main：正解値の照合、乱数、浮動小数の環境、性能計測（--bench）
tools/
  check_native_sources.py       新規：ソース規則の検査（§9.3）
  build_native.sh               変更（§8.2）
  check_js_compat_consts.mjs    変更：C++ の定数と表も照合する（§9.4）
godot/tests/
  test_js_math.gd               書き換え（§9.2）
  test_rng.gd                   書き換え（§9.2）
  test_native_extension.gd      追加：新クラスの登録、浮動小数の環境
verification/godot/c2/          本書と検証記録
```

- `native/src/sim/` と `native/third_party/glibc_sincos/` は Godot のヘッダーを include しない（§9.3 で検査する）。
- 既存の `swarm_native.*`、`register_types.*`、`build_info.*`、`fp_probe.*` は移動しない。`register_types.cpp` に新クラスの登録を加え、デバッグ版では浮動小数の環境を検査する（§7.4）。

## 5. C++ の API（`native/src/sim/`、namespace `swarm::sim`）

### 5.1 数値処理（`js_math.h`）

関数はすべて `double` / `int32_t` / `uint32_t` / `int64_t` を使う。どの関数も `js_compat.gd` の同名の関数の写しである。対応表と、その関数の上流の由来は次のとおり。

| C++（`swarm::sim::js::`） | GDScript（`JsMath.`） | 上流の由来 |
| --- | --- | --- |
| `sin(double)` / `cos(double)` | `sin` / `cos`（`_branred` を含む） | glibc s_sin.c / branred.c（実体は `swarm_glibc::sin/cos`） |
| `atan(double)`、`atan2(double y, double x)` | `atan`、`atan2`、`_atan2_general` | fdlibm（V8 ieee754.cc） |
| `exp(double)`、`log(double)` | `exp`、`log` | fdlibm（V8 ieee754.cc） |
| `hypot(double, double)` | `hypot` | V8 FastMathHypot |
| `round(double)` | `js_round` | V8 Float64Round |
| `trunc`、`mod`（= `std::fmod`） | `trunc`、`js_mod` | IEEE 754 で厳密 |
| `max`、`min`、`max3`、`min3`、`max5`、`min5` | `js_max` ほか | V8 Float64Max / Float64Min |
| `max_n(const double*, size_t)`、`min_n(...)` | `max_n`、`min_n` | 同上 |
| `clamp(v, lo, hi)` | `clamp` | ゲームの clamp |
| `sqrt`、`floor`、`ceil`、`abs` | 同名 | `std::` の関数（IEEE 754 で厳密） |
| `pow(double, double)` | `pow` | 特別な場合だけ処理し、残りは `std::pow`（**ビット一致は保証しない**。GDScript 版と同じ扱い） |
| `to_int32(double) -> int32_t`、`to_uint32(double) -> uint32_t` | 同名 | ECMAScript の ToInt32 / ToUint32 |
| `i32(int64_t) -> int32_t` | `i32` | 下位32ビットへの丸め |
| `imul`、`shl`、`sar`、`shr_u` | 同名 | 32ビット整数の演算 |
| `to_bits(double) -> uint64_t`、`from_bits(uint64_t)`、`high_word` | `to_bits` ほか | `memcpy`（`bits.h`） |

- 関数名は `js::sin` のように名前空間で区別する。C の `sin` と同じ名前を、名前空間の外で使わない。
- `pow` は M1 の戦闘処理では使わない。テストの `pow` ベクトル（490件、IEEE 754 と ECMAScript の特別な場合だけ）を合格させるために置く。

### 5.2 乱数（`seeded_rng.h`、`game_rng.h`、`fx_rng.h`）

GDScript 版と同じ値・同じ乱数の使用回数にする。

```cpp
class SeededRng {           // makeSeededRandom（mulberry32 の変種）
public:
  static constexpr uint32_t kDefaultSeed = 2654435769u;
  explicit SeededRng(int64_t seed = 0);
  static uint32_t normalize_seed(double js_seed);   // seed>>>0||2654435769
  void set_seed(int64_t seed);                       // normalize_seed(double(seed))
  uint32_t next_u32();                               // k、値は k / 2^32
  double next_float();                               // k / 4294967296.0
  int32_t state() const; void set_state(int32_t);    // 状態 a（符号付き int32）
};
class GameRng {             // gameRandom と rand / randi / chance / index / shuffle
public:
  explicit GameRng(int64_t seed = 0);
  void set_seed(int64_t seed);                       // seed_value = to_uint32(double(seed))、draws = 0
  int64_t draws() const; uint32_t seed_value() const;
  double random(); double rand(double a, double b);
  int64_t randi(int64_t a, int64_t b);              // 前提：|a|, |b| <= 2^31（デバッグ版で検査）
  bool chance(double p); int32_t index(int64_t length);
  template <typename T> void shuffle(T* items, size_t n);   // n - 1 回引く
};
class FxRng { /* 既定シード 0x9E3779B9。random / rand_fx / randi_fx / chance_fx。GameRng の draws を変えない */ };
```

- 状態の計算は `uint32_t` で行い（符号付きのあふれは未定義動作なので使わない）、`int32_t` への変換は最後に1回だけ行う。
- 引数の評価順も JS と同じにする。例：`rand` は `a + r * (b - a)`。

### 5.3 浮動小数の環境（`fp_env.h`）

`bool fp_environment_ok(const char** reason)` は次を確かめる。

- `std::fegetround() == FE_TONEAREST`
- 非正規化数が0にされていない。`volatile` を使った `2^-1074 * 1.0 != 0` と `DBL_MIN * 0.5 != 0` で確かめる
- `FLT_EVAL_METHOD == 0`（`static_assert`）。x87 の拡張精度を使っていないことの確認である

## 6. LGPL 部分（`native/third_party/glibc_sincos/`）

- 中身は `js_compat.gd` の `sin`、`cos`、`_branred`、`SINCOSTAB_BITS`、`TOVERP` と、それらが使う定数（`G_*`、`BR_*`）の C++ への写しである。これらは glibc の `s_sin.c`、`branred.c`、`branred.h`、`sincostab.c`、`usncs.h`、`dla.h` の派生物である。
- 各ファイルの先頭に、上流の著作権表示とライセンスの告知を一字一句そのまま写す（`IBM Accurate Mathematical Library` ／ `Copyright (C) 2001-2022 Free Software Foundation, Inc.` ／ LGPL-2.1 以降の告知文）。そのあとに、変更した日付と変更内容の要約を加える（LGPL-2.1 §2(a)。【事実】§2 は、変更したファイルに、変更した旨と日付を目立つように書くことを求めている）。
- `README.md` の「変更点」には、上流からの変更を1項目ずつ書く。
  1. C から GDScript へ移し（S3、`godot/sim/js_compat.gd`）、それを C++17 に写した（C2）。namespace は `swarm_glibc` で、外部に見せるのは `sin` / `cos` だけである
  2. `do_sin`、`do_cos`、`reduce_sincos`、`do_sincos` を `sin` / `cos` の中に展開した
  3. 上位ワードの整数比較を、同じ値の double のしきい値の比較に置き換えた（`G_TH_*`）
  4. `SINCOS_TABLE_LOOKUP` の添字を、`(big + x)` の下位ワードではなく `int(ur * 128) << 2` で求める
  5. 表は IEEE-754 のビット列（`uint64_t`）で持ち、`memcpy` で double にする。`mynumber`（共用体による型変換）は使わない
  6. glibc 内部のマクロ（丸めモードの設定、アンダーフローの強制、errno）を除いた
- 定数は16進浮動小数リテラル（例：`0x1.921FB54442D18p0`）で書く。名前は GDScript 版と同じ（`G_S1` など）にする。値は GDScript 版の `CONST_BITS` と同じビット列になること（§9.4 で照合する）。
- `LICENSE` は `third_party/glibc/LICENSE` の写しである。SHA-256 が §3 と一致することを、`check_native_sources.py` で確かめる。
- SConstruct は、このディレクトリの `.cpp` を同じコンパイラー設定（許可リストで検査する）でコンパイルする。それを `libswarm_glibc_sincos.a` にまとめ、`libswarm_native.*.so` にリンクする（§8.1）。
- `README.md` と `native/THIRD_PARTY_NOTICES.md` に、次の注意を書く。
  - 【事実】LGPL-2.1 §6：LGPL のライブラリを静的にリンクした実行物を配る場合、利用者が改変版のライブラリと再リンクできるようにする必要がある。例：オブジェクトファイルを提供する。
  - 配布方針（共有ライブラリへの切り替えなど）は S9 で決める（2026-10-24 のユーザー判断）。それまでは配布用の APK を作らない。
- fdlibm 部分（`native/src/sim/fdlibm.cpp`、`js_compat.gd` の atan / atan2 / `_atan2_general` / exp / log と定数 `AT_*`、`A2_*`、`EX_*`、`LG_*`、`POW2` の写し）には、`ieee754.cc` 先頭の Sun Microsystems の表示と V8 の表示をそのまま写す。V8 の BSD-3 ライセンス本文は `native/LICENSES/V8-BSD-3-Clause.txt` に置く。

## 7. Godot との受け渡し（`native/src/bindings/`）

### 7.1 方針

- GDScript の `class_name`（`JsMath`、`SeededRng`、`GameRng`、`FxRng`）と名前が重なると登録できないため、C++ のクラスには `Swarm` を付ける。
- 値は Variant の FLOAT（64ビット double）と INT（int64）で受け渡す。`real_t`、`Vector2`、`float` は使わない。配列は `PackedFloat64Array` / `PackedInt64Array` を使う。
- 受け渡し層は計算をしない。`swarm::sim` の関数を呼んで型を変えるだけである。

### 7.2 `SwarmJsMath`（RefCounted、static メソッドだけ）

`sin`、`cos`、`atan`、`atan2`、`exp`、`log`、`hypot`、`js_round`、`trunc`、`js_mod`、`js_max`、`js_min`、`max3`、`min3`、`max5`、`min5`、`max_n(PackedFloat64Array)`、`min_n(PackedFloat64Array)`、`clamp`、`sqrt`、`floor`、`ceil`、`abs`、`pow`、`to_int32`、`to_uint32`、`i32`、`imul`、`shl`、`sar`、`shr_u`、`to_bits`、`from_bits`、`neg_zero`、`fp_environment_ok() -> bool`、`fp_environment_reason() -> String`

- 引数と戻り値の型は GDScript 版と同じにする（float / int）。
- `to_bits` は、GDScript 版と同じく符号付き int64 で返す。

### 7.3 乱数のクラス（RefCounted）

| クラス | メソッド | プロパティ |
| --- | --- | --- |
| `SwarmSeededRng` | `set_seed(int)`、`next_u32() -> int`、`next_float() -> float`、static `normalize_seed(float) -> int` | `state`（int、読み書き可） |
| `SwarmGameRng` | `set_seed(int)`、`random()`、`rand(a, b)`、`randi(a, b)`、`chance(p)`、`index(length)`、`shuffle(Array) -> Array`（その場で並べ替えて返す） | `draws`、`seed_value`（読み取りのみ） |
| `SwarmFxRng` | `set_seed(int)`、`random()`、`rand_fx(a, b)`、`randi_fx(a, b)`、`chance_fx(p)` | — |

- GDExtension のクラスは `new()` に引数を渡せない。そのため、初期状態は既定のシード（SeededRng と GameRng は 0、FxRng は `0x9E3779B9`）とし、`set_seed` で設定する。

### 7.4 登録と環境の検査

- `register_types.cpp` で4クラスを登録する。
- デバッグ版（godot-cpp が `DEBUG_ENABLED` を定義する構成。【未確認】実装時に確かめる）では、モジュールの初期化時に `fp_environment_ok` を呼ぶ。失敗したら `UtilityFunctions::push_error` で理由を出す。C3 では戦闘処理の開始時にも呼ぶ。
- `native/build_profile.json` にクラスを追加する必要があれば追加し、その理由を SConstruct の該当コメントに書き足す。

## 8. ビルド

### 8.1 `native/SConstruct`

1. **ライブラリ**：次の3つを `libswarm_native.<構成>.so` にリンクする。
   - `native/src/**/*.cpp`（既存のとおり）
   - `native/third_party/glibc_sincos/*.cpp` を SharedObject（`-fPIC`、同じ設定）でコンパイルした静的ライブラリ `libswarm_glibc_sincos.a`（置き場所はビルドディレクトリ）
   - godot-cpp
2. **テストプログラム** `swarm_sim_tests`（ビルドディレクトリに出力する。`godot/bin/` には置かない）：
   - リンクするもの：ライブラリと**同じオブジェクトファイル**の `native/src/sim/*.os`、同じ `libswarm_glibc_sincos.a`、`native/tests/*.cpp`
   - 意図：配布するライブラリと同じ機械語を試験するためである
   - Android は `-static` でリンクする。qemu-user で動かすためで、手順0で実行できることを確かめてある
   - Linux はホストでそのまま動けばよい
3. **許可リストの検査を広げる**：
   - third_party と tests のコンパイルコマンドにも、既存の許可リストと必須の設定（`-ffp-contract=off -fno-fast-math -O2`）を適用する
   - テストプログラムのリンクコマンドも検査する。Android だけ `-static` を許可リストに加える
   - 静的ライブラリの作成コマンド（ar）は、プログラムが想定どおりであることだけを確かめる
4. `own-objects.txt` は、ライブラリにリンクする自前のオブジェクト（`src` と `third_party`）を列挙する。テストのオブジェクトは別の一覧 `test-objects.txt` に書く。
5. `SWARM_NATIVE_VERSION` を `0.2.0-c2` にする。
6. 既存の規則（`.cpp` 以外のソースを拒否する、godot-cpp の固定、パスの置き換え）は third_party と tests にも適用する。

### 8.2 `tools/build_native.sh`

1. scons の前に `python3 -I tools/check_native_sources.py` を実行する。違反があれば、その場で失敗させる。
2. `scan_own_objects` が期待するオブジェクトの一覧に、`native/third_party/**/*.cpp` を加える。テストのオブジェクトも FMA を検査する（`test-objects.txt`）。
3. 構成ごとに、ライブラリの検査と FMA の検査のあとで `swarm_sim_tests --golden godot/tests/golden` を実行する。
   - x86_64 はそのまま動かす。arm64 は `$SWARM_QEMU_AARCH64`、armv7 は `$SWARM_QEMU_ARM` で動かす
   - 合格の条件：終了コードが0であり、出力に `RESULT: PASS` がある
   - 各構成の行に件数（照合した行数など）を表示する
   - `--evidence-dir` を指定したら、出力をそこに保存する
4. qemu が見つからない場合は、試験を飛ばさずに失敗させる（Android の構成をビルドするときは qemu を必須とする）。
5. 使い方の説明（先頭のコメント）を更新する。

`tools/run_godot_tests.sh`（PC 向けのデバッグ版だけをビルドする）と `tools/build_android.sh`（全構成）は `build_native.sh` を呼ぶ。そのため変更しなくても、自動的に C++ の試験が入る。ただし、先頭のコメントの説明は直す。

## 9. テスト

### 9.1 C++ 単体テストプログラム（`native/tests/sim_tests.cpp`）

`swarm_sim_tests --golden <dir> [--bench]`。GDScript の `test_js_math.gd`・`test_rng.gd` と同じ内容を確かめ、項目ごとに `PASS`/`FAIL` と件数を出す。最後に `RESULT: PASS` か `RESULT: FAIL` を出す。

1. **浮動小数の環境**：`fp_environment_ok`。失敗したら、他の項目より先に FAIL とする。
2. **math.json**：
   - `vectors` の全28種を、それぞれ対応する関数で照合する（§5.1 の対応表。`floor`/`ceil`/`sqrt`/`abs` も含む）
   - 行数の下限：移植した関数は20,000、薄いラッパー（sqrt/floor/ceil/abs）は2,048、pow は490。下限を下回ったら FAIL とする
   - 比較の規則：f64 はビット単位で比べる。ただし NaN どうしは一致とみなし、-0 と +0 は区別する。i32 / u32 は整数で比べる
   - `max_n` / `min_n` は、`max5` / `min5` の入力で照合する。空配列は -Infinity / +Infinity になること
   - `named`（48件）
   - `i32` の境界値（`test_js_math.gd::test_i32_wraps_to_the_int32_range` と同じ11件）
   - ビット変換の補助関数（同じく `test_bit_helpers_and_negative_zero`）
3. **rng.json**：
   - 全シードの最初の1000個（`next_u32` と `next_float` の両方）
   - チェックポイント（9999、99999、シード424242だけ999999）
   - シードの正規化（17件）
   - `game_rng` の5本の操作列（各400件。値と `draws` の両方）
   - シードが同じに正規化される組（0、2654435769、4294967296、および -1 と 4294967295）
   - 状態の保存と復元
   - 各補助関数が乱数を引く回数（`test_every_helper_draws_as_often_as_in_the_original` と同じ）
   - FxRng が GameRng の `draws` を変えないこと
4. 不一致は1種類につき最大5件まで、入力・期待値・結果を16進で表示する。
5. `--bench`（任意、x86_64 だけで意味がある）：主な関数の1回あたりの ns を表示する。合否の条件にはしない。結果は `verification/godot/c2/bench.txt` に記録する（C3 の性能見積もりに使う）。
6. JSON の読み取り（`golden_json.cpp`）はテスト専用である。範囲は、オブジェクト、配列、文字列、真偽値、null、整数だけとする。整数でない数値や不正な形を見つけたら、異常終了せずに FAIL とする。
   - 正解値のファイルは、整数と、16進や base64 の文字列だけで書かれている【事実：形式を確認済み】

### 9.2 GDScript テスト（C++ 版だけを対象にする）

- `test_js_math.gd`：`JsMath.xxx` を `SwarmJsMath.xxx` に置き換える。
  - ネイティブクラスの static メソッドを Callable にできるかは【未確認】である。そのため `_check` には lambda を渡す
  - `test_constants_match_their_bit_patterns`（GDScript 版の `self_check`）は削除する。C++ の定数は §9.4 で照合する
  - 性能計測は「組み込み関数」と「C++（GDScript から呼ぶ）」を比べる形に改める。呼び出しのオーバーヘッドが大半を占めることを出力に注記する
- `test_rng.gd`：`SeededRng.new(seed)` を `SwarmSeededRng.new()` ＋ `set_seed(seed)` に置き換える。GameRng と FxRng も同様である。
  - 照合の内容と件数は変えない
- `test_native_extension.gd`：
  - 4クラスが登録され、RefCounted を継承していること
  - `SwarmJsMath.fp_environment_ok()` が true であること
  - `version()` が `0.2.0-c2` を含むこと
- 他のテスト（`test_sim_source_rules.gd` など）は変更しない。GDScript の戦闘処理は GDScript 版の `JsMath` / `GameRng` を使い続ける。

### 9.3 ソース規則の検査（`tools/check_native_sources.py`）

コメントと文字列リテラルを除いてから、正規表現で検査する。

| 対象 | 禁止 |
| --- | --- |
| `native/src/sim/**`、`native/third_party/**` | `float`、`long double`、`long`（`long long` も含む。整数は `<cstdint>` の型を使う）、`real_t`、`std::sort`、`unordered_`、`#include <random>`、`<thread>`、`<mutex>`、`<atomic>`、`<future>`、`std::thread`、`fma`（`std::fma`、`fmaf`、`__builtin_fma` を含む）、`#pragma`（`#pragma once` は除く）、`<chrono>`、`<ctime>`、`time(`、`rand(`、`srand(`、godot のヘッダーの include |
| `native/src/bindings/**` | `float`、`real_t`、`Vector2`／`Vector3` などの float32 型、`#pragma`（`once` は除く） |
| `native/tests/**` | `float`、`long double`、`#pragma`（`once` は除く）、`fma` |

- 範囲外の double を整数へキャストする誤りは、正規表現では見つけられない。代わりに次の2つで防ぐ。
  - レビューで確かめる
  - `to_int32` などの試験で、範囲外・NaN・無限大を通す（正解値に含まれている【事実】）
- `--self-test`：各規則について、違反を含む小さなソース片を内蔵する。それを検出できることと、違反のない片を通すことを確かめる。`build_native.sh` は検査の前に、これを毎回実行する。
- `native/third_party/glibc_sincos/LICENSE` の SHA-256 が §3 の値と一致することも検査する。

### 9.4 定数の照合（`tools/check_js_compat_consts.mjs` の拡張）

- C++ の定数は GDScript 版と同じ名前で、`constexpr double <名前> = <16進浮動小数>;` の形で1行に1つ書く。
- スクリプトは C++ の定数を正確に読み、次の3つがビット単位で一致することを確かめる。どれかに欠けている定数があっても失敗とする。
  1. `UPSTREAM` の同名の項目
  2. GDScript 版の `CONST_BITS`
  3. C++ の値
- C++ の `SINCOSTAB_BITS`（440個）と `TOVERP`（75個）は、GDScript 版の表と `tools/golden/_glibc_sin.mjs` の表の両方と照合する。
- GDScript 版（`js_compat.gd`）の照合は、今までどおり続ける。

## 10. 検証（Haiku）

わざと誤りを入れて検出を確かめる作業は行わない（ユーザーの判断、2026-10-25）。次を実行し直して、結果を記録する。

1. `tools/build_native.sh --evidence-dir <一時領域>`（全6構成）。証拠はコミットしないので、要約だけを `build.txt` に書く
2. `tools/run_godot_tests.sh`
3. `tools/build_android.sh --skip-tests`
4. `node tools/check_js_compat_consts.mjs`
5. `python3 -I tools/check_native_sources.py --self-test`

結果は `verification/godot/c2/tests.txt` にまとめる。

## 11. 記録と文書（修正のあと、オーケストレーターが行う）

- `verification/godot/c2/`：`spec.md`（本書）、`build.txt`、`tests.txt`、`bench.txt`、`review.md`（レビューの指摘と対応）
- 設計書：§10 に C2 のビルド構成を加える。§11 に C2 の結果と持ち越し事項を加える。§5.5 に C++ 版の1回あたりの時間を加える
- `docs/HANDOVER.md`：進捗表、次の作業（C3）、既知の問題を更新する。qemu の注記（手動で入れた）は、`setup_cpp.sh` で入るようになったので改める

## 12. 注意点・リスク・未確認事項

| 項目 | 内容 |
| --- | --- |
| GDScript 版の直接の照合がなくなる | ユーザーの判断（C++ 版だけ）による。GDScript 版の `JsMath` / 乱数は C3 まで戦闘処理で使われる。しかし `test_js_math.gd`・`test_rng.gd` で正解値と直接照合されなくなる。間接的には、7本の参照トレースとの照合（既存のテスト）と `check_js_compat_consts.mjs` で守られる。C3 で GDScript 版を消すと、この問題はなくなる |
| 既存の GDScript 版にライセンス表示がない | 【事実】`js_compat.gd` には、glibc（LGPL）と fdlibm の著作権表示が書かれていない（設計書 §5.5 は「別ファイルに分け、ライセンス表示を付けておく」としている）。C2 では変更しない（C3 で削除する予定のため）。報告だけ行う |
| Chromium と同じ値になる根拠 | GDScript 版を `-ffp-contract=off` で写すだけでは、Chromium 141 の x86_64 版と同じ値になる保証はない。正解値（Chromium 141 で照合済み）との一致で確かめる。Android 版 Chromium が FMA を使うかは【未確認】である。ただし照合の基準は Chromium の x86_64 版であり、これまでの方針と同じである |
| `DEBUG_ENABLED` | godot-cpp の template_debug で定義されるかは【未確認】である。実装時に確かめる |
| ネイティブの static メソッドを Callable にすること | 【未確認】。lambda で回避する（§9.2） |
| SCons で共有オブジェクトを Program にリンクすること | 【未確認】。拒否された場合は、同じソースから同じ設定で静的オブジェクトを作る。その場合は、コンパイルコマンドが同一であることを許可リストの検査で確かめ、仕様の変更として報告する |
| qemu による確認の限界 | qemu-user は ARM の命令を PC 上で再現するだけで、実機の FPU の設定（flush-to-zero など）は確かめられない。実機での確認は S9 である |
| 静的リンクと LGPL | §6 のとおり。配布用の APK は S9 の判断まで作らない |

## 13. 範囲外（C3 以降）

- `godot/sim/` の GDScript を C++ に移すこと、GDScript 版 `JsMath` / 乱数を削除すること（C3）
- sin と cos を一度に計算する入口、同じ値の再計算の削減（ビット一致のままの最適化。C3/S6 で必要に応じて）
- `Math.pow` のビット一致（M1 では使わない）
- 共有ライブラリへの切り替えと配布方針（S9）
