# 黒板の検出漏れを減らす追加変更

> 2026-11-02: この記録のOCR位置補助は[公開実写18枚の再評価](../2026-11-02-real-world/README.md)で追加がほぼなく撤去した。分割方式も変更している。以下は当時の記録。

**一部の見落としは改善。黒板の明確な検出漏れが残るため、PR #44 のマージは保留する。**

評価コミット: `b15aeb2997ac1402f10fefad6bb5fa26da1f17cf`。Android 12 API 31 ARM64 エミュレーター、Debug、CPU。前回の公開4画像を全体のまま再使用し、別作者の大きな手書き数式1枚も追加した。追加画像は最初の幾何処理変更後、当該画像での推論前に選択した。最後のOCR枠の調整には5枚とも使用しており、独立したブラインド精度試験ではない。

## 変更と比較条件

- 水平矩形内の平均から、確率成分の凸包の最小面積回転矩形内の平均へ変更。斜め文字の外側の背景を採点に混ぜない。文字間・穴の背景は採点対象とし、疎なノイズを高スコアにしない。
- 概要を960pxから1536pxへ変更し、細部の切り出しで分断される行の文脈を残す。最大26回のPP-OCR推論という上限は維持する。
- 正方形に近い細部成分を一律に除外せず、スコア0.75以上なら一文字の数字・文字を残す。通常の矩形しきい値0.6・確率しきい値0.3は維持する。
- 同梱日本語ML Kit OCR 16.0.1 を全体へ1回実行。信頼度0.5以上の英数字・日本語を含む単語単位の位置を追加する。認識できないことを理由に、先に検出した枠を除外しない。認識文字列はネイティブ内のメモリだけで扱い、Dart・ログ・保存・UIへ返さない。
- 初回実験のOCR行全体の矩形は、曲線上の単語を広く囲みすぎたため不採用。単語単位に変更した最終結果を以下に示す。認識信頼度はこの補助段階だけに使う。

比較モードは `baseline`（旧960px・水平採点・OCRなし）、`geometry`（新しい採点・1536px概要・分割、OCRなし）、`detail`（geometry + OCR補助）。前回の詳細検出はコミット `1e13e5d` の[記録](../2026-11-01-blackboards/README.md)を参照。

## 同じ公開画像での結果

| 画像 | 前回の詳細候補数 | geometry | OCR併用 | 目視で確認した改善・残る問題 |
| --- | ---: | ---: | ---: | --- |
| 暗号の手書き黒板 | 30 | 32 | 32 | 前回漏れた `Picks a`、`Sends A`、斜めの `Swaps …` を囲める。改善の中心は幾何処理。重なる断片枠は残る。 |
| 日本語の献立表 | 99 | 74 | 78 | 曲線上の印刷文字を、よりまとまった部分として検出。数値が一行に統合されるため、候補数の減少は文字の減少を意味しない。OCRが円弧下部の小さな文字などを追加するが、全周の文字は覆えない。 |
| 日本の教室 | 13 | 37 | 37 | 日付23〜28・曜日列の検出を改善。OCRは見出し・既存の注記などの枠を補うが、29日と右側の薄い授業名の大部分は未検出。窓などにも誤候補が出る。 |
| 熱力学の手書き黒板 | 12 | 13 | 13 | 前回漏れた番号1・3に枠が出る。3の長い曲線の末尾は一部枠外。OCRから有意な追加はない。 |
| 追加の大きな数式 | 未測定 | 20 | 20 | 旧baselineは3候補。中央の変数・下の式の検出は増えるが、先頭の大きなC、括弧、右下の記号などを見落とす。大きな文字のストロークを断片として拾う問題も残る。 |

**候補数は精度率ではない。** 網羅的な正解ラベルや文字列の正解を用意しておらず、precision・recall・文字起こし正答率は算出しない。特に数式・手書き・遠くの薄い文字を完全に扱える結果ではない。今回のOCR併用は一部の位置を補うもので、元の検出漏れを全て解決しない。

最終 `detail` の壁時計値は画像順に12994 / 7146 / 4398 / 3665 / 5413ms。転送・セッション作成を含み、正規化は除く。開始時はホストの静的検証・JVMビルドと重なっており、最初の画像には負荷競合がある。各方式1回の値を処理速度の比較や実機性能の根拠にしない。`geometry` と `detail` の前後関係からOCRの処理時間差を算出しない。

## 回帰・保存の確認

- `mise run check`: 整形・解析・134テスト成功。OCRが失敗しても成功した枠の選択を維持でき、再試行後も選択が残ることを含む。
- `mise run text-geometry-test`: JVMの3テスト成功。正負の傾き、矩形内背景による減点、水平・一文字の座標を確認。APKビルドのCIでも実行する。
- 合成の極小日本語20行は、2560pxと3840pxの両方でTP20 / FP0 / FN0を維持。fontSize 8・14も同じ。無地は0候補。IoUは0.3。通常の配送ラベル1280pxは4枠を維持する。
- 公開5画像はOCRを含め `partial=false`・`truncated=false`。黒塗りJPEGで候補中心の黒画素・解像度維持・EXIF除去を確認し、献立表は実Android保存器によるギャラリー保存も成功。
- 実検出器の枠を表示し、ピンチ拡大・タップ選択からJPEGをギャラリーへ保存するAndroid UIテストも成功。テスト後は通常のデバッグアプリを再ビルドしてエミュレーターへ導入した。

保存テストの成功と目視の検出合格は別。実機の速度・発熱は未確認。新しい依存を含む通常Debug APKは273,953,013 bytesで、前回の同じ配布形式より35,066,686 bytes増えた。これはAPKの実測差分であり、OCRモデル単体のサイズではない。合成・実写の測定値、検証コマンド、APKハッシュは[validation.json](validation.json)に記録した。

## 記録と再現

[results.json](results.json)に3モードの全候補座標・時間・目視所見、[sources.json](sources.json)にダウンロードURL・作者・ライセンス・SHA-256を記録。前回4枚のクレジットに加え、追加画像 [Blackboard bold on a blackboard](https://commons.wikimedia.org/wiki/File:Blackboard_bold_on_a_blackboard.jpg) は Jacob Rus、[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)。原画像と枠付き・黒塗りの派生画像は `.private/blackboard-eval/` にのみ保存し、Git・配布APKへ含めない。

マニフェストに従い原画像を `.private/blackboard-eval/input/<id>.jpg` へ用意する。次のテスト開始後、別ターミナルから収集ツールを実行する。ツールはハッシュを照合し、テストAPKのインストール後に画像を配置し、終了前に結果を取得する。

```sh
CAMEREON_DETECTOR_PREVIEW=1 mise exec -- flutter test integration_test/blackboard_text_device_test.dart -d emulator-5554 --dart-define=RUN_BLACKBOARD_TEXT_TESTS=true --reporter expanded > /private/tmp/camereon-blackboards.log 2>&1
```

```sh
python3 tools/detector-eval/blackboards_android.py --sources docs/evaluation-evidence/2026-11-01-text-recovery/sources.json --input .private/blackboard-eval/input --output .private/blackboard-eval/repeated-device --test-log /private/tmp/camereon-blackboards.log --serial emulator-5554
```

テスト後は `mise run detector-debug-install -- emulator-5554` で通常アプリへ戻す。ホスト比較は `small_text.py --oriented` を使用できるが、ML Kitの補助はAndroid側のみであり、ホスト結果を同等のアプリ結果として扱わない。
