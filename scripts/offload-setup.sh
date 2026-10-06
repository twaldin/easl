#!/bin/sh
# scripts/offload-setup.sh <host>: makes an ssh host ready for easl's hosted terminals, the
# tiles whose `host` prop names it (docs/contracts.md "Hosted terminals"). Idempotent, and
# entirely the user's: no root, nothing started. It installs, under the host user's home:
#
#   ~/.local/bin/zmx             zmx 0.8.1 (the release easl's Mac uses), checksum-verified
#   ~/.local/bin/easld           easld built from this checkout for the host's OS and CPU
#   ~/.local/bin/easl            the easl CLI (runs ~/.local/share/easl/bin/easl with bun)
#   ~/.local/share/easl/         easl's files for agents: the CLI, the TS and Python clients, the
#                                omp extension and agent hooks, the skill, the schema, and
#                                Ghostty's shell integration (prompt marks) when one is found here
#   ~/.omp/agent/extensions/easl.ts -> ~/.local/share/easl/extensions/omp/easl.ts
#   ~/.local/share/easl/easld@.service   the system unit easld runs as (below)
#
# easld then has to run as a system unit in the host's capped slice (easld/packaging/linux/
# easld@.service), so the tiles' sessions it starts stay there: the script prints that unit for
# the host's administrator and never installs it. Needs on the host: bun and nc (OpenBSD's, for
# `nc -U`); on this Mac: go, curl, ssh.
#
#   EASL_RESOURCES=<dir>   take easl's files from <dir> (an app's Contents/Resources) instead of
#                          this checkout, so the host's extension and CLI match that app
set -eu

[ $# -eq 1 ] || { echo "usage: scripts/offload-setup.sh <ssh host>" >&2; exit 2; }
host=$1
repo=$(cd "$(dirname "$0")/.." && pwd)
resources=${EASL_RESOURCES:-$repo}
zmx_version=0.8.1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/easl-offload.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

say() { printf '%s\n' "$*"; }
die() { printf 'offload-setup: %s\n' "$*" >&2; exit 1; }
on_host() { ssh -o BatchMode=yes "$host" "$@"; }

# $1: a binary name, $2: the local file. Written beside the old one and renamed over it, so a
# running easld or zmx keeps its file; a no-op when the host has the same bytes.
install_bin() {
  sum=$(shasum -a 256 "$2" | cut -d' ' -f1)
  old=$(on_host "f=\"\$HOME/.local/bin/$1\"; [ -f \"\$f\" ] && { sha256sum \"\$f\" 2>/dev/null || shasum -a 256 \"\$f\"; } | cut -d' ' -f1" || true)
  if [ "$old" = "$sum" ]; then say "$1: up to date"; return 1; fi
  on_host "set -e; mkdir -p \"\$HOME/.local/bin\"; cat > \"\$HOME/.local/bin/.$1.new\"; chmod 755 \"\$HOME/.local/bin/.$1.new\"; mv -f \"\$HOME/.local/bin/.$1.new\" \"\$HOME/.local/bin/$1\"" < "$2" \
    || die "couldn't install ~/.local/bin/$1 on $host"
  say "$1: installed ~/.local/bin/$1"
}

# What the host is.
info=$(on_host 'uname -s; uname -m; printf "%s\n" "$HOME"; id -un') || die "can't reach $host over ssh (it needs to work without a password: ssh $host true)"
os=$(printf '%s\n' "$info" | sed -n 1p)
arch=$(printf '%s\n' "$info" | sed -n 2p)
home=$(printf '%s\n' "$info" | sed -n 3p)
user=$(printf '%s\n' "$info" | sed -n 4p)
case "$os/$arch" in
  Linux/x86_64) target=linux-x86_64 goos=linux goarch=amd64 sha=dfd75720b942466f28870731cc86dbc07afa72fb8f3bd5eeb4ff707e4eecebe8 ;;
  Linux/aarch64 | Linux/arm64) target=linux-aarch64 goos=linux goarch=arm64 sha=943eb44c812333fd450da12097521afd3339436e86f8c2ac618b905c4c9ece68 ;;
  Darwin/arm64) target=macos-aarch64 goos=darwin goarch=arm64 sha=1d86b1c9fba47fa707a6f0e976b20510b07c1c26d0ed010b9414b2a2c5e6beef ;;
  Darwin/x86_64) target=macos-x86_64 goos=darwin goarch=amd64 sha=3208578ad91d8a62077772dc8a1369a92033d9e84169bac673ef8542b6ff9707 ;;
  *) die "$host is $os/$arch, which zmx $zmx_version has no build for" ;;
esac
say "$host: $os $arch, user $user, home $home"

missing=$(on_host 'PATH="$HOME/.bun/bin:$PATH"; for c in bun nc; do command -v "$c" >/dev/null 2>&1 || printf "%s " "$c"; done')
[ -z "$missing" ] || die "$host lacks: $missing(the easl CLI and the omp extension run on bun; the app reaches easld through nc -U)"
on_host 'PATH="$HOME/.bun/bin:$PATH"; command -v omp >/dev/null 2>&1' || say "note: omp isn't installed on $host (tiles can run other programs; install omp for agent tiles)"

# zmx, the release the Mac uses.
if on_host '"$HOME/.local/bin/zmx" version 2>/dev/null' | grep -q "^zmx[[:space:]]*$zmx_version\$"; then
  say "zmx $zmx_version: up to date"
else
  curl -fsSL "https://zmx.sh/a/zmx-$zmx_version-$target.tar.gz" -o "$tmp/zmx.tar.gz" || die "couldn't download zmx $zmx_version for $target"
  printf '%s  %s\n' "$sha" "$tmp/zmx.tar.gz" | shasum -a 256 -c - >/dev/null || die "zmx-$zmx_version-$target.tar.gz doesn't match its checksum"
  tar -xzf "$tmp/zmx.tar.gz" -C "$tmp" zmx
  install_bin zmx "$tmp/zmx" || true
fi

# easld, from this checkout.
command -v go >/dev/null 2>&1 || die "building easld needs go on this Mac"
(cd "$repo/easld" && CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch go build -trimpath -o "$tmp/easld" ./cmd/easld) || die "easld didn't build"
easld_changed=no
install_bin easld "$tmp/easld" && easld_changed=yes

# easl's files, as the app bundle ships them (scripts/bundle.sh), replaced as a whole.
for part in schema bin cli skills extensions clients/ts/src clients/python/easl_sdk; do
  [ -e "$resources/$part" ] || die "$resources has no $part (EASL_RESOURCES is an app's Contents/Resources or a checkout)"
done
mkdir -p "$tmp/files/clients/ts" "$tmp/files/clients/python"
for part in schema bin cli skills extensions; do cp -R "$resources/$part" "$tmp/files/"; done
cp -R "$resources/clients/ts/src" "$tmp/files/clients/ts/src"
cp -R "$resources/clients/python/easl_sdk" "$tmp/files/clients/python/easl_sdk"
# The unit, for the host's administrator to install (below).
cp "$repo/easld/packaging/linux/easld@.service" "$tmp/files/easld@.service"
find "$tmp/files" \( -name '*.test.ts' -o -name __pycache__ -o -name .DS_Store \) -prune -exec rm -rf {} +
# Ghostty's shell integration (OSC 133 prompt marks for agent.read's `block` on the host), from
# the app or a build of this checkout.
integration=
for dir in "${EASL_APP:-/Applications/easl.app}/Contents/Resources" "$resources" "$repo"/.build/*/release "$repo"/.build/*/debug; do
  candidate="$dir/GhosttyKit_GhosttyTerminal.bundle/Ghostty/shell-integration"
  if [ -d "$candidate" ]; then integration=$candidate; break; fi
done
if [ -n "$integration" ]; then
  mkdir -p "$tmp/files/ghostty" && cp -R "$integration" "$tmp/files/ghostty/shell-integration"
else
  say "note: no Ghostty shell integration found here (build the app or install easl.app): hosted shells get no prompt marks"
fi
(cd "$tmp/files" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -cf - .) | on_host 'set -e
d="$HOME/.local/share/easl"
mkdir -p "$HOME/.local/share"
rm -rf "$d.new" "$d.old"
mkdir "$d.new"
tar -xf - -C "$d.new"
if [ -d "$d" ]; then mv "$d" "$d.old"; fi
mv "$d.new" "$d"
rm -rf "$d.old"'
say "easl's files: installed ~/.local/share/easl"

# The CLI on PATH, and omp's extension. A file of the user's own at either path is left alone.
on_host 'set -e
mkdir -p "$HOME/.local/bin" "$HOME/.omp/agent/extensions" "$HOME/.local/state/easl"
chmod 700 "$HOME/.local/state/easl"
cli="$HOME/.local/bin/easl"
if [ ! -e "$cli" ] || grep -q "local/share/easl/bin/easl" "$cli" 2>/dev/null; then
  printf "#!/bin/sh\n# easl CLI (scripts/offload-setup.sh)\nexec \"\$HOME/.local/share/easl/bin/easl\" \"\$@\"\n" > "$cli.new"
  chmod 755 "$cli.new"; mv -f "$cli.new" "$cli"
  echo "easl CLI: installed ~/.local/bin/easl"
else
  echo "note: ~/.local/bin/easl is not easl'"'"'s, left as it is"
fi
ext="$HOME/.omp/agent/extensions/easl.ts"
if [ ! -e "$ext" ] || [ -L "$ext" ]; then
  ln -sfn "$HOME/.local/share/easl/extensions/omp/easl.ts" "$ext"
  echo "omp extension: ~/.omp/agent/extensions/easl.ts -> ~/.local/share/easl/extensions/omp/easl.ts"
else
  echo "note: ~/.omp/agent/extensions/easl.ts is a file of its own, left as it is"
fi'

# The extension loads (its imports resolve) under the host's bun.
on_host 'PATH="$HOME/.bun/bin:$PATH"; cd "$HOME/.local/share/easl" && bun -e "await import(process.env.HOME + \"/.local/share/easl/extensions/omp/easl.ts\")"' >/dev/null \
  || die "the omp extension doesn't load under $host's bun"
say "omp extension: loads"

unit=easld@$user.service
state=$(on_host "systemctl is-active $unit 2>/dev/null" || true)
if [ "$state" = active ]; then
  say "$unit: active"
  [ "$easld_changed" = no ] || say "easld changed: restart it to use the new one (sessions keep running: KillMode=process): sudo systemctl restart $unit"
else
  say ""
  say "easld isn't running as $unit on $host. Its administrator installs the unit once (it is $home/.local/share/easl/easld@.service there, and below):"
  say "  sudo install -m 0644 $home/.local/share/easl/easld@.service /etc/systemd/system/easld@.service"
  say "  sudo systemctl daemon-reload && sudo systemctl enable --now $unit"
  say "It needs agents.slice (the capped slice the tiles run in) to exist. The unit:"
  say ""
  cat "$repo/easld/packaging/linux/easld@.service"
fi
