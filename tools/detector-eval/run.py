#!/usr/bin/env python3
"""Local-only detector experiment. All coordinates refer to EXIF-normalized pixels.

Inputs/outputs may contain personal information; keep them in .private/.
This measures detection, not whether a photograph is safe to publish.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import socket
import statistics
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="+", type=Path)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    config_dir = args.output / "config"
    config_dir.mkdir(exist_ok=True)
    os.environ["YOLO_CONFIG_DIR"] = str(config_dir.resolve())
    os.environ["MPLCONFIGDIR"] = str((args.output / "matplotlib").resolve())

    import cv2
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont, ImageOps
    import torch
    from ultralytics import YOLO, settings
    import rapidocr_onnxruntime
    from rapidocr_onnxruntime.ch_ppocr_det import TextDetector
    from rapidocr_onnxruntime.utils import read_yaml, update_model_path

    settings.update({"sync": False})
    torch.set_num_threads(4)
    cv2.setNumThreads(4)

    def no_network(*unused_args, **unused_kwargs):
        raise RuntimeError("Network disabled during detector evaluation")

    socket.socket.connect = no_network
    socket.socket.connect_ex = no_network
    socket.create_connection = no_network

    required = [args.models / name for name in (
        "yolo26n.pt", "yolo26s.pt", "face_detection_yunet_2023mar.onnx"
    )]
    for path in required:
        if not path.is_file():
            parser.error(f"Download model before running: {path}")
    models = {p.stem: YOLO(str(p)) for p in required[:2]}
    face = cv2.FaceDetectorYN.create(
        str(required[2]), "", (320, 320), score_threshold=0.6,
        nms_threshold=0.3, top_k=5000,
    )
    ocr_root = Path(rapidocr_onnxruntime.__file__).parent
    text_config = update_model_path(read_yaml(ocr_root / "config.yaml"))["Det"]
    text_config.update(intra_op_num_threads=4, inter_op_num_threads=1)
    text_detector = TextDetector(text_config)
    required.append(Path(text_config["model_path"]))

    def timed(fn):
        # One unmeasured warmup per image/config, then repeated wall-clock samples.
        fn()
        times = []
        for _ in range(args.repeats):
            start = time.perf_counter()
            result = fn()
            times.append(round((time.perf_counter() - start) * 1000, 2))
        return {"detections": result, "wall_ms": times,
                "median_ms": round(statistics.median(times), 2)}

    def objects(model, image, size):
        result = model.predict(image, imgsz=size, conf=0.25, iou=0.7,
                               device="cpu", verbose=False)[0]
        return [{"label": result.names[int(b.cls.item())],
                 "score": round(float(b.conf.item()), 4),
                 "box": [round(float(v), 2) for v in b.xyxy[0].tolist()]}
                for b in result.boxes]

    def faces_once(image, rotation=0, offset=(0, 0)):
        h, w = image.shape[:2]
        rotated = np.ascontiguousarray(np.rot90(image, rotation))
        face.setInputSize((rotated.shape[1], rotated.shape[0]))
        _, rows = face.detect(rotated)
        output = []
        for row in ([] if rows is None else rows):
            x, y, bw, bh = row[:4]
            pts = np.array([[x, y], [x + bw, y], [x + bw, y + bh], [x, y + bh]])
            rx, ry = pts[:, 0].copy(), pts[:, 1].copy()
            if rotation == 1:
                pts[:, 0], pts[:, 1] = w - ry, rx
            elif rotation == 2:
                pts[:, 0], pts[:, 1] = w - rx, h - ry
            elif rotation == 3:
                pts[:, 0], pts[:, 1] = ry, h - rx
            pts[:, 0] = pts[:, 0].clip(0, w) + offset[0]
            pts[:, 1] = pts[:, 1].clip(0, h) + offset[1]
            box = [*pts.min(axis=0).tolist(), *pts.max(axis=0).tolist()]
            output.append({"label": "face", "score": round(float(row[-1]), 4),
                           "box": [round(v, 2) for v in box], "rotation": rotation * 90})
        return output

    def faces(image, enhanced):
        # Whole-image rotations plus overlapping native-resolution tiles.
        # No upsampling: tiles test surrounding-context effects, not new detail.
        detections = []
        h, w = image.shape[:2]
        crops = [(0, 0, w, h)]
        if enhanced:
            def starts(length):
                return sorted(set(range(0, max(1, length - 640), 480)) | {max(0, length - 640)})
            crops += [(x, y, min(x + 640, w), min(y + 640, h))
                      for y in starts(h) for x in starts(w)]
        for x, y, right, bottom in crops:
            for rotation in (range(4) if enhanced else [0]):
                detections += faces_once(image[y:bottom, x:right], rotation, (x, y))
        if not detections:
            return []
        xywh = [[d["box"][0], d["box"][1], d["box"][2] - d["box"][0],
                 d["box"][3] - d["box"][1]] for d in detections]
        keep = cv2.dnn.NMSBoxes(xywh, [d["score"] for d in detections], 0.6, 0.3)
        return [detections[int(i)] for i in np.asarray(keep).reshape(-1)]

    def texts(image, long_side):
        h, w = image.shape[:2]
        scale = min(1.0, long_side / max(h, w))
        resized = cv2.resize(image, (round(w * scale), round(h * scale)))
        # The packaged detector's 'max' mode overrides limit_side_len. Use min
        # equal to our resized short edge to preserve the requested size.
        text_detector.limit_type = "min"
        text_detector.limit_side_len = min(resized.shape[:2])
        polygons, _ = text_detector(resized)
        output = []
        for polygon in ([] if polygons is None else polygons):
            points = polygon.astype(float)
            points[:, 0] *= w / resized.shape[1]
            points[:, 1] *= h / resized.shape[0]
            output.append({"label": "text", "score": None,
                           "polygon": points.round(2).tolist(),
                           "box": [*points.min(axis=0).round(2).tolist(),
                                   *points.max(axis=0).round(2).tolist()]})
        return output

    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 17) if platform.system() == "Darwin" else ImageFont.load_default()

    def overlay(original, detections, target):
        canvas = original.copy()
        draw = ImageDraw.Draw(canvas)
        for i, d in enumerate(detections, 1):
            color = "#facc15" if d["label"] == "face" else "#2dd4bf" if d["label"] == "text" else "#fb7185"
            if "polygon" in d:
                draw.polygon([tuple(p) for p in d["polygon"]], outline=color, width=2)
            else:
                draw.rectangle(d["box"], outline=color, width=3)
            if d["label"] != "text":
                title = f'{i}:{d["label"]} {d["score"]:.2f}'
                x, y = d["box"][:2]
                y = max(0, y - 20)
                label_box = draw.textbbox((x, y), title, font=font)
                draw.rectangle(label_box, fill=color)
                draw.text((x, y), title, fill="black", font=font)
        canvas.save(target)

    report = {"environment": {"platform": platform.platform(), "machine": platform.machine(),
                              "python": platform.python_version(), "device": "cpu", "threads": 4,
                              "python_socket_connections_blocked": True,
                              "packages": {name: importlib.metadata.version(name) for name in (
                                  "ultralytics", "torch", "opencv-python", "rapidocr-onnxruntime", "onnxruntime")}},
              "models": [{"name": p.name, "bytes": p.stat().st_size,
                          "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in required],
              "parameters": {"object_conf": 0.25, "face_conf": 0.6, "text_box_thresh": 0.5,
                             "text_recognition": False, "repeats": args.repeats,
                             "warmup_per_image_config": 1}, "images": []}
    for index, path in enumerate(args.images, 1):
        original = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        bgr = cv2.cvtColor(np.asarray(original), cv2.COLOR_RGB2BGR)
        record = {"id": f"photo-{index}", "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                  "width": original.width, "height": original.height, "runs": {}}
        for name, model in models.items():
            for size in (640, 1280):
                key = f"{name}-{size}"
                record["runs"][key] = timed(lambda: objects(model, bgr, size))
        for enhanced in (False, True):
            key = "yunet-rotations-tiles" if enhanced else "yunet-native"
            record["runs"][key] = timed(lambda: faces(bgr, enhanced))
        for size in (640, 1536):
            record["runs"][f"text-{size}"] = timed(lambda: texts(bgr, size))
        for key, run in record["runs"].items():
            overlay(original, run["detections"], args.output / f'{record["id"]}-{key}.jpg')
            print(record["id"], key, len(run["detections"]), run["median_ms"], flush=True)
        report["images"].append(record)
        (args.output / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
