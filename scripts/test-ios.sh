#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcrun --find simctl >/dev/null 2>&1; then
  echo 'Xcode 本体と iOS Simulator をインストールしてください。README を参照してください。' >&2
  exit 1
fi

device_id="${1:-}"
if [[ -z "$device_id" ]]; then
  device_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = [d for runtime, entries in json.load(sys.stdin)["devices"].items()
           if ".iOS-" in runtime for d in entries if d["name"].startswith("iPhone")]
devices.sort(key=lambda d: d["state"] != "Booted")
if not devices:
    sys.exit("利用可能な iPhone Simulator がありません。Xcode から iOS runtime を追加してください。")
print(devices[0]["udid"])
')"
fi

state="$(xcrun simctl list devices --json | python3 -c '
import json, sys
target = sys.argv[1]
print(next((d["state"] for entries in json.load(sys.stdin)["devices"].values()
            for d in entries if d["udid"] == target), "Missing"))
' "$device_id")"
if [[ "$state" == 'Shutdown' ]]; then
  xcrun simctl boot "$device_id"
elif [[ "$state" != 'Booted' ]]; then
  echo "Simulator を起動できません: $device_id ($state)" >&2
  exit 1
fi
xcrun simctl bootstatus "$device_id" -b
flutter test integration_test/app_test.dart -d "$device_id"

# Show the actual app after testing, rather than the integration-test host.
flutter build ios --simulator --debug
xcrun simctl install "$device_id" build/ios/iphonesimulator/Runner.app
xcrun simctl launch "$device_id" dev.camereon.camereon
sleep 3
mkdir -p dist
xcrun simctl io "$device_id" screenshot dist/ios-startup.png
