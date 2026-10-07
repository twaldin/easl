// Package zmxtest is a zmx for tests (session.Manager's, the router's, easld's and its
// conformance replay): it runs no session, it keeps each as a file in `$ZMX_DIR`.
package zmxtest

import (
	"os"
	"path/filepath"
	"strings"
)

// Script is the fake zmx. `attach` records the labels, the directory, the environment and the
// command of a session it creates; `list`, `kill` and `version` answer from them as zmx 0.8.1
// does. A session file holding `dead` is one whose daemon died: `list` finds its socket refused
// and deletes it, as zmx does. Every session's pid is 4242424 unless its file says `pid=<n>` (a
// session started again under its name): above Linux's highest pid (4194304) and macOS's, so no
// process of the machine running the test stands for it (agent.list's foreground process).
const Script = `#!/bin/sh
state="$ZMX_DIR"
case "$1" in
attach)
  shift; labels=""
  if [ "$1" = "--labels" ]; then labels="$2"; shift 2; fi
  name="$1"; shift
  [ -e "$state/$name" ] && exit 0
  { printf 'labels=%s\n' "$labels"; printf 'cwd=%s\n' "$(pwd)"; printf 'socket=%s\n' "$EASL_SOCKET"; printf 'tile=%s\n' "$EASL_TILE_ID"; printf 'path=%s\n' "$PATH"; for a in "$@"; do printf 'arg=%s\n' "$a"; done; env | sed 's/^/env=/'; } > "$state/$name"
  ;;
list)
  found=""
  for f in "$state"/*; do
    [ -f "$f" ] || continue; found=1; name=$(basename "$f")
    if grep -qx dead "$f"; then rm "$f"; printf '  name=%s\terr=ConnectionRefused\tstatus=cleaning up\n' "$name"; continue; fi
    labels=$(sed -n 's/^labels=//p' "$f" | tr ' ' '\t'); pid=$(sed -n 's/^pid=//p' "$f")
    printf '  name=%s\tpid=%s\tclients=0\tcreated=1\tcwd=file://h/tmp\tcmd=sh' "$name" "${pid:-4242424}"
    [ -n "$labels" ] && printf '\t%s' "$labels"
    printf '\n'
  done
  [ -n "$found" ] || echo "no sessions found in $state"
  ;;
kill)
  [ -e "$state/$2" ] || { echo "error: failed to kill session=$2: SessionNotFound"; exit 1; }
  rm "$state/$2"; echo "killed session $2"
  ;;
version)
  printf 'zmx\t\t0.8.1\nsocket_dir\t%s\nlog_dir\t\t%s/logs\n' "$state" "$state"
  ;;
esac
`

// Install writes Script as `dir/zmx` and returns its path.
func Install(dir string) (string, error) {
	path := filepath.Join(dir, "zmx")
	return path, os.WriteFile(path, []byte(Script), 0o755)
}

// Session is what the fake recorded of a session it started.
type Session struct {
	// Labels is `--labels` as given (`k=v` pairs, space-separated).
	Labels string
	Cwd    string
	Env    map[string]string
	Args   []string
}

// Read is the recorded session `name` in the fake's directory `dir` (`ZMX_DIR`); an error when
// there is none.
func Read(dir, name string) (Session, error) {
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return Session{}, err
	}
	s := Session{Env: map[string]string{}}
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		key, value, _ := strings.Cut(line, "=")
		switch key {
		case "labels":
			s.Labels = value
		case "cwd":
			s.Cwd = value
		case "arg":
			s.Args = append(s.Args, value)
		case "env":
			name, v, _ := strings.Cut(value, "=")
			s.Env[name] = v
		}
	}
	return s, nil
}
