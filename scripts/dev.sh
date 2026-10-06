#!/bin/sh
# A development instance of easl for this checkout, isolated from the installed app and from
# other agents' instances (own EASL_HOME: socket, boards, log). See docs/testing.md.
#
#   scripts/dev.sh start [root]     build + bundle, launch without activating on the testing Space
#                                   (no root: the tabs this home had open, else the checkout)
#   scripts/dev.sh restart [root]   rebuild and relaunch, keeping terminal sessions (zmx) alive
#   scripts/dev.sh stop             quit and kill this instance's zmx sessions
#   scripts/dev.sh cli <args…>      run the easl CLI against this instance
#   scripts/dev.sh shot [file]      real pixels: WindowServer capture of the window (default .easl-home/shot.png; yabai)
#   scripts/dev.sh snapshot [file]  view.snapshot (in-process render, the agent-facing view) to a PNG
#   scripts/dev.sh move [space]     move the window to a Space (default: the testing Space) and maximize it (yabai)
#   scripts/dev.sh input <args…>    replay input (scripts/dev-input.swift) into this instance
#   scripts/dev.sh sessions         list this instance's zmx sessions
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
app="${EASL_DEV_APP:-$repo/.build/easl.app}"
# Window placement is optional and needs yabai (docs/testing.md, "Optional: a machine shared with
# other agents"): YABAI, else ~/Applications/Yabai.app, else yabai on PATH.
yabai="${YABAI:-$HOME/Applications/Yabai.app/Contents/MacOS/yabai}"
[ -x "$yabai" ] || yabai="$(command -v yabai || echo "$yabai")"
need_yabai() {
  [ -x "$yabai" ] || { echo "scripts/dev.sh $1 needs yabai (https://github.com/koekeishiya/yabai): install it, or set YABAI to its path" >&2; exit 1; }
}
# The unviewed Space a launch's first window is parked on until it's placed.
park="${EASL_DEV_PARK_SPACE:-7}"
# The testing Space: EASL_DEV_SPACE, else the first Space of the BetterDisplay virtual screen
# named EASL_DEV_DISPLAY (default "CanvasTest"; a headless monitor, so the window renders while
# nobody looks at it), else Space 8. Parallel agents each get their own screen (CanvasTest2, …).
test_space() {
  if [ -n "${EASL_DEV_SPACE:-}" ]; then echo "$EASL_DEV_SPACE"; return; fi
  id="$(betterdisplaycli get --name="${EASL_DEV_DISPLAY:-CanvasTest}" --identifiers 2>/dev/null | sed -n 's/.*"displayID" : "\([0-9]*\)".*/\1/p' | head -n 1)"
  space="$([ -n "$id" ] && "$yabai" -m query --displays 2>/dev/null | python3 -c "import json,sys; print(next((d['spaces'][0] for d in json.load(sys.stdin) if d['id']==$id), ''))" 2>/dev/null)"
  echo "${space:-8}"
}

window_id() {
  pid="$(running_pid)" || { echo "no running dev instance" >&2; exit 1; }
  "$yabai" -m query --windows | python3 -c "import json,sys; print(next((w['id'] for w in json.load(sys.stdin) if w['pid']==$pid), ''))"
}
export EASL_SOCKET="$home/easl.sock"
# zmx keys its socket directory off TMPDIR; match the GUI app's.
zmx_env() { TMPDIR="$(getconf DARWIN_USER_TEMP_DIR)" "$@"; }

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
  set -- EASL_NO_ACTIVATE=1 EASL_DEV_INPUT=1 EASL_DEV_PERF=1 EASL_ROOT="$root"
  [ -z "${EASL_DEV_HOME:-}" ] || set -- "$@" EASL_BROWSER_PROFILE=own
  [ -z "${XDG_CONFIG_HOME:-}" ] || set -- "$@" XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
  [ -z "${EASL_DEV_EXTERNAL_OPEN:-}" ] || set -- "$@" EASL_DEV_EXTERNAL_OPEN="$EASL_DEV_EXTERNAL_OPEN"
  [ -z "${EASL_DEV_DOWNLOADS:-}" ] || set -- "$@" EASL_DEV_DOWNLOADS="$EASL_DEV_DOWNLOADS"
  [ -z "${EASL_DEV_SSH:-}" ] || set -- "$@" EASL_DEV_SSH="$EASL_DEV_SSH"
  [ -z "${EASL_DEV_REMOTE_HOME:-}" ] || set -- "$@" EASL_DEV_REMOTE_HOME="$EASL_DEV_REMOTE_HOME"
  # The checkout's own home keeps the release bundle id, so a developer's everyday instance keeps
  # its browser logins and window frames; other homes get their own (dev-bundle.sh).
  bundle="$("$repo/scripts/dev-bundle.sh" $([ -n "${EASL_DEV_HOME:-}" ] || echo --release-id) "$app" "$home" "$@")"
  n=$#
  while [ "$n" -gt 0 ]; do set -- "$@" --env "$1"; shift; n=$((n - 1)); done
  # EASL_DEV_LAUNCHER (a command, split on spaces) launches instead of `open -g -n`, with the same
  # `open` arguments, in the background (its output in $home/launcher.log), and places the window
  # itself: a guard that keeps test windows off a shared Mac's viewed Spaces, such as
  # `gui-launch --space 7 --guard-seconds 7200 -- -n` (docs/testing.md).
  if [ -n "${EASL_DEV_LAUNCHER:-}" ]; then
    # shellcheck disable=SC2086
    $EASL_DEV_LAUNCHER --stdout "$home/app.log" --stderr "$home/app.log" --env EASL_HOME="$home" "$@" "$bundle" > "$home/launcher.log" 2>&1 &
  else
    # yabai can't place a new window on another display's Space (it lands on the Space being
    # viewed), so a one-shot rule parks this launch's first window on an unviewed Space of the
    # built-in display, and it moves to the testing Space once it exists. One-shot and removed
    # afterwards: a standing rule on app=easl also grabbed every later window (tabs, other
    # instances, the user's own boards) and hid them on the parking Space.
    rule="canvas-dev-$(printf %s "$home" | cksum | cut -d' ' -f1)"
    if [ -x "$yabai" ]; then
      "$yabai" -m rule --remove "$rule" >/dev/null 2>&1 || true
      "$yabai" -m rule --add --one-shot label="$rule" app="^easl$" space="$park" manage=off grid=1:1:0:0:1:1 >/dev/null
    fi
    open -g -n --stdout "$home/app.log" --stderr "$home/app.log" --env EASL_HOME="$home" "$@" "$bundle"
  fi
  i=0
  while [ ! -S "$EASL_SOCKET" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$EASL_SOCKET" ] || { echo "easl did not open its socket; see $home/app.log" >&2; exit 1; }
  # The socket's owner, not the newest process of this bundle: parallel launches of one bundle race.
  lsof -t "$EASL_SOCKET" | head -n 1 > "$home/pid"
  if [ -n "${EASL_DEV_LAUNCHER:-}" ] || [ ! -x "$yabai" ]; then
    # The launcher places the window; callers that look it up by pid (perf-loop.py) find it here.
    if [ -x "$yabai" ]; then
      i=0
      while [ -z "$(window_id)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    fi
    echo "easl pid $(cat "$home/pid"), EASL_SOCKET=$EASL_SOCKET"
    return
  fi
  target="$(test_space)"
  if [ "$target" != "$park" ]; then
    i=0
    while [ -z "$(window_id)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    wid="$(window_id)"
    [ -n "$wid" ] && "$yabai" -m window "$wid" --space "$target" && "$yabai" -m window "$wid" --grid 1:1:0:0:1:1
  fi
  "$yabai" -m rule --remove "$rule" >/dev/null 2>&1 || true
  echo "easl pid $(cat "$home/pid") on Space $target, EASL_SOCKET=$EASL_SOCKET"
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
    # Only a displayed Space is composited; anything else would be a stale frame.
    visible="$("$yabai" -m query --windows --window "$wid" | python3 -c "import json,sys; print(json.load(sys.stdin)['is-visible'])")"
    [ "$visible" = "True" ] || { echo "window $wid is not on a displayed Space; its pixels would be stale (scripts/dev.sh move)" >&2; exit 1; }
    screencapture -x -o -l "$wid" "$out" && echo "$out"
    ;;
  move)
    need_yabai move
    wid="$(window_id)"
    [ -n "$wid" ] || { echo "no easl window" >&2; exit 1; }
    "$yabai" -m window "$wid" --space "${2:-$(test_space)}"
    "$yabai" -m window "$wid" --grid 1:1:0:0:1:1
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
  *) sed -n '2,14p' "$0" >&2; exit 2 ;;
esac
