#!/usr/bin/env bash
#
# Builds Swiftfin for tvOS, signs it with the team in XcodeConfig/DevelopmentTeam.xcconfig,
# and installs it on a paired Apple TV.
#
# One-time Apple TV pairing:
#   1. Apple TV: Settings > Remotes and Devices > Remote App and Devices (keep this screen open).
#   2. Mac: Xcode > Window > Devices and Simulators, select the Apple TV, click "Pair".
#      Xcode registers the device with your team so automatic signing can create a profile.
#
# Usage:
#   Scripts/install-appletv.sh            # first paired Apple TV
#   Scripts/install-appletv.sh <UDID>     # a specific device
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA:-$ROOT/.build/DerivedData-device}"
CONFIGURATION="${CONFIGURATION:-Release}"

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
    JSON="$(mktemp)"
    xcrun devicectl list devices --quiet --json-output "$JSON" >/dev/null 2>&1 || true
    DEVICE="$(python3 -I - "$JSON" <<'EOF'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("deviceType") == "appleTV" and hw.get("reality") != "simulated":
        print(hw.get("udid") or d.get("identifier"))
        break
EOF
)"
    rm -f "$JSON"
fi

if [[ -z "$DEVICE" ]]; then
    echo "No paired Apple TV found. Pair it in Xcode > Devices and Simulators first (see the header of this script)." >&2
    exit 1
fi

echo "==> Building Swiftfin tvOS ($CONFIGURATION) for device $DEVICE"
xcodebuild \
    -project "$ROOT/Swiftfin.xcodeproj" \
    -scheme "Swiftfin tvOS" \
    -configuration "$CONFIGURATION" \
    -destination "id=$DEVICE" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    build | grep -E "error:|warning: .*signing|\*\* BUILD" || true

APP="$DERIVED/Build/Products/$CONFIGURATION-appletvos/Swiftfin.app"
if [[ ! -d "$APP" ]]; then
    echo "Build failed: $APP not found" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"
echo "==> Signed by: $(codesign -dv "$APP" 2>&1 | grep '^Authority=' | head -1)"

echo "==> Installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
echo "==> Launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || true
