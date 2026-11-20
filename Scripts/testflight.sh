#!/usr/bin/env bash
#
# Archives Swiftfin X for tvOS and uploads it to App Store Connect / TestFlight.
#
# Requirements (one time):
#   - Xcode > Settings > Accounts: signed in with an Apple ID on team DEVELOPMENT_TEAM (XcodeConfig/Shared.xcconfig)
#   - App Store Connect > Apps > "+": a tvOS app with the bundle ID PRODUCT_BUNDLE_IDENTIFIER (com.microapps.swiftfinx)
#
# Optional App Store Connect API key instead of the Xcode account:
#   ASC_KEY_ID=XXXX ASC_ISSUER_ID=uuid [ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8]
#
# The build number defaults to a timestamp (yyyymmddHHMM); override with BUILD_NUMBER.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/testflight"
ARCHIVE="$OUT/SwiftfinX-tvOS.xcarchive"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

setting() {
    xcodebuild -project "$ROOT/Swiftfin.xcodeproj" -scheme "Swiftfin tvOS" -configuration Release -showBuildSettings 2>/dev/null |
        awk -v key="$1" '$1 == key && $2 == "=" { $1 = $2 = ""; sub(/^  /, ""); print; exit }'
}

TEAM="$(setting DEVELOPMENT_TEAM)"
BUNDLE_ID="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
VERSION="$(setting MARKETING_VERSION)"
[[ -n "$TEAM" ]] || die "DEVELOPMENT_TEAM is empty (XcodeConfig/Shared.xcconfig)"

auth=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
    [[ -f "$key" ]] || die "API key not found: $key"
    auth+=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

rm -rf "$OUT"
mkdir -p "$OUT"

log "Archiving $BUNDLE_ID $VERSION ($BUILD_NUMBER) for team $TEAM"
xcodebuild archive \
    -project "$ROOT/Swiftfin.xcodeproj" \
    -scheme "Swiftfin tvOS" \
    -configuration Release \
    -destination "generic/platform=tvOS" \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$ROOT/.build/DerivedData-archive" \
    -skipMacroValidation -skipPackagePluginValidation \
    "${auth[@]}" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    >"$OUT/archive.log" 2>&1 || { grep -E ": error: |error:" "$OUT/archive.log" | tail -20; die "archive failed, see $OUT/archive.log"; }

cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
EOF

log "Uploading to App Store Connect"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" \
    "${auth[@]}" \
    >"$OUT/upload.log" 2>&1 || { grep -iE "error|fail" "$OUT/upload.log" | tail -20; die "upload failed, see $OUT/upload.log"; }

log "Uploaded $BUNDLE_ID $VERSION ($BUILD_NUMBER). It appears in TestFlight after App Store Connect finishes processing (usually 5-30 min)."
