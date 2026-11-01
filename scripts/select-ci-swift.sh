#!/bin/bash
set -euo pipefail

printf 'Runner image: %s %s\n' "$ImageOS" "$ImageVersion"
sudo xcode-select -s /Applications/Xcode_27.0.app/Contents/Developer
swift_version=$(swift --version)
printf '%s\n' "$swift_version"
if ! printf '%s\n' "$swift_version" | grep -Eq 'Swift version 6\.4(\.|[[:space:]])'; then
    echo 'Select the Swift 6.4 toolchain' >&2
    exit 1
fi
xcode_version=$(xcodebuild -version)
printf '%s\n' "$xcode_version"
if [ "$xcode_version" != $'Xcode 27.0\nBuild version 27A266a' ]; then
    echo 'Expected Xcode 27.0 build 27A266a' >&2
    exit 1
fi
xcrun --show-sdk-version
