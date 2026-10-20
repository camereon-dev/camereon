# Gemma 4 E2B / SmolVLM2 の Android 画像入力検証

関連: [#23](https://github.com/camereon-dev/camereon/issues/23)、[全体の設計](../../docs/ai-analysis-design.md)。

モデルのロードと、画像そのものを渡した応答を確認する独立した評価アプリ。
リスクの分類・スコアリング・自動加工は [後続タスク #24](https://github.com/camereon-dev/camereon/issues/24) で検討する。
本体アプリの pubspec・minSdk・撮影画面は変更しない。

## 必要なもの

- リポジトリと同じ Flutter 3.47.7 / Dart 3.13.5、JDK、Android SDK
- Android 11（API 30）以上・ARM64 の実機、USB デバッグと接続の許可
- Python 3、Pillow（`requirements.txt`。架空の評価画像の描画用）
- モデル保存領域（Gemma 4 約 2.59 GB / SmolVLM2 約 361 MB。ホストと端末の両方に必要）

`flutter_gemma` の現行後継 `flutter_edge_ai 2.4.1` と、`flutter_edge_ai_litertlm 1.15.0` を固定する。
ネイティブライブラリはパッケージのビルドフックが取得・検証する。初回ビルドにはネットワークが必要。

## 1. モデルを入手する

Gemma 4 E2B を主候補、SmolVLM2 500M を軽量比較用にする。Gemma 3n は今回の検証から外した。
公開配布はいずれも認証不要で、配布メタデータのライセンスは Apache-2.0。

| 候補 (`--candidate`) | 固定情報 | ファイル | 容量 |
| --- | --- | --- | --- |
| `gemma4`（既定） | [model.json](model.json) | `gemma-4-E2B-it.litertlm` | 2,588,147,712 bytes |
| `smolvlm2` | [smolvlm2.json](smolvlm2.json) | `SmolVLM2-500M.litertlm` | 360,822,960 bytes |

`--fetch-model` を付けると、選択したモデルの固定リビジョンを Mac 側にダウンロードし、サイズ・SHA-256 を照合する。
取得先は `$VLM_EVAL_DIR/models/`（既定 `/private/tmp/camereon-vlm-eval/models/`）。モデルの取得は端末内の画像送信とは無関係で、評価 APK にはネットワーク権限を付けない。
別途取得したファイルがある場合は `--fetch-model` の代わりに `--model /path/to/model.litertlm` を指定する。
Web 用や別の量子化・変換版は受け付けない。容量と実行時 RAM は別に測定する。

参照: [Gemma 4 配布](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)、[SmolVLM2 配布](https://huggingface.co/litert-community/SmolVLM2-500M)。

## 2. APK を準備する

リポジトリのルートで実行する。

```sh
python3 -m venv /private/tmp/camereon-vlm-venv
/private/tmp/camereon-vlm-venv/bin/python -m pip install -r tools/vlm-eval/requirements.txt
source /private/tmp/camereon-vlm-venv/bin/activate
python3 tools/vlm-eval/run.py --prepare
```

実機やモデルがなくてもビルドできる。生成先は `/private/tmp/camereon-vlm-eval/app/`。
`VLM_EVAL_DIR` で作業ディレクトリを変更できる。生成アプリは `camereon_vlm_eval`、applicationId は `dev.camereon.camereon_vlm_eval`。

- 初回は `flutter create` で Android アプリを生成する。
- `pubspec.yaml.template`・`main.dart.template`・`evaluator.dart.template` を生成アプリの依存定義と Dart ソースとして配置する。
- テンプレート形式なのは、本体の静的解析・依存解決に実験用 SDK や、生成先だけにある assets を混ぜないため。
- `pubspec.lock` を使って依存を固定し、API 30・ARM64 用の debug APK をビルドする。
- 評価 APK からネットワーク権限を除去し、完成 APK でも権限を確認する。

APK: `/private/tmp/camereon-vlm-eval/app/build/app/outputs/flutter-apk/app-debug.apk`

## 3. 実機で実行する

```sh
adb devices -l
python3 tools/vlm-eval/run.py \
  --serial <device-id> \
  --candidate gemma4 --fetch-model --with-ocr --repeats 2
```

モデルは Android のアプリ専用領域へストリーム転送し、Mac 側と端末側の両方で SHA-256 を照合する。
同じモデルがすでにある場合は再転送しない。検証用アプリを削除すると、端末側のモデルと結果も消える。
モデル・APK・作業領域が入る空き容量を確保する。
初回 CPU 推論ではモデル本体のほかに Gemma 4 約 963 MiB、SmolVLM2 約 291 MiB のキャッシュが増えた。
転送前の空き容量チェックは、モデル容量に加えて Gemma 4 は 2 GiB、SmolVLM2 は 1 GiB の作業領域を見込む。キャッシュや OS の要件は環境で変わる。
複数モデルを比較する場合は未使用モデルのコピー・キャッシュを削除するか、十分な空き領域を持つ端末を使う。

既存 APK で再測定する場合:

```sh
python3 tools/vlm-eval/run.py --skip-build \
  --serial <device-id> --model /path/to/model.litertlm --repeats 3
```

`--skip-build` は APK とソースのハッシュが準備時と同じ場合だけ利用できる。
`ANDROID_SERIAL` と `GEMMA_MODEL` 環境変数でも指定できる。
SmolVLM2 は `--candidate smolvlm2 --fetch-model` で選ぶ。質問は既定で英語、`--language ja` で日本語。出力上限は `--max-output-tokens`（既定 160）。
CPU と比較する場合は `--backend cpu`。GPU を要求しても CPU に切り替わる場合があるため、結果の実際のバックエンドを必ず確認する。

1 回の実行は最大 900 秒（`--timeout` で変更）。時間超過・終了時はこの評価アプリだけを停止する。

今回の短い質問での比較を追試する場合（両方を保持するにはモデル・キャッシュ分の容量が必要）:

```sh
python3 tools/vlm-eval/run.py --serial <device-id> \
  --candidate gemma4 --fetch-model --backend cpu \
  --only-image parcel_label_ja --with-ocr
python3 tools/vlm-eval/run.py --skip-build --serial <device-id> \
  --candidate smolvlm2 --fetch-model --backend cpu \
  --only-image parcel_label_ja --with-ocr
```

実機では別途 `--backend gpu` でも実行する。性能値と誤りを含む今回の結果は [検証記録](../../docs/gemma-evaluation.md) を参照する。

## 4. 比較するケース

すべて同じ質問を使い、ケースごとに会話をリセットする。

1. 画像なし: 対照。`NO_IMAGE` と答えるよう指示している。
2. 赤い円: 1 つの赤い円がある画像。
3. 青い図形: 3 本の青い縦長の長方形がある画像。
4. 架空の荷物ラベル: 茶色の箱に、架空の名前・住所の白いラベルがある画像。
5. 日本語の架空荷札: 名前・住所・電話番号を含む。`fixtures/parcel_ja.png` と正解データをリポジトリに含む。

2〜5 を `--repeats` 回実行する。評価画像は Pillow で描画した独自の合成画像で、実在の個人情報を含まない。
画像名や正解文はプロンプトに渡さず、実際の PNG バイト列を `Message.withImage` で渡す。

`--with-ocr` は、日本語荷札に固定の文字列・位置・ブロック ID を与えたケースも追加する。これは **PaddleOCR の実行結果ではなく、正解を用意した OCR 入力**。質問は各ブロックの意味を英語で短く答える形式で、文字列のコピーやリスク評価は求めない。VLM が日本語の文字列と画像を関連付けられるかを切り分けるために使う。OCR の誤読・読み落としを含む結合評価は後続で行う。

日本語荷札だけを比較する場合は `--only-image parcel_label_ja --with-ocr`。画像なし対照は残る。初期の長い説明を求めた質問とは出力を分け、結果 JSON に各ケースの実際の質問を保存する。

これは画像入力の成立を確かめる最初の対照実験。合成画像で動いたことだけで、日常写真の認識精度を確認済みとはしない。
実写画像も確認する場合は、1〜10 枚の JPEG/PNG/WebP が入ったフォルダを指定する。

```sh
python3 tools/vlm-eval/run.py --skip-build \
  --serial <device-id> --model /path/to/model.litertlm \
  --images /path/to/private-photos
```

実写は EXIF の向きを反映し、長辺 1024px 以下・メタデータなしの JPEG にして端末の専用領域へ転送する。
APK には埋め込まない。終了時には端末側の入力コピーを削除する。元画像は変更しない。
Mac 側の結果フォルダ `private-images/` には実際に入力した画像が残るため、認識全文を含む結果とともに非公開で扱い、不要になったら削除する。

## 5. 結果

`/private/tmp/camereon-vlm-eval/results/<実施日時>/` に保存する。

| ファイル | 内容 |
| --- | --- |
| `environment.json` | 実機/エミュレーター、端末、OS、RAM、SDK・モデル・ソース・APK の識別情報、評価画像と正解 |
| `eval-config.json` | 使用モデル、要求したバックエンド、繰り返し回数 |
| `result.json` | モデルロード時間、実際のテキスト/画像バックエンド、ケースごとの出力と時間、RSS、失敗時の段階 |
| `memory.txt` | 実行中の `dumpsys meminfo` 記録 |

時間は、モデルロード・セッション作成・画像入力・最初のテキスト出力・推論完了を分ける。
初回ロードには端末のキャッシュ状態などの影響がある。再実行と同じ条件とは扱わない。
今回は debug ビルドでの成立確認であり、製品版の性能値ではない。RSS/PSS だけで GPU の全使用メモリを測れるわけではない。

終了状態 `completed` は推論 API が実行されて空でない出力を得たことを示す。
意味が正しいかは `semantic_review: pending` のまま残し、画像と照合して別途記録する。リスク評価の正しさは測っていない。
モデル未配置、画像入力失敗、プロセス終了、時間超過は成功として扱わない。

## 実写画像と保存の注意

この初期ツールの公開・保存対象は合成画像の結果。通常の撮影画像を評価するときは、画像と認識全文を公開ログ・Git・Issue に含めない。
結果ディレクトリやモデルファイルはコミットしない。合成画像の結果だけを確認して `docs/evaluation-evidence/` に抜き出すことは可能。

参照: [Flutter パッケージ](https://pub.dev/packages/flutter_edge_ai)、[LiteRT-LM の Android 画像入力](https://developers.google.com/edge/litert-lm/android)。
