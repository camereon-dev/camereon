# 今後のアイデア

MVP の範囲外だが、今後の検討のために残すメモ。採用時は Issue にして定義書へ反映する。

## テキストの自動検出

- 写り込んだ文字（住所・名札・書類など）を自動で見つけて隠す候補にしたい。
- 文字の内容まで精査する段階では [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) の利用を検討する。精度が高いと評判。
  端末内で動かせるか（モデルサイズ、Android での推論速度、ライセンス）を確認してから採用を決める。
- その前段として、OCR をかけずに「テキストらしい領域があるか」を雑に判定する仕組みはどちらにしても必要になりそう。
  プレビューや撮影直後に軽く判定し、該当しそうな場所を知らせる・OCR の対象を絞る用途を想定する。
- 画像は端末内で処理する方針（[MVP 定義書](mvp-definition.md) 第 6 節）を守る。外部の OCR API は使わない。

## UI

- ローディング表示には [loading_animation_widget](https://pub.dev/packages/loading_animation_widget)、
  画面の動きには [flutter_animate](https://pub.dev/packages/flutter_animate) を使うとよさそう。
