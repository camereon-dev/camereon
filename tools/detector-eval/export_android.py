#!/usr/bin/env python3
"""Re-export the pinned YOLO26s source into the bundled Android ONNX asset."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--destination", type=Path,
                        default=Path("android/app/src/main/assets/object_detection"))
    args = parser.parse_args()
    if hashlib.sha256(args.source.read_bytes()).hexdigest() != "646f8bc3fe0a656803d95c294f7852321748cb29d13466a1af8862e2db384a1b":
        parser.error("Source is not the evaluated YOLO26s checkpoint")
    if importlib.metadata.version("ultralytics") != "8.4.89":
        parser.error("Use requirements-export.txt to pin the export implementation")
    from ultralytics import YOLO
    import onnxruntime as ort
    import numpy as np
    exported = Path(YOLO(str(args.source)).export(format="onnx", imgsz=640,
        dynamic=True, simplify=False, opset=17, nms=False, device="cpu"))
    session = ort.InferenceSession(str(exported), providers=["CPUExecutionProvider"])
    result = session.run(None, {session.get_inputs()[0].name: np.zeros((1, 3, 384, 640), dtype=np.float32)})[0]
    if result.shape != (1, 300, 6):
        raise ValueError(f"Unexpected output shape: {result.shape}")
    args.destination.mkdir(parents=True, exist_ok=True)
    target = args.destination / "yolo26s.onnx"
    shutil.copyfile(exported, target)
    manifest_path = args.destination / "model.json"
    manifest = json.loads(manifest_path.read_text())
    manifest.update(bytes=target.stat().st_size, sha256=hashlib.sha256(target.read_bytes()).hexdigest())
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print("Updated model and SHA-256:", manifest["sha256"])


if __name__ == "__main__":
    main()
