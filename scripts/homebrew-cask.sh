#!/bin/sh
# Prints the Homebrew cask for a notarized release: scripts/homebrew-cask.sh <version> <zip sha256>.
# The Release workflow writes it to twaldin/homebrew-tap's Casks/easl.rb after publishing
# (docs/releasing.md "Homebrew"), so `brew install --cask twaldin/tap/easl` installs that release.
# Only for a notarized zip: Homebrew doesn't support casks that fail Gatekeeper, and the cask clears
# the quarantine flag Homebrew sets, so the zip it pins must be one spctl accepted as notarized.
set -eu

version="${1:-}"
sha256="${2:-}"
printf %s "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "usage: $0 <version, e.g. 0.2.2> <sha256 of easl-<version>.zip>" >&2; exit 2; }
printf %s "$sha256" | grep -Eq '^[0-9a-f]{64}$' || { echo "$0: '$sha256' isn't a SHA-256 (64 lowercase hex digits)" >&2; exit 2; }

cat <<EOF
# Written by twaldin/easl's Release workflow (scripts/homebrew-cask.sh); the next release replaces it.
cask "easl" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/twaldin/easl/releases/download/v#{version}/easl-#{version}.zip"
  name "easl"
  desc "Board for coding agents: terminals, code, notes and browser tiles"
  homepage "https://easl.sh/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "easl.app"

  # Gatekeeper's first-launch prompt can open on a Space nobody is looking at, and a launch from an
  # agent's shell (open -g, the easl CLI inside the app) then waits on it with nothing shown (easl#60).
  # The Release workflow writes this cask only for a zip spctl accepted as notarized, and sha256 pins
  # that zip, so the flag only asks for a confirmation. If clearing it fails, the app keeps it.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/easl.app"], must_succeed: false
  end

  # Quitting keeps terminal tiles running (zmx holds their sessions); boards are saved on quit.
  uninstall quit: "net.waldin.easl"

  # docs/install.md "Uninstall": boards, the browser profile, preferences, caches and the logs zmx
  # keeps for easl's terminal sessions.
  zap trash: [
    "~/.local/state/zmx/logs/canvas-obj_*.log",
    "~/.omp/agent/extensions/easl.ts",
    "~/Library/Application Support/Easl",
    "~/Library/Application Support/Easl-stale-*",
    "~/Library/Caches/net.waldin.easl",
    "~/Library/HTTPStorages/net.waldin.easl*",
    "~/Library/Preferences/net.waldin.easl.plist",
    "~/Library/WebKit/net.waldin.easl",
  ]

  caveats <<~CAVEATS
    Terminal tiles need zmx; the easl CLI and agent integrations need bun:
      brew install neurosnap/tap/zmx oven-sh/bun/bun

    For omp, link easl's extension:
      mkdir -p ~/.omp/agent/extensions
      ln -sf #{appdir.join("easl.app/Contents/Resources/extensions/omp/easl.ts").to_s.shellescape} ~/.omp/agent/extensions/easl.ts
  CAVEATS
end
EOF
