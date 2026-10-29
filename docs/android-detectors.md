# Android検出器プレビュー

撮影した写真・システムの写真選択で開いた画像から、顔・人物・画面・文字を自動検出し、写真上の枠タップで黒塗りを選択・解除できる。YOLO26sとPP-OCRv5をAPKに同梱し、初回の追加モデル取得は不要。

通常の編集フローからGemmaの説明・取得画面を外した。過去のGemma検証用コード・依存は残している。今回のAPKは検出結果を範囲候補として使い、投稿可否を判定しない。

## ビルド・インストール

Android 11以上・ARM64向け。Flutter/JDKは `mise.toml` の固定版を使用する。

```sh
mise run detector-apk
# USBデバッグを許可した端末を接続
adb devices
mise run detector-install -- <device-id>
```

生成物:

- `dist/camereon-detector-arm64.apk`
- `dist/camereon-detector-arm64.apk.sha256`

アプリ表示名は `camereon detector`、IDは `dev.camereon.camereon.demo.detector_preview`。ローカルのdebug鍵でRelease署名する。既存beta/demoとは別IDなので並べてインストールできる。同じ開発機の鍵なら次回も上書き更新できる。ベータ公開用の署名構成と同時には選択できない。

ビルド済みAPKは `adb -s <device-id> install -r dist/camereon-detector-arm64.apk` でも導入できる。インストール先端末の承認表示が出た場合は端末で操作する。

### Debug版

```sh
mise run detector-debug-install -- <device-id>
# 起動中のDebug版へ接続（ブレークポイント・ホットリロード）
mise exec -- flutter attach -d <device-id> --app-id dev.camereon.camereon.demo.detector_preview
```

Debug版は毎回ビルドして上書きする。生成物は `dist/camereon-detector-debug-arm64.apk` とチェックサム。Release版と同じプレビューID・ローカル鍵なので、アプリ内データを保持して切り替えられる。`android:debuggable=true` のAPKを生成し、Release APKとは別名で保持する。

VS Codeでは `camereon detector (debug)` を選んで起動できる。既に起動している場合は `Attach to camereon detector` を選ぶ。Kotlin側はAndroid Studioの「Attach debugger to Android process」から `dev.camereon.camereon.demo.detector_preview` へ接続する。

2026-10-27、Debug APKをARM64エミュレーターへ上書きして起動し、APKとインストール先のDEBUGGABLEフラグ、`run-as`、JDWP、FlutterのVM接続とホットリロード成功を確認した。CLIは接続解除し、アプリを起動したまま保持した。Debug APKは213,053,148 bytes。詳細は[Debug導入の確認記録](evaluation-evidence/2026-10-27-detectors/android-debug-deployment.json)に残す。

## 使い方

1. 起動画面で撮影するか「写真を選ぶ」で画像を開く。カメラの許可を与えなくても写真選択・サンプル編集は利用できる。
2. 写真を大きく表示し、顔・文字・人物・画面を自動検出する。検出中は光のシートが写真を走り、候補の枠が現れる。アニメーションを減らす設定では光の移動と枠の登場アニメーションを停止する。
3. 枠をタップして黒塗り、もう一度タップして解除する。手動ドラッグや番号一覧はなく、下のガラス調バーで「すべて／顔だけ」と取り消しを操作する。完全に重なる枠だけ選択メニューを表示する。検出に失敗した場合は上のステータスから再試行できる。
4. 顔だけを隠すなら「顔だけ」→顔枠をタップする。表示切替でも適用済みの黒塗りは保持する。人物の輪郭に沿ってPCを残す機能は未実装（[必要なモデルと保存処理](detection-integration.md)）。
5. 矢印から保存前の画像を確認し、「写真に保存」。元写真は上書きしない。

写真選択はAndroidの `ACTION_OPEN_DOCUMENT` を使用し、選択した1画像の読み取りだけを許可してもらう。ライブラリ全体の読み取り権限・永続URI権限は取得しない。選択データは最大32MiB、既存の画像処理側でも画素数を検査する。キャンセルは通常画面へ戻す。

## 実装

- 共通型: `CandidateKind.person / screen / text`、`RegionCandidate`、`HideRegion`。
- Flutterから長辺1600px以下の正規化済みPNGを渡し、Androidのバックグラウンドスレッドで推論する。UIスレッドでモデルを実行しない。
- 640pxと1280pxでアスペクト比を保つletterbox（RGB、114埋め、stride32）を使う。動的形状ONNX、出力 `[1,300,6]`、xyxy・confidence・class ID。confidence 0.25、対象クラス0/62/63/67、2解像度間の同じクラスの重複をIoU 0.7で除く。
- モデルロード・SHA-256検証・2回の推論後にsession/tensor/bitmapを解放。最大200候補。SDKの型や文字列はFlutterへ返さない。
- 元写真の座標へ戻し、範囲を外側へ丸めて既存の候補UI・JPEG生成・MediaStore保存へ渡す。再試行でも他の種類の候補・選択履歴を保持する。
- 新しい物体検出にネットワークコードはない。通常の検出・編集にGemmaのモデルは不要。

モデルは `android/app/src/main/assets/object_detection/` に同梱。配布元、元重みのSHA-256、変換パラメーター、ONNXのSHA-256と容量は `model.json` に記録。YOLOのAGPL-3.0全文も同じディレクトリに含める。推論ランタイムは既存のONNX Runtime Android 1.24.3を共用する。

元重みから変換し直す場合:

```sh
uv pip install --python /private/tmp/camereon-detector-venv/bin/python -r tools/detector-eval/requirements-export.txt
/private/tmp/camereon-detector-venv/bin/python tools/detector-eval/export_android.py .private/detector-eval/models/yolo26s.pt
```

変換スクリプトは元重みのハッシュと変換器バージョンを検査し、出力の動的入力・shapeを実行確認する。ONNXメタデータの日時などで変換後のハッシュは変わるため、生成物とmanifestを一緒に更新する。

## 検証

2026-10-27、Android 12 / API31 / ARM64エミュレーターで、同梱ONNXを実行した。端末には画像をAPKと別に配置し、実写や読み取った文字はGitに追加していない。

静的解析・format・unit/widget全108件、Androidの無地画像と実写3枚の結合2件が成功。Release APKは122,997,811 bytes（約123MB）。APK署名、モデルのSHA-256一致、ARM64以外のJNI混入がないことを確認し、エミュレーターへインストールした。[検証JSON](evaluation-evidence/2026-10-27-detectors/android-deployment.json)に容量・ハッシュ・確認項目を記録する。

通常起動したRelease版でも、システムの写真選択から画像3を開き、人物・画面候補4件の表示、画面候補1件の選択、確認、ギャラリーへの保存成功表示まで確認した。候補の数は画像リサイズ等でも変化し、正しく見つけた個人情報の数ではない。実写を含むスクリーンショットは `.private/android-deployment/` に保持する。

- 無地画像で候補0件を確認。
- 提供画像1で人物2件以上とスマホの範囲を確認。
- 画像2で画面3件以上、画像3でテレビの範囲を確認。
- 各候補が元画像の範囲内にあることを確認。
- 画像3で実際の編集UIから再検出・全適用・確認・MediaStore保存・一時元画像削除まで成功。

再実行（端末が複数ある場合は対象IDを指定する）:

```sh
CAMEREON_DETECTOR_PREVIEW=1 mise exec -- flutter test integration_test/object_regions_device_test.dart -d <device-id>
```

実写3枚の任意テストは、上のコマンドに `--dart-define=RUN_PRIVATE_DETECTOR_TESTS=true` を付ける。インストール後、別ターミナルで以下を実行するとdebugアプリ専用領域へ3枚を配置する。テスト終了時に入力ファイルを削除する。

```sh
python3 tools/detector-eval/stage_android.py \
  .private/detector-eval/input/photo-1.png \
  .private/detector-eval/input/photo-2.png \
  .private/detector-eval/input/photo-3.png \
  --serial <device-id>
```

実機の速度・消費電力は未測定。小さな写真・書類、ぼけた文字、画面の境界には見落とし・余分な範囲がある。[実写の検出評価](detector-evaluation.md)を参照。モデルの容量だけをAPK増分として扱わない。
