#!/usr/bin/env python3
"""Host reproduction of main's PP-OCRv5 text detector, not an Android benchmark.

Resize kernels/runtime differ from Flutter/Android. No text recognition is run.
"""
import argparse
import hashlib
import json
from pathlib import Path
import socket
import statistics
import time

import cv2
import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw, ImageOps
from rapidocr_onnxruntime.ch_ppocr_det.utils import DBPostProcess


def detect(image, session, long_side, contour=False):
    h, w = image.shape[:2]
    scale = min(1.0, long_side / max(h, w))
    # Dart rounds positive ties upwards, as does Kotlin roundToInt.
    sw, sh = int(w * scale + 0.5), int(h * scale + 0.5)
    first = cv2.resize(image, (sw, sh), interpolation=cv2.INTER_LINEAR)
    iw, ih = max(32, int(sw / 32 + 0.5) * 32), max(32, int(sh / 32 + 0.5) * 32)
    resized = cv2.resize(first, (iw, ih), interpolation=cv2.INTER_LINEAR)
    data = (resized.astype(np.float32) / 255 - np.array([.485, .456, .406], dtype=np.float32)) / np.array([.229, .224, .225], dtype=np.float32)
    tensor = data.transpose(2, 0, 1)[None]
    probability = session.run(None, {session.get_inputs()[0].name: tensor})[0][0, 0]
    mh, mw = probability.shape
    if contour:
        # Comparison: contour scoring + rotated polygon expansion, rather than
        # main's mean of the entire axis-aligned rectangle. Same network/threshold.
        post = DBPostProcess(thresh=.3, box_thresh=.6, max_candidates=1000,
                             unclip_ratio=1.5, use_dilation=False, score_mode="fast")
        polygons, scores = post(probability[None, None], (h, w))
        found = [{"label": "text", "score": float(score), "polygon": polygon.tolist(),
                  "box": [*polygon.min(axis=0).tolist(), *polygon.max(axis=0).tolist()]}
                 for polygon, score in zip(polygons, scores)]
        return {"detections": found[:200], "truncated": len(found) > 200,
                "resized": [sw, sh], "model_input": [iw, ih]}
    count, labels, stats, _ = cv2.connectedComponentsWithStats((probability >= .3).astype(np.uint8), connectivity=4)
    found = []
    for component in range(1, count):
        left, top, width, height, _ = stats[component]
        if min(width, height) < 3:
            continue
        score = float(probability[top:top + height, left:left + width].mean())
        if score < .6:
            continue
        margin = float(width) * height * 1.5 / (2 * (width + height))
        found.append({"label": "text", "score": round(score, 4), "box": [
            max(0, left - margin) * w / mw, max(0, top - margin) * h / mh,
            min(mw, left + width + margin) * w / mw,
            min(mh, top + height + margin) * h / mh,
        ]})
    found.sort(key=lambda d: (d["box"][1], d["box"][0]))
    return {"detections": found[:200], "truncated": len(found) > 200,
            "resized": [sw, sh], "model_input": [iw, ih]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="+", type=Path)
    parser.add_argument("--model", type=Path, default=Path("android/app/src/main/assets/text_detection/inference.onnx"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(args.model.read_bytes()).hexdigest()
    if digest != "a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d":
        parser.error("Model differs from main 74049eb; verify model/preprocessing before evaluating")
    def no_network(*a, **kw):
        raise RuntimeError("Network disabled during detector evaluation")
    socket.socket.connect = no_network
    socket.socket.connect_ex = no_network
    socket.create_connection = no_network
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(args.model), sess_options=options, providers=["CPUExecutionProvider"])
    report = {"model": args.model.name, "sha256": digest, "onnxruntime": ort.__version__,
              "main_reference": "74049eb", "android_execution": False,
              "postprocess": "four-connected components; threshold .3; rectangle mean >= .6; unclip 1.5",
              "images": []}
    for index, path in enumerate(args.images, 1):
        original = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        bgr = cv2.cvtColor(np.asarray(original), cv2.COLOR_RGB2BGR)
        record = {"id": f"photo-{index}", "runs": {}}
        for size, contour in ((960, False), (1536, False), (960, True), (1536, True)):
            detect(bgr, session, size, contour)
            samples = []
            for _ in range(3):
                start = time.perf_counter()
                output = detect(bgr, session, size, contour)
                samples.append(round((time.perf_counter() - start) * 1000, 2))
            output.update(wall_ms=samples, median_ms=round(statistics.median(samples), 2))
            key = f'ppocrv5-{"contour-" if contour else ""}{size}'
            record["runs"][key] = output
            canvas = original.copy()
            draw = ImageDraw.Draw(canvas)
            for d in output["detections"]:
                if "polygon" in d:
                    draw.polygon([tuple(p) for p in d["polygon"]], outline="#2dd4bf", width=2)
                else:
                    draw.rectangle(d["box"], outline="#2dd4bf", width=2)
            canvas.save(args.output / f'{record["id"]}-{key}.jpg')
            print(record["id"], key, len(output["detections"]), output["median_ms"], flush=True)
        report["images"].append(record)
        (args.output / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
