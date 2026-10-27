#!/usr/bin/env python3
"""Build a local interactive review from actual detector output, without inference."""
import argparse
import html
import json
from pathlib import Path
import shutil

from PIL import Image, ImageDraw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--text-results", required=True, type=Path)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = json.loads(args.results.read_text())
    texts = {x["id"]: x for x in json.loads(args.text_results.read_text())["images"]}
    notes = json.loads(args.notes.read_text())
    cards = []
    for record in results["images"]:
        ident = record["id"]
        source = args.input / f"{ident}.png"
        shutil.copyfile(source, args.output / source.name)
        layers = {}
        for key, run in record["runs"].items():
            if key.startswith("text-"):
                continue
            # Filter object output by the explicit review policy. Full raw output
            # remains in results.json and the individual all-object overlays.
            layers[key] = {**run, "detections": [d for d in run["detections"] if d["label"] in ("person", "cell phone", "tv", "face")]}
        layers.update(texts[ident]["runs"])
        record["review_layers"] = layers
        record["notes"] = notes[ident]
        canvas = Image.open(source).convert("RGB")
        draw = ImageDraw.Draw(canvas)
        for d in layers["yolo26s-1280"]["detections"]:
            draw.rectangle(d["box"], outline="#00d3ff", width=4)
            draw.text((d["box"][0] + 4, d["box"][1] + 4), d["label"], fill="#00d3ff", stroke_width=2, stroke_fill="black")
        for number, missing in enumerate(notes[ident]["misses"], 1):
            box = missing["box"]
            draw.rectangle(box, outline="#ff3860", width=4)
            draw.text((box[0], max(0, box[1] - 16)), f"MISS {number}", fill="#ff3860", stroke_width=2, stroke_fill="black")
        canvas.save(args.output / f"{ident}-review.jpg", quality=93)
        cards.append(f'<section id="{ident}"><h2>{html.escape(notes[ident]["title"])}</h2><p>{html.escape(notes[ident]["summary"])}</p>'
                     f'<div class="stage"><img src="{ident}.png" alt="検証画像 {ident}"><svg viewBox="0 0 {record["width"]} {record["height"]}" aria-label="検出枠"></svg></div>'
                     '<p class="stats"></p><ul>' + ''.join(f'<li>{html.escape(x)}</li>' for x in notes[ident]["details"]) + '</ul></section>')
    # Inline data; images and report remain local, with no external resources.
    data = json.dumps(results["images"], ensure_ascii=False).replace("<", "\\u003c")
    document = '''<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>実写3枚の検出レビュー</title><style>
body{font:16px/1.65 system-ui,sans-serif;background:#10131b;color:#e6edf5;margin:0}main{max-width:1250px;margin:auto;padding:25px}h1{font-size:28px}h2{font-size:22px}p,li{max-width:1050px}.toolbar{position:sticky;top:0;z-index:2;background:#1b2232;padding:16px;border:1px solid #445;display:flex;gap:20px;flex-wrap:wrap}select{padding:8px;background:#fff;color:#111}section{margin:35px 0 60px}.stage{position:relative;line-height:0}.stage img{width:100%;height:auto}.stage svg{position:absolute;inset:0;width:100%;height:100%}.stats{color:#9ee1eb}a{color:#9ee1eb}.warning{border-left:4px solid #ff647c;padding:12px;background:#251b25}li{margin-bottom:8px}
</style><main><h1>検出器でどこまで拾えるか — 実写3枚</h1>
<p>2026-10-27 / main 74049eb取り込み済み / Apple M3 CPUで実測。スマートフォン実機での時間ではありません。</p>
<p class="warning">水色＝検出枠。赤＝目視で追加した見落としの注記（YOLO26s・1280px基準、正解ラベル網羅ではありません）。人物・画面を候補にする方針で絞っています。投稿可否や個人情報の有無を自動判定した結果ではありません。</p>
<div class="toolbar"><label>検出条件 <select id="mode">
<option value="yolo26s-1280">YOLO26s / 1280px</option><option value="yolo26s-640">YOLO26s / 640px</option><option value="yolo26n-1280">YOLO26n / 1280px</option><option value="yolo26n-640">YOLO26n / 640px</option><option value="yunet-native">顔 / 通常</option><option value="yunet-rotations-tiles">顔 / 回転＋分割</option><option value="ppocrv5-960">文字 / main相当960px</option><option value="ppocrv5-1536">文字 / 1536px</option><option value="ppocrv5-contour-1536">文字 / 輪郭後処理1536px</option>
</select></label><label><input type="checkbox" id="misses" checked>見落としの注記</label><label><input type="checkbox" id="mask">検出枠を黒塗りで試す</label></div>
''' + ''.join(cards) + '''<p>顔検出は対象が実在の人か画面内の映像かを区別しません。小さな写真・書類には手動確認が必要です。元画像・座標・このレポートはGit管理外の.private/内に保存しています。</p></main><script>
const records=DATA;
const ns='http://www.w3.org/2000/svg';
function rect(svg, box, color, mask, dashed){const node=document.createElementNS(ns,'rect');node.setAttribute('x',box[0]);node.setAttribute('y',box[1]);node.setAttribute('width',box[2]-box[0]);node.setAttribute('height',box[3]-box[1]);node.setAttribute('fill',mask?'black':'none');node.setAttribute('stroke',color);node.setAttribute('stroke-width','3');if(dashed)node.setAttribute('stroke-dasharray','12 6');svg.appendChild(node);}
function render(){const key=document.querySelector('#mode').value;const mask=document.querySelector('#mask').checked;for(const record of records){const section=document.getElementById(record.id);const svg=section.querySelector('svg');svg.replaceChildren();const run=record.review_layers[key];for(const d of run.detections)rect(svg,d.box,'#00d3ff',mask,false);if(document.querySelector('#misses').checked)for(const d of record.notes.misses)rect(svg,d.box,'#ff3860',false,true);section.querySelector('.stats').textContent=`表示候補 ${run.detections.length}件 / 計測中央値 ${run.median_ms}ms（ウォームアップ後3回）`}}
document.querySelectorAll('select,input').forEach(x=>x.addEventListener('change',render));render();
</script></html>'''.replace('DATA', data)
    (args.output / "index.html").write_text(document, encoding="utf-8")
    print(args.output / "index.html")


if __name__ == "__main__":
    main()
