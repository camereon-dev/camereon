#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A separate app ID preserves installed beta/demo data and signing compatibility.
export CAMEREON_DETECTOR_PREVIEW=1
unset CAMEREON_AI_PREVIEW CAMEREON_BETA_KEYSTORE CAMEREON_BETA_PASSWORD
flutter pub get --enforce-lockfile
flutter build apk --release --target-platform android-arm64 "$@"
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk dist/camereon-detector-arm64.apk
python3 - <<'PY'
import hashlib
from pathlib import Path
apk = Path('dist/camereon-detector-arm64.apk')
apk.with_suffix('.apk.sha256').write_text(f'{hashlib.sha256(apk.read_bytes()).hexdigest()}  {apk.name}\n')
print(f'{apk}: {apk.stat().st_size:,} bytes')
PY
