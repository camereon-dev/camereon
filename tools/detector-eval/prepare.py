#!/usr/bin/env python3
"""Download fixed public model files; does not read photographs."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(Path(__file__).with_name("models.json").read_text())
    for spec in manifest:
        target = args.destination / spec["name"]
        if target.is_file() and target.stat().st_size == spec["bytes"] and hashlib.sha256(target.read_bytes()).hexdigest() == spec["sha256"]:
            print("Verified", target.name)
            continue
        temporary = target.with_suffix(target.suffix + ".part")
        try:
            with urllib.request.urlopen(spec["url"], timeout=120) as source, temporary.open("wb") as output:
                while chunk := source.read(1024 * 1024):
                    output.write(chunk)
            if temporary.stat().st_size != spec["bytes"] or hashlib.sha256(temporary.read_bytes()).hexdigest() != spec["sha256"]:
                raise ValueError(f"Model integrity check failed: {target.name}")
            temporary.replace(target)
            print("Downloaded and verified", target.name)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
