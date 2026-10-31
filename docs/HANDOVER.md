# 引き継ぎ書：Elemental Swarm の Godot 移植

- 作成日：2026-10-24（C1 完了時点）。2026-10-31 に C2 完了時点の内容に更新
- 対象ブランチ：`claude/directx-game-engine-refactor-255pfv`
- 詳細な設計と決定の経緯：[`docs/godot-port-design.md`](godot-port-design.md)。本書はその要約と、作業を続けるための手順をまとめたものである。

## 1. 現状の要約

- Android の WebView 版ゲーム（fg.4、Canvas2D とフレーム生成）を、Godot 4.7.2 のゲームエンジン方式に作り直している。
- 最初の到達点（M1）は縦切りの試作である。範囲は次のとおり。
  - キャラは catalyst、ウェーブは W1〜W4、敵は swarm と assassin
  - 武器は catalytic_ring と pulse・blades・wand
- 戦闘処理は、元のゲームと**乱数の使用回数と座標がビット単位で一致すること**を、元ゲームの実行記録（参照トレース）との照合で確かめながら移植している。
- S5 までの戦闘処理は GDScript で書いた。性能が不足したため、戦闘処理全体を C++（GDExtension）へ移す方針に切り替えた。C1 でそのビルド環境が整い、C2 で数学関数と乱数を C++ に移した。
- **次の作業は C3**（S3〜S5 の戦闘処理を C++ に移す）である。§7 を参照。

## 2. 決定事項（ユーザーの判断）

| 日付 | 決定 |
| --- | --- |
| 2026-10-19 | 既製エンジンへ移植する（Godot 4.7.2、GDScript、Compatibility レンダラー）。アプリIDは別の `com.elementalswarm.engine` |
| 2026-10-19 | fg.4 のソースは `webview-fg4/` に参照用としてそのまま残す。署名鍵はリポジトリに入れない |
| 2026-10-19 | M1 は縦切りの試作とする |
| 2026-10-19 | 画面の向きは fullUser でよい（端末の回転ロックに従う） |
| 2026-10-19 | モデル分担：Opus は全体設計と最終判断、Sonnet は中核の実装、Haiku は並列の下請け作業 |
| 2026-10-24 | **戦闘処理全体を C++（GDExtension）に移す**（案A）。GDScript には表示と UI だけを残す |
| 2026-10-24 | sin/cos の移植元（glibc、LGPL-2.1以降）は当面そのまま使う。配布方針と一緒に S9 で決める |
| 2026-10-25 | C2：qemu は版とハッシュを固定して `setup_cpp.sh` で入れる。LGPL の sin/cos は別ディレクトリの静的ライブラリにする。C++ は GDScript 版の写しとする。`test_js_math.gd`・`test_rng.gd` は C++ 版だけを試験する。仕様書はリポジトリに入れる |
| 2026-10-25 | C2：わざと誤りを入れて検出を確かめる検証は行わない。`js_compat.gd` に著作権表示がない件は記録だけ |

## 3. 進捗

| 手順 | 内容 | 状態 | コミット |
| --- | --- | --- | --- |
| S1 | Godot 環境、雛形、デバッグ版 APK の書き出し | 完了 | `6b582df` |
| S2 | 画像14枚と配置データの抽出（元とバイト一致） | 完了 | `6a6c253` |
| S3 | 戦闘処理の土台（V8 と一致する数学関数、乱数、定義データ、実行順、移動、カメラ） | 完了 | `8fbf70c` |
| S4 | 参照トレースの採取ツール、比較ツール | 完了 | `59247d8` |
| S5 | 敵とウェーブ（出現の指揮、AI、接触ダメージ）。7本のトレースと全ステップ一致 | 完了 | `b13a389` |
| C1 | C++ ビルド環境（NDK、godot-cpp、SCons、決定性の検査） | 完了 | `05a4123` |
| C2 | 数学関数と乱数を C++ に移す（qemu の導入 `79b59f0`、仕様書 `403f51a`） | 完了 | 本書を更新したコミット |
| C3 | S3〜S5 の戦闘処理を C++ に移し、7本のトレースで照合する | **次** | — |
| S6 | 武器・弾・ダメージ・経験値（C++ で移植） | 未着手 | — |
| S7 | 描画と補間（MultiMesh、レイヤー、地形） | 未着手 | — |
| S8 | UI と入力（HUD、仮想スティック、画面、簡略版レベルアップ） | 未着手 | — |
| S9 | 性能計測、配布用 APK、報告書、ライセンスと署名の決定 | 未着手 | — |

各手順の検証記録は `verification/godot/<手順>/` にある。

## 4. リポジトリ構成

```
webview-fg4/           元の fg.4 一式（変更禁止）。tests/fixtures/original.html が移植の基準
docs/                  設計書（godot-port-design.md）と本書
godot/                 Godot プロジェクト
  sim/                 戦闘処理（GDScript、57ファイル）。C3 で C++ に置き換える
    defs/              元ゲームから抽出した定義データ（JSON）
    systems/           システム（元の UPDATE_*_SYSTEMS に対応）
  render/              描画（現時点では atlas_layout.gd だけ）
  assets/atlas/        元ゲームから抽出した WebP 14枚と配置データ
  tests/               ヘッドレステスト、正解値（golden/）、参照トレース（reference/）、照合用コード（trace/）、性能計測（bench/）
  swarm_native.gdextension   C++ 拡張の定義
native/                C++ 拡張のソース（SConstruct、build_profile.json）
  src/sim/             Godot に依存しない C++17 の戦闘処理（C2：JsMath と乱数）
  src/bindings/        Godot との受け渡し（SwarmJsMath、SwarmSeededRng、SwarmGameRng、SwarmFxRng）
  third_party/glibc_sincos/  LGPL の sin/cos（静的ライブラリ。由来とライセンスは README.md）
  tests/               C++ 単体テスト（swarm_sim_tests。正解値をビット単位で照合する）
tools/                 セットアップ、ビルド、抽出、正解値生成、トレース採取・比較のスクリプト
verification/godot/    各手順の検証記録
export/                APK の出力先（Git 管理外）
```

## 5. 環境構築と主なコマンド

作業環境は使い捨てのコンテナである。キャッシュ（`~/.cache/elemental-swarm-engine`）は新しいセッションでは消えるので、最初に作り直す。

```bash
tools/setup_godot.sh    # Godot 4.7.2、Android テンプレート、build-tools、platform-tools、デバッグ鍵（約1.4GB を取得）
tools/setup_cpp.sh      # NDK r28b（約720MB、展開後2.2GB）、godot-cpp、SCons、qemu-user（ARM のテスト用）。テストだけなら --host-only
```

| 目的 | コマンド | 所要時間の目安 |
| --- | --- | --- |
| 全テスト（抽出データと正解値の照合、C++ の PC 向けビルドと単体テスト、Godot テスト213件） | `tools/run_godot_tests.sh` | 約2分30秒 |
| C++ 拡張のビルドと単体テスト（全6種。ARM は qemu で実行） | `tools/build_native.sh`（PC 向けだけなら `--host-only --debug-only`） | 約1〜2分 |
| デバッグ版 APK の書き出しと検査 | `tools/build_android.sh --skip-tests` | 約30秒 |
| 元ゲームの参照トレースの採取 | `node tools/reference-trace/capture.mjs --script dirs8 --seed 424242 --out <file>`（先に `tools/reference-trace` で `npm ci` が必要） | — |
| 移植版のトレースの出力 | `tools/emit_port_trace.sh <参照トレース> <出力> --oracle` | — |
| トレースの比較 | `node tools/compare_trace.mjs <参照> <移植版> --fields ... --ignore ...`（S5 の比較条件は `verification/godot/s5/traces.txt` にある） | — |
| 性能計測 | `tools/bench_sim.sh` | — |
| 正解値と Chromium の照合 | `node tools/verify_golden_chromium.mjs` | — |

- Godot は必ず `source tools/lib/toolchain.sh` のあと `swarm_godot` 経由で起動する。設定やデータをキャッシュ内に閉じ込め、adb も専用ポートで動かすためである。
- Chromium 141 は `/opt/pw-browsers/chromium-1194/` に入っている。Playwright 1.62.1 は `tools/reference-trace/package-lock.json` で固定している。

## 6. 検証の仕組み

1. **正解値**（`godot/tests/golden/`）：元ゲームの関数を `node:vm` で切り出して実行した結果である。浮動小数はビット列で保存する。
   - sin/cos は Node 22 と Chromium で結果が違うため、Chromium 141 で照合した。
   - `tools/check_generated.sh` が、元ゲームから作り直した値とのずれを毎回検査する。
2. **参照トレース**（`godot/tests/reference/`、7本）：元ゲームを Android 相当の設定で1ステップずつ動かし、状態と「どのシステムが乱数を何回使ったか」を記録したものである。形式は `tools/reference-trace/FORMAT.md` にある。
3. **照合補助（テスト専用）**：未移植の処理の影響を、参照トレースの記録で補う仕組みである。`godot/tests/trace/replay_oracle.gd` にある。
   - 現在補っているのは、projectile/player の乱数の空引きと、撃破の強制である。
   - 配布版からは使えないことをテストで確かめている。S6 で不要になる。
4. **ソース規則の検査**：`test_sim_source_rules.gd` は、sim 内で Godot 組み込みの数学関数・時刻・float32 を使っていないことを検査する。C++ 側は `native/SConstruct` と `tools/build_native.sh` が次を検査する。
   - コンパイラー設定（許可リスト）
   - 融合命令（FMA）がないこと
   - 依存ライブラリと 16KiB 境界
   - 絶対パスが埋め込まれていないこと
   - ソース規則（`tools/check_native_sources.py`：float、long、std::sort、スレッド、fma、pragma、Godot の include などの禁止。ライセンス本文のハッシュ）
5. **C++ 単体テスト**（C2）：`swarm_sim_tests` が全6構成で `math.json`・`rng.json` をビット単位で照合する。`build_native.sh` が毎回実行する。C++ の定数と表は `tools/check_js_compat_consts.mjs` が上流の値・GDScript 版と照合する。

## 7. 次の作業：C3（戦闘処理の C++ 化）

C2 の結果（詳細は `verification/godot/c2/`）：

- `JsMath` と `SeededRng` / `GameRng` / `FxRng` を、GDScript 版の写しとして C++ に移した（`native/src/sim/`、`native/third_party/glibc_sincos/`）。
- 全6構成で、正解値と 519,631 件すべてが一致した（ARM は qemu）。Godot テストは 213 件すべて合格した。
- C++ 版の速さ（PC、配布用の設定）：sin 約19ns、atan2 約15ns、exp 約9ns、乱数1回 約2ns。GDScript 版の sin は約0.8〜1.0µs である（`bench.txt`）。

C3 では次を行う。

1. `godot/sim/` の GDScript（約1万行）を `native/src/sim/` の C++ に移す。数学関数と乱数は C2 のもの（`swarm::sim::js::`、`GameRng`）を使う。
2. GDScript との受け渡しは `native/src/bindings/` に置く。値は PackedFloat64Array / PackedInt64Array で受け渡す。
3. 7本の参照トレースと正解値をそのまま使って照合する。照合の仕組み（`godot/tests/trace/`）を C++ 版に向ける。
4. `tools/bench_sim.sh` で性能を再計測する（目標：敵100体で1ステップ4ms以下）。
5. 移し終えたら、GDScript 版の戦闘処理と `js_compat.gd`・乱数3ファイルを削除する（表示と UI だけを GDScript に残す）。
6. 守る規則は設計書 §11 と `tools/check_native_sources.py` のとおり。戦闘処理の開始時に `fp_environment_ok` を呼ぶ。

## 8. 既知の問題・リスク・未確認事項

| 項目 | 内容 | 対応時期 |
| --- | --- | --- |
| 性能 | GDScript 版は敵100体で1ステップ 5〜6.5ms（配布用テンプレート、PC）。目標は4ms。原因は GDScript の処理の重さである。C2 で数学関数と乱数は C++ になったが、戦闘処理はまだ GDScript 版を使う | C3 で C++ 化し、再計測する |
| 実機未確認 | Android 端末でのインストール、起動、ビット一致、速度は一度も確かめていない | S9（端末が必要） |
| ライセンス | sin/cos は LGPL-2.1以降で、C2 から静的ライブラリとして拡張に組み込んでいる。静的リンクで配布するなら、再リンクできるようにする義務がある（LGPL §6）。配布用の APK は作っていない | S9 で配布方針と一緒に決める（`native/THIRD_PARTY_NOTICES.md`） |
| ライセンス表示の欠落 | 【事実】`godot/sim/js_compat.gd` には glibc と fdlibm の著作権表示がない（ユーザー判断で記録だけ） | C3 で GDScript 版を消す |
| GDScript 版の数学関数の照合 | C2 から `test_js_math.gd`・`test_rng.gd` は C++ 版だけを試験する（ユーザー判断）。GDScript 版は参照トレースの照合で間接的に守られる | C3 で GDScript 版を消す |
| qemu の限界 | ARM での一致は qemu-user で確かめた。実機の FPU の設定（flush-to-zero など）は確かめていない | S9（端末が必要） |
| 署名 | デバッグ用の使い捨て鍵だけを使っている。配布用の鍵は未作成である | S9（ユーザーの確認を取ってから作る） |
| Godot 4.7.2 の不具合 | 作業ツリーを新しく取り出した直後の初回の取り込みで、C++ 拡張を読み込むと異常終了する。`tools/lib/godot_project.sh` の回避策で防いでいる | 回避済み |
| provider の重複 | Gradle なしの書き出しで、2つの provider が同じ authority を持つ。端末での影響は未確認で、ビルド時に警告を出している | 実機確認時 |
| godot-cpp | 正式な版のタグがない master のコミットに固定している | v10 のタグが出たら移行する |
| Linux 版の C++ ライブラリ | glibc 2.38 以上が必要。PC でのテスト専用で、配布はしない | 必要になったら |
| 大きなテクスチャ | `signature_fx.webp` は 512×2944 である。OpenGL ES 3.0 で保証される最大サイズ（2048）を超える | S7 |
| 粒子の数 | 粒子が1,100個以上になると、ダメージ数字の表示が乱数を引かなくなる。そのため、元と同じ数を保つ必要がある | S7 |
| W4 の照合 | W4 は、コミットしていない 8,640 ステップのトレースでしか確かめていない | S6 でハッシュ等を用いてコミットする |
| 分析資料 | S5 までの分析仕様は一時領域にしかなく、消えている。移植済みの GDScript と設計書がその代わりになる。C2 からは仕様書をリポジトリに入れている（`verification/godot/c2/spec.md`） | — |

## 9. 作業の進め方（これまでの方式）

- 各手順の前後でユーザーの確認を取る。ファイルや資料を作る前にも確認する。
- 各手順の仕様書は `verification/godot/<手順>/spec.md` としてリポジトリに入れる（C2 から）。
- 手順は次の流れで進め、合格するまで修正とレビューを繰り返す。
  1. 分析（Opus）
  2. 実装（Sonnet）
  3. 検証（Haiku）：テストと照合の再実行、わざと誤りを入れて検出できるかの確認（C2 では、ユーザーの判断で再実行だけを行った）
  4. レビュー（Opus）
  5. 修正（Sonnet）
- コミットは、最終確認（テストと APK 検査の再実行）のあと、オーケストレーター（Opus）が行う。サブエージェントには git の書き込み操作をさせない。
- `webview-fg4/` は変更しない。元ゲームのスクリプト（npm/python/ビルド）は実行しない。
- 報告は「実施内容」「確認済み」「未確認・残課題」に分ける。事実・推測・未確認を区別して書く。
