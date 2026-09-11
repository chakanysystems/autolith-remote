#!/bin/bash
# Source this file so DEVELOPER_DIR also applies to subsequent validation commands.
# Select Xcode 27.0 and optionally pin an exact build with AUTOLITH_VALIDATION_XCODE_BUILD.
set -euo pipefail

required_version='27.0'
required_build=${AUTOLITH_VALIDATION_XCODE_BUILD:-}
selected=''
# GitHub's installed inventory varies by image. Inspect actual binaries rather than
# assuming an Xcode_27_RC.app pathname or silently using the runner default.
for app in /Applications/Xcode*.app; do
    developer_dir="$app/Contents/Developer"
    [[ -x "$developer_dir/usr/bin/xcodebuild" ]] || continue
    identity=$(DEVELOPER_DIR="$developer_dir" "$developer_dir/usr/bin/xcodebuild" -version)
    printf '%s: %s\n' "$app" "$identity"
    version_line=${identity%%$'\n'*}
    build_line=${identity#*$'\n'}
    if [[ "$version_line" == "Xcode $required_version" ]] &&
       [[ -z "$required_build" || "$build_line" == "Build version $required_build" ]]; then
        selected="$developer_dir"
        break
    fi
done
if [[ -z "$selected" ]]; then
    printf 'ERROR: Validation requires Xcode %s (build constraint: %s).\n' "$required_version" "${required_build:-any}" >&2
    printf 'Select the xcode-27 runner or install the required toolchain. Inventory: https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md\n' >&2
    exit 1
fi
export DEVELOPER_DIR="$selected"
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
if [[ "$simulator_sdk" != '27.0' ]]; then
    printf 'ERROR: Expected iOS Simulator SDK 27.0, found %s\n' "$simulator_sdk" >&2
    exit 1
fi
xcrun swift --version
