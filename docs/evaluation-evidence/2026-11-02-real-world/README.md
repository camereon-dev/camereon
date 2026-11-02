# 公開実写18枚での再評価と負荷対策

**判定: 文字・顔・人物・画面・車両の候補が公開実写で実用的に出ること、エミュレーター上の文字検出が1枚あたり最大4.3秒・多くは2〜3秒に収まることを確認し、PR #44 をマージする。** 実機の速度・発熱・ピークメモリは未測定で、以下は検出候補の数と目視であり精度率ではない。

評価コミット: `30275cd`（本記録の1つ前のコミット）。Android 12 API 31 ARM64 エミュレーター（4 vCPU・4 GB）、Debug、CPU、ONNX Runtime 1.24.3。2026-11-01の黒板5枚の記録では、合成画像の改善が実写へ一般化するか不明だったため、博物館・図書館・飲食店・駅・名札・駐車場・人混みなど、ウェブ上の公開写真18枚を推論前に選んで全体のまま評価した。

## 画像と出典

[sources.json](sources.json) にWikimedia Commonsの取得URL・作者・ライセンス・SHA-256・サイズを記録した。すべてCC0またはCC BY / CC BY-SA。原画像と枠付き・黒塗り派生画像は `.private/realworld-eval/` にのみ保存し、Git・APKへ含めない。クレジット: デニス モジョ（museum-labels、CC BY 2.0）、Adavyd（museum-label-levitan、CC0）、BurgererSF（museum-intro-label、CC0）、Asturio Cantabrio（library-iida、CC BY-SA 4.0）、Asturio Cantabrio（library-azumino、CC BY-SA 4.0）、Texas State Library and Archives Commission from Austin, TX（library-marathon-signage、CC BY 2.0）、Texas State Library and Archives Commission from Austin, TX（library-digital-signage、CC BY 2.0）、Basile Morin（restaurant-chiyoda、CC BY-SA 4.0）、Kim Ahlström（menu-wall、CC BY 2.0）、Ryohei Noda（menu-today、CC BY 2.0）、terrykimura（station-akihabara、CC BY-SA 2.0）、Nick Richards（station-shinjuku、CC BY-SA 2.0）、Batidei（badge-employee、CC BY-SA 4.0）、DERDAKI ILIAS（badge-wikicamp、CC BY-SA 4.0）、KKPCW（parking-lpr、CC BY-SA 4.0）、Halowand（parking-shizuoka、CC BY-SA 3.0）、PH Car Spotter（car-civic、CC BY-SA 4.0）、Daniel Salomons（louvre-crowd、CC BY-SA 2.5）。

駐車場2枚のナンバープレートは投稿者がぼかし済みで、文字検出の見落としとしては扱わない。

## 変更の要点

1. **分割の削減**: 各軸で「1辺704px以下・64px以上重なる最小枚数」に分割し、約1.5倍で1024pxへ拡大する。2560×1920で20→12枚、1308×1780で20→6枚、1024×681で12→2枚。概要1536pxと最大4×4枚で最大17回。合成の極小文字20行はTP 20を維持（下表）。
2. **OCR位置補助の撤去**: 2026-11-01に追加した同梱日本語ML Kit OCRは、公開18枚のうち16枚で追加候補0件、残りは+3・+1だった（旧コードでの測定）。依存ごと外し、APKを小さくした。
3. **転送を生画素へ**: 長辺2560pxのPNG符号化が0.8〜0.95秒（1024pxでも0.2秒）かかっていた。RGBA画素と寸法をそのまま渡し、ネイティブで `幅×高さ×4` を検査する（約60ms）。
4. **セッション再利用とメモリ**: SHA-256検証済みのONNXセッションをプロセス内で共有し、各推論後にアリーナを縮小する。設定比較中に変種ごとのセッションを保持したところ、テストプロセスが2.9 GBでlow memory killerに終了した。縮小後は複数回の検出でも下記の範囲に収まった。`onTrimMemory`・画面破棄で解放し、`OutOfMemoryError` を含む失敗は候補なしで返してアプリを落とさない。
5. **スレッド数**: 4 vCPUのエミュレーターで2→4スレッドは1.2〜2.3倍速かった。コア数−1を2〜4に収める（このエミュレーターでは3）。XNNPACK実行プロバイダーは全画像でCPUより遅く不採用。
6. **顔の最小サイズ 0.05→0.02**: 美術館の人混みで5→9顔（+58ms）。追加された4つはいずれも背景の実在の顔で、他2枚は変化なし。
7. **車両候補**: car・motorcycle・bus・truckを「車両」として追加（ナンバープレート用）。駐車場で9台、小さな1枚でも隣接車を含む。同じ車がcarとtruckで二重に出る問題は、車両同士は種類をまたいで統合し、他車両に80%以上含まれる部分枠を捨てることで抑えた。
8. **顔と重なる文字候補の非表示**: 目・眼鏡として顔の内側に出る文字枠と、スカーフの縁など顔の大部分を囲むだけの斜め成分の文字枠を、編集画面で表示しない。選択済みは残し、顔と一致する枠は従来の選択メニューのまま。
9. **物体→文字の順**: 速い人物・画面・車両の枠を先に表示し、時間のかかる文字の分割を後に回す。

試して採用しなかった案: 概要の確率マップが無反応な分割を省く（図書館の背表紙など、概要が0.0でも分割だけが拾う領域が31枚あり不可）、平坦な分割の省略（省けるのは199枚中4枚）、斜め成分を短い軸平行矩形へ分割（わずかに傾いた手書き行まで分かれて候補が増える）。

## 文字検出: 公開18枚のAndroid結果

各1回の壁時計値（ms）/ 候補数。転送・ネイティブ処理を含み、正規化を除く。「2026-11-01 詳細」は旧分割＋OCRの値で、最初の8枚はホスト側のPython評価と重なって遅い（通過回数21〜26回は正確）。

| 画像 | 転送前サイズ | 従来960 ms / n | 2026-11-01 詳細 ms / n | 今回 詳細 ms / n |
| --- | --- | ---: | ---: | ---: |
| museum-labels | 1024×681 | 669 / 4 | 15170 / 4 | **520** / 4 |
| museum-label-levitan | 2475×2259 | 231 / 12 | 40062 / 12 | **3606** / 12 |
| museum-intro-label | 1308×1780 | 148 / 20 | 17972 / 21 | **1233** / 21 |
| library-iida | 5467×3634 | 464 / 4 | 18702 / 52 | **2310** / 45 |
| library-azumino | 5792×3851 | 561 / 9 | 10930 / 74 | **2453** / 65 |
| library-marathon-signage | 3024×4032 | 336 / 2 | 10722 / 9 | **2459** / 6 |
| library-digital-signage | 3024×4032 | 290 / 3 | 6093 / 18 | **2452** / 22 |
| restaurant-chiyoda | 3762×4559 | 416 / 22 | 6747 / 113 | **2883** / 109 |
| menu-wall | 3008×2000 | 208 / 15 | 5762 / 31 | **2130** / 30 |
| menu-today | 4576×3432 | 385 / 99 | 5382 / 105 | **2596** / 108 |
| station-akihabara | 4752×3168 | 332 / 0 | 5062 / 16 | **2156** / 12 |
| station-shinjuku | 2048×1536 | 178 / 5 | 6406 / 10 | **2257** / 14 |
| badge-employee | 1017×715 | 130 / 4 | 3840 / 21 | **724** / 14 |
| badge-wikicamp | 5568×3712 | 499 / 2 | 5751 / 36 | **2322** / 34 |
| parking-lpr | 3489×2004 | 229 / 1 | 4089 / 7 | **1914** / 9 |
| parking-shizuoka | 4288×3216 | 363 / 1 | 11789 / 13 | **2814** / 7 |
| car-civic | 698×491 | 116 / 0 | 225 / 1 | **99** / 1 |
| louvre-crowd | 3766×2596 | 392 / 1 | 7237 / 10 | **4264** / 11 |

合計: 2026-11-01 詳細 181941 ms → 今回 39192 ms。最大 4264 ms（人混みの写真）。全件 `truncated=false`。

候補数の増減は分割の粒度の違いで、文字の増減ではない。黒塗り出力（全候補を黒塗り）の目視では、駅名標の全文字、博物館ラベル4行、飲食店の主要な看板、献立表・手書きメニューの各行、名札の氏名、図書館の掲示とタイトルの多くを覆った。残る見落とし・誤検出: 図書館の細かな背表紙の一部、飲食店の縦長のれん・幟、遠い薄い文字、空の雲・天井・サンダル・カメラなど模様への誤候補、斜め手書きで背景を広く含む枠。人混みの写真では顔の上に文字候補が出るが、顔枠と重なる文字枠は編集画面で非表示になる。

## 合成の極小文字

| 画像 | 方式 | TP/FP/FN | ms |
| --- | --- | --- | ---: |
| font6_2560 | 従来960 | 0/0/20 | 225 |
| font6_2560 | 詳細 | 20/0/0 | 2199 |
| font6_3840 | 従来960 | 0/0/20 | 217 |
| font6_3840 | 詳細 | 20/2/0 | 1823 |
| font8_2560 | 従来960 | 14/6/6 | 104 |
| font8_2560 | 詳細 | 20/0/0 | 1749 |
| font14_2560 | 従来960 | 20/0/0 | 103 |
| font14_2560 | 詳細 | 20/0/0 | 1896 |
| blank_2560 | 従来960 | 0/0/0 | 137 |
| blank_2560 | 詳細 | 0/0/0 | 2163 |

`integration_test/small_text_device_test.dart` の判定（詳細でTP≥18・FP≤2、無地0件、1280px送り状4枠）を満たす。

## 設定比較（detector_probe_device_test.dart）

文字検出（新分割、PNG転送時の計測。「符号化」はFlutter側のPNG / 生RGBAのms）:

| 画像 | 転送 | 符号化 PNG / 生 | 2スレッド | 4スレッド | XNNPACK 4 | 回数 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| museum-labels | 1024×681 | 218 / 19 | 1385 | 596 | 819 | 3 |
| library-iida | 2560×1702 | 860 / 62 | 3069 | 2023 | 3881 | 13 |
| restaurant-chiyoda | 2112×2560 | 892 / 66 | 3689 | 2861 | 5142 | 17 |
| menu-today | 2560×1920 | 779 / 62 | 3008 | 2511 | 4542 | 13 |
| badge-wikicamp | 2560×1707 | 951 / 60 | 2703 | 1982 | 3853 | 13 |
| louvre-crowd | 2560×1765 | 612 / 41 | 2884 | 2082 | 4024 | 13 |

顔（ML Kit、最小サイズ 0.05 → 0.02）:

| 画像 | 0.05 | 0.02 |
| --- | --- | --- |
| restaurant-chiyoda | 2 (491 ms) | 2 (507 ms) |
| badge-wikicamp | 5 (385 ms) | 5 (483 ms) |
| louvre-crowd | 5 (267 ms) | 9 (325 ms) |

物体（YOLO26s 640+1280、2スレッド）:

| 画像 | ms | 候補 |
| --- | ---: | --- |
| library-digital-signage | 905 | person 4, screen 1 |
| badge-wikicamp | 823 | person 6, screen 7 |
| parking-lpr | 706 | person 1, vehicle 9 |
| parking-shizuoka | 838 | vehicle 3 |
| car-civic | 775 | vehicle 4 |
| louvre-crowd | 809 | person 20, screen 2 |

## 負荷

テストプロセス（Debug、Dartテストが復号済み写真を保持）の `dumpsys meminfo` TOTAL PSSの最大値: 公開18枚の連続検出で 690 MB、合成小文字で 637 MB、設定比較（セッション3種を順に生成・解放）で 926 MB。製品のRelease APK単体の値や実機の値ではない。2秒間隔の採取。

## 回帰

- `mise run check`: 整形・解析・unit/widget 134件成功（顔と重なる文字候補の非表示、車両の種類、物体→文字の順を追加）。
- `mise run text-geometry-test`: JVM 6件（幾何3件、分割計画3件）。
- Android: 公開18枚の検出と黒塗り出力、合成小文字、送り状の検出から拡大・タップ・JPEG保存、無地の物体0件、起動・ギャラリー保存・サンプル編集の各テストが成功。

## 再現

```sh
CAMEREON_DETECTOR_PREVIEW=1 mise exec -- flutter test integration_test/blackboard_text_device_test.dart -d emulator-5554 --dart-define=RUN_BLACKBOARD_TEXT_TESTS=true --timeout none --reporter expanded > /private/tmp/camereon-public.log 2>&1
python3 tools/detector-eval/blackboards_android.py --sources docs/evaluation-evidence/2026-11-02-real-world/sources.json --input .private/realworld-eval/input --output .private/realworld-eval/device --test-log /private/tmp/camereon-public.log --serial emulator-5554

CAMEREON_DETECTOR_PREVIEW=1 mise exec -- flutter test integration_test/detector_probe_device_test.dart -d emulator-5554 --dart-define=RUN_DETECTOR_PROBE=true --timeout none --reporter expanded > /private/tmp/camereon-probe.log 2>&1
python3 tools/detector-eval/blackboards_android.py --sources docs/evaluation-evidence/2026-11-02-real-world/sources.json --input .private/realworld-eval/input --output .private/realworld-eval/probe --test-log /private/tmp/camereon-probe.log --serial emulator-5554 --marker 'detector probe: timing' --ready PROBE_READY --collect probe.json
```

画像は `sources.json` のURLから取得してSHA-256を照合し、`.private/realworld-eval/input/<id>.jpg` に置く。ホストでの反復は `tools/detector-eval/small_text.py` を使う。テスト後は `mise run detector-debug-install -- emulator-5554` で通常アプリへ戻す。
