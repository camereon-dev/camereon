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
PR #26 は確認時点で書式チェックが失敗していた。また `main.dart` が空の `XFile` で編集画面へ直接入る確認用起動に変わっていたため、カメラ起動を維持する修正が必要。
#9 の選択範囲は元画像の画素座標で #10 へ渡し、`HideRegion` へ接続する。画面上の `Rect` だけでは結合を完了としない。

## コードの配置

- `lib/core/analysis/scene_analysis.dart`: SDK・Widgetに依存しない画像・OCR補足・結果・インターフェース
- `lib/core/analysis/infrastructure/`: 固定モデルの取得・SHA-256検証とLiteRT-LMアダプター
- `lib/features/analysis/`: 縮小用の画像準備、画面・進捗・キャンセル
- `lib/analysis_demo.dart`: 合成画像で同じ本体の解析画面を開く開発用エントリーポイント。通常の起動先は `lib/main.dart`

モデルの固定値は単独検証の `tools/vlm-eval/model.json` と一致させる。モデルを変更するときは両方を更新・再検証する。
通常ログには画像・OCR全文・回答を出さず、SDKのログも無効にする。モデルと会話は1件ずつ実行し、完了・失敗・キャンセルで解放する。
ダウンロードは進捗を表示し、中止・通信エラー・サイズ不一致・ハッシュ不一致で `.part` を削除する。検証済みのファイルだけをモデルとして公開する。
画面を閉じると、その画面が開始したダウンロード・解析を中止する。モデルロード中は native 処理の終了後に解放する場合がある。

## 既存ベータを保って実機で試す

`CAMEREON_AI_PREVIEW=1` を付けると、アプリIDが `dev.camereon.camereon.demo.ai_preview`、表示名が `camereon AI preview` になる。
既存の `camereon beta` を置き換えずに試せる。プレビューはベータ版として公開しない。

```sh
CAMEREON_AI_PREVIEW=1 flutter run -d <device-id>
```

1. Android 11以上・ARM64の実機でUSBデバッグを許可し、ロックを解除する。
2. 撮影後に「端末内で写真を解析」を開く。
3. 初回だけWi-Fi環境でモデルを取得する。取得が終わるまで画面を開いておく。
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

## 確認状況と完了条件

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
