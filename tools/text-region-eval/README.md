# 文字領域だけの検出・比較

Issue #14。比較結果・採用理由・ライセンスは [docs/text-region-detection.md](../../docs/text-region-detection.md)。

- 本体: PP-OCRv5 mobile **det** + ONNX Runtime。認識モデル・辞書・文字列出力なし。
- 比較用: `edge_density_detector.dart`。長辺960px、24pxタイルの水平/垂直エッジ密度をまとめる簡易方式。本体からは参照しない。
- 同じ7画像（配送ラベル、1280px版、90度回転、低コントラスト、合成書類、無地、文字なし模様）で各4回。初回と後続3回の中央値を分ける。
- 正解枠と予測枠の一対一対応、IoU >= 0.3。TP / FP / FNを出力する。小規模な合成画像の検証であり実写全般の精度ではない。

## 再実行

```sh
flutter test integration_test/text_regions_device_test.dart -d <android-device-id> --reporter expanded
```

`TEXT_REGION_EVAL` で始まるJSONが比較結果。画像・認識文字列はログに出さない。
後半は実際のネイティブ検出→編集画面→全候補適用→JPEG保存・EXIF除去まで確認する。端末の写真に架空画像を1枚保存する。

オフラインの再確認では、端末のWi-Fi・モバイルデータを切ってからテストする。ADBのUSB/エミュレーター接続と、ホスト側のビルド用通信は別。

モデルはAPKに同梱し、初回利用にも通信不要。復元が必要な場合だけ、開発機で `python3 tools/text-region-eval/fetch_model.py` を実行する。固定リビジョン・容量・SHA-256を照合する。
