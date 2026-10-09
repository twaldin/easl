#!/bin/sh
case "$1" in
list)
  n=$(cat "$HOME/lists" 2>/dev/null || echo 0)
  echo $((n + 1)) > "$HOME/lists"
  f="$HOME/list-$n"
  [ -f "$f" ] || f="$HOME/list-last"
  cat "$f"
  ;;
attach)
  printf 'attach %s SHELL=%s ZMX_DIR=%s\n' "$2" "$SHELL" "$ZMX_DIR"
  ;;
esac
