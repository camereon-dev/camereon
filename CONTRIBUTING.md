# チームでの開発

## 開始する

README に沿って Flutter 3.47.4 と Android の環境を用意する。
SDK バージョンは `pubspec.yaml` と `.fvmrc`、依存バージョンは `pubspec.lock` を共有する。
SDK を更新する PR では両方のバージョン指定を変更し、Android のビルド・起動テストを実行する。

## 変更する

Issue に目的と完了条件を書き、タスクごとのブランチで開発する。
PR には変更内容、確認方法、未確認の環境を記載する。別メンバー 1 人以上がレビューし、CI の 2 jobs が成功したら `main` へ取り込む。

`lib/app.dart` はテーマとアプリの入口、`lib/features/` は機能ごとの画面を置く。
今後追加するカメラ・画像処理・保存は、画面から切り離してテストできる形にする。

## PR 前の確認

```sh
flutter pub get
dart format lib test integration_test
flutter analyze
flutter test
```

OS 固有の設定や依存を変更したら、Android の integration test とビルドも確認する。
`.github/workflows/mobile.yml` は静的解析・画面テストと配布物の作成を確認する。
端末上の起動テストは `.github/workflows/android-device-tests.yml` を手動実行する。通常の配布では Emulator を起動しない。

署名鍵、SDK のローカルパス、画像に含まれる個人情報をコミットしない。
デモ配布・レビュー・結合確認の担当も、実装担当と同じように Issue に記録する。
