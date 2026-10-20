# ベータ版の自動リリース

しばらくは GitHub Releases の **Pre-release** として Android APK を配布する。
現在のアプリは起動直後にカメラを開き、撮影・撮り直し・前面と背面の切り替えができる。編集・画像加工・保存は今後追加する。

## 公開の流れ

1. PR の解析・画面テストと、変更内容に応じた Android のビルド・端末確認を行い、レビュー後に `main` へマージする。
2. `main` の解析・画面テストが成功すると、ARM64 の APK を固定のベータ署名鍵でビルドする。
3. APK の署名、アプリ ID、バージョン、SHA-256 を検証する。
4. APK と SHA-256 を GitHub Pre-release に添付し、自動公開する。

Emulator の起動は公開の前提にしない。端末テストは PR に `device-test` ラベルを付けるか、**Android device tests** を必要なときに手動実行する。
PR や `main` 以外のブランチには、ベータ署名鍵を渡さず、Release を公開しない。
Release 公開 job だけが `contents: write` を持つ。ビルド job はリポジトリの読み取り権限で動く。

## バージョン

- `pubspec.yaml` の基本バージョンを使う。現在は `0.1.0`。
- ベータの表示バージョンは `0.1.0-beta.<CI 実行番号>`。
- タグは `v0.1.0-beta.<CI 実行番号>`。実行番号には飛び番がある。
- Android の `versionCode` も同じ実行番号を使い、後のベータ版へ更新できるようにする。
- タグは、その APK を作ったコミットを指す。

公開先: [GitHub Releases](https://github.com/camereon-dev/camereon/releases)

公開するファイルは `camereon-beta-arm64.apk` と `camereon-beta-arm64.apk.sha256`。
Android 7.0 以上の ARM64 端末で利用できる。アプリ ID は `dev.camereon.camereon.demo`、表示名は `camereon beta`。
正式版を出すタイミングでは、配布先・アプリ ID・バージョン方針を改めて決める。

## 署名の設定

ベータ版は毎回同じ PKCS12 鍵を使う。

| GitHub の設定 | 名前 | 内容 |
| --- | --- | --- |
| Actions Secret | `CAMEREON_BETA_KEYSTORE_BASE64` | PKCS12 ファイルを Base64 にした値 |
| Actions Secret | `CAMEREON_BETA_PASSWORD` | キーストアと秘密鍵に共通のパスワード |
| Actions Variable | `CAMEREON_BETA_CERT_SHA256` | 署名証明書の SHA-256。小文字の64桁、コロンなし |

alias は `camereon-beta`。鍵はビルド中だけ runner の一時領域に復元し、ビルド後に削除する。
署名設定が不足している場合や証明書が一致しない場合は、公開を失敗させる。debug 署名の APK をベータとして公開しない。

この作業環境のバックアップは、元のプロジェクトの `.private/beta-signing/` に保存する。
`camereon-beta.p12` と `credentials.json` をチームの安全な保管先へバックアップする。
このフォルダは Git 管理外。鍵やパスワードをリポジトリ・Release へ含めない。
Secrets は値を後から取得できないため、バックアップを保持する。

以前のデモ APK は debug 署名だったため、ベータ版への切り替え時は初回のみアンインストールが必要。
以降のベータ版は同じ鍵で上書き更新できる。

## 手動公開と再実行

- 新しいベータ版を公開する: **Checks and beta release → Run workflow → main**。
- 失敗した公開を再試行する: 失敗した CI の **Re-run failed jobs**。同じ実行番号・タグを使う。
- 既に公開済みのタグなら、添付ファイルと対象コミットを確認して既存 Release を使う。
- 途中で止まった draft は、APK とチェックサムを揃えてから公開する。
- 既存タグが別のコミットを指す場合は失敗させ、公開済みのタグやファイルを上書きしない。

通常の PR・手動テスト用のデモ APK は debug 署名。公開ベータ版とは署名が異なる。
