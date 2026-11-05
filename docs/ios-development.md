# iPhoneへの直接インストール

対象はMacから手元のiPhoneへの開発用インストール。App Store、TestFlight、配布用CIは使用しない。

## 環境と署名

- `mise.toml` のFlutter/Dart、Xcode、CocoaPodsを使用する。
- iOSの対応下限は15.5。実機での確認範囲は末尾の検証記録を参照。
- XcodeにApple Accountでサインインし、Personal Teamを選ぶ。iPhoneのDeveloper Modeを有効にし、Macを信頼する。
- この構成はカメラ、写真の選択・追加、同梱モデルの端末内推論に特別な有料entitlementを要求しない。
- `ios/Flutter/Signing.xcconfig` はGit管理外。次の内容を自分のTeam IDで作成する。

```xcconfig
CAMEREON_DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Team IDはXcodeのSigning & Capabilitiesで確認できる。必要ならRunnerのBundle Identifierも自分のTeamで利用可能な値に変更する。既定値は `dev.camereon.camereon.personal`。AndroidのアプリIDには影響しない。

## インストールと再署名

```sh
flutter pub get --enforce-lockfile
flutter devices
flutter run --release -d <iPhone-device-id>
```

初回はiPhoneで開発者の信頼、カメラ、写真の追加を許可する。日常利用にはReleaseビルドを使う。DebugビルドはFlutter/Xcodeのデバッガーに接続して動かすためのもの。

無料のPersonal Teamによるプロファイルは期限付き。期限切れで起動できなくなったら、Macに接続して同じTeam・Bundle IDで上記コマンドを再実行する。通常はアンインストールせず上書きできる。今回生成されたLocalProvisionプロファイルの有効期間は7日だった。アプリ削除は端末内のアプリデータも消すため、再署名の通常手順には含めない。

## 入出力とプライバシー

- 写真選択はPHPicker。ライブラリ全体の読取権限を求めない。
- 入力をImageIOで向き補正・画素コピーし、静止画のPNGにする。25メガピクセル（24MP表記の4284×5712も含む）、入力128MiBを超えるものと複数フレーム画像は拒否する。
- 保存は追加専用権限。Dartで加工・再エンコードしたJPEGだけを新しいPhotosアセットへ追加する。元写真や調整データを添付しない。
- 写真ライブラリにある元写真は変更しない。OSによるiCloud写真の取得・同期はユーザーの設定に従う。
- 撮影は音声無効。未加工の撮影ファイルは編集終了時と次回起動時に削除する。
- 検出の失敗はUIに表示する。空の検出結果で成功したことにはしない。
- Gemmaの内容説明はiOSでは有効にしない。

## 検証用コマンド

```sh
flutter analyze --no-pub
flutter test --no-pub
flutter test integration_test/app_test.dart -d <device-id>
flutter test integration_test/ios_photo_test.dart -d <iPhone-device-id>
flutter test integration_test/photo_edit_save_test.dart -d <iPhone-device-id>
flutter test integration_test/ios_camera_test.dart -d <iPhone-device-id>
```

撮影テストは実際に背面カメラで撮影するが、写真ライブラリに保存するのは全面を隠したJPEGのみ。各テストにはOSの権限確認への操作が必要な場合がある。

## 検証記録

2026-11-03、iPhone 16 Pro / iOS 27.0.1で `ios_acceptance_test.dart` の4件が成功（終了コード0）。静的解析も指摘なし。

| 公開評価写真 | 顔 | 人物 | 画面 | 車両 | 文字 |
| --- | ---: | ---: | ---: | ---: | ---: |
| louvre-crowd | 5 | 21 | 2 | 0 | 10 |
| parking-lpr | 0 | 0 | 0 | 6 | 8 |

対象を含む写真で各種類の正例、輪郭の生成、候補座標の範囲、部分失敗・切り捨てがないことを確認した。この枚数は検出結果であり、正解数・再現率ではない。Androidの既存評価とは顔・文字の件数が異なり、検出の完全一致は保証していない。

編集・保存は合成サンプルと向き／メタデータ付き画像で検証した。候補選択、取り消し、保存前確認、Photosへの保存成功、JPEGの向き・画素・EXIF／サムネイル除去、編集終了時の撮影ファイル削除が成功。公開写真そのものの編集・保存、およびPHPickerを手操作する一連の確認とは区別する。

初回の再試行では評価写真の未配置と、保存完了前のテスト判定により失敗した。写真転送待ちとPhotosの完了通知待ちを追加して成功を確認。アプリ本体の動作はこの再検証では変更していない。途中にXcode／VM Serviceへの接続失敗もあり、最終実行では接続に成功した。終了処理で既に終了済みのプロセスを再度停止するFlutter側の警告が出たが、テスト結果と終了コードはいずれも成功。

この追加検証では通常利用用Release版の導入・単独起動は確認していない。

参考: [AppleのPersonal Teamの制限](https://developer.apple.com/help/account/basics/about-your-developer-account/)、[FlutterのiOS実機設定](https://docs.flutter.dev/platform-integration/ios/setup)。

## 実装の構成と対象外

| 部分 | iOSの方針 |
| --- | --- |
| 編集UI・候補選択・取り消し・保存前確認 | Androidと同じFlutterコード |
| 隠し処理・JPEG出力 | 共通Dartコード。全隠し領域の和集合を色参照から除外 |
| 写真選択・保存 | `PhotoBridge.swift` のPHPicker・ImageIO・Photos |
| 撮影 | 既存cameraプラグインのiOS実装。音声収録なし |
| 顔 | Google ML Kit Face Detection 8.0.0のネイティブAPI |
| 文字 | 同梱PP-OCRv5とONNX Runtime 1.24.3。Swiftで分割検出・輪郭処理 |
| 人物・画面・車両 | 同梱YOLO26s-segとONNX Runtime 1.24.3。Swiftで前後処理 |
| モデル | AndroidのassetsをXcodeのフォルダーリソースとして同梱。SHA-256照合後にロード |

Android固有の権限・MediaStore・Kotlin検出器は維持する。iOSでは同じMethodChannelの契約を実装する。Flutter側の `Android…` というクラス名は互換性のため残っているが、iOSでも対応するネイティブ処理に接続する。端末内推論にネットワークは使用しない。Gemmaによる内容説明、TestFlight、App Store Connect、掲載情報、配布用CIは今回の対象外。

現在固定しているML Kit版にはApple SiliconのiOS 26以降Simulator用arm64バイナリがなく、検出器を含む構成の検証は実機で行う。検出器追加前のSimulator起動成功を、最終構成のSimulator対応とは扱わない。

## 公開写真による検出テスト

`integration_test/ios_real_detection_test.dart` は、写真内に対象がある場合の顔・人物・画面・車両・文字の検出と輪郭・座標範囲を検証する。精度保証やAndroidとの完全一致を確認するテストではない。

[既存の評価写真の出典・ライセンス・SHA-256](evaluation-evidence/2026-11-03-shaped-frosted/sources.json)に従い、`louvre-crowd` と `parking-lpr` の元画像を取得してハッシュを照合する。`/tmp/camereon-ios-eval/` にそれぞれ `<id>.jpg` として置き、次のテストを開始し、ログに `Waiting for USB evaluation fixtures` が出たら、別のターミナルで転送する。テスト用インストールでアプリ領域が置き換わることがあるため、起動後に転送する。90秒待っても画像がない場合はテストが失敗する。

```sh
# ターミナル1: 検出・編集・保存を同じ実機セッションで検証
flutter test integration_test/ios_acceptance_test.dart -d <iPhone-device-id> --no-uninstall

# ターミナル2: 上記の待機ログが出た後に実行
xcrun devicectl device copy to --device <iPhone-device-id> \
  --source /tmp/camereon-ios-eval \
  --destination 'Library/Application Support/ios-evaluation' \
  --domain-type appDataContainer \
  --domain-identifier dev.camereon.camereon.personal
flutter test integration_test/ios_detection_test.dart -d <iPhone-device-id>
flutter test integration_test/ios_real_detection_test.dart -d <iPhone-device-id> --no-uninstall
```

画像はテスト用のアプリ領域だけで使用し、この検出テストから写真ライブラリには保存しない。通常アプリの配布物やGitに評価写真を追加しない。

## 外付けドライブのXcodeで実機テストが起動しない場合

今回のMacでは `/Applications/Xcode.app` が外付けドライブ上のXcodeへのシンボリックリンクだった。AppleScriptの `Application(...).running()` はリンク側では `false`、実体側では `true` を返し、Flutterが `Xcode is not running` と判断する状態を確認した。Xcodeの再起動だけで解消しない場合は、実体パスのDeveloperディレクトリをそのコマンドに指定する。システム全体の設定変更は不要。

```sh
DEVELOPER_DIR=/Volumes/ESD-EWC/Xcode/Xcode.app/Contents/Developer \
  flutter test integration_test/ios_acceptance_test.dart -d <iPhone-device-id> --no-pub
```

`ios_acceptance_test.dart` は公開写真の検出と編集・保存のテストを一度の起動で実行する。別のMacでは自身のXcodeの実体パスに読み替える。

## ユーザーによるRelease版の確認（2026-11-03）

以下はユーザーの実機操作報告。自動テストの結果とは区別する。

- Release版をiPhoneへインストールできた。
- HEICを写真選択から編集・保存まで処理できた。
- 実際の撮影から自動検出・編集・保存まで問題なし。
- ホーム画面へ移動した後にアプリを再び開けた（基本的なバックグラウンド復帰）。OSによるプロセス終了後の復元は未確認。
- 連続撮影・編集で問題は見られなかった。メモリ使用量の測定・負荷限界の確認は未実施。
- カメラ権限を設定で取り消した後、アプリから設定画面へ移動できた。
- 当初開けなかった4284×5712のLive Photoは、画素数上限の修正後、2026-11-04にユーザーが編集・保存できたと確認。保存結果は静止画JPEG。
- iCloudだけに原本がある写真の読み込み、Android実機の操作確認は未確認。
- 2026-11-04、Macから切り離してアプリを終了・再起動し、単独で使用できることをユーザーが確認。

権限取り消し後の「許可する」は、iOSが再度許可ダイアログを出せない状態でもカメラの初期化を再試行していた。`CameraAccessDeniedWithoutPrompt` を別状態として扱い、再試行ボタンを表示せず「設定を開く」とカメラをオンにする説明だけを表示するよう修正。カメラ画面の12件のテスト、静的解析、Android Debugビルド、iOS Releaseビルドは成功。2026-11-04に修正版Releaseを実機へ上書きインストールし、デバッガーを接続せず起動できた。同日、ユーザーが「設定を開く」からカメラを再許可できたと確認。

### 24MP表記の写真の上限修正

開けなかったLive Photoの報告サイズは4284×5712、実画素数は24,470,208。従来の24,000,000画素上限を超えており、iOSのImageIO正規化とFlutter共通処理で拒否されるサイズだった。形式だけを原因と断定しない。

一般的な24MP写真を縮小せず受け付けるため、iOS入力・保存・顔検出、Flutterの画像処理、Android顔検出の上限を25,000,000画素へ統一した。入力128MiB制限と複数フレーム拒否は維持する。元のLive Photoは修正後に静止画として編集・保存できたとのユーザー確認を得た。動画・音声付きのLive Photo保存は対象外。追加した実機テストは同じ4284×5712の合成PNGを正規化・編集・JPEG保存するもので、Live Photo自体の対応確認とは区別する。

2026-11-04、修正後の共通テスト156件、静的解析、Android Debugビルド、iOS Releaseビルドは成功。iPhone 16 Proで `ios_photo_test.dart` の2件が成功し、4284×5712の合成PNGを同じ画素数のまま正規化・編集・JPEG保存できることを確認した。さらに同日、ユーザーが以前開けなかった元のLive Photoを写真選択から編集・保存できたと報告。これにより、報告された写真の不具合は修正後に解消したことを確認した。


## 追加の手動確認結果（2026-11-04）

ユーザーから、提示した追加確認項目のうちAndroid実機・署名期限切れ後の再署名・iCloudからの原本取得以外は問題なしとの報告を得た。以下をユーザー確認済みとして記録する。

- 標準の「写真」アプリで保存JPEGを開いて拡大し、隠した場所・向き・画質を確認。
- 写真追加権限を拒否した場合、保存成功と誤表示せず、編集結果を保持して再試行可能。
- 写真選択をキャンセルした後、撮影・写真選択を継続可能。
- 編集中・保存前確認中にホームへ移動して復帰しても、隠し領域を維持して操作を継続可能。
- Macから切り離した状態でアプリを終了・再起動し、単独で使用可能。

未検証として残す項目はAndroid実機での回帰確認、署名期限切れ後の再署名、iCloud上にしか原本がない場合の取得。ユーザーは現在これらを確認できないため、追加操作を求めず保留とする。Androidの自動テスト・ビルド成功は実機確認の代替とは扱わない。iCloud原本の所在は写真選択画面で確実に区別できないため、通常の写真選択成功から原本取得の成功を推定しない。

以上は提示した操作範囲での確認であり、メモリ使用量の定量測定やOSによる強制終了後の状態復元など、未実施の検証まで成功したとは扱わない。
