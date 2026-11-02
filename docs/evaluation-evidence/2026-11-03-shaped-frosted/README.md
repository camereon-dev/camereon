# 形に沿った枠とすりガラスの塗り、まとめて選ぶ操作

**判定: 編集画面の見た目と操作を変える変更。公開実写での出力を目視し、端末上のテストが通ることを確認した。実機の速度・メモリは未測定。**

評価コミット: `98b1ad1`（本記録の1つ前のコミット）。Android 12 API 31 ARM64 エミュレーター（4 vCPU・4 GB）、Debug、CPU、ONNX Runtime 1.24.3。2026-11-02の公開18枚から6枚（看板の多い飲食店、手書きと印刷の献立、駅名標、名札と人物、駐車場、美術館の人混み）を使った。

## 変更

- **形**: 顔は楕円、文字は確率成分の凸包を余白ぶん広げた多角形、人物・画面・車両は分割モデル YOLO26s-seg のマスクを marching squares で多角形にした輪郭。`HideRegion` は整数の外接矩形に加えて形と頂点を持つ。
- **塗り**: 黒ではなく、形の外側の画素だけから作る「すりガラス」。形の短辺の半分より広い周囲を大きくぼかした色場で内側を置き換え、縁は外側へ2〜24pxなじませ、周囲の明るさのばらつきに応じた弱い決定的ノイズを足す。内側の画素は参照しないので黒塗りと同じく復元できない。保存時は元解像度、編集画面では長辺2048px以下の窓で同じ計算をし、1範囲1枚の静止画として写真に重ねる。拡大・移動中の毎フレームぼかしはない。
- **操作**: 枠タップに加え、長押しでなぞると通った枠をまとめて切替（1回の取り消し単位）、下のバーの「すべて」「顔 n」「文字 n」などで種類ごとに一括切替。「顔だけ」の表示切替は廃止。候補枠の描画は形の線だけで、ぼかしフィルターを使わない。

## 端末での結果（公開6枚）

各1回の壁時計値（ms）。文字は詳細検出、物体は640/1280pxの2回、顔はML Kit。「全部隠す」は元解像度で文字・物体・顔の全候補を塗って JPEG にするまでの時間（Dart の isolate、Debug=JIT）。

| 画像 | サイズ | 文字 ms / 候補 | 物体 ms / 種類 | 顔 ms / 数 | 全部隠す ms / 範囲 |
| --- | --- | ---: | --- | ---: | ---: |
| restaurant-chiyoda | 3762×4559 | 3040 / 111 | 1290 / person 4, vehicle 1 (5 輪郭) | 568 / 2 | 4176 / 118 |
| menu-today | 4576×3432 | 2627 / 108 | 933 /  (0 輪郭) | 335 / 0 | 3036 / 108 |
| station-akihabara | 4752×3168 | 2191 / 12 | 833 /  (0 輪郭) | 356 / 0 | 2076 / 12 |
| badge-wikicamp | 5568×3712 | 2285 / 28 | 988 / person 7, screen 4 (11 輪郭) | 458 / 5 | 5878 / 44 |
| parking-lpr | 3489×2004 | 1850 / 10 | 633 / vehicle 6 (6 輪郭) | 239 / 0 | 1092 / 16 |
| louvre-crowd | 3766×2596 | 2205 / 10 | 883 / person 21, screen 2 (23 輪郭) | 393 / 9 | 2948 / 42 |

出力画像の目視: 人物はシルエットに沿ったすりガラスになり、背景の壁・床の色が入る。顔は楕円。看板・名札・駅名標の文字は角の丸い形で、周囲の看板の色（白地なら白、緑帯なら緑がかった灰色）になる。人物の中の顔・文字の枠は重なるが、保存結果は重ねて塗るだけなので破綻しない。原画像・出力は `.private/realworld-eval/` にのみ置く。

## 編集画面の流れ（名札・人混みの2枚）

`integration_test/editor_flow_device_test.dart`: 写真を開く→全検出の完了→「すべて」で全候補を隠す→表示用のすりガラスが全範囲ぶん揃う→「保存前に確認」で元解像度の JPEG ができるまで。

| 画像 | 候補 | 検出完了 ms | 表示の塗り ms | 確認（保存用）ms |
| --- | ---: | ---: | ---: | ---: |
| badge-wikicamp | 44 | 9804 | 1058 | 5635 |
| louvre-crowd | 42 | 5204 | 645 | 2816 |

テストプロセスの `dumpsys meminfo` TOTAL PSS 最大値: 1045 MB（2秒間隔。Debug のテストプロセスで、Release 単体や実機の値ではない）。

通常Debug ARM64 APK（`mise run detector-debug-install`）は 230,926,220 bytes。同梱は `yolo26s-seg.onnx`（41,726,473 bytes）と `inference.onnx`（4,826,518 bytes）で、検出専用の `yolo26s.onnx` は含まない。エミュレーターには通常のデバッグアプリを再導入した。

## 回帰

- `mise run check`: 整形・解析・unit/widget（形の判定・多角形化・すりガラスの塗り・表示用パッチ・種類ボタン・長押しなぞりを含む）。
- `mise run text-geometry-test`: JVM 9件（凸包・外側への拡張・斜め成分の輪郭を追加）。
- Android: 公開6枚の検出と全候補の塗り出力、送り状の検出→拡大→タップ→JPEG保存（文字の暗い画素が消えること）、合成写真の編集→保存、無地の物体0件。

## 再現

```sh
CAMEREON_DETECTOR_PREVIEW=1 mise exec -- flutter test integration_test/blackboard_text_device_test.dart -d emulator-5554 --dart-define=RUN_BLACKBOARD_TEXT_TESTS=true --timeout none --reporter expanded > /private/tmp/camereon-public.log 2>&1
python3 tools/detector-eval/blackboards_android.py --sources docs/evaluation-evidence/2026-11-03-shaped-frosted/sources.json --input .private/realworld-eval/input --output .private/realworld-eval/device --test-log /private/tmp/camereon-public.log --serial emulator-5554

CAMEREON_DETECTOR_PREVIEW=1 mise exec -- flutter test integration_test/editor_flow_device_test.dart -d emulator-5554 --dart-define=RUN_EDITOR_FLOW_TEST=true --timeout none --reporter expanded > /private/tmp/camereon-editor.log 2>&1
python3 tools/detector-eval/blackboards_android.py --sources docs/evaluation-evidence/2026-11-03-shaped-frosted/sources.json --input .private/realworld-eval/input --output .private/realworld-eval/editor --test-log /private/tmp/camereon-editor.log --serial emulator-5554 --marker 'editor flow: detect' --ready EDITOR_READY --collect editor.json
```

分割モデルの再出力は `tools/detector-eval/export_android.py <yolo26s-seg.pt> --variant seg`（[Android検出器](../../android-detectors.md)）。
