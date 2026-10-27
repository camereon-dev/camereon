#!/usr/bin/env python3
"""Stage local photos in an installed debug app for the opt-in integration test.

Uses adb's stdin; private image paths are never added to the APK or Git.
"""
import argparse
from pathlib import Path
import shlex
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", type=Path, nargs=3)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--package", default="dev.camereon.camereon.demo.detector_preview")
    args = parser.parse_args()
    base = ["adb", "-s", args.serial, "shell", "-T"]
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if subprocess.run(base + ["run-as", args.package, "pwd"], capture_output=True).returncode == 0:
            break
        time.sleep(2)
    else:
        parser.error("Debug app not installed within 180 seconds")
    subprocess.run(base + ["run-as", args.package, "mkdir", "-p", "files/detector-eval"], check=True)
    for i, source in enumerate(args.images, 1):
        target = f"files/detector-eval/photo-{i}.png"
        command = "run-as " + shlex.quote(args.package) + " sh -c " + shlex.quote(f"cat > {target}.part")
        subprocess.run(base + [command], input=source.read_bytes(), check=True)
        subprocess.run(base + ["run-as", args.package, "mv", target + ".part", target], check=True)
    print("Staged three private images in debug app storage")


if __name__ == "__main__":
    main()
