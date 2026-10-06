package session

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeZmx is a zmx that keeps its sessions as files in `state`: `attach` records the labels,
// the directory, the environment and the command of a session it creates; `list`, `kill` and
// `version` answer from them as zmx 0.8.1 does.
const fakeZmx = `#!/bin/sh
state="$FAKE_ZMX_STATE"
case "$1" in
attach)
  shift; labels=""
  if [ "$1" = "--labels" ]; then labels="$2"; shift 2; fi
  name="$1"; shift
  [ -e "$state/$name" ] && exit 0
  { printf 'labels=%s\n' "$labels"; printf 'cwd=%s\n' "$(pwd)"; printf 'socket=%s\n' "$EASL_SOCKET"; printf 'tile=%s\n' "$EASL_TILE_ID"; printf 'path=%s\n' "$PATH"; for a in "$@"; do printf 'arg=%s\n' "$a"; done; } > "$state/$name"
  ;;
list)
  found=""
  for f in "$state"/*; do
    [ -f "$f" ] || continue; found=1; name=$(basename "$f")
    labels=$(sed -n 's/^labels=//p' "$f" | tr ' ' '\t')
    printf '  name=%s\tpid=4242\tclients=0\tcreated=1\tcwd=file://h/tmp\tcmd=sh' "$name"
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

func fixture(t *testing.T) (*Manager, string) {
	t.Helper()
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	if err := os.MkdirAll(filepath.Join(state, "logs"), 0o755); err != nil {
		t.Fatal(err)
	}
	zmx := filepath.Join(dir, "zmx")
	if err := os.WriteFile(zmx, []byte(fakeZmx), 0o755); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(dir, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	m := &Manager{Zmx: zmx, Shell: "/bin/bash", Home: home, Env: []string{"PATH=/usr/bin:/bin", "FAKE_ZMX_STATE=" + state, "EASL_SOCKET=/inherited"}}
	return m, state
}

func record(t *testing.T, state, name string) map[string][]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(state, name))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string][]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		key, value, _ := strings.Cut(line, "=")
		out[key] = append(out[key], value)
	}
	return out
}

func code(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

// A spawn starts the command in the login shell, which stays after it, in the directory and with
// the environment and labels given; spawning again leaves the running session alone.
func TestSpawnStartsTheSessionOnce(t *testing.T) {
	m, state := fixture(t)
	cwd := t.TempDir()
	labels := map[string]string{"canvas.board": "brd_1", "canvas.tile": "obj_a", HomeLabel: "mac-1"}
	name, created, err := m.Spawn(SpawnRequest{Tile: "obj_a", Command: []string{"omp", "--model", "it's"}, Cwd: cwd,
		Env: map[string]string{"EASL_SOCKET": "/run/mac-1/easl.sock", "EASL_TILE_ID": "obj_a", "PATH": "/share/easl/bin"}, Labels: labels})
	if err != nil || !created || name != "canvas-obj_a" {
		t.Fatalf("spawn: %q %v %v", name, created, err)
	}
	got := record(t, state, "canvas-obj_a")
	if want := []string{"canvas.board=brd_1 canvas.home=mac-1 canvas.tile=obj_a"}; strings.Join(got["labels"], "|") != want[0] {
		t.Errorf("labels %v, want %v", got["labels"], want)
	}
	if real, _ := filepath.EvalSymlinks(cwd); got["cwd"][0] != real && got["cwd"][0] != cwd {
		t.Errorf("cwd %v, want %s", got["cwd"], cwd)
	}
	if got["socket"][0] != "/run/mac-1/easl.sock" || got["tile"][0] != "obj_a" {
		t.Errorf("env: socket %v tile %v", got["socket"], got["tile"])
	}
	if got["path"][0] != "/share/easl/bin:/usr/bin:/bin" {
		t.Errorf("PATH %v: easl's bin goes before easld's own", got["path"])
	}
	wantArgs := []string{"/bin/bash", "-l", "-c", `'omp' '--model' 'it'"'"'s'; exec '/bin/bash' -l`}
	if strings.Join(got["arg"], "\x00") != strings.Join(wantArgs, "\x00") {
		t.Errorf("command %q, want %q", got["arg"], wantArgs)
	}

	_, created, err = m.Spawn(SpawnRequest{Tile: "obj_a", Command: []string{"other"}, Labels: labels})
	if err != nil || created {
		t.Fatalf("second spawn: created %v err %v", created, err)
	}
	if got := record(t, state, "canvas-obj_a"); got["arg"][3] != wantArgs[3] {
		t.Errorf("second spawn replaced the session: %q", got["arg"])
	}
}

// Without a command the session is the login shell, in the user's home.
func TestSpawnWithoutCommandIsTheLoginShell(t *testing.T) {
	m, state := fixture(t)
	if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_b"}); err != nil {
		t.Fatal(err)
	}
	got := record(t, state, "canvas-obj_b")
	if strings.Join(got["arg"], " ") != "/bin/bash -l" {
		t.Errorf("command %q", got["arg"])
	}
	if real, _ := filepath.EvalSymlinks(m.Home); got["cwd"][0] != real && got["cwd"][0] != m.Home {
		t.Errorf("cwd %v, want the home %s", got["cwd"], m.Home)
	}
	if got["socket"][0] != "/inherited" {
		t.Errorf("easld's own environment should reach the session: EASL_SOCKET %v", got["socket"])
	}
}

// Another instance's session (its `canvas.home` label) is neither taken over nor ended.
func TestAnotherHomesSessionIsRefused(t *testing.T) {
	m, state := fixture(t)
	if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_c", Labels: map[string]string{HomeLabel: "mac-1"}}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_c", Labels: map[string]string{HomeLabel: "mac-2"}}); code(err) != "conflict" || !strings.Contains(err.Error(), "mac-1") {
		t.Errorf("spawn from another home: %v", err)
	}
	if _, err := m.Kill("obj_c", "mac-2"); code(err) != "conflict" {
		t.Errorf("kill from another home: %v", err)
	}
	if _, err := os.Stat(filepath.Join(state, "canvas-obj_c")); err != nil {
		t.Errorf("the session should still run: %v", err)
	}
}

// Kill ends the session and deletes zmx's log of it; a session that isn't there is `false`.
func TestKillEndsTheSessionAndItsLog(t *testing.T) {
	m, state := fixture(t)
	if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_d", Labels: map[string]string{HomeLabel: "mac-1"}}); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(state, "logs", "canvas-obj_d.log")
	other := filepath.Join(state, "logs", "canvas-obj_e.log")
	for _, f := range []string{log, other} {
		if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	killed, err := m.Kill("obj_d", "mac-1")
	if err != nil || !killed {
		t.Fatalf("kill: %v %v", killed, err)
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Errorf("the session's log should be gone: %v", err)
	}
	if _, err := os.Stat(other); err != nil {
		t.Errorf("another session's log was touched: %v", err)
	}
	if killed, err := m.Kill("obj_d", "mac-1"); err != nil || killed {
		t.Errorf("second kill: %v %v", killed, err)
	}
}

func TestSpawnChecksItsParams(t *testing.T) {
	m, _ := fixture(t)
	for name, req := range map[string]SpawnRequest{
		"missing cwd":   {Tile: "obj_f", Cwd: filepath.Join(m.Home, "nope")},
		"tile path":     {Tile: "../x"},
		"label value":   {Tile: "obj_f", Labels: map[string]string{"canvas.home": "a b"}},
		"env name":      {Tile: "obj_f", Env: map[string]string{"A=B": "x"}},
		"env value nul": {Tile: "obj_f", Env: map[string]string{"A": "x\x00y"}},
	} {
		if _, _, err := m.Spawn(req); code(err) != "invalid_params" {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, _, err := (&Manager{}).Spawn(SpawnRequest{Tile: "obj_f"}); code(err) != "unavailable" || !strings.Contains(err.Error(), "offload-setup.sh") {
		t.Errorf("no zmx: %v", err)
	}
}

// `zmx list` lines: other sessions are left out, labels kept, an unreachable session marked.
func TestParseListsCanvasSessions(t *testing.T) {
	out := "  name=dev\tpid=1\tclients=1\tcreated=1\tcwd=file://h/\n" +
		"* name=canvas-obj_2\tpid=22\tclients=1\tcreated=1\tcwd=file://h/\tcmd=bash -l\tcanvas.home=mac-1\tcanvas.tile=obj_2\n" +
		"  name=canvas-obj_1\terr=Timeout\tstatus=unreachable\n"
	got := Parse(out)
	if len(got) != 2 || got[0].Name != "canvas-obj_1" || got[1].Name != "canvas-obj_2" {
		t.Fatalf("sessions %+v", got)
	}
	if !got[0].Unreachable || got[0].PID != 0 || got[0].Tile != "obj_1" {
		t.Errorf("unreachable session %+v", got[0])
	}
	if got[1].PID != 22 || got[1].Clients != 1 || got[1].Labels[HomeLabel] != "mac-1" || len(got[1].Labels) != 2 || got[1].Unreachable {
		t.Errorf("session %+v", got[1])
	}
	if len(Parse("no sessions found in /tmp/zmx-1000\n")) != 0 {
		t.Error("an empty list should parse empty")
	}
}
