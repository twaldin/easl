#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: scripts/build-ghostty.sh <new-GhosttyKit.xcframework-path>" >&2
    exit 2
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
output="$1"
case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
if [ -e "$output" ]; then
    echo "Refusing to replace existing output: $output" >&2
    exit 2
fi
[ "$(uname -s)" = Darwin ] || { echo "This build requires macOS and Xcode's Metal compiler." >&2; exit 1; }
[ "$(zig version)" = 0.16.0 ] || { echo "Zig 0.16.0 is required." >&2; exit 1; }
xcrun --find metal
xcrun --find metallib

scratch="$(mktemp -d "${TMPDIR:-/tmp}/easl-ghostty.XXXXXX")"
printf 'Native build scratch: %s\n' "$scratch"
trap 'rm -rf "$scratch"' EXIT
wrapper_revision=b7f888e3baf8585ea9d590ab1a45b49475e00d1c
ghostty_revision=3c47ca159368eb4a860ffe5333abdf4a85b2767b
for entry in "wrapper https://github.com/Lakr233/libghostty-spm.git $wrapper_revision" \
             "ghostty https://github.com/ghostty-org/ghostty.git $ghostty_revision"; do
    read -r name remote revision <<< "$entry"
    git init -q "$scratch/$name"
    git -C "$scratch/$name" remote add origin "$remote"
    git -C "$scratch/$name" fetch --depth 1 origin "$revision"
    git -C "$scratch/$name" checkout --detach FETCH_HEAD
    [ "$(git -C "$scratch/$name" rev-parse HEAD)" = "$revision" ]
done
(
    cd "$scratch/wrapper"
    Script/apply-patches.sh "$scratch/ghostty"
    git -C "$scratch/ghostty" apply "$repo/patches/ghostty-async-rendering.patch"
    ZIG_OPTIMIZE=ReleaseFast ZIG_BUILD_EXTRA_ARGS=-j2 Script/build-platform.sh "$scratch/ghostty" macos "$scratch/artifacts"
)

mkdir -p "$(dirname "$output")"
python3 - "$scratch/artifacts/macosx" "$output" "$repo/patches/ghostty-async-rendering.patch" "$wrapper_revision" "$ghostty_revision" <<'PY'
import hashlib
import json
import pathlib
import plistlib
import shutil
import sys

artifact, output, patch = map(pathlib.Path, sys.argv[1:4])
slice_path = output / "macos-arm64_x86_64"
slice_path.mkdir(parents=True)
shutil.copy2(artifact / "lib/libghostty.a", slice_path / "libghostty.a")
shutil.copytree(artifact / "include", slice_path / "Headers")
with (output / "Info.plist").open("wb") as stream:
    plistlib.dump({"CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0",
                  "AvailableLibraries": [{"LibraryIdentifier": "macos-arm64_x86_64",
                                          "LibraryPath": "libghostty.a", "HeadersPath": "Headers",
                                          "SupportedArchitectures": ["arm64", "x86_64"],
                                          "SupportedPlatform": "macos"}]}, stream)
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
provenance = {"wrapperRevision": sys.argv[4], "ghosttyRevision": sys.argv[5],
              "zigVersion": "0.16.0", "optimize": "ReleaseFast", "buildJobs": 2,
              "patchSHA256": sha(patch),
              "files": {str(path.relative_to(output)): sha(path)
                        for path in sorted(output.rglob("*")) if path.is_file()}}
(output / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
PY
lipo -info "$output/macos-arm64_x86_64/libghostty.a"
printf 'Built %s\n' "$output"
