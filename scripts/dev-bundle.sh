#!/bin/sh
# The bundle a development instance runs from: a copy of <app> at <home>/easl.app that brings
# its instance's environment with it, so however macOS relaunches it (logging back in, the Dock,
# Finder, `open` with no environment) it runs on its own home, never on the user's default one
# beside their live app (docs/testing.md "Development bundles"). Used by scripts/dev.sh and
# scripts/perf-replica.sh; <app> itself (a release bundle, .build/easl.app, a frozen copy) is
# never changed.
#
#   scripts/dev-bundle.sh [--release-id] <app> <home> [KEY=VALUE…]   prints the copy's path
#
# The copy's Info.plist gets LSEnvironment (EASL_HOME and the given variables), which
# LaunchServices applies to every launch. ZMX_DIR, XDG_STATE_HOME and TMPDIR are always
# set from the final EASL_HOME (after KEY=VALUE), not from the copy directory: a rehearsal
# passes a different support directory than the directory the copy lives in (docs/testing.md).
# CFBundleIdentifier is <app's>.dev.<hash of the copy directory>, so
# it shares no user defaults, saved window state, WebKit default store or TCC identity with the
# release app or another home (`--release-id` keeps <app's>: the checkout's own home, a
# developer's everyday instance, keeps its browser logins and window frames); and
# NSQuitAlwaysKeepsWindows false. Then it is signed again ad hoc, keeping the source's
# entitlements and hardened runtime, and registered with LaunchServices.
set -eu
release_id=
[ "${1:-}" != --release-id ] || { release_id=1; shift; }
[ $# -ge 2 ] || { sed -n '9p' "$0" >&2; exit 2; }
source="$1"; home="$2"; shift 2
case "$home" in /*) ;; *) home="$PWD/$home" ;; esac
support="$(python3 "$(dirname "$0")/dev-zmx.py" "$home" "$@")"
[ -f "$source/Contents/Info.plist" ] || { echo "scripts/dev-bundle.sh: $source is not an app bundle" >&2; exit 1; }
copy="$home/easl.app"
[ "$(cd "$source" && pwd -P)" != "$(mkdir -p "$copy" && cd "$copy" && pwd -P)" ] || { echo "scripts/dev-bundle.sh: $source is this home's own copy; pass the bundle it was made from" >&2; exit 1; }
rm -rf "$copy"
# A clone on APFS: no bytes copied.
cp -Rc "$source" "$copy" 2>/dev/null || { rm -rf "$copy"; cp -R "$source" "$copy"; }
python3 - "$copy/Contents/Info.plist" "$home" "$support" "$release_id" "$@" <<'EOF'
import hashlib, plistlib, sys
path, home, support, release_id, pairs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
with open(path, "rb") as f:
    info = plistlib.load(f)
env = {"EASL_HOME": home}
for pair in pairs:
    key, sep, value = pair.partition("=")
    if not sep or not key:
        sys.exit(f"scripts/dev-bundle.sh: {pair!r} is not KEY=VALUE")
    env[key] = value
env["EASL_HOME"] = support
env["ZMX_DIR"] = support + "/zmx"
env["XDG_STATE_HOME"] = support + "/state"
env["TMPDIR"] = support + "/tmp"
base = info["CFBundleIdentifier"].split(".dev.")[0]
info["CFBundleIdentifier"] = base if release_id else f"{base}.dev.{hashlib.sha256(home.encode()).hexdigest()[:10]}"
info["LSEnvironment"] = env
info["NSQuitAlwaysKeepsWindows"] = False
with open(path, "wb") as f:
    plistlib.dump(info, f)
EOF
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime "$copy" 2>/dev/null
# LaunchServices caches Info.plist; register the copy so the next launch reads this one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$copy"
echo "$copy"
