# Elemental Swarm — Android fg.4

- Android版: `11.11.9-fg.4` / versionCode `1111195`
- アプリID: `com.elementalswarm.mobile`
- 対象: Android 10（API 29）以降 / target SDK 36
- 基準: 添付されたfg.3のソースZIPとAPK

fg.3の記録・補間・画像複製を軽量化した版です。ゲームの更新刻み、ダメージ、敵・弾の上限、乱数、ウェーブ条件、画質設定を維持しています。AndroidのJavaコードと権限もfg.3のままです。

## インストール

`ElementalSwarm_11.11.9_framegen4.apk` をAndroid端末で開き、インストールしてください。fg.3とアプリID・署名証明書が一致し、versionCodeを増やしています。実機での更新インストールは未確認です。ゲームのHTML・画像・音声生成処理はAPKに同梱し、プレイに通信は使用しません。

## フレーム生成

開始画面または一時停止画面の「画面設定」で切り替えます。

| 設定 | 動作 |
| --- | --- |
| OFF | 通常描画です。 |
| AUTO | 表示周期を確認し、推定90Hz以上で生成を使用します。 |
| 2x | 60Hzでも使用します。60Hzでは実30＋生成30、120Hzでは実60＋生成60を目指す構成です。 |

移動履歴とCanvas描画記録から中間画面を合成します。負荷が続く場合は通常描画に戻し、待機後に再試行します。OSが高リフレッシュレート要求を採用することや、端末での特定FPSを保証する機能ではありません。過去と現在の実フレームを使うため、表示には追加の遅延があります。DLSS 3のSDK・ニューラルモデルは使用していません。

## fg.4の最適化

- 作成後に変更しない地形・光彩・被弾点滅アトラス・属性演出Canvasを共有します。動的な光源マップや未登録のCanvasは独立したスナップショットを維持します。
- 共有画像の破棄を、保持中のフレームから参照されなくなるまで遅延します。
- 描画状態とパスを共有し、変更時にコピーする構造にしました。既に記録した描画への変更の混入を防ぎます。
- 並進だけの変換を簡単な計算で処理し、描画順・パス・対応命令の準備を再利用します。ペアの破棄時には準備した情報も破棄します。
- 12点の移動履歴を再利用し、負荷判定の分位値は必要時に算出し、同じ計測窓では結果を再利用します。判定しきい値とバックオフ条件は維持しています。
- フレーム生成UIでは同じ文字列・属性の再書き込みを避けます。

測定値と検証範囲は `TEST_REPORT.md`、生の結果は `verification/framegen/` にあります。ブラウザー上のCPU処理時間とAndroid実機のFPS・GPU性能・発熱は別の指標です。

## 再ビルド

Linux x86_64 / WSL2、Python 3.9以降、Java 17以降と `keytool` が必要です。GradleやAndroid Studioは必須ではありません。

```bash
python3 build_apk.py
```

初回は固定SHA-256で検査するAndroid SDK Build Tools 36、Platform 36、Eclipse Java Compiler 3.40.0を取得します。出力先は `dist/ElementalSwarm_11.11.9_framegen4.apk` です。`.signing/` には添付版から継続した更新用の署名鍵・設定を含めています。

HTMLを編集・再生成する場合:

```bash
npm ci
npm run build:html
```

編集対象は `frame_generation/frame-synthesis.js`、`frame_generation/frame-generation-runtime.js`、`frame_generation/build_frame_generation.cjs` です。`app/src/main/assets/index.html` は生成物です。`baseline_mobile1.html` と元ゲームの回帰用fixtureは基準として保持しています。

## テスト

```bash
npm ci
SWARM_CHROME_BINARY=/absolute/path/to/chrome-headless-shell npm test
SWARM_CHROME_BINARY=/absolute/path/to/chrome-headless-shell npm run test:performance
```

Chromiumは別途用意してください。検証環境ではChrome Headless Shell 141を使用しました。`npm test` は既存6スイートとfg.3との差分描画・演出キャッシュの追加テストを実行します。性能比較は同じブラウザーでfg.3→fg.4→fg.4→fg.3の順に、各バージョン160組、8条件を測定します。各組は新規に記録し、次の組まで `requestAnimationFrame` を待ちます。

`tests/fixtures/fg3-reference.cjs` は元の生成スクリプトとエンジンから比較用HTMLをメモリー内で再構成し、添付版HTMLのSHA-256と一致することを検査します。テスト専用APIはHTTP応答にだけ挿入し、配布HTMLには含めません。Android APIはブラウザーテストではモックです。

## patchの適用

`framegen-perf-fg4.patch` は添付fg.3のソースに適用します。生成HTML・測定結果・画像・ビルド出力はpatchから除外しています。

```bash
cd ElementalSwarmAndroid_fg3
patch -p1 < ../framegen-perf-fg4.patch
npm ci
npm run build:html
python3 build_apk.py
```

適用後に再生成したHTMLとfg.4のHTMLがバイト単位で一致することを確認しています。

## 未確認の範囲

Android実機・エミュレーターでのインストール、WebViewの実FPS、入力遅延、GPU時間、温度、消費電力、長時間の熱による性能低下は未測定です。実機のファイル選択画面、画面端の余白、バックグラウンド復帰も追加確認が必要です。

