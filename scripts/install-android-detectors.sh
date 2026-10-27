#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then
  echo 'usage: bash scripts/install-android-detectors.sh [device-id]' >&2
  exit 2
fi
if [[ ! -f dist/camereon-detector-arm64.apk ]]; then
  bash scripts/build-android-detectors.sh
fi
device_args=()
if [[ $# -eq 1 ]]; then device_args=(-s "$1"); fi
adb "${device_args[@]}" install -r dist/camereon-detector-arm64.apk
adb "${device_args[@]}" shell am start -n dev.camereon.camereon.demo.detector_preview/dev.camereon.camereon.demo.MainActivity
