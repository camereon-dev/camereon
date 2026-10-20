# camereon

写真に写り込んだ個人情報を簡単に隠して、SNSへ投稿する前の確認を助けるカメラアプリ。

[アプリ紹介・ダウンロード](https://camereon-dev.github.io/camereon/)

Android 向けに Flutter で開発する。起動するとすぐにカメラが開く。撮影した写真をドラッグして複数箇所を黒塗りし、保存前に確認して Android のギャラリーへ新しい JPEG として保存できる。取り消し・全リセット・撮り直しに対応する。起動画面の「サンプルで試す」から、カメラの許可や AI モデルなしで架空の配送ラベルを編集できる。撮影後には Gemma 4 による端末内の内容説明も利用できる。

## 今回の範囲

[ベータ版の取得・運用](docs/beta-releases.md) / [今回の定義・完了条件](docs/bootstrap-definition.md) / [プロダクト全体の MVP 定義](docs/mvp-definition.md) / [検証記録](docs/verification.md) / [今後のアイデア](docs/ideas.md)

チームで作業を分担する場合は [共有仕様と分担の進め方](docs/team-development.md) を参照する。

撮影後の自動検出は [オンデバイス解析の設計案](docs/ai-analysis-design.md) を参照する。OCR と VLM の単独検証、共通の入出力、本体への結合方針をまとめている。

本体の解析機能・実機プレビュー・チームの担当範囲は [Gemma 4 組み込み手順](docs/gemma-integration.md) を参照する。

## 起動する

Flutter **3.47.7** / Dart **3.13.5** / JDK **25**（Temurin）を使う。ツールのバージョンは [mise](https://mise.jdx.dev/) の `mise.toml` で固定し、CI も同じファイルを使う。

```sh
mise install
flutter doctor -v
flutter pub get
flutter devices
flutter run -d <device-id>
```

Android は Android Studio・SDK と、Emulator または USB 接続した実機が必要。現時点の最小対応は Android 11（API 30）、ビルド用 SDK は API 36。
初回は `flutter doctor --android-licenses` でライセンスを確認する。実機では開発者向けオプションの USB デバッグを有効にして、接続を許可する。

Emulator は Android Studio の Device Manager で作成するか、作成済みのものを起動する。

```sh
flutter emulators
flutter emulators --launch <emulator-id>
flutter devices
flutter run -d <device-id>
```

## テストする

```sh
mise run check   # format・analyze・widget test
```

widget test は偽のカメラ（`CameraPlatform` の差し替え）を使い、起動直後のプレビュー、撮影と撮り直し、カメラの切り替え、権限拒否・カメラなしの表示、サンプルからの編集、小さい画面と文字拡大時のレイアウトを確認する。
画像処理では向き・解像度・黒塗り・メタデータ除去、編集画面では座標変換・取り消し・失敗時の状態保持を自動テストで確認する。
integration test はカメラ起動、サンプルの編集・保存、人工画像を使った編集から保存・一時ファイル削除、MediaStore への保存と不正入力の拒否を確認する。実機での撮影操作は別途確認する。

```sh
# 起動済みの Android Emulator または実機
mise run device-test -- -d <android-device-id>
```

## Android のベータ版を取得する

[GitHub Releases](https://github.com/camereon-dev/camereon/releases) の最新の **Pre-release** を開き、`camereon-beta-arm64.apk` をダウンロードしてインストールする。Android 11 以上の ARM64 端末に対応する。

ベータ版は固定の署名鍵で署名する。以前の debug 署名のデモ APK を入れていた場合は、初回のみ `camereon demo` をアンインストールする。以降のベータ版は上書き更新できる。

## ローカルのデモ APK を作る

```sh
mise run apk
```

`dist/camereon-demo.apk` と SHA-256 ファイルができる。APK は端末を選びにくい universal APK とし、デモ用の debug 鍵で署名する。アプリ ID は `dev.camereon.camereon.demo`、表示名は `camereon demo`。
このローカル APK はチーム内デモ用。自動公開するベータ APK には専用の署名鍵を使う。

USB 接続した端末にインストールする場合:

```sh
adb install -r dist/camereon-demo.apk
```

端末に APK ファイルを渡して開く方法でもインストールできる。その場合、Android の案内に従ってファイルを開くアプリからのインストールを許可する。
ローカルのデモ APK と公開ベータ版は署名が異なるため、切り替える場合は既存のアプリをアンインストールしてから入れ直す。

## GitHub Actions で確認・配布する

動作確認やデバッグはローカルの方が速いため、CI は PR の確認とベータ公開に絞る。

[Checks and beta release](https://github.com/camereon-dev/camereon/actions) は `main` への push、PR、手動実行で動く。

| Job | 内容 |
| --- | --- |
| Format, analyze and widget tests | バージョン・依存を固定してフォーマット、静的解析、widget test を実行 |
| Build signed Android beta | main で ARM64 のベータ APK を固定鍵で署名し、署名・バージョン・チェックサムを確認 |
| Publish beta GitHub Release | 検証済み APK を Pre-release として自動公開 |

`main` への push（PR のマージを含む）で、解析・画面テスト → 署名付き APK ビルド → GitHub Pre-release 公開まで自動実行する。ベータ版の名前は `v0.1.0-beta.<CI 実行番号>` の形式。同じ CI の再実行では既存の公開 Release を使い、重複公開しない。

手動で新しいベータ版を出す場合は、**Checks and beta release → Run workflow → main** を選ぶ。
PR や別ブランチからは公開しない。APK の公開はビルドと検証が成功した場合に行う。

公開先は [GitHub Releases](https://github.com/camereon-dev/camereon/releases)。ブラウザーで APK を直接取得できる。Actions の成果物にはベータ APK・SHA-256・公開用メタデータを30日間保持する。GitHub Release の添付ファイルはその期間に依存しない。
署名鍵の設定・バックアップ・再実行については [ベータ版の運用](docs/beta-releases.md) を参照する。

デモ APK が必要なときは、Actions の **Android demo APK** から **Run workflow** を選ぶ（ARM64 実機用）。
Android のビルド設定（`android/`・`mise.toml`・`pubspec`・ビルドスクリプト）を変える PR では、このワークフローが自動で動いてビルドを確認する。

通常の CI は Emulator の準備・起動、端末テストを行わない。
端末上の起動確認が必要なときは、PR に `device-test` ラベルを付けるか、Actions の **Android device tests** から **Run workflow** を選ぶ。
この手動ワークフローでカメラ起動・編集・ギャラリー保存の integration test と APK のインストール・起動を確認し、`android-startup-screenshot` を取得できる（14 日間保存）。手動テストの完了を待たずに通常の APK 配布を進められる。
初回やキャッシュがない実行では依存の取得に時間がかかる。通常の APK ビルドは10分、配布 job 全体は15分でタイムアウトする。

## ユーザー・チーム側の準備

- ローカルで Android を確認する人: Android Studio・SDK を導入し、SDK ライセンスを確認して Emulator または実機を準備する。
- リポジトリ管理者: GitHub Actions の実行を有効にする。自動ベータ公開では署名用 Secrets と証明書の SHA-256 を設定する（このリポジトリでは初期設定済み）。
- チーム: PR のレビュー担当を決め、PR の解析・画面テストの成功を確認して取り込む。必要に応じて `main` の保護ルールに必須チェックを設定する。

開発ルールは [CONTRIBUTING.md](CONTRIBUTING.md)。環境の不具合は `flutter doctor -v` で不足している項目を確認する。

紹介サイトは `site/` で管理し、GitHub Pages へ自動公開する。サイトの更新・画像差し替えの手順は [サイトの README](site/README.md) を参照する。

参考: [Flutter 導入](https://docs.flutter.dev/install)、[Android ビルド](https://docs.flutter.dev/deployment/android)、[integration test](https://docs.flutter.dev/testing/integration-tests)。

関連 Issue: [#1 定義書作る](https://github.com/camereon-dev/camereon/issues/1)
