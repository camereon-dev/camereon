# 起動・配布基盤の検証記録

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
