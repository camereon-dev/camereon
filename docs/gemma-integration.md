# Gemma 4 の本体組み込みと実機確認

関連: [#28](https://github.com/camereon-dev/camereon/issues/28)、[単独検証 #23](https://github.com/camereon-dev/camereon/issues/23)、[比較結果](gemma-evaluation.md)。

## 今回追加する機能

撮影後の画面から「端末内で写真を解析」を開くと、Gemma 4 が写真の内容を説明する。
初回は約2.59GBのモデルを明示操作で取得する。モデル配置後の推論は端末内で行い、写真を外部へ送信しない。
見落としや誤りがあることを表示する。危険箇所の判定・位置の提案・自動黒塗りは後続 #24 と検出機能で扱う。

## 対応環境の変更

- この組み込みから Android 11（API 30）以上。以前の起動・撮影版は API 24 以上だった
- AI は ARM64 のみ。x86_64 のエミュレーターでは通常のカメラ起動確認と AI 解析を区別する
- モデル 2,588,147,712 bytes に加え、ダウンロード前に 2 GiB の作業領域を見込む。CPU の単独検証では約963 MiBのキャッシュが増えた
- Release のベータ配布は従来と同じアプリ ID・署名。モデルを APK に含めない
- `INTERNET` 権限はモデルの取得に使う。解析サービスには HTTP クライアントを渡さない

## 他の担当との境界

| 担当 | 今回の接点 |
| --- | --- |
| #9 編集画面（PR #26） | `captured_photo_screen.dart` は変更しない。`camera_screen.dart` の遷移先で `PhotoAnalysisEntry` に既存画面を包む。編集・選択・黒塗りは #9 が担当 |
| #10 画像処理（PR #27） | `PhotoProcessor`・`SourcePhoto`・`HideRegion` の型と実装は変更しない。解析側は Flutter と同じデコード経路で長辺1024px以下のPNGを作り、VLMだけに渡す。座標や保存用画像は返さない |
| #11 保存 | MediaStore・保存権限・`PhotoSaver` は変更しない。最低OSがAndroid 11になる点は共有が必要 |
| #12 全体結合 | 解析画面を開閉しても親の編集状態を保持する。保存前確認・編集・保存の全体結合は後続 |

#9/#10/#11 は並行して進められる。`pubspec.yaml`・`pubspec.lock` は共用なので、#10 の `image` 追加と今回の AI 依存をマージ後に両方残して依存解決する。
PR #26/#27/#29 は main へマージ済み。カメラ起動を維持し、編集・画像処理・保存と解析の両方の MethodChannel・依存を保持して結合した。
#9 の選択範囲は元画像の画素座標で #10 へ渡し、`HideRegion` へ接続する。画面上の `Rect` だけでは結合を完了としない。

## コードの配置

- `lib/core/analysis/scene_analysis.dart`: SDK・Widgetに依存しない画像・OCR補足・結果・インターフェース
- `lib/core/analysis/infrastructure/`: 固定モデルの取得・SHA-256検証とLiteRT-LMアダプター
- `lib/features/analysis/`: 縮小用の画像準備、画面・進捗・キャンセル
- `lib/analysis_demo.dart`: 合成画像で同じ本体の解析画面を開く開発用エントリーポイント。通常の起動先は `lib/main.dart`

モデルの固定値は単独検証の `tools/vlm-eval/model.json` と一致させる。モデルを変更するときは両方を更新・再検証する。
通常ログには画像・OCR全文・回答を出さず、SDKのログも無効にする。モデルと会話は1件ずつ実行し、完了・失敗・キャンセルで解放する。
ダウンロードは進捗・転送速度・残り時間の目安を表示する。一時停止・通信エラーでは `.part` と配布URL・サイズ・SHA-256の識別情報を保持し、HTTP Rangeで続きから再開する。ハッシュ不一致等の破損データは破棄し、全体のSHA-256検証に成功したファイルだけをモデルとして公開する。
ダウンロードはアプリ共通の `ModelDownloadController` が所有する。画面を閉じても取得は継続し、開き直すと現在の進捗へ接続する。アプリ終了・OSによる中断の後も保存済みのバイト位置から再開できる。解析は画面を閉じると中止する。モデルロード中は native 処理の終了後に解放する場合がある。

## 既存ベータを保って実機で試す

`CAMEREON_AI_PREVIEW=1` を付けると、アプリIDが `dev.camereon.camereon.demo.ai_preview`、表示名が `camereon AI preview` になる。
既存の `camereon beta` を置き換えずに試せる。プレビューはベータ版として公開しない。

```sh
CAMEREON_AI_PREVIEW=1 flutter run -d <device-id>
```

1. Android 11以上・ARM64の実機でUSBデバッグを許可し、ロックを解除する。
2. 撮影後に「端末内で写真を解析」を開く。
3. 初回だけWi-Fi環境でモデルを取得する。アプリ内で他の画面へ移動しても取得は続く。一時停止・アプリ終了後は「ダウンロードを再開」で続きから取得する。
4. 「写真を解析する」で説明が出ることを、写してよい被写体で確認する。
5. 通常の方式で失敗する場合は「解析の設定」の互換モードを試す。設定欄で実際のGPU/CPUと時間を確認できる。
6. オフライン、再実行、中止、戻る、モデルの削除を確認する。

端末側でインストール確認が出た場合は許可が必要。今回の実機では最初のUSBインストールが `INSTALL_FAILED_USER_RESTRICTED` で停止し、端末側の確認を依頼した。既存アプリはアンインストールしていない。

### ホストからモデルを配置して通信なしで準備する

開発用の debug プレビューをインストールした場合だけ利用できる。通常の Release APK では `run-as` は使えない。

```sh
CAMEREON_AI_PREVIEW=1 flutter build apk --debug --target-platform android-arm64
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk
python3 tools/vlm-eval/prepare_app_model.py \
  --serial <device-id> --model /path/to/gemma-4-E2B-it.litertlm
```

専用領域 `files/ai/models/` へモデルだけを転送し、ホストと実機のSHA-256を照合する。写真や既存ベータのデータは読み書きしない。
その後、同じプレビューID・同じローカルdebug署名のRelease APKへ更新すれば、モデルを保持してRelease相当で確認できる。

```sh
CAMEREON_AI_PREVIEW=1 flutter build apk --release --target-platform android-arm64
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-release.apk
```

撮影なしの合成サンプルで画面を確認する場合は、ビルド・起動に `-t lib/analysis_demo.dart` を指定する。
このサンプルはVLMの内容説明を試すもので、#15 の編集・保存までのデモの完了には含めない。

解析画面と空き容量不足の確認記録: [スクリーンショット](evaluation-evidence/2026-10-20-vlm/main-ui/storage-error.png)、[実施条件](evaluation-evidence/2026-10-20-vlm/main-ui/verification.json)。

## 初回の確認状況と完了条件（2026-10-20時点）

- APKのDebug/Releaseビルド、静的解析、既存10テストは成功
- AndroidManifestで minSdk=30 とプレビュー用の別IDを確認
- エミュレーターで解析画面、合成画像の表示、モデル未配置、空き容量不足の表示を確認。本体の推論は、開発機の一時領域不足で配置・再起動を完了できず未確認
- 実機のAndroid 16 / ARM64と十分な空き容量は確認。インストールは端末側の許可待ち
- 実機の画像解析、GPU/CPU、メモリ、オフライン、再実行・中止・戻るを確認するまで #28 は完了にしない
- #23 は単独推論の比較が済んでいるが、実機確認の残件を維持
- #9/#10/#11 は各担当の受け入れ条件と結合確認で完了判断。今回の解析追加では閉じない
- #13/#14 の顔・文字の検出、#24 のリスク評価は後続

今回作成したローカルプレビュー APK は `dist/ai-preview/camereon-ai-preview.apk`（約61.3MB、Git管理外）。
プレビューは本体の通常起動・撮影後の解析入口を含む Release ビルド。合成サンプルの画面には開発用の Debug APK を使った。
開発機の容量確保のため、今回ダウンロードした再取得可能なモデルキャッシュと生成済みビルドフォルダは整理し、APK・ソース・検証結果は保持した。
ホストからのモデル再配置には、固定した配布元からモデルを再取得するか、アプリ内の取得ボタンを使う。

## 統合・実機検証（2026-10-21）

修正・検証対象は PR #30。端末は Xiaomi 14T Pro / Android 16 / ARM64。
通常の編集・黒塗り・保存の実装を最新mainから取り込み、API 30以上で動作させた。

- モデル管理のSHA-256検証を、HTTPクライアントを捕捉しないトップレベル関数からisolateへ渡すよう修正。これによりモデル取得の正常系が失敗する不具合を解消した。
- 空き容量不足・ハッシュ不一致・サイズ不一致・中止・重複操作・既存モデルの保持と、画面の成功・失敗・再試行・削除・離脱を自動テストへ追加。解析画面から戻った際の編集状態保持も確認。
- 静的解析と全76テストが成功。CPU互換モードはテキスト・画像の両方にCPUを指定する。
- 固定モデルをUSB配置し、ホストと実機のサイズ・SHA-256を照合。実機のSDKで画像推論・中止・重複実行の拒否・中止後の再実行・モデル削除が成功。

| 実行 | 実際のテキスト / 画像バックエンド | 完了時間 |
| --- | --- | ---: |
| 通常モード | GPU / CPU | 22.269秒 |
| 互換モード | CPU / CPU | 11.525秒 |
| 中止後の再実行 | CPU / CPU | 11.690秒 |

入力はリポジトリ内の架空の荷札で、名前・住所・電話番号を含む情報カードとして内容を説明できた。
Debugビルドで各1回の確認であり、キャッシュや実行順を統制した性能比較ではない。
GPU推論中の手動スナップショットはPSS 3,237,134 KiB、プロセスの最大RSS記録は約2.84 GiB。
全端末の必要RAM・発熱・長時間利用の性能を保証する値ではない。

[合成画像の出力・時間・確認項目](evaluation-evidence/2026-10-21-device/gemma-result.json)と
[後半のメモリサンプル](evaluation-evidence/2026-10-21-device/memory-samples.json)を保存した。
通常の写真・認識文・端末シリアルは記録に含めない。

実機用の任意実行テストは `integration_test/analysis_device_test.dart` と
`integration_test/analysis_screen_device_test.dart`。通常CIでは実モデル推論をスキップする。

```sh
CAMEREON_AI_PREVIEW=1 flutter test integration_test/analysis_screen_device_test.dart \
  -d <device-id> --dart-define=RUN_AI_DEVICE_TESTS=true
# 初回配置は別ターミナルで、テストAPKのインストール後に実行する。
python3 tools/vlm-eval/prepare_app_model.py \
  --serial <device-id> --model /path/to/gemma-4-E2B-it.litertlm
```

検証用スクリプトは、モデルの初回配置では待機中のテストアプリを停止しない。
既存モデルを差し替える際は、読み込み中のファイルを置き換えないよう停止する。

残る確認は実際の日常写真での精度、機内モードでの実撮影、長時間利用と発熱、
モデルの全容量をアプリ内の取得ボタンから取得する実機確認。
モデル取得の異常系と整合性は小さな検体による自動テストで確認している。
#23/#28 はこれらの残件を維持し、自動クローズしない。

追加の実機画面テストも成功。DartのHTTPクライアント生成を禁止した状態で、
編集 → 実際の解析画面にGPU推論結果を表示 → 編集へ戻る → 選択保持 →
保存前確認 → MediaStore保存 → 成功表示 → 一時ファイル削除を確認した。
機内モードで端末全体の通信を切った試験とは区別する。
最終ソースから通常起動のARM64 Releaseプレビュー（約61.5MB）もビルドした。
通常のAndroid CIは起動・加工・保存の3ファイルを明示実行し、モデルが必要な任意実行テストの空APKビルドを避ける。

配布APKの検査で、AI依存のJNIライブラリが他のABIも含めて混入することを確認したため、
Flutterのtarget-platformに合わせてJNIも絞り込む設定を追加した。
ベータ公開前の検査もARM64以外の混入を拒否する。x86_64の通常端末テストは維持する。

## 撮影画像とモデル取得の修正（2026-10-21）

- 編集の画像読み込みを `FlutterPhotoProcessor` に変更。解析・プレビューと同じ端末デコーダーで画素と向きを確定し、元のEXIF・サムネイルを持たないPNGを編集へ渡す。JPEG書き出しは既存のisolateの黒塗り・メタデータ除去処理を維持する。
- 重複EXIFを持つ合成JPEGで「解析は表示できるが旧編集デコーダーは拒否する」条件を再現。EXIF Orientation 1〜8の寸法・向きと、黒塗り後のメタデータ除去を自動テスト。
- モデル取得は1 MBを上限に書き込みをまとめ、ネットワークの各チャンクでのflushを廃止。画面移動中の継続、途中データの復元、Range非対応時の安全な再取得、Content-Range不一致、破損、残り容量の確認をテストする。
- 実際の固定モデルURLへ `Range: bytes=1048576-1048576` を送り、206 / `bytes 1048576-1048576/2588147712` と1バイトの応答を確認。

今回のユーザーの実写そのものを取得・検査したわけではない。追加作業開始時点でUSB実機は未接続。端末全体のバックグラウンド制限を回避するforeground serviceは導入していないため、OSで通信を止められた場合は再開操作が必要。
