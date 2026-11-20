#!/usr/bin/env bash
#
# Builds Swiftfin tvOS for the Apple TV Simulator, installs it, and launches it.
#
#   Scripts/simulator.sh create   # create the simulator if it does not exist
#   Scripts/simulator.sh run      # build, boot, install, launch
#   Scripts/simulator.sh udid     # print the simulator UDID
#
# Environment:
#   SIM_NAME        simulator name (default "Swiftfin Apple TV")
#   SIM_DEVICE_TYPE device type identifier (default Apple TV 4K 3rd generation)
#   CONFIGURATION   Debug (default) or Release
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA:-$ROOT/.build/DerivedData}"
CONFIGURATION="${CONFIGURATION:-Debug}"
SIM_NAME="${SIM_NAME:-Swiftfin Apple TV}"
SIM_DEVICE_TYPE="${SIM_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

latest_runtime() {
    xcrun simctl list runtimes --json | python3 -I -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "tvOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")
'
}

udid() {
    xcrun simctl list devices available --json | python3 -I -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "tvOS" not in runtime:
        continue
    for d in devices:
        if d["name"] == name:
            print(d["udid"])
            sys.exit(0)
' "$SIM_NAME"
}

create() {
    local id runtime
    id="$(udid)"
    if [[ -n "$id" ]]; then
        log "Simulator \"$SIM_NAME\" exists ($id)"
        return
    fi
    runtime="$(latest_runtime)"
    [[ -n "$runtime" ]] || die "no tvOS Simulator runtime installed, run: make setup"
    log "Creating simulator \"$SIM_NAME\" ($runtime)"
    xcrun simctl create "$SIM_NAME" "$SIM_DEVICE_TYPE" "$runtime"
}

run() {
    create
    local id app bundle_id
    id="$(udid)"

    log "Booting simulator \"$SIM_NAME\""
    xcrun simctl boot "$id" 2>/dev/null || true
    open -a Simulator --args -CurrentDeviceUDID "$id"

    log "Building Swiftfin tvOS ($CONFIGURATION)"
    set -o pipefail
    xcodebuild \
        -project "$ROOT/Swiftfin.xcodeproj" \
        -scheme "Swiftfin tvOS" \
        -configuration "$CONFIGURATION" \
        -destination "id=$id" \
        -derivedDataPath "$DERIVED" \
        -skipMacroValidation \
        -skipPackagePluginValidation \
        build 2>&1 | tee "$ROOT/.build/build.log" | grep -E "error:|\*\* BUILD" || true
    grep -q "\*\* BUILD SUCCEEDED" "$ROOT/.build/build.log" || die "build failed, see .build/build.log"

    app="$DERIVED/Build/Products/$CONFIGURATION-appletvsimulator/Swiftfin.app"
    [[ -d "$app" ]] || die "$app not found"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"

    xcrun simctl bootstatus "$id" -b >/dev/null
    log "Installing $bundle_id"
    xcrun simctl install "$id" "$app"
    log "Launching"
    xcrun simctl launch "$id" "$bundle_id" >/dev/null
    log "Running. Server for sign-in: http://localhost:8096 (user: demo, no password)"
}

mkdir -p "$ROOT/.build"
case "${1:-run}" in
    create) create ;;
    run) run ;;
    udid) udid ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
