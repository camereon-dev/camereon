#!/usr/bin/env python3
"""Re-export the pinned YOLO26s checkpoint into the bundled Android ONNX asset.

The segmentation variant is the bundled one: it returns the same boxes plus
32 mask coefficients per candidate and a prototype tensor, so people, screens
and vehicles can be hidden along their silhouette instead of a rectangle.
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil

VARIANTS = {
    "det": {
        "sha256": "646f8bc3fe0a656803d95c294f7852321748cb29d13466a1af8862e2db384a1b",
        "file": "yolo26s.onnx",
        "shapes": [(1, 300, 6)],
    },
    "seg": {
        "sha256": "3da1d83e31caec96f9300eb4064f4f62882c133c7c264d63dfe61a7c197837a4",
        "file": "yolo26s-seg.onnx",
        "shapes": [(1, 300, 38), (1, 32, 96, 160)],
    },
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--variant", choices=VARIANTS, default="seg")
    parser.add_argument("--destination", type=Path,
                        default=Path("android/app/src/main/assets/object_detection"))
    args = parser.parse_args()
    variant = VARIANTS[args.variant]
    if hashlib.sha256(args.source.read_bytes()).hexdigest() != variant["sha256"]:
        parser.error("Source is not the evaluated YOLO26s checkpoint for this variant")
    if importlib.metadata.version("ultralytics") != "8.4.89":
        parser.error("Use requirements-export.txt to pin the export implementation")
    from ultralytics import YOLO
    import onnxruntime as ort
    import numpy as np
    exported = Path(YOLO(str(args.source)).export(format="onnx", imgsz=640,
        dynamic=True, simplify=False, opset=17, nms=False, device="cpu"))
    session = ort.InferenceSession(str(exported), providers=["CPUExecutionProvider"])
    outputs = session.run(None, {session.get_inputs()[0].name: np.zeros((1, 3, 384, 640), dtype=np.float32)})
    shapes = [tuple(o.shape) for o in outputs]
    if shapes != variant["shapes"]:
        raise ValueError(f"Unexpected output shapes: {shapes}")
    args.destination.mkdir(parents=True, exist_ok=True)
    target = args.destination / variant["file"]
    shutil.copyfile(exported, target)
    manifest_path = args.destination / "model.json"
    manifest = json.loads(manifest_path.read_text())
    manifest.update(file=variant["file"], bytes=target.stat().st_size,
                    sha256=hashlib.sha256(target.read_bytes()).hexdigest())
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print("Updated model and SHA-256:", manifest["sha256"])


if __name__ == "__main__":
    main()
