#!/bin/bash
# Run from any directory: bash ci_scripts/validate.sh [swiftpm|simulator|all]
# Simulator builds compile the app and embedded extension; they are not device tests.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-all}
case "$mode" in swiftpm|simulator|all) ;; *) echo "Unknown validation mode: $mode" >&2; exit 2 ;; esac
source ci_scripts/select-validation-xcode.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/autolith-validation.XXXXXX")
trap 'rm -rf "$work"' EXIT
if [[ "$mode" == swiftpm || "$mode" == all ]]; then
    # No filters: execute every Package.swift test target with Apple's XCTest runner.
    xcrun swift test --scratch-path "$work/swiftpm"
fi
if [[ "$mode" == simulator || "$mode" == all ]]; then
    # A fresh DerivedData directory prevents stale app/extension products hiding errors.
    # The app target explicitly depends on and embeds AutolithActivity.
    xcodebuild -project Autolith.xcodeproj -scheme Autolith \
        -configuration Release -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$work/DerivedData" \
        CODE_SIGNING_ALLOWED=NO build
    app="$work/DerivedData/Build/Products/Release-iphonesimulator/Autolith.app"
    test -x "$app/Autolith"
    test -x "$app/PlugIns/AutolithActivity.appex/AutolithActivity"
fi
