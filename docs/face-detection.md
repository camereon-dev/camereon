# Issue #13 顔候補の実装と検証

現在の編集UIは、写真上の顔枠を直接タップして適用・解除する。「顔だけ」で他の種類の候補枠を隠せる。番号ボタン・手動ドラッグ・一括適用は表示しない。以下の過去の評価記録にある個別ボタン操作は、その評価時点のUIを指す。最新の操作は[検出器の統合](detection-integration.md)を参照。

2026-10-27。既存ベース ffd16c7。顔検出・編集接続は実装、実機の受け入れ確認は未完了。

## 実装

- Android: `com.google.mlkit:face-detection:16.1.7` の同梱モデル。Kotlin MethodChannelアダプター。Gemmaのモデル確認・取得・推論を呼ばない。
- 正規化済み SourcePhoto のPNGのみを渡す。ワーカースレッドでデコードし、回転0のBitmapを推論。撮影画像や検出結果をファイル・ログ・外部APIへ送らない。
- 同時実行はネイティブで1件。検出器はリクエストごとに作成・解放する。キャンセルは世代番号による遅延結果の破棄であり、実行中の推論は終了まで画像を保持する。
- 暫定設定: ACCURATE、最小顔サイズ0.05、検出入力の長辺最大1600、枠の各辺へ幅・高さの10%の余白。ランドマーク・輪郭・分類・追跡は無効。性能・小さい顔の精度の採用保証は未実施。
- 実際の検出入力寸法からx/yを独立にSourcePhotoへ復元し、HideRegion.fromRectで外丸め・クリップ。表示とタップ判定は同じ画像矩形を使用する。
- 枠タップで個別適用・解除。顔IDから安定した候補へ変換し、全種類で選択・取り消し履歴を共有する。同位置の別種類は独立して選択でき、保存時だけ同じ範囲をまとめる。
- 検出中も検出済み候補の選択・保存が可能。保存前確認時に検出を論理キャンセルし、適用済み領域だけをスナップショットで既存redactへ渡す。保存失敗・編集復帰は状態保持。
- 顔なし、失敗、キャンセルを区別。失敗・キャンセル時に再試行可能。Gemma画面への遷移・アプリ非表示・画面破棄では検出結果を無効化する。

## 2026-10-27 エミュレーターでの検証結果

対象はベース `ffd16c7` に本作業ツリーの #13 変更を加えたもの。今回の追加変更は結合テストと検証記録であり、検出設定・本体の保存処理は変更していない。

### 接続不調の調査と復旧

- Pixel_10a AVD、Android 17 / API 37（`android-37.2/google_apis_playstore_ps16k/arm64-v8a`）、Emulator 37.1.11。AVDの実体は `Pixel_10a.ini` が指す `Pixel_10a_2.avd`。通常の名前から推測したパスではなかった。
- `adb devices` は `device`、`sys.boot_completed` は1。ゲスト `/data` の空きは5.8 GB。確認できた既存アプリ終了記録はユーザー要求のforce-stopで、ML Kitのクラッシュ／ANRを示す記録ではなかった。
- APKインストール後にVM ServiceのWebSocket接続が切断し、同時に `adb shell pidof` なども応答しない状態を再現した。`adb get-state` は `device` を返すため、それだけでは正常判定できない。
- `adb -s emulator-5554 reconnect` 実行後、`adb shell echo connection-ok` が即時に成功。その後の同じテストは端末上で実行・完走できた。エミュレーターの再作成・初期化やアプリ本体の変更は不要だった。
- **確認できた故障箇所はadb接続層の停滞**。なぜ停滞したか（エミュレーター／adbd／ホストのどこが起点か）は特定できていない。GradleのJava警告を原因とする証拠もない。再発時は一件ずつ実行し、shellの応答確認と再接続を行う。

### 初回オフラインとGemma未導入

- 既存の通常アプリを維持するため、`CAMEREON_AI_PREVIEW=1` の検証用ID `dev.camereon.camereon.demo.ai_preview` を使用。
- インストール前に検証用アプリが存在しないことを `pm list packages` で確認。失敗した試行から再実行するときは今回作成した検証用アプリだけを `pm clear`。最終実行前にも検証用パッケージなしを確認した。
- **インストール・初回起動前**に機内モードを有効にし、Wi-Fiとモバイル通信を明示的に無効化。値は `airplane_mode_on=1`, `wifi_on=0`, `mobile_data=0`、`dumpsys connectivity` は `Active default network: none`。開発PCはビルド依存の取得に通信を利用する。
- Gemmaモデルの配置・ダウンロードは一切行わず、テスト開始時にアプリsupport領域に `.litertlm` がないことも検査。
- テストの最初のML Kit呼び出しは `CapturedPhotoScreen` の自動検出。先に直接APIを呼んでウォームアップしない。顔候補表示と個別適用・解除・再適用が成功した。

### 保存先からの検証

実際のML Kit → 候補表示 → 個別適用 → 既存 `PhotoProcessor.redact` → 保存前確認 → 実際の `AndroidPhotoSaver` → MediaStore保存が完走した。

テストは `Pictures/camereon` の保存前後の差分から、新しく作られたアプリ所有JPEGだけを読み出す。メモリ上の保存入力だけで合否を判定しない。

- 保存先JPEGと保存入力のSHA-256が一致。
- 保存先JPEGのサイズが820×1024、EXIFなし。
- 適用領域 `[284,47,524,367]` の内側全画素（JPEG境界の影響を避けて各辺2画素内側）がRGB各成分5未満。領域外の画素は明るさを保持。
- テスト終了後にMediaStoreの登録も確認。`content://media/external/images/media/26` を `adb exec-out content read` で別途読み出し、同じSHA-256になった。URIのIDはこのエミュレーターの今回の値であり再実行では変わる。
- SHA-256: `641acf590915697ecb1507af6f776a992cfe64c9c36a4e34623b7479b94047c2`。
- URIから読み戻した画像を目視して、顔の黒塗りと周囲の画像が残ることも確認。
- Flutterテスト終了時に検証アプリはアンインストールされる。MediaStore行の `owner_package_name` はその後NULLになったため、終了後の確認は所有者ではなく保存先・ハッシュで照合した。

### 画像別の結果と制約

入力画像は一時領域のみ。画像そのものをリポジトリへ追加しない。出典の公開テスト画像を使用したことと、自由な再配布の許諾が確認できていることは同義ではない。再配布せず、独自画像への置換時は使用許諾を確認する。

| ケース | 用意した入力 | 可視の顔数 | ML Kit候補数 | 結果 |
| --- | --- | --- | --- | --- |
| 正面 | MediaPipe portrait.jpg、820×1024 | 1 | 1 | 検出・UI適用・保存先読み戻し成功 |
| 複数人 | GoogleのMediaPipeサンプルが参照する2人画像、1280×853 | 2 | 3 | 過検出。左側の人物に重なる候補が2つ返る |
| 複数人・縮小比較 | 同じ2人画像を幅640へ縮小、640×427 | 2 | 2 | この入力では重複候補なし |
| 小さい顔 | 正面画像を高さ256へ縮小し1600×1200の単色背景に配置 | 1 | 1 | 余白付き候補59×79画素 |
| さらに小さい顔 | 正面画像を高さ128へ縮小し同背景に配置 | 1 | 1 | 余白付き候補31×41画素 |
| 斜め向き | OpenCV lena.jpg、512×512 | 1 | 1 | 斜め向きでの検出。真横の横顔の代用とはしない |
| 真横の横顔 | 今回は用意できていない | — | — | 未検証。エミュレーターで追加可能な残作業 |
| 顔なし | 640×480の単色生成画像 | 0 | 0 | 候補なし。自然風景での誤検出評価ではない |

小さい顔は縮小合成による制御画像であり、遠距離撮影時のぼけ・暗所・圧縮劣化を評価したものではない。候補サイズは10%余白と丸めを含むため、顔そのものの画素サイズではない。

2人画像は当初「2件」を期待するアサーションが**実測3件で失敗**した。これを隠さず、機能回帰テストと精度評価を分離し、可視の顔数・検出数・全座標を記録するようにした。最終テストの成功は精度の全面的な採用合格を意味しない。入力解像度による重複候補の変化が確認されたが、小さい顔への影響があるため設定や重複除去ルールをこの検証だけで変更していない。

画像出典:

- [MediaPipeの正面画像](https://storage.googleapis.com/mediapipe-assets/portrait.jpg)
- [Googleの顔検出サンプルノートブック](https://colab.research.google.com/github/googlesamples/mediapipe/blob/main/examples/face_detector/python/face_detector.ipynb) が参照する [2人画像](https://i.imgur.com/Vu2Nqwb.jpeg)
- [OpenCVの斜め向き画像](https://raw.githubusercontent.com/opencv/opencv/master/samples/data/lena.jpg)

入力SHA-256、全座標、通信条件、保存画像ハッシュは [機械可読な評価記録](face-detection-evaluation.json) に保存した。JPEGの直接入力とPNG再エンコードを経た評価では座標がわずかに異なる。保存検証では実際にUIへ返った候補座標を使っている。

### その他の確認

- `integration_test/face_detection_test.dart`: 最後まで成功（実ML Kit、UI、保存先読み戻し、画像別評価、EXIF回転正規化）。
- `mise run check`: format・analyze・全104テスト成功。
- `integration_test/photo_edit_save_test.dart` の個別実行: サンプル編集、向き付き画像、カメラメタデータ付き画像の編集→確認→保存→撮り直し・一時ファイル片付けの3テストが成功。
- 同梱モデルと既存Flutter Edge AI / LiteRT-LMを含むビルド成功。これは依存の共存確認であり、Gemma推論との同時実行性能の保証ではない。
- EXIF Orientation 6の生成画像を正規化し、元のサイズと顔位置が許容差内で一致。実カメラの姿勢・ミラー挙動は別途未確認。
- 前回未完走だった既存端末テストも、検証用アプリID・`--concurrency=1` で再実行し、`app_test.dart`、`gallery_save_test.dart`、`photo_edit_save_test.dart` の全6テストが成功。起動、MediaStore保存、不正JPEG拒否、手動編集・確認・保存・撮り直しまで検証した。`mise run device-test` にも直列実行を明示した。並行実行が接続停滞の唯一の原因だったとまでは断定しない。

## 再現手順

```sh
# 検証端末を明示。adbがdeviceでもshellが止まる場合だけ再接続する。
adb -s emulator-5554 reconnect
adb -s emulator-5554 shell echo connection-ok

# 初回起動前に設定する。通常アプリのデータは消さない。
adb -s emulator-5554 shell cmd connectivity airplane-mode enable
adb -s emulator-5554 shell svc wifi disable
adb -s emulator-5554 shell svc data disable
adb -s emulator-5554 shell settings get global airplane_mode_on
adb -s emulator-5554 shell settings get global wifi_on
adb -s emulator-5554 shell settings get global mobile_data
adb -s emulator-5554 shell dumpsys connectivity
adb -s emulator-5554 shell pm list packages dev.camereon.camereon.demo.ai_preview
# 検証用アプリが残っている場合のみ、今回の検証用データをリセットする。
# adb -s emulator-5554 shell pm clear dev.camereon.camereon.demo.ai_preview

python3 - /absolute/path/front.jpg /absolute/path/two-people.jpg /absolute/path/oblique.jpg <<'PYTHON'
import base64, json, pathlib, sys
keys = ['FACE_FIXTURE_BASE64', 'FACE_GROUP_BASE64', 'FACE_OBLIQUE_BASE64']
pathlib.Path('/tmp/face-defines.json').write_text(json.dumps({
    key: base64.b64encode(pathlib.Path(path).read_bytes()).decode()
    for key, path in zip(keys, sys.argv[1:])
}))
PYTHON
CAMEREON_AI_PREVIEW=1 mise exec -- flutter test integration_test/face_detection_test.dart -d emulator-5554 --dart-define-from-file=/tmp/face-defines.json --reporter expanded
mise run check
CAMEREON_AI_PREVIEW=1 mise run device-test
```

正面画像は必須。2人・斜め向きのdefineを省くとそのケースは評価されないので、出力の `fixtures` に含まれるものだけを実施済みとする。入力画像を埋め込んだテストAPK、definesファイル、読み戻した写真をコミット・配布しない。

保存先ファイルの検査はAndroidエミュレーターの標準パスを使う。異なる環境では `FACE_GALLERY_DIRECTORY` を指定する。読み戻しに失敗した場合は成功扱いにせずテストが失敗する。

検証終了時にはエミュレーターが未接続だったため、通信設定の復元コマンドは実行できなかった。通常利用へ戻す際は、起動後に機内モードを解除し、必要に応じてWi-Fi・モバイル通信を有効化する。

## 残る確認とIssue完了条件

| 条件 | エミュレーターで確認済み | 残る確認 |
| --- | --- | --- |
| ネットワークなしで候補表示 | 初回起動前から通信なし・Gemmaなしで、実ML Kitの候補が編集画面に表示 | 実機での初回オフライン動作 |
| 適用が手動黒塗りと同じ扱いで保存される | 実UI→既存加工→MediaStore保存→保存先読み戻し・画素検査、URI経由の同一性確認 | 実機の写真アプリでの最終確認 |
| 縦・横・前面カメラで位置がずれない | 正規化座標とEXIF回転入力の一致 | 実機カメラ固有の撮影方向、前面ミラー・反転 |

エミュレーターで追加可能な残作業: 真横の横顔、自然風景、暗所・遮蔽の画像評価、重複候補の扱いの検討。

実機で未確認: 実カメラの向き・反転、初回／繰り返し時間、ピークメモリ、発熱、連続撮影、Gemma推論との共存性能。今回のエミュレーター結果から実機性能を保証しない。

Issue全体の実機確認は未完了。一括適用、MediaPipe比較、統合リスク判定は今回の対象外。

## origin/main 統合の確認（2026-10-27）

統合元: `origin/main` の `e8cfcba`（文字領域検出 #36、配布CI・APK名の更新 #35）。Issue #13側の親は `72f238b`。作業開始時に未コミット変更はなかった。

競合した5ファイルは、次の意図で統合した。

- Android Gradle: 同梱ML Kitと文字検出用ONNX Runtimeを両方保持。mainのProGuard設定も保持。
- MainActivity: 顔・文字の両ハンドラーを登録・解放し、mainのバージョン情報チャネルも保持。
- PhotoAnalysisEntry: mainの「編集画面で読み込めたSourcePhotoをGemmaへ渡す」「読み込み失敗中は解析へ進めない」と、顔検出側の画面被覆通知・二重遷移防止を両立。
- CapturedPhotoScreen: 顔・手動編集の履歴を保持し、文字候補の選択・解除・一括適用・再検出はmainの仕様を維持。保存時は両方の範囲を合わせ、全リセットは両方の選択と顔・手動の履歴を消す。片側の解除で相手の同座標範囲を消さない。顔の一括適用は追加していない。
- mise.toml: 文字検出の端末テストを追加しつつ顔テスト用タスクを保持。今回のFlutter実行では `--concurrency` はintegration testで無効という警告が出たため、device-testは各ファイルを独立コマンドとして順に実行する配列に変更した。過去の `--concurrency=1` 指定だけを直列実行の保証とはしない。

CI・配布処理、GemmaのCPUフォールバック・エラー表示、アプリバージョン表示もmainから維持した。スクロールする操作パネルに合わせてテストは可視化後に操作し、文字候補の配置検査はスクロールによる全体移動を除いて比較する。

確認結果:

- `mise run check`: 静的解析・整形・全120テスト成功。顔と文字が同じ範囲の場合の個別解除、顔の取り消し、文字一括適用、保存、全リセットの混在回帰テストを追加。
- `mise run apk`: release APKビルド成功。同梱ML Kit・ONNX Runtime・既存Gemma依存が共存。
- オフラインのPixel_10aエミュレーターで `app_test.dart`、`gallery_save_test.dart`、`photo_edit_save_test.dart`、`text_regions_device_test.dart`、`face_detection_test.dart` の全9結合テスト成功。検証用アプリIDを使用し、Gemmaモデルの準備はしない。
- 実際の文字モデルで候補表示→個別切り替え・一括適用→JPEG保存が成功。実際の顔モデルでも候補表示→個別適用・解除→保存先JPEG読み戻し・黒塗り検査が成功。
- 顔評価の既知の制約（2人の原寸画像で3候補）は変わらず、隠さず記録。保存画像ハッシュは前回と同じ `641acf590915697ecb1507af6f776a992cfe64c9c36a4e34623b7479b94047c2`。
- 配布スクリプトはPython 3.15で `python -m unittest discover -s scripts/tests` の9テスト成功。macOS標準Python 3.9ではテスト側の `TestCase.enterContext` がなく起動時に失敗したため、対応ランタイムで確認した。スクリプトを古いPython向けに改変していない。

実機固有の向き・反転や性能の未確認事項は変わらない。
