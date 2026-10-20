# 起動・配布基盤の検証記録

## 画像処理（#10）

検証日: 2026-10-20。
対象: `83433a6` を起点とする `codex/issue-10-photo-processor` の作業ツリー。
Flutter 3.47.7 / Dart 3.13.5 / macOS arm64、image 4.12.0。
契約と #9 の接続手順は [画像処理](photo-processing.md) を参照。

| 確認 | 結果 |
| --- | --- |
| `dart format lib test integration_test` | 成功 |
| `mise run check` | 成功。ロックファイル照合・フォーマット検査・静的解析（指摘なし）・全42件のテスト成功 |
| JPEG / PNG の Orientation 1〜8、PNG 再正規化 | 成功。非対称の人工画像で回転・反転・寸法を検証 |
| 黒塗り・半開区間・全解像度・元画素の非依存性 | 成功。エンコード前の全画素検査と最終 JPEG の比較 |
| EXIF・未加工サムネイル・その他の付加情報除去 | 成功。入力の EXIF/サムネイルの存在も確認し、出力を独立した構造検査で確認 |
| エラー・入力変更防止 | 成功。公開 API の isolate 経由で検証 |
| `mise run apk` | 成功。release APK を生成 |
| Android integration test | 未実施。接続実機なし。既存 Pixel_10a AVD は通常起動・ヘッドレス起動とも空き容量不足で起動失敗 |
| 編集画面との結合確認 | 未実施。編集画面は追加・接続していない |

テストで見つけた PNG EXIF の問題を修正した。
image 4.12.0 は PNG の eXIf をデコードしないため補助読取を追加した。
また、同版の ExifData.read は成功時にも false を返すため、
戻り値に依存せず TIFF ヘッダー検査と実際の向きのテストで確認する。

実機での処理時間・最大メモリ、広色域の色再現、前面カメラの鏡像、
画面との座標一致、保存後の写真アプリ表示と一時ファイル削除は未確認。
JPEG 再読込後の黒塗り境界には圧縮誤差があり、RGB 値の完全一致は保証しない。
APK ビルドの成功は、未接続の画像処理の Android 実行確認を意味しない。

---

検証日: 2026-10-13

検証対象の実装コミット: `69f799d342f0d866e3f046ed6e2722783ace533e`

CI: [成功した実行](https://github.com/camereon-dev/camereon/actions/runs/38359139420)
／ [配布 APK](https://github.com/camereon-dev/camereon/actions/runs/38359139420/artifacts/11794780085)

以下は起動・配布基盤を作った時点の検証結果。
通常配布 CI の短縮ではワークフローとビルドスクリプトを変更している。

## ローカル環境

- macOS 26.6.2 / Apple Silicon
- Flutter 3.47.4 / Dart 3.13.3
- Android SDK API 36 / Android Studio 同梱 JDK 25

## 結果

| 確認 | 結果 |
| --- | --- |
| Dart フォーマット | 成功 |
| flutter analyze | 成功・指摘なし |
| widget test | 2 件成功。説明の開閉、小さい画面・文字拡大時の操作を確認 |
| Android release APK | 成功。`dist/camereon-demo.apk` を生成 |
| Android Emulator 起動テスト | 成功。Pixel Tablet API 31 上で説明の開閉を確認 |
| Android APK インストール・通常起動 | 成功。release APK のインストールと cold launch が成功し、スクリーンショットを目視確認 |
| GitHub Actions | 2 jobs とも成功。Ubuntu runner / JDK 17 / Android Emulator API 35（Pixel 6）で確認 |
| CI の Android 起動テスト | 成功。起動・説明の開閉を確認 |
| CI の配布 APK | 生成・インストール・通常起動が成功 |
| CI 成果物の取得 | APK・SHA-256・起動画面をダウンロードし、SHA-256 の一致と画面の表示を確認 |

ローカルの配布物は `dist/camereon-demo.apk`、CI から取得した配布物は `dist/ci/camereon-demo.apk`。
両方とも universal APK（約 44 MB）。起動画面の画像は同じディレクトリの `android-startup.png` に保存している。

## 制約

- APK はデモ用 debug 鍵で署名する。別環境の APK へ更新する場合はアンインストールが必要になることがある。
- Android の実機確認は、今回の完了条件に含めない。Emulator 上で検証する。
- 撮影・加工・保存は未実装。起動画面には今後追加予定であることを表示する。

## 配布 CI の短縮

マージ後の通常配布で Emulator の工程が20分以上完了せず、APK のアップロードまで進まなかったため、旧実行を中止した。

- 通常 CI は静的解析・画面テストと release APK の生成・配布を行う。
- Emulator、integration test、端末へのインストールと起動は手動ワークフローへ移した。
- Gradle の依存キャッシュを追加し、debug と release の二重ビルドを通常配布から除いた。
- APK ビルドの前に依存を固定して取得し、Flutter の release 用プラグイン生成を実行する。
- workflow の actionlint とビルドスクリプトの構文確認が成功。新しい配布 CI の所要時間は実行後に確認する。

## カメラ起動（#8）

検証日: 2026-10-14 ／ 対象: `af3f37f`（#8 のマージコミット）

| 確認 | 環境 | 結果 |
| --- | --- | --- |
| フォーマット・静的解析・widget test | macOS / Flutter 3.47.7 | 成功。偽のカメラで 6 件 |
| integration test（カメラ画面の起動） | Emulator Pixel Tablet API 31 | 成功 |
| 権限ダイアログ・切り替え・復帰・前面カメラ撮影・撮り直し・一時ファイル削除・権限拒否から設定経由の復帰 | Emulator Pixel Tablet API 31 | 成功（手動） |
| 背面カメラの撮影 | Emulator Pixel Tablet API 31 | 失敗。撮影時にエミュレーターのカメラ HAL がクラッシュする（解像度を下げても再現） |
| カメラ起動・撮影 | 実機 Xiaomi 14T Pro（HyperOS 3.0.4 / Android 16） | 成功（チームメンバーが手動確認） |
| release APK の権限 | — | `CAMERA` と CameraX 由来の `ACCESS_NETWORK_STATE` のみ |

背面カメラの撮影失敗はエミュレーター固有と判断した（#17）。

制約:

- 画面は縦向き固定のため、横向きに構えて撮っても縦向きで保存される（#16）。
- タブレットのエミュレーターでは縦向き固定が効かず、横画面で表示された。

## PR #27 の追加レビュー（2026-10-20）

Flutter 3.47.7 / Dart 3.13.5、macOS で依存ロックの照合・静的解析・全43テストが成功。
JPEG デコーダーが Orientation を消す前に検証するよう修正し、不正な Orientation と
寸法だけでは検出できない未正規化 JPEG の拒否を回帰テストに追加した。
編集画面・Android 保存との結合結果は後続の統合記録を参照する。

## 編集・画像処理・保存の統合（PR #26・#27・#29）

検証日: 2026-10-20。対象は各 PR の修正コミットと、それらを取り込んだ PR #26。
Flutter 3.47.7 / Dart 3.13.5 / Temurin JDK 25、macOS で実施。

- #27: JPEG の向きをデコーダーが消す前に検証。不正な向き・未正規化画像の拒否を含む43テストと静的解析が成功。CI の品質チェックと release APK ビルドも成功。
- #29: 19テストと静的解析が成功。Android 12 / Pixel Tablet API 31 エミュレーターで `integration_test/gallery_save_test.dart` の2テストが成功。実保存と非JPEG入力の拒否を確認。
- 保存画像の MediaStore 行を確認。`relative_path=Pictures/camereon/`、`is_pending=0`。保存ファイルを adb で取得し、Pillow で JPEG・48×32・全画素黒・EXIFなしを独立に確認。
- 統合後はロック照合・フォーマット・静的解析と全61テストが成功。
- #26: 元画素の座標変換、縦横・余白・画像端・重なり・ドラッグ取消、取り消し・リセット、読み込み再試行、加工・保存失敗時の状態保持、二重保存防止、破棄確認、小画面と文字拡大を widget test で検証。
- `integration_test/photo_edit_save_test.dart` が Android 12 エミュレーターで成功。EXIF Orientation 6 の人工JPEG → 32×48へ正規化 → ドラッグ → 保存前確認 → ネイティブ保存 → 成功表示 → 戻る → 元一時ファイル削除を確認。出力の解像度・黒塗り座標・EXIF/サムネイル除去も検査。

再現: `mise run check`、接続済み端末に対して `mise run device-test -- -d <device-id>`。
端末テストには架空の人工画像だけを使い、ギャラリーにテスト用JPEGを作成する。

制約:

- 接続された Xiaomi 14T Pro / Android 16 は USB インストールが端末側で拒否され、今回の実機テストは未完了。既存の撮影確認記録とは区別する。
- Android 9 以下の権限ダイアログ・実保存は未確認。権限拒否・例外・再試行は Dart のテストで確認。
- 大きな実機写真の処理時間・ピークメモリ、オフラインでの実撮影から保存の手動操作は未計測。
