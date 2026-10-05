#!/bin/sh
# Build easl and assemble .build/easl.app (ad-hoc signed) so macOS and window managers
# treat it as a real application. Usage: scripts/bundle.sh [debug|release]
# EASL_VERSION (default: the VERSION file) and EASL_BUILD (default 1) set the bundle version.
# EASL_BUNDLE_APP assembles it elsewhere (a frozen copy for studies), leaving the bundle a
# running dev instance launched from .build/easl.app untouched.
# Distribution signing (Developer ID, hardened runtime, notarization) is scripts/notarize.sh's.
set -eu
config="${1:-debug}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
version="${EASL_VERSION:-$(cat "$repo/VERSION")}"
build="${EASL_BUILD:-1}"
cd "$repo"
swift build -j 4 -c "$config" --product Easl
bin="$(swift build -c "$config" --show-bin-path)"
app="${EASL_BUNDLE_APP:-$repo/.build/easl.app}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/clients/ts" "$app/Contents/Resources/clients/python"
cp "$bin/Easl" "$app/Contents/MacOS/Easl"
for bundle in "$bin"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
# extensions/omp/easl.ts imports ../../clients and ../../skills, which sit beside it here too.
cp -R schema bin cli skills extensions LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
# The hooks' tests (`bun test extensions/agent-hooks`) stay in the checkout.
find "$app/Contents/Resources/extensions" -name '*.test.ts' -delete
[ -d resources ] && cp -R resources "$app/Contents/Resources/resources"
# The app icon (Info.plist CFBundleIconFile). It is drawn from the brand mark by the site's
# `bun scripts/app-icon.ts <out.icns>` (an .iconset with every size, packed by iconutil).
cp scripts/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R clients/ts/src "$app/Contents/Resources/clients/ts/src"
# Tiles put clients/python on PYTHONPATH: only the SDK, so no other package (its tests) shadows
# the user's, and no stale bytecode.
cp -R clients/python/easl_sdk clients/python/pyproject.toml "$app/Contents/Resources/clients/python/"
find "$app/Contents/Resources/clients/python" -name __pycache__ -prune -exec rm -rf {} +
# Importing the SDK would write bytecode into the bundle for whichever Python the user runs, and a
# file added to the bundle breaks its signature. A plain file named __pycache__ where Python would
# make that directory makes it skip writing (the import still works, compiled in memory), without
# touching the user's own code the way PYTHONDONTWRITEBYTECODE or PYTHONPYCACHEPREFIX would.
find "$app/Contents/Resources/clients/python" -name '*.py' -exec dirname {} \; | sort -u | while IFS= read -r dir; do
  : > "$dir/__pycache__"
done
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.waldin.easl</string>
  <key>CFBundleName</key><string>easl</string>
  <key>CFBundleDisplayName</key><string>easl</string>
  <key>CFBundleExecutable</key><string>Easl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>CanvasApp.CanvasApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>A program running in easl wants to control another app.</string>
  <key>NSMicrophoneUsageDescription</key><string>A program or page running in easl wants to use the microphone.</string>
  <key>NSCameraUsageDescription</key><string>A program or page running in easl wants to use the camera.</string>
  <key>NSLocationUsageDescription</key><string>A page in a browser tile wants to know your location.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>A page in a browser tile wants to know your location.</string>
</dict>
</plist>
PLIST
# SwiftPM copies some resource files (tree-sitter queries) read-only; the README's
# `xattr -dr com.apple.quarantine` can't clear a read-only file, so make everything user-writable.
chmod -R u+w "$app"
codesign --force --sign - "$app"
# Development input replay helper (docs/testing.md); rebuilt only when its source changes.
if [ ! -x "$repo/.build/dev-input" ] || [ "$repo/scripts/dev-input.swift" -nt "$repo/.build/dev-input" ]; then
  swiftc -O "$repo/scripts/dev-input.swift" -o "$repo/.build/dev-input"
fi
echo "$app"
