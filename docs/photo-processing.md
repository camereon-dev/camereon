# 画像処理（Issue #10）

`ImagePhotoProcessor` は既存の `PhotoProcessor` を実装する。
画面、カメラ、保存先、ファイル操作には依存しない。

## 受け渡し

```dart
final PhotoProcessor processor = ImagePhotoProcessor();
final source = await processor.normalize(capturedBytes);
// #9: source.bytes を表示し、source.width / height の画素座標で領域を選ぶ。
final jpeg = await processor.redact(source, regions);
// 保存前確認は jpeg.bytes を表示し、保存時は PhotoSaver.save(jpeg) に渡す。
```

- 入力は JPEG または静止 PNG。アニメーションやその他の形式は拒否する。
- `normalize` は EXIF の回転・反転を画素へ反映し、メタデータのない RGB PNG を返す。
- PNG の透過部分は白に合成する。ICC は引き継がず、広色域・HDR の色再現は保証しない。
- JPEG は image 4.12.0 のデコーダーが向きを補正する。PNG は同版が `eXIf` を解釈しないため、チャンクから TIFF を読み、`bakeOrientation` で補正する。
- `redact` は `normalize` の結果を入力とする。新しい RGB 画像へ画素だけをコピーして、全領域を検証後に黒で上書きする。右端・下端は含まない。
- 空リストも有効。毎回元の `SourcePhoto` から加工し、出力 JPEG を再加工の入力にしない。
- 最終 JPEG は品質 100・yuv444、正規化後の全解像度。向きによる縦横の交換以外に縮小・切り取りはしない。
- JPEG は非可逆圧縮なので、再読込後の境界の色には誤差がある。エンコード前の選択範囲は完全な黒で上書きする。
- 入力バイト列と領域リストは処理受付時にコピーする。出力バイト列は変更不可。
- デコードからエンコードまでは `Isolate.run` 内で行う。UI 側で重複操作を抑止し、画面破棄・選択変更後の古い結果は破棄する。処理のキャンセルは未対応。
- 既定の上限は 24,000,000 画素、入力 128 MiB。コンストラクターで変更可能。暫定の保護値であり、実機のメモリ・応答時間を保証する値ではない。超過時は縮小せず失敗する。

## エラー

`PhotoProcessingException.reason` で、画像不正、未対応形式、上限超過、
SourcePhoto の寸法不一致等、不正領域、エンコード失敗、worker 失敗を区別する。
画像・EXIF・元の例外文字列をログやエラーメッセージに載せない。
失敗時は未加工画像を返さず、呼び出し元の SourcePhoto と選択状態を保持する。
ファイル読み込みと削除の失敗は入力側、写真ライブラリへの保存失敗は保存側の責務。

## #9 の接続作業

1. 撮影後にバイト列を読み、`normalize` の完了後に編集を可能にする。
2. `SourcePhoto.bytes` を表示し、実際の表示位置・倍率・余白を考慮して画素座標へ変換する。
3. `HideRegion.fromRect` で作った同じ領域を、プレビューと `redact` に使用する。
4. 取り消し・リセットは領域リストを更新する。加工中の重複操作を止める。
5. 保存前確認には `RedactedJpeg.bytes` を表示する。エラー時は状態を保持し再試行を案内する。
6. 元の撮影ファイルの削除と、戻る・再撮影・画面破棄時の結果の破棄を接続する。

編集画面・撮影画面への接続はこの変更には含めていない。
プレビューとの位置一致、実機撮影の向き・鏡像、最大画像での性能・メモリ、
写真アプリでの表示、一時ファイル削除を含む一連の結合確認は未実施。

## 単体テスト

`test/support/photo_fixtures.dart` が架空のカラーパターンとメタデータを生成する。
外部画像・実在の個人情報・バイナリの検体ファイルは使用しない。

- JPEG と PNG の Orientation 1〜8、Orientation なし、PNG 再正規化時の不変性。
- 縦横・正方形・奇数寸法・1画素画像での解像度維持。
- 四隅・右下端・1画素幅・重なり・隣接範囲を、圧縮前の全画素で検査。
- 選択範囲の元画素だけが違う画像から、同じ JPEG が生成されること。
- EXIF の GPS・日時・端末情報、EXIF/JFXX サムネイル、XMP・IPTC・コメント・末尾データを除去。
- PNG チャンクと JPEG セグメントをライブラリとは独立に検査。
- 入出力の変更防止、空領域、再加工、破損入力、未対応形式、上限、不正寸法・領域の失敗。

公式参照:
[image 4.12.0](https://pub.dev/packages/image/versions/4.12.0)、
[bakeOrientation](https://pub.dev/documentation/image/4.12.0/image/bakeOrientation.html)、
[fillRect](https://pub.dev/documentation/image/4.12.0/image/fillRect.html)、
[JpegEncoder](https://pub.dev/documentation/image/4.12.0/image/JpegEncoder/encode.html)、
[Isolate.run](https://api.dart.dev/dart-isolate/Isolate/run.html)。
