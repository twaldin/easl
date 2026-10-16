#!/bin/sh
# A second easl instance showing a copy of a dev board, for performance work on the testing
# Space while the original stays in use. Terminal tiles are dropped so the copy never attaches to
# the original's zmx sessions.
#
#   scripts/perf-replica.sh start <board-id|file> [app]   copy .easl-home/boards/<id>.json (or a board file) and launch
#   PERF_HOME (default /tmp/canvas-perf-home) and EASL_DEV_SPACE keep parallel replicas apart.
#   scripts/perf-replica.sh stop
#   scripts/perf-replica.sh pid | window
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
home="${PERF_HOME:-/tmp/canvas-perf-home}"
# Places the replica's window with yabai, like scripts/dev.sh (docs/testing.md).
yabai="${YABAI:-$HOME/Applications/Yabai.app/Contents/MacOS/yabai}"
[ -x "$yabai" ] || yabai="$(command -v yabai || echo "$yabai")"
need_yabai() {
  [ -x "$yabai" ] || { echo "scripts/perf-replica.sh $1 needs yabai (https://github.com/koekeishiya/yabai): install it, or set YABAI to its path" >&2; exit 1; }
}
park="${EASL_DEV_PARK_SPACE:-7}"

# The pid file counts only while that process owns this home's socket (see scripts/dev.sh).
pid() { [ -f "$home/pid" ] && kill -0 "$(cat "$home/pid")" 2>/dev/null && lsof -t "$home/easl.sock" 2>/dev/null | grep -qx "$(cat "$home/pid")" && cat "$home/pid"; }
window() { "$yabai" -m query --windows | python3 -c "import json,sys; print(next((w['id'] for w in json.load(sys.stdin) if w['pid']==$(pid)), ''))"; }

case "${1:-}" in
  start)
    need_yabai start
    source="$2"; app="${3:-$repo/.build/easl.app}"
    [ -f "$source" ] || source="$repo/.easl-home/boards/$source.json"
    board="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$source")"
    [ -z "$(pid || true)" ] || { echo "replica already running" >&2; exit 1; }
    rm -rf "$home"; mkdir -p "$home/boards"
    python3 - "$source" "$home/boards/$board.json" <<'EOF'
import json, sys
board = json.load(open(sys.argv[1]))
objects = board["objects"] if isinstance(board["objects"], list) else list(board["objects"].values())
drop = {o["id"] for o in objects if o["type"] == "terminal"}
kept = [o for o in objects if o["id"] not in drop]
board["objects"] = kept if isinstance(board["objects"], list) else {o["id"]: o for o in kept}
json.dump(board, open(sys.argv[2], "w"))
print(f"{len(kept)} objects ({len(drop)} terminals dropped)")
EOF
    root="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['root'])" "$home/boards/$board.json")"
    # Park the first window before moving it to EASL_DEV_SPACE, if set.
    rule="canvas-dev-$(printf %s "$home" | cksum | cut -d' ' -f1)"
    "$yabai" -m rule --remove "$rule" >/dev/null 2>&1 || true
    "$yabai" -m rule --add --one-shot label="$rule" app="^easl$" space="$park" manage=off grid=1:1:0:0:1:1 >/dev/null
    # PERF_MALLOC_STACKS=1 records allocation stacks for `malloc_history <pid> <address>`. The
    # replica runs from a copy that carries this environment (scripts/dev-bundle.sh).
    set -- EASL_NO_ACTIVATE=1 EASL_DEV_INPUT=1 EASL_DEV_PERF=1 EASL_ROOT="$root"
    [ -z "${PERF_MALLOC_STACKS:-}" ] || set -- "$@" MallocStackLogging=1
    bundle="$("$repo/scripts/dev-bundle.sh" "$app" "$home" "$@")"
    n=$#
    while [ "$n" -gt 0 ]; do set -- "$@" --env "$1"; shift; n=$((n - 1)); done
    open -g -n --stdout "$home/app.log" --stderr "$home/app.log" --env EASL_HOME="$home" "$@" "$bundle"
    i=0; while [ ! -S "$home/easl.sock" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    lsof -t "$home/easl.sock" | head -n 1 > "$home/pid"
    i=0; while [ -z "$(window)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    space="${EASL_DEV_SPACE:-$park}"
    if [ "$space" != "$park" ]; then
      "$yabai" -m window "$(window)" --space "$space"
      "$yabai" -m window "$(window)" --grid 1:1:0:0:1:1
    fi
    "$yabai" -m rule --remove "$rule" >/dev/null 2>&1 || true
    echo "replica pid $(pid) window $(window) on Space $space, EASL_SOCKET=$home/easl.sock"
    ;;
  stop)
    p="$(pid || true)"; [ -n "$p" ] && kill "$p" && while kill -0 "$p" 2>/dev/null; do sleep 0.1; done
    rm -rf "$home"
    ;;
  pid) pid ;;
  window) need_yabai window; window ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
