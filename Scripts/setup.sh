#!/usr/bin/env bash
#
# Prepares a Mac to build Swiftfin for tvOS:
#   - checks that full Xcode (not just Command Line Tools) is selected
#   - accepts the Xcode license and installs first-launch components
#   - downloads the tvOS platform / Simulator runtime if missing
#   - installs Brewfile tools (swiftformat, swiftlint) when Homebrew is available
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Xcode
developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" != *".app/Contents/Developer" ]]; then
    xcode_app="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1 || true)"
    if [[ -n "$xcode_app" ]]; then
        log "Selecting $xcode_app (requires your password)"
        sudo xcode-select -s "$xcode_app/Contents/Developer"
    else
        die "Xcode is not installed. Install it from the App Store (https://apps.apple.com/app/xcode/id497799835), open it once, then re-run make setup."
    fi
fi
log "Using $(xcodebuild -version | head -1) at $(xcode-select -p)"

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    log "Accepting the Xcode license and installing first-launch components (requires your password)"
    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
fi

# tvOS platform + Simulator runtime
if xcrun simctl list runtimes | grep -q "^tvOS"; then
    log "tvOS Simulator runtime installed: $(xcrun simctl list runtimes | grep '^tvOS' | tail -1 | cut -d' ' -f1-2)"
else
    log "Downloading the tvOS platform (several GB, this takes a while)"
    xcodebuild -downloadPlatform tvOS
fi

# Developer tools
if command -v brew >/dev/null; then
    log "Installing Brewfile tools"
    brew bundle --file "$ROOT/Brewfile"
else
    log "Homebrew not found, skipping swiftformat/swiftlint (optional, only needed for formatting)"
fi

command -v python3 >/dev/null || die "python3 is required (it ships with Xcode's command line tools)"

log "Toolchain ready"
