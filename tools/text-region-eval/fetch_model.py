"""Restore the bundled official detection model at the pinned revision."""
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen


def main():
    destination = Path(__file__).resolve().parents[2] / "android/app/src/main/assets/text_detection"
    spec = json.loads((destination / "model.json").read_text())
    model = destination / spec["file"]
    if model.exists() and hashlib.sha256(model.read_bytes()).hexdigest() == spec["sha256"]:
        print("Bundled detector verified; no download needed.")
        return
    url = spec["repository"] + "/resolve/" + spec["revision"] + "/" + spec["file"]
    with urlopen(url, timeout=90) as response:
        data = response.read(spec["bytes"] + 1)
    if len(data) != spec["bytes"] or hashlib.sha256(data).hexdigest() != spec["sha256"]:
        raise ValueError("Detection model size or SHA-256 mismatch")
    temporary = model.with_suffix(".download")
    temporary.write_bytes(data)
    temporary.replace(model)
    print("Bundled detector restored and verified.")


if __name__ == "__main__":
    main()
