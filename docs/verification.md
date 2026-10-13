# 起動・配布基盤の検証記録

検証日: 2026-10-13

検証対象の実装コミット: `69f799d342f0d866e3f046ed6e2722783ace533e`

CI: [成功した実行](https://github.com/camereon-dev/camereon/actions/runs/38359139420)
／ [配布 APK](https://github.com/camereon-dev/camereon/actions/runs/38359139420/artifacts/11794780085)

この記録の追記ではドキュメントのみを変更している。

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
