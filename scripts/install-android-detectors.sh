#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=release
artifact=dist/camereon-detector-arm64.apk
if [[ "${1:-}" == "--debug" ]]; then
  mode=debug
  artifact=dist/camereon-detector-debug-arm64.apk
  shift
fi
if [[ $# -gt 1 ]]; then
  echo 'usage: bash scripts/install-android-detectors.sh [--debug] [device-id]' >&2
  exit 2
fi
if [[ "$mode" == debug ]]; then
  bash scripts/build-android-detectors.sh --debug
elif [[ ! -f "$artifact" ]]; then
  bash scripts/build-android-detectors.sh
fi
adb_command=(adb)
if [[ $# -eq 1 ]]; then adb_command+=(-s "$1"); fi
"${adb_command[@]}" install -r "$artifact"
"${adb_command[@]}" shell am start -n dev.camereon.camereon.demo.detector_preview/dev.camereon.camereon.demo.MainActivity
