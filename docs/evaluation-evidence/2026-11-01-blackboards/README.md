# 公開された黒板写真での確認

**判定: 不合格。PR #44 はマージしない。**

この記録は修正前の結果。[その後の検出改善とOCR併用の再評価](../2026-11-01-text-recovery/README.md)を参照。文字起こしに関する以下の記述も評価時点の仕様であり、現在は認識文字列を内部で位置の補助だけに使う。

2026-11-01、PR #44 の `1e13e5dbd9eb04bdd205ac1abcc56a864b3078b9` を、Android 12 API 31 ARM64 エミュレーターの Debug ビルドで実行した。公開画像4枚を推論前に選び、文字に都合のよい切り抜きは行わず、写真全体を通常の正規化・転送・ネイティブ検出へ渡した。モデル・しきい値・フィルターは変更していない。候補枠を元画像へ重ね、各画像の読める主要な文字に明確な行抜け・部分抜けが残らないことを確認条件とした。

現在の機能は文字の**位置の検出**であり、文字列を返すOCR認識器はない。文章の正確な文字起こしを合格条件にする場合も、現状は満たさない。

## 目視結果

| 画像 | 従来→詳細の候補数 | 従来→詳細 ms | 不合格となる具体例 |
| --- | ---: | ---: | --- |
| [暗号の手書き黒板](https://commons.wikimedia.org/wiki/File:Mathematics_(cryptography)_on_a_blackboard.jpg) | 16→30 | 1393→4976 | 左の `Picks a`、斜めの `Sends A` が未検出。斜めの `Swaps A for …` も大部分が枠に入らない。 |
| [日本語の献立表](https://commons.wikimedia.org/wiki/File:School_lunch_menu_board_(939283104).jpg) | 86→99 | 439→5378 | 大きな見出し・栄養量の数値は多く検出するが、円弧上の日本語が断片的で、読める部分も残る。主に印刷文字であり、手書きの合格例ではない。 |
| [日本の教室](https://commons.wikimedia.org/wiki/File:JapaneseClassroom.jpg) | 6→13 | 415→3873 | 手書き予定表の見出しと一部注記は拾うが、日付23〜29や右側の授業欄を大きく見落とす。遠くて薄い条件で弱い。 |
| [熱力学の手書き黒板](https://commons.wikimedia.org/wiki/File:Two-blackboards1783.jpg) | 12→12 | 319→3561 | 大きな数式の多くは囲むが、箇条書きの番号1・3が枠の外に残る。元画像の端で欠けた文字・消し跡は判定対象から除いた。 |

各方式1回の壁時計値。転送・セッション生成を含み、正規化は除く。全件 `truncated=false` であり、500候補の上限到達ではない。網羅的な正解ラベルは作っておらず、精度率・再現率は算出しない。追加された候補数を「正しく読めた文字数」と解釈しない。

検出候補をすべて黒塗りしたJPEGでは、元の解像度、候補中心の黒画素、EXIF除去を自動確認し、献立表1枚はAndroidギャラリーへの保存成功も確認した。これは保存経路の検証であり、文字の検出漏れは救えない。検証用の一括黒塗りはテスト内だけで、製品UIへの追加ではない。

## 記録と出典

- [sources.json](sources.json): 原画像のURL、SHA-256、サイズ、作者、ライセンス。
- [results.json](results.json): 評価コミット、端末、全候補の元画像座標、時間、目視所見。
- `integration_test/blackboard_text_device_test.dart`: 実際のAndroid検出器・画像処理・保存器を呼ぶ、明示的な有効化が必要なテスト。テストの成功は目視合格を意味しない。

原画像と枠付き・黒塗りの派生画像は `.private/blackboard-eval/` に保存し、Git・APKには収録しない。原画像のクレジットは David Malone（暗号、CC BY 4.0）、Toshiyuki IMAI（献立表、CC BY-SA 2.0）、tony cassidy（教室、CC BY-SA 2.0）、alegri / 4freephotos.com（熱力学、CC BY 3.0）。各ライセンスのリンクはマニフェストに含む。

## 再現手順

1. `sources.json` のURLから4枚を取得し、SHA-256を照合する。
2. 次のコマンドを実行する。テストAPK導入でアプリ領域が消えるため、画像の配置はテスト名がログへ出た後に行う。

   ```sh
   CAMEREON_DETECTOR_PREVIEW=1 mise exec -- flutter test integration_test/blackboard_text_device_test.dart -d emulator-5554 --dart-define=RUN_BLACKBOARD_TEXT_TESTS=true --reporter expanded
   ```

3. 別ターミナルから `adb -s emulator-5554 shell run-as dev.camereon.camereon.demo.detector_preview mkdir -p files/blackboard-eval` を実行。`adb shell run-as … sh -c 'cat > files/blackboard-eval/<id>.jpg'` の標準入力で4枚を配置する。**最後に**同じ方法で `sources.json` を配置する。3分以内に配置する。
4. `BLACKBOARD_READY` が出たら60秒以内に `adb exec-out run-as … cat files/blackboard-eval/results.json` と各 `<id>-masked.jpg` をファイルへ取り出し、`adb shell run-as … touch files/blackboard-eval/collected` で確認を返す。ここで `…` は上記のアプリID。
5. 元画像へ結果の `runs.detail.boxes` を重ねて目視確認する。座標は `[left, top, right, bottom]`。候補数の増加だけでは合格にしない。テスト後、`mise run detector-debug-install -- emulator-5554` で通常アプリへ戻す。

合成の極小文字20行の改善は維持されているが、今回の黒板では不十分だった。薄い手書き・斜め文字・曲線上の文字・孤立した文字への対策を検討し、独立した画像も加えて再評価する必要がある。
