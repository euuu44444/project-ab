# Elemental Swarm Godot移植 設計書（マイルストーン1：縦切り試作）

- 作成日: 2026-10-19
- 対象: `webview-fg4/`（Android WebView版 11.11.9-fg.4）→ `godot/`（Godot 4.7.2 版、新規）
- 役割: 分析・設計・レビューは Opus、コード実装・テスト実行は Sonnet のサブエージェントが担当する。
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
  extract_assets.py             original.html から WebP とレイアウトを抽出
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
| 数値は64ビット double | `float` も64ビットである【事実】。`int` が混ざらないよう明示する |
| `Math.round(x)`：0.5は正の無限大側へ丸める | `floor(x + 0.5)` を使う。組み込みの `round()` は0から離れる側へ丸めるため、負の数で結果が変わる |
| `x \| 0`、`>>> 0`、`Math.imul` | `js_compat.gd` で32ビットにマスクする関数を用意する（`to_int32`、`to_uint32`、`imul`） |
| `Math.hypot(a, b)` | V8 の実装に合わせた `js_hypot` を用意する【未確認：V8 の内部アルゴリズム】。乖離が出たら見直す |
| `Math.sin/cos/atan2` | 組み込み関数を使う。V8（fdlibm）と端末の libm で最下位ビットが異なる可能性がある【推測】。乖離の原因と判明した場合だけ、fdlibm の移植を検討する |
| `Array.prototype.sort`：安定ソート | 元がソートしている箇所には安定ソートを実装する。Godot の `sort_custom` が安定かは【未確認】 |
| `Map` / `Set`：挿入順を保持 | `Dictionary` も挿入順を保持する【事実】 |
| `%`：結果は被除数の符号に従う | `fmod` と int の `%` も同じ挙動である。移植のたびに確認する |

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

## 6. 描画層

### 6.1 共通

- ドット絵であるため、テクスチャのフィルタは Nearest にする（元の `imageSmoothingEnabled=false` に対応）。
- 画面の拡大方式は `display/window/stretch/mode = "canvas_items"`、`aspect = "expand"` とする。画面の向きは、元と同じく端末の回転に追従する（fullSensor 相当）。
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

1. `tools/reference-trace/` から元のゲーム（`webview-fg4/tests/fixtures/original.html`）を Playwright と Chromium（`/opt/pw-browsers`）で起動する。
   - 既存テストと同じく、HTTP応答にだけテスト用フックを挿入する。配布用のHTMLは変更しない。
2. 条件を固定する。シードは 424242 と 24681357、キャラは catalyst、難易度は normal とする。入力は台本で固定する（例：8方向へ1秒ずつ移動）。
3. `update(FIXED_DT)` を1ステップずつ呼ぶ。各ステップで次の値を JSON Lines に記録する。
   - `gameRandomDraws`
   - プレイヤーの x, y, hp, xp, level
   - 敵の数と、各敵の id, kind, x, y, hp
   - 弾の数と位置
   - 経験値オーブの数
4. 最初のレベルアップ（`pendingLevelUps > 0`）が起きた時点で採取を止める。そこまでは M1 の範囲だけで再現できるためである。
5. Godot の `sim` も同じ条件で実行し、同じ形式のトレースを出す。`tools/compare_trace.py` で比べる。
   - 乱数の回数、敵の数、id、kind は完全に一致すること。
   - 座標と hp の差は 1e-6 以下であること（相対・絶対のどちらか）。
   - 一致しない場合は、最初に乖離したステップと項目を報告する。三角関数の差による乖離（§5.2）なら、その旨を明記したうえで扱いを相談する。

### 9.3 レベルアップ以降

元のゲームとの一致は求めない。代わりに次の振る舞いを確かめる。

- 長時間（W1〜W4、約144秒相当）を実行しても例外が出ないこと。
- 上限（§2.3）を超えないこと。
- メモリーが単調に増えないこと。

### 9.4 描画の確認

- Xvfb とソフトウェアGPU（Mesa llvmpipe）で、Godot を OpenGL 3 描画として起動できるかを【未確認】である。起動できれば、固定シードの場面を Movie Maker モードで PNG に書き出す。そのうえで、レイヤー順と補間（中間の時刻で位置がずれないこと）を目で確かめる。
- 元のゲームと画素単位で一致することは求めない（描画方式が異なるため）。

### 9.5 検証できない範囲

- 実機・エミュレーターでのインストール、FPS、入力遅延、発熱、高リフレッシュレート（90/120Hz）の採用は検証できない。この環境に Android 端末がないためである。

## 10. ビルドと署名

1. `tools/setup_godot.sh` で次を取得し、SHA-512 を照合する。
   - `Godot_v4.7.2-stable_linux.x86_64.zip`
   - `Godot_v4.7.2-stable_export_templates.tpz`（1,281,349,702バイト）
   - 照合には公式の `SHA512-SUMS.txt` を使う。GitHub releases からの取得はこの環境で可能であった【事実：2026-10-19 に確認】
2. テンプレートを展開し、Android 用以外は削除する。
3. Android SDK は、Godot 4.7 の公式ドキュメントにある構成をそろえる（Build-Tools 35.0.1、Platform 35、Platform-Tools、JDK 17）。
   - fg.4 の `build_apk.py` と同じく、`dl.google.com` から固定版を取得し、ハッシュを照合する。
   - ビルドは Gradle を使わず、事前ビルド済みのテンプレートで行う方針である。ただし Godot 4.7 で Gradle なしの APK 出力ができるかは【未確認】である。手順 S1 で確かめる。
4. 鍵は `keytool` で新しく作り、`.signing-engine/`（`.gitignore` 対象）に置く。
   - エクスポート時は `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`、`GODOT_ANDROID_KEYSTORE_RELEASE_USER`、`GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD` で渡す。
   - **鍵をなくすと更新版を配れなくなる。** ユーザーが手元で保管する必要がある。
5. 権限は追加しない（インターネット権限を含めない）。`export_presets.cfg` で確認する。
6. 出力は `godot/export/ElementalSwarm_engine_m1.apk`（`.gitignore` 対象）とする。apksigner で署名を検証し、zipalign で配置を検査する。

## 11. 実装手順（各手順の前後でユーザーの確認を取る）

| 手順 | 内容 | 担当 | 完了条件 |
| --- | --- | --- | --- |
| S1 | 環境とプロジェクトの雛形：`setup_godot.sh`、`project.godot`、空のシーンで APK を試しに出力 | Sonnet（Opus がレビュー） | ヘッドレスで起動でき、空の APK に署名・検証できる |
| S2 | アセット抽出：`extract_assets.py` で WebP 14枚と `atlas_layout.json` を作る | Sonnet | 抽出した画像が元の data URI とバイト単位で一致する |
| S3 | sim の基礎：`js_compat`、`rng`、定義データ、`game_state`、システム実行順、プレイヤーの移動とカメラ | Sonnet | §9.1 が合格する |
| S4 | 参照トレースの採取ツール：元ゲームのトレースを JSON Lines で出力 | Sonnet | 2つのシードで、最初のレベルアップまで採取できる |
| S5 | 敵とウェーブ：出現の指揮、敵の更新、空間グリッド、片付け | Sonnet | 敵が最初に出るステップから、トレースが一致する |
| S6 | 武器・弾・ダメージ・経験値：catalytic_ring、pulse、blades、wand、撃破、回収 | Sonnet | §9.2 が最初のレベルアップまで合格する |
| S7 | 描画と補間：MultiMesh、レイヤー、カメラ、軽量画質の地形 | Sonnet | §9.4 を確認できる（可能な範囲） |
| S8 | UI と入力：HUD、仮想スティック、各画面、簡略版レベルアップ、W4 での終了 | Sonnet | §9.3 が合格する |
| S9 | 性能計測、APK 出力、報告書（`godot/TEST_REPORT.md`） | Sonnet（Opus が報告をレビュー） | §5.5 を計測し、APK を出力・検証する |

- 各手順の終わりに、Opus が差分をレビューしてからコミット・pushする。
- サブエージェントには、作業範囲外のファイル（特に `webview-fg4/`）を変更させない。

## 12. リスクと対策

| リスク | 影響 | 対策 |
| --- | --- | --- |
| 移植量が大きい（約1,550関数、DOM UI、音声） | 全機能そろうまでに長くかかる | 縦切りで進め、M2 以降で段階的に追加する（§13） |
| GDScript の実行速度【推測】 | 大量配置の場面で更新が遅れる | 1. 型付けと PackedArray で最適化する<br>2. それでも足りなければ、よく使う処理だけ C++（GDExtension、Android NDK が必要）へ移す。移す前に相談する |
| 浮動小数の違い（三角関数）【推測】 | 参照トレースが長い時間で乖離する | 最初の乖離点を報告する。必要なら fdlibm を移植する |
| Gradle なしの出力に制約がある【未確認】 | min/target SDK を変えられない可能性 | S1 で確かめる。必要なら Gradle ビルドに切り替えるか相談する |
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
