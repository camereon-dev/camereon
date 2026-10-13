#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

flutter pub get --enforce-lockfile
# Let Flutter regenerate native plugin registration for release mode.
flutter build apk --release "$@"
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk dist/camereon-demo.apk
python3 - <<'PY'
import hashlib
from pathlib import Path
apk = Path('dist/camereon-demo.apk')
Path('dist/camereon-demo.apk.sha256').write_text(
    f'{hashlib.sha256(apk.read_bytes()).hexdigest()}  {apk.name}\n'
)
PY
echo '配布物: dist/camereon-demo.apk（デモ用の debug 鍵で署名）'
