#!/bin/sh
# A development instance of easl for this checkout, isolated from the installed app and from
# other agents' instances (own EASL_HOME: socket, boards, log). See docs/testing.md.
#
#   scripts/dev.sh start [root]     build + bundle, launch unfocused on the current Space
#                                   (no root: the tabs this home had open, else the checkout)
#   scripts/dev.sh restart [root]   rebuild and relaunch, keeping terminal sessions (zmx) alive
#   scripts/dev.sh stop             quit and kill this instance's zmx sessions
#   scripts/dev.sh cli <args…>      run the easl CLI against this instance
#   scripts/dev.sh shot [file]      real pixels: WindowServer capture of the window (default .easl-home/shot.png; yabai)
#   scripts/dev.sh snapshot [file]  view.snapshot (in-process render, the agent-facing view) to a PNG
#   scripts/dev.sh input <args…>    replay input (scripts/dev-input.swift) into this instance
#   scripts/dev.sh sessions         list this instance's zmx sessions
#   scripts/dev.sh zmx-env <cmd…>   run <cmd> with this home's zmx paths (no GUI)
#
# More instances of one checkout (parallel agents, user studies): EASL_DEV_HOME picks another
# home (with its own browser profile, EASL_BROWSER_PROFILE=own), and EASL_DEV_APP launches a
# prebuilt bundle (a frozen copy) instead of rebuilding. Either way the instance runs from a copy
# in its home that carries its environment (scripts/dev-bundle.sh), so a relaunch by macOS
# (logging back in) can't start it on the user's default home.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
home="${EASL_DEV_HOME:-$repo/.easl-home}"
case "$home" in /*) ;; *) home="$PWD/$home" ;; esac
home="$(python3 "$repo/scripts/dev-zmx.py" "$home")"
app="${EASL_DEV_APP:-$repo/.build/easl.app}"
# Window-id lookup needs yabai: YABAI, else ~/Applications/Yabai.app, else yabai on PATH.
yabai="${YABAI:-$HOME/Applications/Yabai.app/Contents/MacOS/yabai}"
[ -x "$yabai" ] || yabai="$(command -v yabai || echo "$yabai")"
need_yabai() {
  [ -x "$yabai" ] || { echo "scripts/dev.sh $1 needs yabai (https://github.com/koekeishiya/yabai): install it, or set YABAI to its path" >&2; exit 1; }
}

window_id() {
  pid="$(running_pid)" || { echo "no running dev instance" >&2; exit 1; }
  "$yabai" -m query --windows | python3 -c "import json,sys; print(next((w['id'] for w in json.load(sys.stdin) if w['pid']==$pid), ''))"
}
# Waits up to 5 s for the instance's first window to exist.
wait_window() {
  i=0
  while [ -z "$(window_id)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
export EASL_SOCKET="$home/easl.sock"
# zmx 0.8.1 keeps sockets and logs in ZMX_DIR.
zmx_dir="$home/zmx"
zmx_state="$home/state"
zmx_tmp="$home/tmp"
zmx_env() {
  ZMX_DIR="$zmx_dir" XDG_STATE_HOME="$zmx_state" TMPDIR="$zmx_tmp" "$@"
}

# The instance running on this home: the holder of its instance lock (the pid it wrote there,
# while that process has the file open), else, for an instance from before the lock, the pid
# file's while that process owns this home's socket. Neither file counts alone: a home copied
# from another instance's carries both, and trusting them quit the user's own instance. With a
# holder missed (a stale pid file), `start` would remove its socket, leaving it with no API,
# while the new launch hands over to it and exits.
running_pid() {
  pid="$(cat "$home/instance.lock" 2>/dev/null)"
  if [ -n "$pid" ] && lsof -t "$home/instance.lock" 2>/dev/null | grep -qx "$pid"; then echo "$pid"; return; fi
  [ -f "$home/pid" ] || return 1
  pid="$(cat "$home/pid")"
  kill -0 "$pid" 2>/dev/null || return 1
  lsof -t "$EASL_SOCKET" 2>/dev/null | grep -qx "$pid" && echo "$pid"
}

quit() {
  pid="$(running_pid)" || return 0
  kill "$pid"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  # A wedged instance must not outlive its pid file: restart would start a second one on the
  # same sockets and boards.
  if kill -0 "$pid" 2>/dev/null; then
    echo "easl $pid did not quit; killing it" >&2
    kill -9 "$pid"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  fi
  rm -f "$home/pid"
}

# Sessions this instance created (their `canvas.home` label). Matching board ids instead killed
# the live instance's agents from a dev home holding copies of its boards.
sessions() {
  label="canvas.home=$(printf %s "$home" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  zmx_env zmx list 2>/dev/null | awk -F'\t' -v label="$label" '
    { for (i = 1; i <= NF; i++) if ($i == label) { sub(/^ *name=/, "", $1); print $1 } }'
}

# Without a root, start/restart bring back the tabs this home had open (open-boards.json, first
# tab selected); a fresh home opens the checkout.
saved_root() {
  python3 -c "import json,sys; roots=json.load(open(sys.argv[1])); print(roots[0] if roots else '')" "$home/open-boards.json" 2>/dev/null || true
}

launch() {
  root="${1:-$(saved_root)}"
  root="${root:-$repo}"
  [ -n "${EASL_DEV_APP:-}" ] || "$repo/scripts/bundle.sh" >/dev/null
  mkdir -p "$home"
  rm -f "$EASL_SOCKET"
  # The instance's environment, in its bundle for any launch (dev-bundle.sh adds EASL_HOME)
  # and on this one. XDG_CONFIG_HOME passes through so a scratch Ghostty config can be tried,
  # EASL_DEV_DOWNLOADS so browser downloads land in a test folder, EASL_DEV_EXTERNAL_OPEN=log
  # so links handed to the default browser or another app are only logged, and EASL_DEV_SSH
  # and EASL_DEV_REMOTE_HOME so File › Open Remote… reaches another dev instance through a
  # private sshd (docs/testing.md).
  # EASL_DEV_PERF=0 turns the probes off, e.g. to let the instance sample its own stalls.
  set -- EASL_NO_ACTIVATE=1 EASL_DEV_INPUT=1 EASL_DEV_PERF="${EASL_DEV_PERF:-1}" EASL_ROOT="$root" \
    ZMX_DIR="$zmx_dir" XDG_STATE_HOME="$zmx_state" TMPDIR="$zmx_tmp"
  [ -z "${EASL_DEV_HOME:-}" ] || set -- "$@" EASL_BROWSER_PROFILE=own
  [ -z "${XDG_CONFIG_HOME:-}" ] || set -- "$@" XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
  [ -z "${EASL_DEV_EXTERNAL_OPEN:-}" ] || set -- "$@" EASL_DEV_EXTERNAL_OPEN="$EASL_DEV_EXTERNAL_OPEN"
  [ -z "${EASL_DEV_DOWNLOADS:-}" ] || set -- "$@" EASL_DEV_DOWNLOADS="$EASL_DEV_DOWNLOADS"
  [ -z "${EASL_DEV_SSH:-}" ] || set -- "$@" EASL_DEV_SSH="$EASL_DEV_SSH"
  [ -z "${EASL_DEV_REMOTE_HOME:-}" ] || set -- "$@" EASL_DEV_REMOTE_HOME="$EASL_DEV_REMOTE_HOME"
  for name in EASL_DEV_HOST_READ_TRACE EASL_DEV_HOST_FILE_CONCURRENCY EASL_LSP_SWIFT EASL_LSP_PYTHON EASL_LSP_TYPESCRIPT EASL_LSP_GO EASL_LSP_RUST; do
    value="$(printenv "$name" || true)"
    [ -z "$value" ] || set -- "$@" "$name=$value"
  done
  # EASL_DEV_FRAME="x y w h" sets explicit window geometry in AppKit screen coordinates.
  [ -z "${EASL_DEV_FRAME:-}" ] || set -- "$@" EASL_DEV_FRAME="$EASL_DEV_FRAME"
  # EASL_UPDATE_URL: the latest.json easl › Check for Updates… reads instead of easl.sh's, e.g. a
  # local server's to test the updater (Updater.swift; docs/testing.md). A development instance
  # never checks by itself.
  [ -z "${EASL_UPDATE_URL:-}" ] || set -- "$@" EASL_UPDATE_URL="$EASL_UPDATE_URL"
  # The checkout's own home keeps the release bundle id, so a developer's everyday instance keeps
  # its browser logins and window frames; other homes get their own (dev-bundle.sh).
  bundle="$("$repo/scripts/dev-bundle.sh" $([ -n "${EASL_DEV_HOME:-}" ] || echo --release-id) "$app" "$home" "$@")"
  n=$#
  while [ "$n" -gt 0 ]; do set -- "$@" --env "$1"; shift; n=$((n - 1)); done
  set -- --stdout "$home/app.log" --stderr "$home/app.log" --env EASL_HOME="$home" "$@" "$bundle"
  # EASL_DEV_LAUNCHER (split on spaces) replaces `open -g -n` with the same arguments.
  # Custom launchers must not activate, add window rules, or move windows.
  if [ -n "${EASL_DEV_LAUNCHER:-}" ]; then
    # shellcheck disable=SC2086
    $EASL_DEV_LAUNCHER "$@" > "$home/launcher.log" 2>&1 &
  else
    open -g -n "$@"
  fi
  i=0
  while [ ! -S "$EASL_SOCKET" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$EASL_SOCKET" ] || { echo "easl did not open its socket; see $home/app.log" >&2; exit 1; }
  # The socket's owner, not the newest process of this bundle: parallel launches of one bundle race.
  lsof -t "$EASL_SOCKET" | head -n 1 > "$home/pid"
  if [ -x "$yabai" ]; then
    wait_window
  fi
  echo "easl pid $(cat "$home/pid"), EASL_SOCKET=$EASL_SOCKET"
}

case "${1:-}" in
  start) quit; launch "${2:-}" ;;
  restart) quit; launch "${2:-}" ;;
  stop)
    quit
    for name in $(sessions); do zmx_env zmx kill "$name" --force >/dev/null 2>&1 || true; done
    ;;
  cli) shift; exec bun "$repo/cli/easl.ts" "$@" ;;
  shot)
    need_yabai shot
    out="${2:-$home/shot.png}"
    wid="$(window_id)"
    [ -n "$wid" ] || { echo "no easl window" >&2; exit 1; }
    if [ -n "${EASL_DEV_FORBIDDEN_SPACES:-}" ]; then
      display="$("$yabai" -m query --windows --window "$wid" | python3 -c "import json,sys; print(json.load(sys.stdin)['display'])")"
      showing="$("$yabai" -m query --spaces --display "$display" | python3 -c "import json,sys; print(next(s['index'] for s in json.load(sys.stdin) if s['is-visible']))")"
      for forbidden in $EASL_DEV_FORBIDDEN_SPACES; do
        [ "$showing" != "$forbidden" ] || { echo "display $display is showing forbidden Space $showing; capture refused without moving the window" >&2; exit 1; }
      done
    fi
    [ ! -d "$out" ] || { echo "capture destination is a directory: $out" >&2; exit 1; }
    capture_dir="$(mktemp -d "${out}.XXXXXX")"
    trap 'rm -f "$capture_dir/shot.png"; rmdir "$capture_dir"' 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    screencapture -x -o -l "$wid" "$capture_dir/shot.png"
    [ -s "$capture_dir/shot.png" ] || { echo "screencapture did not write an image" >&2; exit 1; }
    mv -f "$capture_dir/shot.png" "$out"
    echo "$out"
    ;;
  snapshot)
    out="${2:-$home/snapshot.png}"
    bun "$repo/cli/easl.ts" view.snapshot --out "$out" >/dev/null && echo "$out"
    ;;
  input)
    shift
    pid="$(running_pid)" || { echo "no running dev instance" >&2; exit 1; }
    exec "$repo/.build/dev-input" "$pid" "$@"
    ;;
  sessions) sessions ;;
  zmx-env) shift; [ $# -gt 0 ] || { echo "usage: scripts/dev.sh zmx-env <cmd…>" >&2; exit 2; }; zmx_env "$@" ;;
  *) sed -n '2,14p' "$0" >&2; exit 2 ;;
esac
