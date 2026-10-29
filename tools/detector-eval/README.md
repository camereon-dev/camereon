# SNS投稿前の実写検出評価

YOLO26n / YOLO26s、YuNet、文字検出を同じローカル画像で比較する。本体への組み込みは行わない。結果は[実写評価の記録](../../docs/detector-evaluation.md)を参照。

元写真・結果JSON・検出枠画像・HTMLは `.private/` に置く。実写や読み取れる情報をGitに追加しない。HTMLはローカルファイルとして開け、外部リソースを使わない。

## 準備

Python 3.12。今回の計測はmacOS / Apple M3 / CPU。ホスト環境の依存は `requirements-lock.txt` に固定した。

```sh
uv venv /private/tmp/camereon-detector-venv --python 3.12
uv pip install --python /private/tmp/camereon-detector-venv/bin/python -r tools/detector-eval/requirements-lock.txt
/private/tmp/camereon-detector-venv/bin/python tools/detector-eval/prepare.py .private/detector-eval/models
```

モデルは `models.json` の公開配布物を取得し、容量・SHA-256を検証する。YOLOはUltralyticsの評価用モデル、YuNetはOpenCV Zooの固定コミット。アプリ配布用のモデル選定とは分ける。文字検出v4はRapidOCRパッケージに同梱され、v5はmainにあるモデルを使う。画像を推論サービスへ送らない。評価時はPythonのソケット接続も禁止する（OS全体の通信遮断を検証したものではない）。

## 実行

入力は任意の3枚。今回の写真はこのリポジトリに含まない。

```sh
/private/tmp/camereon-detector-venv/bin/python tools/detector-eval/run.py \
  .private/detector-eval/input/photo-1.png \
  .private/detector-eval/input/photo-2.png \
  .private/detector-eval/input/photo-3.png \
  --models .private/detector-eval/models --output .private/detector-eval/results

/private/tmp/camereon-detector-venv/bin/python tools/detector-eval/text_v5.py \
  .private/detector-eval/input/photo-1.png \
  .private/detector-eval/input/photo-2.png \
  .private/detector-eval/input/photo-3.png \
  --output .private/detector-eval/text-v5
```

- YOLO: confidence 0.25、imgsz 640 / 1280、COCO学習済みn / s。全クラスの出力を保存する。
- YuNet: confidence 0.6。元解像度と、90度ごとの回転＋640pxタイル（480px間隔）を比較する。重複枠はNMS 0.3で除く。
- 文字v4: 検出専用。RapidOCRのDB後処理、長辺640 / 1536。認識器はロード・実行しない。
- 文字v5: main `74049eb` と同じ重み・BGR正規化・四近傍成分・矩形スコア・拡張式をホストで再現。長辺960 / 1536と輪郭後処理を比較する。Flutter/Androidと画像リサイズ・ランタイムが異なるので、実アプリでの測定とは呼ばない。
- 各画像・設定で1回ウォームアップし、その後3回のwall-clock時間を保存。モデルロード・画像デコード・出力画像生成は時間に含めない。モデルサイズはAPKの増分ではない。
- JSONの座標はEXIFの向きを正規化した元画像の画素。`photo-1` 等は入力順。写真が変わる場合は前回の結果と混ぜないよう出力先を変える。

## ローカルの比較画面

`notes.json` は画像を目視して作る。以下は形式のみの例で、正解データや自動判定ではない。

```json
{
  "photo-1": {
    "title": "画像1",
    "summary": "観察結果",
    "details": ["検出できた箇所と残った箇所"],
    "misses": [{"label": "見落とし", "box": [10, 20, 30, 40]}]
  }
}
```

入力ファイルを `photo-1.png` 等の順で用意し、各画像の注記を作成して実行する。

```sh
/private/tmp/camereon-detector-venv/bin/python tools/detector-eval/render_report.py \
  --results .private/detector-eval/results/results.json \
  --text-results .private/detector-eval/text-v5/results.json \
  --input .private/detector-eval/input \
  --notes .private/detector-eval/notes.json \
  --output .private/detector-eval/review
```

`review/index.html` で条件・注記・黒塗りプレビューを切り替える。物体の表示対象はperson / cell phone / tv、顔検出はfaceに限定する。顔や画面を見つけたことと、隠す必要があることは別に扱う。原画像を上書きしない。
