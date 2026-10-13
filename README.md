# camereon

写真に写り込んだ個人情報を簡単に隠して、SNSへ投稿する前の確認を助けるカメラアプリ。

Android 向けに Flutter で開発する。現在は起動画面とアプリの説明を表示するデモ。撮影・加工・画像保存は次の段階で追加する。

## 今回の範囲

[今回の定義・完了条件](docs/bootstrap-definition.md) / [プロダクト全体の MVP 定義](docs/mvp-definition.md) / [検証記録](docs/verification.md)

## 起動する

Flutter **3.47.4** / Dart **3.13.3** を使う。バージョンは `pubspec.yaml` と `.fvmrc` で固定する。
Flutter を直接使う場合は `flutter --version` を確認する。FVM を使う場合は `fvm install` のあと、以下の `flutter` / `dart` を `fvm flutter` / `fvm dart` に読み替える。

```sh
flutter doctor -v
flutter pub get
flutter devices
flutter run -d <device-id>
```

Android は Android Studio・SDK と、Emulator または USB 接続した実機が必要。現時点の最小対応は Android 7.0（API 24）、ビルド用 SDK は API 36。
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
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test --coverage
```

起動画面、説明ダイアログの開閉、小さい画面と文字拡大時の操作を widget test で確認する。
端末上での起動と説明の開閉は integration test で確認する。

```sh
# 起動済みの Android Emulator または実機
flutter test integration_test/app_test.dart -d <android-device-id>
```

## Android のデモを配布する

```sh
bash scripts/build-android-demo.sh
```

`dist/camereon-demo.apk` と SHA-256 ファイルができる。APK は端末を選びにくい universal APK とし、デモ用の debug 鍵で署名する。アプリ ID は `dev.camereon.camereon.demo`、表示名は `camereon demo`。
この APK はチーム内デモ用。ストア公開時は正式な署名とアプリ ID を設定する。

USB 接続した端末にインストールする場合:

```sh
adb install -r dist/camereon-demo.apk
```

端末に APK ファイルを渡して開く方法でもインストールできる。その場合、Android の案内に従ってファイルを開くアプリからのインストールを許可する。
CI や別の PC で作った APK は署名が異なるため、更新時に `INSTALL_FAILED_UPDATE_INCOMPATIBLE` が出たら、既存の `camereon demo` をアンインストールしてから入れ直す。この段階ではユーザーデータを保存しない。

## GitHub Actions で確認・配布する

[Android checks and demo](https://github.com/camereon-dev/camereon/actions) は `main` への push、PR、手動実行で動く。

| Job | 内容 |
| --- | --- |
| Format, analyze and widget tests | バージョン・依存を固定してフォーマット、静的解析、widget test を実行 |
| Android launch test and demo APK | Android Emulator 上で起動テストし、配布用 APK を生成・インストール・起動 |

配布手順:

1. Actions から実行結果を開き、対象コミットとテスト成功を確認する。
2. Artifacts の `camereon-android-demo` をダウンロードして ZIP を展開する。
3. `camereon-demo.apk` を Android 端末へ渡し、インストールする。
4. 起動して `camereon` の画面を確認し、「このアプリについて」→「閉じる」を試す。

APK の保管期間は 30 日。期間を過ぎた場合は再実行して取得する。Android の通常起動画面は `android-startup-screenshot` で取得できる（14 日間保存）。Actions の成果物の取得には GitHub ログインとリポジトリの読み取り権限が必要。
今回は Actions の成果物を Android のデモ配布先とする。公開ストア、公開 Release は対象に含めない。

## ユーザー・チーム側の準備

- ローカルで Android を確認する人: Android Studio・SDK を導入し、SDK ライセンスを確認して Emulator または実機を準備する。
- リポジトリ管理者: GitHub Actions の実行を有効にする。今回のデモ配布では追加の Secrets は不要。
- チーム: PR のレビュー担当を決め、2 jobs の成功を確認して取り込む。必要に応じて `main` の保護ルールに必須チェックを設定する。

開発ルールは [CONTRIBUTING.md](CONTRIBUTING.md)。環境の不具合は `flutter doctor -v` で不足している項目を確認する。

参考: [Flutter 導入](https://docs.flutter.dev/install)、[Android ビルド](https://docs.flutter.dev/deployment/android)、[integration test](https://docs.flutter.dev/testing/integration-tests)。

関連 Issue: [#1 定義書作る](https://github.com/camereon-dev/camereon/issues/1)
