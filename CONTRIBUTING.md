# チームでの開発

## 開始する

README に沿って `mise install` で Flutter・JDK を入れ、Android の環境を用意する。
ツールのバージョンは `mise.toml`、依存バージョンは `pubspec.lock` を共有する。
Flutter を更新する PR では `mise.toml` と `pubspec.yaml` の両方を変更し、Android のビルド・起動テストを実行する。

## 変更する

Issue に目的と完了条件を書き、タスクごとのブランチで開発する。
PR には変更内容、確認方法、未確認の環境を記載する。別メンバー 1 人以上がレビューし、PR の解析・画面テストが成功したら `main` へ取り込む。
`main` へのマージ後はベータ版を自動公開する。[ベータ版の運用](docs/beta-releases.md) を確認する。

`lib/app.dart` はテーマとアプリの入口、`lib/features/` は機能ごとの画面を置く。
画像処理・保存は画面から切り離してテストできる形にする。

機能をまたいで受け渡す型は `lib/core/photo/` に置く。

| 型 | 内容 |
| --- | --- |
| `SourcePhoto` | 編集の元画像。向きを正規化しメタデータを除いたバイト列と画素サイズ |
| `HideRegion` | 黒塗りする範囲。`SourcePhoto` の画素座標の整数の長方形（外側へ丸める） |
| `RedactedJpeg` | 黒塗りを焼き込んだ保存用 JPEG |
| `PhotoProcessor` | `normalize`（撮影画像 → `SourcePhoto`）と `redact`（→ `RedactedJpeg`） |
| `PhotoSaver` | `RedactedJpeg` をギャラリーに保存し、`SaveResult` を返す |

撮影 → `PhotoProcessor.normalize` → 編集画面で `HideRegion` を選ぶ → `PhotoProcessor.redact` → `PhotoSaver.save` の順に渡す。
検出機能（顔・テキスト）も候補を `HideRegion` で返す。

## PR 前の確認

```sh
dart format lib test integration_test
mise run check
```

OS 固有の設定や依存を変更したら、Android の integration test とビルドも確認する。
動作確認・デバッグはローカル（`mise run device-test`・`mise run apk`）で行う。
`.github/workflows/mobile.yml` は静的解析・画面テストとベータ版の公開を行う。
デモ APK は `.github/workflows/android-demo.yml` を手動実行する（ビルド設定を変える PR では自動実行）。
端末上の起動テストは PR に `device-test` ラベルを付けるか、`.github/workflows/android-device-tests.yml` を手動実行する。

署名鍵、SDK のローカルパス、画像に含まれる個人情報をコミットしない。
デモ配布・レビュー・結合確認の担当も、実装担当と同じように Issue に記録する。
