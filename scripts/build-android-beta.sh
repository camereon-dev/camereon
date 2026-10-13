#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CAMEREON_BETA_KEYSTORE:?Beta signing keystore is required}"
: "${CAMEREON_BETA_PASSWORD:?Beta signing password is required}"
: "${CAMEREON_BETA_CERT_SHA256:?Expected beta signing certificate is required}"
: "${GITHUB_RUN_NUMBER:?Beta build number is required}"

version="$(python3 scripts/beta_release.py version)"
bash scripts/build-android-demo.sh \
  --build-name="$version" \
  --build-number="$GITHUB_RUN_NUMBER" \
  --target-platform android-arm64
python3 scripts/beta_release.py package
