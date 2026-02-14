#!/usr/bin/env bash
set -euo pipefail

# Generates a 6.5-inch iPhone App Store screenshot using the iPhone 11 Pro Max simulator.
# Output: docs/app-store/screenshots/iphone65-1.png
#
# Notes:
# - Uses DEBUG + simulator-only ScreenshotMode (SCREENSHOT_MODE=1).
# - Does not require Photos permission or real media.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEST_DIR="$ROOT_DIR/docs/app-store/screenshots"
mkdir -p "$DEST_DIR"

DEVICE_NAME="ClipDock iPhone 11 Pro Max (6.5-inch)"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max"
RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-18-6"

if ! xcrun simctl list devices | rg -Fq "${DEVICE_NAME}"; then
  xcrun simctl create "${DEVICE_NAME}" "${DEVICE_TYPE}" "${RUNTIME_ID}" >/dev/null
fi

UDID="$(
  xcrun simctl list devices -j | python3 -c '
import json,sys
data=json.load(sys.stdin)
name=sys.argv[1]
for _, devices in data.get("devices", {}).items():
    for d in devices:
        if d.get("name") == name:
            print(d.get("udid", ""))
            raise SystemExit(0)
raise SystemExit(1)
' "${DEVICE_NAME}"
)"

echo "Using simulator: ${DEVICE_NAME} (${UDID})"

xcrun simctl bootstatus "${UDID}" -b >/dev/null

# Ensure the Simulator app is open and focused on this device.
open -a Simulator --args -CurrentDeviceUDID "${UDID}" || true
sleep 2

# Set a stable status bar (best-effort; some fields may be ignored on newer iOS).
xcrun simctl status_bar "${UDID}" override --time "9:41" --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100 || true

echo "Generating Xcode project..."
xcodegen generate >/dev/null

DD="$ROOT_DIR/.build/appstore-screenshots-dd"
rm -rf "$DD"

echo "Building app for simulator..."
xcodebuild \
  -scheme ClipDock \
  -configuration Debug \
  -derivedDataPath "$DD" \
  -destination "platform=iOS Simulator,id=${UDID}" \
  build >/dev/null

APP_PATH="$DD/Build/Products/Debug-iphonesimulator/ClipDock.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: app not found at $APP_PATH" >&2
  exit 1
fi

BUNDLE_ID="com.wenfeng.clipdock"
echo "Installing..."
xcrun simctl install "${UDID}" "$APP_PATH" >/dev/null

echo "Launching (SCREENSHOT_MODE=1)..."
SIMCTL_CHILD_SCREENSHOT_MODE=1 xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" >/dev/null || true

sleep 2

OUT="$DEST_DIR/iphone65-1.png"
echo "Capturing screenshot: $OUT"
xcrun simctl io "${UDID}" screenshot --type=png "$OUT"

echo "Done."
echo "$OUT"
