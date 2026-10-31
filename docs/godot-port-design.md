# Elemental Swarm Godot移植 設計書（マイルストーン1：縦切り試作）

- 作成日: 2026-10-19
- 対象: `webview-fg4/`（Android WebView版 11.11.9-fg.4）→ `godot/`（Godot 4.7.2 版、新規）
- 役割: 分析・設計・レビューは Opus、コード実装・テスト実行は Sonnet のサブエージェントが担当する（S4 以降は §11 の分担に従う）。
- 表記: 【事実】はソースや一次情報で確かめた内容、【推測】は根拠はあるが未検証の内容、【未確認】はこれから確かめる内容を示す。

## 1. 決定事項

| 項目 | 決定 |
| --- | --- |
| 方式 | 既製ゲームエンジンへの移植（B方式） |
| エンジン | Godot 4.7.2-stable（2026-08-18公開）。言語は静的型付きの GDScript を使う |
| 描画 | Compatibility レンダラー（OpenGL ES 3）を使う |
| アプリID | `com.elementalswarm.engine`（新しいアプリ）。fg.4（`com.elementalswarm.mobile`）とは並べてインストールできる |
| 署名 | エンジン版専用の鍵を新規に作り、リポジトリ外で保管する。fg.4 の鍵は使わない |
| 既存版 | `webview-fg4/` は変更せず、参照用・比較用として残す（Canvas2D描画とフレーム生成を含む） |
| 最初の到達点 | M1 は縦切りの試作である。範囲は §8 で定める |
| 進め方 | §11 の手順ごとに、着手前と完了後にユーザーの確認を取る |

## 2. 現行fg.4の構造（分析結果）

### 2.1 全体【事実】

- `webview-fg4/tests/fixtures/original.html`（1,967,015バイト）は1つの `<script>` から成る。そのうちJSが約1.72MB、WebP画像14枚（data URI）が約0.61MBを占める。名前付き関数は約1,550個ある。
- 画面のUI（メニュー、カード、ルールブック、HUD）は HTML/CSS の DOM で作られている。効果音とBGMは Web Audio で生成している。地形と光源は Worker で生成している。セーブは `localStorage`（キー `elemental-swarm-save` など）に書いている。
- Android 側は `MainActivity.java` の WebView ホストだけである。描画は WebView の Canvas2D で行っている。

### 2.2 ゲームループ【事実】

- 更新は固定刻みである（`FIXED_DT = 1/60`、`MAX_STEPS_PER_FRAME = 5`）。累積器 `simAccumulator` と補間係数 `renderAlpha` を持つ。
- `interpX/interpY` と `capturePreviousTransforms()` は既にある。ただし `renderInterpolation = false` で無効になっており、補間対象もプレイヤー・敵・カメラだけである。
- 更新は `UPDATE_MAIN_SYSTEMS`（43システム）を固定順で実行する。描画は `RENDER_SYSTEMS`（28システム）を固定順で実行する。システム一覧は §5.3 と §6.2 に示す。
- 乱数は3系統ある。
  - `gameRandom` は戦闘に影響する。`setGameSeed(seed)` を呼ぶと `makeSeededRandom`（Mulberry32 系、32ビット整数演算）に切り替わり、使った回数を `gameRandomDraws` で数える。
  - `fxRandom` と `audioRandom` は演出専用で、`Math.random` を使う。

### 2.3 内容の規模【事実】

| 種類 | 数 | 内訳 |
| --- | ---: | --- |
| キャラクター | 10 | catalyst, arcanist, ranger, archivist, sentinel, striker, harmonizer, pathfinder, miko, berserker |
| 武器 | 24 | 汎用14種と、キャラ専用（signature）10種 |
| 属性 | 10 | fire, water, ice, lightning, wind, poison, light, dark, earth, wood。二属性・三属性の反応がある |
| 敵の種類 | 7＋2 | swarm(W1), assassin(W3), tank(W5), artillery(W7), bomber(W9), support(W11), controller(W13)、および elite, boss |
| ウェーブ | 30 | 1ウェーブ36秒。W5 は elite ウェーブ |
| 上限 | — | 敵100体。弾は520発（タッチ端末、以下同）、経験値オーブ480個、敵弾420発 |
| マップ | — | 26000×26000 |

- 開始時の装備は、キャラ固有の武器1つだけである（`makeWeapon(signatureWeaponIdForCharacter(c.id))`）。
- 最初の解放は、武器が pulse・blades・wand、属性が fire・water・earth・wood である。

### 2.4 fg.4の性能上の課題【事実：TEST_REPORT.md より】

高負荷時は、時間の大半を drawImage や stroke などブラウザー内部の Canvas2D 描画が占める。たとえば最高画質・大量配置の P95 は約274msであった。フレーム生成は描画命令の記録と合成のコストが上乗せされる方式であり、描画負荷そのものは減らせない。

## 3. 方式：ゲームエンジン方式の要点

1. **シミュレーションと描画を分ける。** 戦闘状態は Node に依存しない純粋なデータ（`sim/`）として持つ。描画（`render/`）はその状態を読むだけにする。こうすると、ヘッドレス実行で戦闘を検証できる。
2. **固定60Hzで更新する。** `_physics_process` を `physics_ticks_per_second = 60`、`max_physics_steps_per_frame = 5` で使い、元の `FIXED_DT` と `MAX_STEPS_PER_FRAME` に対応させる。
3. **補間して描画する。** 描画では `Engine.get_physics_interpolation_fraction()` を使い、前回と今回の状態の間を補間する。補間対象は全エンティティ（プレイヤー・敵・弾・経験値オーブ・カメラ）とする。90Hz・120Hzの表示でも、実際の描画は表示周期ごとに1回行う。合成フレームは作らない。
4. **GPUでまとめて描画する。** 敵・弾・経験値オーブ・粒子は、アトラスごとに1つの `MultiMeshInstance2D` で描く。インスタンスごとの位置・回転・色・アトラスの領域は `RenderingServer.multimesh_set_buffer` で一括転送する。
5. **フレーム生成は移植しない。** 3 で置き換える。fg.4 の実装は `webview-fg4/` に残す。

## 4. ディレクトリ構成

```
godot/                          Godot プロジェクト（project.godot）
  project.godot
  export_presets.cfg            パスワードは含めない。環境変数で渡す
  assets/atlas/*.webp           tools/extract_assets.py で抽出した画像
  assets/atlas/atlas_layout.json  ART_LAYOUTS から生成したセル配置
  sim/                          決定的な戦闘シミュレーション（Node非依存）
    js_compat.gd                JSと互換の数値ヘルパー（§5.2）
    rng.gd                      makeSeededRandom の移植
    defs/                       CHARACTERS, WEAPONS, ENEMY_ARCHETYPES, enemySpec など定義データ
    game_state.gd               元の game オブジェクトに相当
    systems/*.gd                UPDATE_MAIN_SYSTEMS の各システム
    sim.gd                      step(dt) が元の update(FIXED_DT) に相当
  render/                       描画（RENDER_SYSTEMS 順のレイヤー）
  ui/                           HUD、仮想スティック、開始画面、レベルアップ、結果画面
  main.tscn / main.gd           ループ、入力、補間、シーン切り替え
  tests/                        ヘッドレステスト（外部アドオン不使用の最小ランナー）
tools/
  extract_assets.mjs            original.html から WebP とレイアウトを抽出（Node 22、標準ライブラリのみ。--check で差分検出）
  check_assets.sh               抽出結果とリポジトリの一致を検査（run_godot_tests.sh が最初に実行）
  setup_godot.sh                Godot 本体、テンプレート、Android SDK の取得と SHA-512 照合
  build_android.sh              ヘッドレスでの APK エクスポート
  reference-trace/              元ゲームから参照トレースを採取（Playwright）
  compare_trace.py              参照トレースと Godot のトレースを比較
docs/godot-port-design.md       本書
webview-fg4/                    既存版（変更しない）
```

## 5. シミュレーション層

### 5.1 移植の原則

- 元の関数を1つずつ移植する。各関数の先頭に `# port: <元の関数名>` と書き、追跡できるようにする。
- **`gameRandom` を呼ぶ順序と回数は元と同じに保つ。** 呼び出しの省略、追加、並べ替えはしない。M1 の対象外の機能が乱数を引く場合は、引く回数だけ合わせたスタブを置く。
- 演出用の乱数（`fxRandom`）は戦闘用とは別のインスタンスにする。戦闘状態には影響させない。
- GDScript はすべて静的型付けで書く（`var x: float`、`Array[Enemy]`）。性能のためである。
- エンティティは `RefCounted` を継承した型付きクラスにする。よく使うループでは辞書を避ける。

### 5.2 JSとの数値互換（落とし穴）

| JS | GDScript での扱い |
| --- | --- |
S3 で、各関数20万件以上を Chromium 141（V8 14.1）と照合した。当初の想定のうち3点は、この実測で誤りと分かったので改めた。照合結果は `verification/godot/s3/math.txt` にある。

| JS | GDScript での扱い（S3 で確定） |
| --- | --- |
| 数値は64ビット double | `float` も64ビットである【事実】。`int` が混ざらないよう明示する |
| `Math.round(x)` | `JsMath.js_round`（V8 と同じく ceil を使う方式）を使う。`floor(x + 0.5)` は 1.14% で一致しなかった【事実：S3】。-0 の扱いと 0.49999999999999994 などで結果が違うためである |
| `x \| 0`、`>>> 0`、`Math.imul` | `JsMath.to_int32` / `to_uint32` / `imul` を使う。`int(x)` は範囲外の値や NaN で結果が違う【事実：S3】 |
| `Math.sin/cos` | **組み込み関数は使わない。** V8 14.1 と同じ glibc s_sin.c の方式を移植した `JsMath.sin/cos` を使う。組み込み関数との不一致は、PC で約0.07%、Android の libm を再現した環境で約2.8% だった【事実：S3、Android は実機ではなくエミュレーション】 |
| `Math.atan2/atan/exp/log` | **組み込み関数は使わない。** fdlibm を移植した `JsMath` 版を使う。組み込み関数との不一致は、atan2 で 15.2%、exp で 8.7% だった【事実：S3】 |
| `Math.hypot(a, b)` | V8 の FastMathHypot を移植した `JsMath.hypot` を使う。`sqrt(x*x+y*y)` では 35% が一致しなかった【事実：S3】 |
| `Math.min/max`、`clamp` | `JsMath.js_min/js_max/clamp` を使う。組み込み関数は NaN と ±0 の扱いが異なる |
| `Math.sqrt/floor/ceil/abs` | IEEE 754 で結果が厳密に決まるため、組み込み関数をそのまま使える【事実：S3】 |
| `Math.pow` | M1 では使わない（レベルアップ後の抽選だけで使う）。元の Chromium 自身も実行環境の libm に依存するため、ビット一致は保証しない |
| `Array.prototype.sort`：安定ソート | 元がソートしている箇所には安定ソートを実装する。Godot の `sort_custom` が安定かは【未確認】 |
| `Map` / `Set`：挿入順を保持 | `Dictionary` も挿入順を保持する【事実】 |
| `%`（浮動小数） | `JsMath.js_mod`（`fmod`）を使う。GDScript では float 同士の `%` はコンパイルエラーになる【事実：S3】 |

- 移植した関数は `godot/tests/golden/` の正解値（各2万件以上）と、ビット単位で一致することを確かめている。正解値は `tools/verify_golden_chromium.mjs` で Chromium 141 と照合済みである。
- Node 22 の V8 は sin/cos の方式が Chromium と異なり、約3% が一致しない。そのため、sin/cos の正解値は Node では作らない。
- `godot/tests/test_sim_source_rules.gd` が、`godot/sim/` で組み込みの数学関数を使っていないことを検査する。

### 5.3 システムの実行順

`UPDATE_MAIN_SYSTEMS` の43システムを元の順序のまま配列で持つ。M1 では次の **太字** だけを実装し、残りは何もしないスタブにする。スタブでも、乱数を引く場合は §5.1 に従う。

character/berserker, character/sentinel, player/reaction-buffs, **player/movement**, **player/camera**, **wave/progress**, **index/enemy-by-id**, **index/separation-1**, damage/root-link-reset, weapon/hazards, **enemy/cleanup-1**, character/archivist-records, character/archivist-bank, character/miko-barrier, **enemy/squads**（swarm と assassin に関わる部分）, **enemy/update**, enemy/ground-attacks, **index/separation-2**, character/striker, character/harmonizer, character/harmony-fields, character/pathfinder, character/ranger-catalyst, ability/update, ability/meta-progression, **weapon/update**, weapon/signature-actions, weapon/turrets, weapon/saplings, **projectile/player**, damage/root-link-flush, **enemy/cleanup-2**, projectile/enemy, projectile/enemy-beams, pickup/loot, **pickup/xp**, player/contract-dots, **fx/particles**（演出用乱数のみ）, **hud/pending-choice**, fx/screen-flash, **player/regen**, hud/tutorial, **hud/update**（UIへの通知のみ）

`UPDATE_INTRO_SYSTEMS` と `UPDATE_KO_SYSTEMS` も同じ方針で扱う。M1 で実装するのは、KO演出と `frame/end-run` だけである。

### 5.4 空間検索

`rebuildEnemySeparationGrid` と `queryEnemiesCircleBroad` は、グリッドの寸法（`ENEMY_SEPARATION_GRID_SIZE` など）と走査順をそのまま移植する。候補の列挙順が変わると、最寄りの敵の判定や命中の順序が変わり、乱数の消費も変わるためである。

### 5.5 性能目標

- GDScript は V8 の JIT より遅い可能性がある【推測】。そのため M1 では、次の負荷場面で `sim.step()` を計測する。
  - 敵100体、弾520発、経験値オーブ480個
- 目標は、PC上のヘッドレス実行で1ステップの中央値が4ms以下とする。
- 端末での値は測れない。目標を超えた場合の対策は §12 に示す。
- 【事実：S3】移植した数学関数は、1回あたり約0.4〜1.2µs かかる。組み込み関数の15〜40倍である。
  - 元ゲームの計算量を再現した試算では、敵100体で約1.13ms、追尾弾520発で約3.85ms かかった。組み込み関数ならそれぞれ 0.22ms、0.61ms である。
  - このままでは目標の4ms を超えるおそれがある。S5・S6 で実際の処理を移植したら、すぐに計測する。
  - 対策の候補は次の3つである。どれを使うかは、計測結果を見てユーザーと決める。
    1. ビット一致を保ったまま減らす：同じ値の再計算をやめる、sin と cos を一度に計算する
    2. 数学関数だけ C++（GDExtension）に移す
    3. 検証用は移植版、配布版は組み込み関数と切り替える
       - 通常のプレイは乱数のシードを固定しないので、最下位ビットの差はゲームの挙動として問題にならない【推測】
  - **ユーザーの判断（2026-10-20）：S5・S6 で実測してから決める。** それまでは移植版のまま進める。
- 【事実：S5 の実測】`tools/bench_sim.sh` で計測した。1ステップの中央値（ms）である。計測した PC は 2.8GHz の Xeon 仮想マシン。

  | 場面 | エディター（デバッグ版） | 配布用テンプレート | 配布用＋組み込み数学関数 | 配布用＋ビット一致のままの最適化 |
  | --- | ---: | ---: | ---: | ---: |
  | 敵100体（密集） | 8.5〜9.0 | 6.51 | 5.76 | 5.61 |
  | 敵100体（分散） | 6.0〜7.0 | 5.07 | 4.00 | 4.04 |
  | 敵30体（序盤相当） | 1.9 | 1.54 | 1.27 | 1.24 |

  - 処理時間の 88〜92% は enemy/update が占める。主な原因は、近くの敵を調べる処理と、GDScript の関数呼び出しやプロパティ参照のオーバーヘッドである。
  - 数学関数を組み込み関数に替えても 11〜21% しか速くならない。同じ効果が、ビット一致を保った簡単な最適化（約20行）でも得られた。
  - 実際の M1 のプレイでは、敵は同時に最大23体である（参照トレースより）。この規模なら問題ない【推測：中位のスマホで2〜3ms】。
  - 一方、§5.5 の目標場面（敵100体＋弾520発＋経験値オーブ480個）は、敵だけで目標を超えている。S6 で弾とオーブを加えると、中位のスマホでは1フレームの時間（16.7ms）を超える見込みである【推測】。
  - Opus レビューの推奨は次のとおりである。
    1. 組み込み数学関数への切り替えはしない。
    2. S6 でビット一致のままの最適化を入れる。
    3. `tools/bench_sim.sh` に配布用テンプレートでの計測を加える。
    4. S6 の後、目標場面の負荷で GDExtension（C++）化を判断する。
- **ユーザーの判断（2026-10-24）**：今すぐ C++ 化し、範囲は戦闘処理全体とする（案A）。
  - 状態・乱数・数学関数・全システムを GDExtension（C++）に移す。GDScript に残すのは表示と UI だけである。
  - 手順は C1 → C2 → C3 → S6 とする。
    - C1：ビルド環境
    - C2：数学関数と乱数を C++ に移す
    - C3：S3〜S5 の戦闘処理を C++ に移し、7本のトレースで照合する
    - S6：武器と弾を最初から C++ で移植する
  - C++ は浮動小数の演算を融合させない（`-ffp-contract=off`）。`-ffast-math` 系の最適化は使わない。arm64 の clang は既定で a*b+c を1命令（FMA）にまとめ、結果が変わるためである。
  - 照合の方法（正解値・参照トレース）は今と同じものを使う。
- 【事実：C2 の実測】C++ 版の数学関数と乱数の1回あたりの時間（`verification/godot/c2/bench.txt`。PC、配布用と同じ `-O2 -ffp-contract=off`、中央値）：sin 18〜20ns、cos 18〜21ns、atan2 14〜15ns、exp 約9ns、log 約8ns、hypot 約4ns、乱数1回 1.5〜2ns。GDScript 版（sin 約0.8〜1.0µs）の約40〜50分の1である。GDScript から1回ずつ呼ぶと、呼び出しの負担が大半を占める。そのため C3 では、戦闘処理全体を C++ で動かす。
- **ライセンス【事実】**：sin/cos の移植元である glibc s_sin.c は LGPL-2.1 以降である。fdlibm（atan2/exp/log）は、著作権表示を残せば自由に使える。
  - ユーザーの判断（2026-10-24）：当面はそのまま使う。配布方針と一緒に S9 で決める。
  - それまで LGPL の部分は別ファイルに分け、ライセンス表示を付けておく。

## 6. 描画層

### 6.1 共通

- ドット絵であるため、テクスチャのフィルタは Nearest にする（元の `imageSmoothingEnabled=false` に対応）。
- 画面の拡大方式は `display/window/stretch/mode = "canvas_items"`、`aspect = "expand"` とする。
  - 基準サイズは 390×390 である。これにより、画面の短い辺が常に約390単位になる。縦向きなら約390×N、横向きなら約N×390 で、元のゲームが CSS ピクセルで世界を表示しているのに近い。
  - PC で実行するときのウィンドウは 390×844 とする（`window_*_override`）。これは元のテストで使っている表示サイズである。
  - 戦闘処理では、表示中の領域の大きさ（`viewW/viewH`）を入力として受け取る。参照トレースでは 390×844 に固定する。元のゲームは、敵の出現距離などをこの大きさから計算しているためである。
- 画面の向きは `orientation = 6`（sensor）とする。【事実：S1 で確認】Godot 4.7.2 の Gradle なし出力では、Android の設定値が fullSensor(10) ではなく fullUser(13) になる。四方向とも回転できるが、端末側の回転ロックに従う。**ユーザーの判断（2026-10-19）により fullUser を採用した。**
- 自前で補間するため、`physics/common/physics_jitter_fix = 0` とする。Godot のドキュメントが、自前で補間する場合は 0 にするよう求めているためである。S1 のレビューで判明した。
- カメラは `sim` のカメラ位置を補間した値を使う。オフセットは画面中央とする（元の `-cam.x + viewW*0.5`）。

### 6.2 レイヤーの順序

`RENDER_SYSTEMS` の順序を、`CanvasLayer` と `z_index` で再現する。M1 で実装するのは **太字** だけである。

**world/terrain**（M1は軽量画質の64px模様）, ultra/terrain, world/hazards, ultra/fields, enemy/ground-attacks, character/miko-barrier, weapon/turrets, weapon/saplings, **pickup/xp**, pickup/loot, ultra/trails, **projectile/player**, ultra/enemy-aura, **enemy/body**, **player/body**, projectile/enemy, projectile/enemy-beams, **fx/signature**（catalyst の発射演出）, **fx/sprite**, ultra/impacts, **fx/particles**, overlay/ambient, **overlay/map-border**, overlay/threat-markers, **overlay/low-hp**, hud/reaction-buffs, overlay/screen-flash, **overlay/damage-flash**

### 6.3 一括描画

- アトラスごとに `MultiMeshInstance2D` を1つ置く（characters、enemies、projectiles、hits、effects など）。
- インスタンスのデータは Transform2D（8 float）、色（4 float）、カスタム（4 float）とする。カスタムにはアトラスのセル番号と左右反転を入れる。シェーダーは `INSTANCE_CUSTOM` からUVを求める。
- 毎フレーム、補間した位置で PackedFloat32Array を組み立て、まとめて転送する。インスタンス数は上限（§2.3）で確保し、`visible_instance_count` で可変にする。
- 円・線・矩形などの図形（`fillRect` / `arc` / `stroke` の置き換え）は、図形ごとに `_draw()` でまとめて描く。数が多いもの（被弾の数字など）は M2 以降で MultiMesh 化する。

## 7. 入力・UI

- 入力は2つ用意する。
  - 仮想スティック：画面左半分のどこでも、触れた点を原点にする。元の `input.moveX/moveY` に対応する。
  - キーボード：WASD と矢印キー。元の `inputVector()` と同じく、合成した値の長さが1を超えたら正規化する。
- HUD は Godot の Control で作る。M1 では HP、XP、レベル、ウェーブ番号と残り時間、一時停止ボタンを置く。
- 日本語の表示には、Android では `SystemFont` で端末のCJKフォントを使う。フォントは同梱しない。端末での表示は【未確認】である。
- M1 の画面は4つとする。
  - 開始：catalyst で開始するボタンだけを置く
  - 一時停止
  - レベルアップ：簡略版。§8 で定める
  - 結果

## 8. M1の範囲

| 含む | 含まない（M2以降） |
| --- | --- |
| キャラ catalyst（固有値のうち、M1で効くのは直接ダメージ×0.85とXP×1.5） | 他の9キャラ、キャラ固有システム |
| 武器 catalytic_ring（最大4体まで連鎖し、威力は100→50→25→12.5%） | catalyst の過負荷能力（`cat_overload`。能力システム自体が M2 以降） |
| 汎用武器 pulse・blades・wand（レベルアップで追加・強化） | 他の汎用11種、武器MOD、宝箱 |
| 敵 swarm・assassin（W1〜W4） | W5 の elite 以降、tank 以降の敵、boss、敵弾 |
| ウェーブの進行、出現の指揮（`updateWave`、`spawnDirectorEnemyBatch` の通常ウェーブ部分） | 特殊ウェーブ、契約、異常因子、エンドレス |
| ダメージ、会心、回避、装甲、ノックバック、撃破、経験値の落下と回収、レベルアップ | 属性、反応、状態異常、能力、メタ進行、ルールブック |
| 難易度 normal（固定） | 他の難易度 |
| 被ダメージ、KO、結果画面 | セーブ、統計、効果音、BGM |
| 軽量画質の地形、最小限の演出 | 最高画質の演出、昼夜、光源マップ、Worker 生成 |

- **レベルアップ（簡略版）**：候補は catalytic_ring の強化、pulse・blades・wand の追加または強化から3枚とする。抽選には M1 専用の別乱数を使う。このため、最初のレベルアップ以降は元のゲームと一致しない（§9.3）。
- **終了条件**：W4 を終えると「試作版はここまで」と書いた結果画面を出す。

## 9. 検証計画

### 9.1 単体テスト（ヘッドレス）

- 実行方法：`godot --headless --path godot -s res://tests/run_tests.gd`。終了コードで合否を返す。
- 対象は次のとおり。
  - `rng.gd`：元の `makeSeededRandom` と比べ、シードごとの先頭1,000個が完全に一致すること。期待値は、original.html から関数の本文だけを取り出して Node で生成する。
  - `js_compat.gd`：丸め、32ビット演算、hypot の境界値。
  - `enemySpec`、`gainXp` の XP 曲線、`weaponDamage`：元の式とウェーブ別の値が一致すること。

### 9.2 参照トレースの比較（M1の中心となる受け入れ基準）

S4 で実装した仕組みである。形式の詳細は `tools/reference-trace/FORMAT.md` にある。

1. `tools/reference-trace/capture.mjs` が、元のゲーム（`webview-fg4/tests/fixtures/original.html`）を Playwright 1.62.1 と Chromium 141 で起動する。
   - Android 相当の環境（390×844、タッチ操作、`IS_COARSE_POINTER=true`）をまねて動かす。
   - HTTP応答にだけテスト用フックを挿入する。元のファイルは変更しない。
2. 条件を固定する。
   - シードは 424242 と 24681357、キャラは catalyst、難易度は normal とする。
   - 入力の台本は3種類（`dirs8`：8方向へ1秒ずつ、`idle`、`zigzag`）で、元のタッチ操作の処理を通して与える。
   - 演出用の `Math.random` もシードで固定する。
3. `capturePreviousTransforms(); update(FIXED_DT)` を1ステップずつ呼ぶ。各ステップの終わりの状態を、gzip 圧縮した JSON Lines（形式 `swarm-trace/1`）に記録する。
   - 浮動小数は IEEE 754 のビット列（16進）で記録する。
   - **乱数の使用回数を、ステップごと・システムごとに記録する**（`slot_draws`）。どのシステムにも属さない使用は、すべてのトレースで0回であった。
   - 項目の一覧はヘッダーに持たせる。S5・S6 で項目を足しても形式は変わらない。
4. 最初のレベルアップ（`pendingLevelUps > 0`）が起きた時点で採取を止める。
   - 加えて、検証専用の長時間版（`--long-run`）がある。経験値の必要量と体力を極端に上げてレベルアップと死亡を止め、W3 までと assassin の動きを記録する。
5. 決定性を確かめた【事実：S4】。次のいずれでも、記録はバイト単位で同一であった。
   - 同じ条件で2回採取した
   - 演出用乱数のシードを変えた（粒子の数だけが変わる）
   - CPU を6倍遅くした
6. Godot 側は `SimTrace` が同じ形式を出力する。`tools/compare_trace.mjs` が、項目ごとに最初に乖離したステップと値（ビット列と ulp 差）を報告する。
   - 乱数の回数と座標は、**ビット単位での一致**を求める（許容誤差なし）。
   - 比較の範囲は、元にあって移植版にまだない処理の最初の影響（接触ダメージなど）までとする。この境界はトレース自身から求め、Node と Godot の両方の実装が同じ値を出すことをテストで確かめる。
   - 一致しない場合は、最初に乖離したステップと項目を報告する。

### 9.3 レベルアップ以降

元のゲームとの一致は求めない。代わりに次の振る舞いを確かめる。

- 長時間（W1〜W4、約144秒相当）を実行しても例外が出ないこと。
- 上限（§2.3）を超えないこと。
- メモリーが単調に増えないこと。

### 9.4 描画の確認

- 【事実：S1 で確認】Xvfb とソフトウェアGPU（Mesa llvmpipe）上で、Godot を OpenGL 3 描画（Compatibility）で起動できた。Movie Maker モードで 390×844 の PNG を書き出せた（`verification/godot/s1/render.txt`）。
- S7 では、固定シードの場面を同じ方法で書き出す。そのうえで、レイヤー順と補間（中間の時刻で位置がずれないこと）を目で確かめる。
- 元のゲームと画素単位で一致することは求めない（描画方式が異なるため）。

### 9.5 検証できない範囲

- 実機・エミュレーターでのインストール、FPS、入力遅延、発熱、高リフレッシュレート（90/120Hz）の採用は検証できない。この環境に Android 端末がないためである。

## 10. ビルドと署名

S1 で実際に組んだ構成である。

1. `tools/setup_godot.sh` は、ダウンロード物をリポジトリの外のキャッシュ（既定は `~/.cache/elemental-swarm-engine`、`SWARM_CACHE_DIR` で変更できる）に取得する。
   - 取得するたびに、スクリプト内に固定したサイズとハッシュで照合する。照合が済むまで、展開も実行もしない。
   - Godot の2ファイルは SHA-512 で照合する。値は公式の `SHA512-SUMS.txt` と一致することを確かめてある。
     - `Godot_v4.7.2-stable_linux.x86_64.zip`
     - `Godot_v4.7.2-stable_export_templates.tpz`（1,281,349,702バイト）
   - Android SDK は SHA-256 と、Google が公開している SHA-1 の両方で照合する。
   - 再実行してもダウンロードし直さず、既存のファイルを照合し直すだけである。
2. Godot は self-contained モード（本体の隣に `_sc_` を置き、設定とテンプレートを本体の隣に保存する方式）で動かす。テンプレートは Android 用の4ファイルだけを展開する。
3. Android SDK と JDK は、公式ドキュメントの構成から次のように変えた【事実：S1 で確認】。
   - Build-Tools は 36.0.0 を使う。Godot 4.7.2 の標準の target SDK が 36 で、それに合う apksigner を選ぶためである。
   - Platform-Tools は r37.0.1 を入れる。adb は使わないが、ないと書き出し前の検査で止まるためである。
   - Platform は入れない。Gradle なしの書き出しでは参照されないためである。
   - JDK は 21 を使う。17 以上であればよい。
4. ビルドは Gradle を使わない。【事実：S1 で確認】
   - Gradle なしでも APK を書き出せた。
   - その場合、minSdk は 24、targetSdk は 36 に固定され、変更できない。対象の Android 10 以降は範囲に含まれるため、問題はない。
5. S1 では、使い捨てのデバッグ用鍵（キャッシュ内）で署名した。配布用の鍵は S9 で、ユーザーの確認を取ってから作る。
   - 作った鍵は `.signing-engine/`（`.gitignore` 対象）に置く。
   - **鍵をなくすと更新版を配れなくなる。** ユーザーが手元で保管する必要がある。
   - Godot 4.7.2 は、署名時にパスワードをコマンドラインで apksigner に渡す。コマンドラインは同じ端末上の他のプロセスから見えてしまう。そのため S9 では、署名なしで書き出してから `apksigner sign --ks-pass env:...` で署名する。
6. 権限は追加しない（インターネット権限を含めない）。`build_android.sh` が書き出した APK のマニフェストを調べ、権限があれば失敗させる。
7. 出力先は `export/`（リポジトリ直下、`.gitignore` 対象）とする。`build_android.sh` は次を検査する。
   - apksigner での署名の検証
   - zipalign での 16KiB 配置
   - パッケージ名、バージョン、ABI、SDK 水準
   - ネイティブライブラリの 16KiB 境界
9. C++（GDExtension）のビルド環境【事実：C1 で構築】：
   - `tools/setup_cpp.sh` が、次の3つを版を固定して取得し、照合してからキャッシュに入れる。
     - Android NDK r28b（28.1.13356709、サイズ・SHA-1・SHA-256 で照合）
     - godot-cpp（master のコミット `8070599`、api_version=4.7。Godot 4.7.2 自身が出力する API と一致することを毎回確かめる）
     - SCons 4.10.1（ハッシュを固定した仮想環境）
   - テスト用に PC 向けだけを取得するモード（`--host-only`）もある。
   - `native/SConstruct` は、浮動小数に関わるコンパイラー設定を許可リストで検査する。`-ffp-contract=off -fno-fast-math -O2` 以外は使えない。
   - `tools/build_native.sh` は、全6種（Linux x86_64 と Android arm64/armv7、それぞれ debug/release）をビルドし、出力を検査する。
     - 自前のオブジェクトに融合命令（FMA）がないこと（逆アセンブルで確認）
     - 16KiB 境界
     - 依存ライブラリ（Android は libc/libm/libdl だけ）
     - 絶対パスが埋め込まれていないこと
   - godot-cpp は必要なクラスだけをビルドする（`native/build_profile.json`）。全6種のビルドは約47秒、テスト前の PC 向けビルドは約8秒である。
   - Godot 4.7.2 は、作業ツリーを新しく取り出した直後の初回の取り込みで、C++ 拡張を読み込むと異常終了することがある。対策として、`tools/lib/godot_project.sh` が拡張の一覧ファイルを先に作る。
   - 書き出した APK では、拡張は `lib/arm64-v8a/` と `lib/armeabi-v7a/` に入る。
   - arm64/armv7 の実行は、qemu-user（PC 上で ARM 用のプログラムを動かすツール）で確かめた。実機では確認していない。
10. 【事実：S1 で確認】書き出した APK では、FileProvider と androidx.startup の InitializationProvider が同じ authority を持っている。Godot 4.7.2 の書き出し処理がすべての provider の authority を `<パッケージ名>.fileprovider` に書き換えるためである。端末での影響は【未確認】で、`build_android.sh` は警告として表示する。
11. C2 で加えた構成【事実：C2 で構築】（詳細は `verification/godot/c2/spec.md`）：
   - `native/src/sim/`：Godot に依存しない C++17（`JsMath` と乱数）。`native/src/bindings/`：Godot との受け渡し。
   - `native/third_party/glibc_sincos/`：LGPL の sin/cos。静的ライブラリ `libswarm_glibc_sincos.a` にして拡張にリンクする。
   - `native/tests/`：単体テストプログラム `swarm_sim_tests`。ライブラリと同じ `sim` のオブジェクトをリンクする（Android は `-static`）。
   - `tools/build_native.sh` は、ビルドの前に `tools/check_native_sources.py`（ソース規則）を実行する。構成ごとに `swarm_sim_tests` で正解値を照合し、ARM は qemu-user（`setup_cpp.sh` が版を固定して入れる）で動かす。

## 11. 実装手順（各手順の前後でユーザーの確認を取る）

| 手順 | 内容 | 担当 | 完了条件 |
| --- | --- | --- | --- |
| S1 | 環境とプロジェクトの雛形：`setup_godot.sh`、`project.godot`、空のシーンで APK を試しに出力 | Sonnet（Opus がレビュー） | ヘッドレスで起動でき、空の APK に署名・検証できる |
| S2 | アセット抽出：`extract_assets.py` で WebP 14枚と `atlas_layout.json` を作る | Sonnet | 抽出した画像が元の data URI とバイト単位で一致する |
| S3 | sim の基礎：`js_compat`、`rng`、定義データ、`game_state`、システム実行順、プレイヤーの移動とカメラ | Sonnet | §9.1 が合格する |
| S4 | 参照トレースの採取ツール：元ゲームのトレースを JSON Lines で出力。**乱数の使用回数をステップごと・システムごとに記録する** | Sonnet | 2つのシードで、最初のレベルアップまで採取できる |
| S5 | 敵とウェーブ：出現の指揮、敵の更新（接触ダメージと押し出しを含む）、空間グリッド、片付け | Sonnet | 敵が最初に出るステップから、7本の参照トレースと一致する。条件は次のとおり<br>・S6 の担当で未移植のシステム（projectile/player、enemy/cleanup-2）は、記録した回数（`slot_draws`）だけ乱数を空引きして代用する<br>・撃破は `TraceReader.removed_enemy_ids` に従って片付けの前に敵を外す<br>・ダメージだけで変わる項目（敵の hp など）は S6 まで比較から外す |
| S6 | 武器・弾・ダメージ・経験値：catalytic_ring、pulse、blades、wand、撃破、回収 | Sonnet | §9.2 が最初のレベルアップまで合格する |
| S7 | 描画と補間：MultiMesh、レイヤー、カメラ、軽量画質の地形 | Sonnet | §9.4 を確認できる（可能な範囲） |
| S8 | UI と入力：HUD、仮想スティック、各画面、簡略版レベルアップ、W4 での終了 | Sonnet | §9.3 が合格する |
| S9 | 性能計測、APK 出力、報告書（`godot/TEST_REPORT.md`） | Sonnet（Opus が報告をレビュー） | §5.5 を計測し、APK を出力・検証する |

- 各手順の終わりに、Opus が差分をレビューしてからコミット・pushする。
- S5 の結果【事実】：7本の参照トレースすべてが、S5 の比較対象で全ステップ一致した。
  - テスト専用の仕組みは、未移植の projectile/player の乱数の空引きと、撃破の強制だけを補った。
  - W1〜W4 を通した 8,640 ステップの検証用トレース（コミットしていない）でも一致した。
  - M1 用の終了処理として、W4 終了時に勝利で終わる処理（`WaveRules.M1_LAST_WAVE = 4`）を加えた。
- C1 の結果【事実】：C++ 拡張を全6種でビルドでき、Godot（PC）で読み込めることと、APK に同梱されることを確かめた。テスト210件はすべて合格した。
- C2 の結果【事実】：
  - `JsMath` と乱数3種を、GDScript 版の写しとして C++ に移した（ユーザーの判断）。
  - 全6構成で正解値と 519,631 件すべてが一致した（arm64・armv7 は qemu-user 8.2.2）。Godot テストは 213 件すべて合格した（`test_js_math.gd`・`test_rng.gd` は C++ 版だけを試験する）。
  - C++ の定数と表は、`check_js_compat_consts.mjs` で上流の値・GDScript 版と照合した。記録は `verification/godot/c2/`（`spec.md`、`build.txt`、`tests.txt`、`bench.txt`、`review.md`）にある。
  - GDScript の戦闘処理は、C3 まで GDScript 版の `JsMath` と乱数を使い続ける。
- C2 以降で C++ の戦闘処理に適用する規則（C1 レビューの推奨を採用）：
  1. 構成：
     - `native/src/sim/` は Godot に依存しない純粋な C++17 にする。数学、乱数、状態、システムの順に追加していく。
     - LGPL の sin/cos は独立したライブラリとして分け、ライセンスの写しと由来を添える。
     - Godot との受け渡し部分は別ディレクトリに置く。値は PackedFloat64Array/PackedInt64Array で受け渡す（Vector2 や real_t は32ビットなので使わない）。
  2. 正解値（`godot/tests/golden/`）の照合を、C++ 単体のテストプログラムでも行う。対象は x86_64、arm64、armv7 で、ARM は qemu-user で動かす。
  3. 禁止事項：
     - `float`、`long double`、`long`（armv7 では32ビット）
     - `std::sort`（不安定で、ライブラリごとに順序が違う）。安定ソートを使う
     - `unordered_*` を順に走査すること
     - `<random>`、FP 関連の pragma、`fma`、スレッド
     - 範囲外の double を整数へキャストすること（未定義動作）。JS の ToInt32 は明示的に実装する
  4. NaN は比較やハッシュに生のビット列を使わない。x86 と ARM で NaN のビット列が異なる【事実：C1 で計測】。
  5. デバッグ版では、実行開始時に浮動小数の環境（丸めモード、flush-to-zero なし）を検査する。
- S5 から持ち越す事項：
  - S6：テスト専用の仕組みによる弾の注入と乱数の空引きをやめ、自前の弾で照合する。ビット一致のままの最適化を入れる。W4 の照合をコミットする（ステップごとのハッシュなど）。
  - S7：粒子の数を元と同じに保つ。粒子が1,100個以上になると、ダメージ数字の表示が乱数を引かなくなり、乱数の消費がずれるためである。
  - S8：W4 開始時の解放メッセージを移植する。
- S4 以降のモデル分担（ユーザー指示、2026-10-19）は次のとおりである。
  - Opus：全体設計と最終判断（各手順の仕様、レビュー、コミットの可否）
  - Sonnet：中核の処理（移植、統合、修正）
  - Haiku 5.5：並列で処理できる下請け作業（資料の洗い出し、正解値の採取、検証結果の取りまとめ）
  - 元ゲームとビット単位で一致させる移植は、Haiku に任せない。
- サブエージェントには、作業範囲外のファイル（特に `webview-fg4/`）を変更させない。

## 12. リスクと対策

| リスク | 影響 | 対策 |
| --- | --- | --- |
| 移植量が大きい（約1,550関数、DOM UI、音声） | 全機能そろうまでに長くかかる | 縦切りで進め、M2 以降で段階的に追加する（§13） |
| GDScript の実行速度【推測】 | 大量配置の場面で更新が遅れる | 1. 型付けと PackedArray で最適化する<br>2. それでも足りなければ、よく使う処理だけ C++（GDExtension、Android NDK が必要）へ移す。移す前に相談する |
| 浮動小数の違い（三角関数）【推測】 | 参照トレースが長い時間で乖離する | 最初の乖離点を報告する。必要なら fdlibm を移植する |
| Gradle なしの出力の制約【事実：S1 で確認】 | 1. min/target SDK が 24/36 に固定される<br>2. 画面の向きが fullUser になる<br>3. provider の authority が重複する | 1 は Android 10 以降が対象なので問題ない。2 は fullUser を採用した（ユーザー判断）。3 は端末で確かめ、必要なら Gradle ビルドへの切り替えを相談する |
| 大きなテクスチャ【事実：S2 で確認】 | `signature_fx.webp` は 512×2944 である。OpenGL ES 3.0 が保証する最大テクスチャサイズは 2048 なので、古い端末では読み込めない可能性がある | S7 で端末の上限を確かめる。必要なら画像を分割する |
| 実行時に生成する画像【事実：S2 で確認】 | 被弾時の白い点滅、縮小した演出、範囲の着色、地形、メニュー背景は、元のゲームが実行時に作っている | S7 でシェーダーかコードで作り直す。必要な値は `atlas_layout.json` の `runtime_derived` に記録した |
| 日本語フォント【未確認】 | 端末によって文字化けする | SystemFont の代替表示を確かめる。必要なら Noto Sans JP（OFL）のサブセットを同梱する |
| fg.4 のセーブを引き継げない | 進行状況が新アプリへ移らない | M2 以降で、元の「セーブの書き出し」で作った JSON を取り込む機能を検討する |
| APK のサイズ増【推測：数十MB】 | 配布サイズが大きくなる | 不要なモジュールを除いたテンプレートは M2 以降で検討する |
| 高リフレッシュレートの採用【未確認】 | 120Hz で動かない可能性 | 補間描画なので60Hzでも滑らかさは保てる。端末での確認が必要 |

## 13. M2以降の見通し（参考、順序は M1 の結果で見直す）

1. 属性・反応・状態異常（ゲームの中核）と、W5 の elite・tank
2. 能力システム、宝箱、汎用武器の残り
3. 残りの敵・boss・敵弾、W30 まで、エンドレス
4. 残りの9キャラと各キャラ固有システム
5. 効果音・BGM の移植（Web Audio の生成処理を AudioStreamGenerator へ移す、または事前に録音して入れる）
6. セーブ・統計・ルールブック・設定画面、最高画質の演出、地形生成、昼夜・光源

## 14. 出典

- Godot 公式ダウンロードアーカイブ（4.7.2-stable：2026-08-18公開、2026-10-19閲覧）: https://godotengine.org/download/archive/
- Godot 4.7 公式ドキュメント「Exporting for Android」（更新日は不明、2026-10-19閲覧）: https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html
- Godot 4.7.2 の SHA512-SUMS.txt（GitHub releases、2026-10-19取得）: https://github.com/godotengine/godot/releases/download/4.7.2-stable/SHA512-SUMS.txt
