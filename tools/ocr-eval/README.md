# PaddleOCR の Android 評価

PaddleOCR 公式の Android SDK を使い、接続した Android 端末で日本語画像の認識結果と処理時間を測る。
結果のまとめは [docs/ocr-evaluation.md](../../docs/ocr-evaluation.md)。

アプリ本体には組み込んでいない。モデルと SDK は実行時に取得し、リポジトリには含めない。

## 必要なもの

- macOS（テスト画像の描画にヒラギノフォントを使う）
- Python 3 と Pillow
- Android SDK、`adb`、[mise](https://mise.jdx.dev/)（JDK 21 を自動で入れる）
- 起動済みの Android Emulator、または USB デバッグを有効にした実機（arm64、Android 8.0 以上）

## 実行する

```sh
# 端末が複数つながっている場合は ANDROID_SERIAL で指定する
ANDROID_SERIAL=<device-id> bash tools/ocr-eval/run.sh
```

作業ディレクトリは `$TMPDIR/camereon-ocr-eval`（`OCR_EVAL_DIR` で変更可）。
初回は SDK・モデル（約 60MB）・Gradle の依存を取得するため時間がかかる。
結果は作業ディレクトリの `result-<端末名>-<日時>.txt` に保存される。

スクリプトは次の順に進む。

1. PaddleOCR の `deploy/ppocr-android` を固定コミットで取得し、OpenCV を公式の Maven 版に差し替える
2. PP-OCRv6 small / tiny、PP-OCRv5 mobile の ONNX モデルを取得し、SHA-256 を確認する
3. 架空の個人情報を描いたテスト画像を作る（`make_images.py`）
4. 評価用の instrumented test（`CamereonEvalTest.kt`）を入れたテスト APK をビルドしてインストールする
5. 検出前の縮小なし・長辺 960px の 2 通りで実行し、ログを集める

## 結果の読み方

```
[EVAL] model=PP-OCRv6_small image=2_address_label.jpg lines=4 medianMs total=304 det=203 rec=98
[EVAL]   0.94 "〒150-0002" box=(182,489)-(488,561)
```

- `lines`: 検出した行数
- `medianMs`: 5 回の中央値（ミリ秒）。`det` は検出、`rec` は認識
- 各行: 認識スコア、読んだ文字、検出枠（左上と右下の画素座標）

エミュレーターで RAM 2GB だと、縮小なしの v6 small でメモリ不足になり落ちることがある。
その場合はエミュレーターを `-memory 6144` で起動する。
