#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode=release
if [[ "${1:-}" == "--debug" ]]; then
  mode=debug
  shift
fi

# A separate app ID preserves installed beta/demo data and signing compatibility.
export CAMEREON_DETECTOR_PREVIEW=1
unset CAMEREON_AI_PREVIEW CAMEREON_BETA_KEYSTORE CAMEREON_BETA_PASSWORD
flutter pub get --enforce-lockfile
flutter build apk "--$mode" --target-platform android-arm64 "$@"
mkdir -p dist
artifact=camereon-detector-arm64.apk
if [[ "$mode" == debug ]]; then artifact=camereon-detector-debug-arm64.apk; fi
cp "build/app/outputs/flutter-apk/app-$mode.apk" "dist/$artifact"
python3 - "$artifact" <<'PY'
import hashlib
import sys
from pathlib import Path
apk = Path('dist') / sys.argv[1]
apk.with_suffix('.apk.sha256').write_text(f'{hashlib.sha256(apk.read_bytes()).hexdigest()}  {apk.name}\n')
print(f'{apk}: {apk.stat().st_size:,} bytes')
PY
