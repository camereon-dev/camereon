# camereon

写真に写り込んだ個人情報を簡単に隠して、SNSへ投稿する前の確認を助けるカメラアプリ。

[アプリ紹介・ダウンロード](https://camereon-dev.github.io/camereon/)

Android と iOS 向けに Flutter で開発する。撮影した写真や「写真を選ぶ」で開いた画像を端末内の日本語OCRで読み取り、日本の住所表記に一致する範囲を最初から隠す。住所枠のタップで解除・再適用し、保存前に確認して、新しいJPEGとして写真ライブラリへ保存できる。通常画面の編集対象は住所と顔で、どちらも検出時に隠す。人物全体・画面・車両・一般文字の候補は表示しない。

iPhoneはMacからPersonal Teamで直接インストールする。[導入・再署名と検証範囲](docs/ios-development.md)を参照。

## 今回の範囲

[ベータ版の取得・運用](docs/beta-releases.md) / [今回の定義・完了条件](docs/bootstrap-definition.md) / [プロダクト全体の MVP 定義](docs/mvp-definition.md) / [検証記録](docs/verification.md) / [今後のアイデア](docs/ideas.md)

チームで作業を分担する場合は [共有仕様と分担の進め方](docs/team-development.md) を参照する。

撮影後の自動検出は [オンデバイス解析の設計案](docs/ai-analysis-design.md) を参照する。OCR と VLM の単独検証、共通の入出力、本体への結合方針をまとめている。

Androidの人物・画面検出、別IDのAPKビルド・インストールは [Android検出器プレビュー](docs/android-detectors.md) を参照する。Gemmaの過去の検証は [Gemma 4 組み込み手順](docs/gemma-integration.md) に残す。

## 写真を用意せずに試す

1. 起動画面で「サンプルで試す」をタップする。
2. 架空の配送ラベルの住所は最初から隠れている。住所枠をタップすると解除し、もう一度タップすると再適用する。
3. 「取り消す」で直前の選択へ戻せる。「住所」ボタンで住所候補を一括切替できる。
4. 右下の矢印から確認画面へ進み、「写真に保存」をタップする。
   保存後は「共有」で他のアプリへ送り、「開く」で写真アプリに表示できる。共有されるのは隠した後のJPEGだけ。
5. 端末の写真アプリで新しいJPEGを確認する。

サンプルは本プロジェクトで作成した合成画像。サンプルも通常写真と同じOCRで読み取る。[出典・利用範囲](tools/vlm-eval/fixtures/README.md)を参照。

## 写真の日本住所を隠す

通常の撮影・写真選択では固定座標を使わず、Androidは同梱ML Kitの日本語文字認識、iOSはVisionの日本語文字認識を使う。OCRの文字列と座標から、都道府県・市区町村・町域・丁目番地などの表記を住所候補にする。「東京都」「横浜市」「123番地」「1-2-3」のように都道府県・市区町村・番地だけがある場合も、個別の候補として隠す。字・大字・小字の単独表記も候補にする。連続住所も「愛知県／豊橋市／大岩町／字北山」のように分割し、番地とその後ろに続く建物名・部屋番号も別候補にする。住所形式だけでなく文章・見出し内の都道府県名、市区町村名、字名も拾って隠す。デジタル庁のアドレス・ベース・レジストリから作成した約41万語の同梱辞書で市区町村・大字・町域・小字を照合する。「豊橋」「北山」のように末尾の市区町村や先頭の字がない表記も、それだけで候補にする。検索は端末内で完結する。住所と顔の各候補は独立して解除・再適用できる。都道府県の省略、全角数字、漢数字、ハイフン、隣接行への折り返しにも対応する。OCR文字列はメモリ内だけで処理し、ログやファイルには保存しない。

最初の住所・顔の検出が終わるまで写真の表示と保存前確認を待ち、候補は選択済みで表示する。タップによる解除・再適用、取り消し、確認画面からの戻りに対応し、保存時は選択した範囲だけをすりガラス状の塗りで加工する。読み取り失敗は画面上から再試行できる。再試行で同じ住所が返っても、解除した選択を戻さない。

公式データ由来の地名辞書と住所表記ルールを併用するが、所在地全体の実在性を検証するものではない。辞書未収録の地名、数字だけで番地と判断できない表記、縦書きや小さい・不鮮明な文字は見落とす場合がある。短い地名と同じ人名・一般語も隠れる場合があるため、保存前に画像全体を確認する。データの出典・利用条件はカメラ画面の「データ出典・ライセンス」から確認できる。[辞書の生成と更新](tools/address-dictionary/README.md)。[実装・検証範囲](docs/japanese-address-detection.md)を参照。

顔は既存のML Kit検出器を利用する。物体・文字領域だけの検出器は比較評価用に残し、通常の編集画面では起動しない。過去の[検出方式と統合記録](docs/detection-integration.md)は住所限定フロー以前の仕様。

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

[GitHub Releases](https://github.com/camereon-dev/camereon/releases) の最新の **Pre-release** を開き、`camereon-beta-<バージョン>-arm64.apk` をダウンロードしてインストールする。Android 11 以上の ARM64 端末に対応する。

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
