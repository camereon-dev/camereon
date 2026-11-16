# 電話番号だけを自動で隠す

写真の読み込み後、電話番号と判別した範囲だけを自動で選択し、既存のすりガラス塗りを適用する。従来の全文字候補・顔・人物・画面・車両の検出と編集は維持する。他の種類は自動選択しない。

- 電話番号の枠をタップ、または「電話番号」チップで表示・非表示を切り替える。
- 自動選択も取り消し可能。他の候補を追加しても通常の履歴で戻せる。
- 表示用のすりガラス画像を生成している間も、電話番号は不透明な塗りで隠し、読み取れる状態を残さない。
- 一度表示へ戻した番号は、同じ写真の再検出で自動選択し直さない。多少の枠のずれも重なり率で同じ番号とみなす。
- 保存はユーザーが確認して実行する。検出だけでは保存や外部送信はしない。

## 実装

従来の `text_regions` 呼び出しでPP-OCRv5の文字領域を返す処理を残し、独立した電話OCRの位置を `phoneBoxes` として追加する。Flutterは元画像座標へ変換し、`CandidateKind.phone` として保持する。同じ行の名前・住所・TELラベルは、文字候補として残り、電話番号のマスクには含めない。

| 部分 | Android | iOS |
| --- | --- | --- |
| OCR | 同梱ML Kit Text Recognition 16.0.1（Latin） | Apple Vision `VNRecognizeTextRequest`（en-US、言語補正なし） |
| 位置 | 一致する文字のSymbol座標のみを結合 | `VNRecognizedText.boundingBox(for:)`で一致部分のみ取得 |
| 通信 | モデルをビルド時に同梱、初回もオフライン | OSの端末内Vision処理 |

認識文字列はネイティブの一時メモリだけで扱い、Flutter・画面・ログ・ファイルに渡さない。チャンネルの返値は数値座標と状態だけ。モデルの一方が失敗しても、もう一方の候補を残して `partial=true` を返し、編集画面に再試行を表示する。両方が失敗した場合は成功0件として扱わず、検出失敗にする。

Androidで部分文字の座標が得られない場合、行全体を電話番号として隠すことはせず、その候補を見送る。

## 対応形式と限界

- 日本国内の10桁固定電話・0120などの番号、11桁の050/070/080/090/0800。
- ハイフン・空白・括弧・全角数字・全角記号、国番号 `+81`（`+81 (0)` 表記を含む）。
- 郵便番号、日付、時刻、長すぎる数字列、ハイフンで続く長い識別子の一部分は対象外。
- 形式からの候補判別であり、加入者・割当・実在の検証ではない。同形式の管理番号やFAX番号との区別は保証しない。
- 日本以外の国番号、短縮番号、内線、複数行に分かれた番号は今回の対象外。
- OCRが読み間違えた数字の推測置換は行わない。小文字・手書き・強い傾き・低コントラストでは漏れや誤候補があり、保存前の確認が必要。
- 従来の全文字候補の検出はOCR結果で削らない。電話番号を読めなくても、元の文字枠から手動で隠せる。

## 検証

- `flutter analyze --no-pub`
- `flutter test --no-pub`
- Android: `cd android && ./gradlew :app:testDebugUnitTest`
- iOSの共通判定コーパス: `swiftc ios/Runner/PhoneNumberMatcher.swift scripts/test-ios-phone-matcher.swift -o /tmp/camereon-phone-check`、続けて `/tmp/camereon-phone-check android/app/src/test/resources/phone_numbers.tsv`
- 端末: `flutter test integration_test/phone_numbers_device_test.dart -d <device-id>`

共通判定コーパスは合成番号と負例を含み、AndroidとSwiftの一致範囲を検証する。画面テストは自動選択、他候補の保持、再検出後の解除維持、取り消し、保存へ渡す領域を確認する。端末テストは実OCRで数字部分だけを検出し、氏名・郵便番号・日付・TELラベルが保存JPEGに残ること、電話領域の暗い画素が消えること、通常の文字候補が残ることを確認する。

2026-11-16: 静的解析・Flutter 175件・Android/JVM 12件・Android/Swift共通判定30ケースが成功。Androidエミュレーターで、オフラインの実OCR・自動マスク・保存の2件が成功。検証後は通信設定を元へ戻した。[検証記録と画面](evaluation-evidence/2026-11-16-phone-numbers/README.md)を参照。

SwiftのVision検出クラスはmacOS上の合成画像で動作確認したが、Xcode/iOS SDKがないため、iOS全体のビルドとiPhone実機での検証は未実施。既存の文字検出の速度・APKサイズ測定はこのOCR追加後の数値ではない。

参考: [ML Kit Android（同梱方式とSymbol座標）](https://developers.google.com/ml-kit/vision/text-recognition/v2/android)、[Apple Visionの文字範囲座標](https://developer.apple.com/documentation/vision/vnrecognizedtext/boundingbox(for:))。
