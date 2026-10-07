package session

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/session/zmxtest"
)

func fixture(t *testing.T) (*Manager, string) {
	t.Helper()
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	if err := os.MkdirAll(filepath.Join(state, "logs"), 0o755); err != nil {
		t.Fatal(err)
	}
	zmx, err := zmxtest.Install(dir)
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(dir, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	m := &Manager{Zmx: zmx, Dir: state, Shell: "/bin/bash", Home: home, Env: []string{"PATH=/usr/bin:/bin", "EASL_SOCKET=/inherited"}}
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

// A session whose owner labels aren't the caller's (another home's: a board copied there has the
// same ids; another board's; one without them) is neither taken over nor ended.
func TestAnotherOwnersSessionIsRefused(t *testing.T) {
	m, state := fixture(t)
	mine := map[string]string{HomeLabel: "mac-1", "canvas.board": "brd_1", "canvas.tile": "obj_c"}
	if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_c", Labels: mine}); err != nil {
		t.Fatal(err)
	}
	for key, other := range map[string]string{HomeLabel: "mac-2", "canvas.board": "brd_2", "canvas.tile": "obj_x"} {
		labels := map[string]string{}
		for k, v := range mine {
			labels[k] = v
		}
		labels[key] = other
		if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_c", Labels: labels}); code(err) != "conflict" || !strings.Contains(err.Error(), mine[key]) {
			t.Errorf("spawn with another %s: %v", key, err)
		}
	}
	if _, err := m.Kill("obj_c", "mac-2"); code(err) != "conflict" {
		t.Errorf("kill from another home: %v", err)
	}
	if _, err := os.Stat(filepath.Join(state, "canvas-obj_c")); err != nil {
		t.Errorf("the session should still run: %v", err)
	}
	if _, created, err := m.Spawn(SpawnRequest{Tile: "obj_c", Labels: mine}); err != nil || created {
		t.Errorf("its owner's spawn: created %v, %v", created, err)
	}

	// A session nobody labelled (started by hand) can't be shown to be the caller's.
	if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_u"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_u", Labels: map[string]string{HomeLabel: "mac-1"}}); code(err) != "conflict" || !strings.Contains(err.Error(), "none") {
		t.Errorf("spawn over an unlabelled session: %v", err)
	}
	if _, err := m.Kill("obj_u", "mac-1"); code(err) != "conflict" {
		t.Errorf("kill of an unlabelled session: %v", err)
	}
}

// zmx runs only in the user's own directory: made 0700 when missing, closed to others when they
// can only read it, and refused (zmx never runs) when it is a symlink, another user's, or others
// can write to it. A spawn's `env` can't point zmx elsewhere.
func TestZmxRunsOnlyInTheUsersOwnDirectory(t *testing.T) {
	m, _ := fixture(t)
	m.Dir = filepath.Join(t.TempDir(), "state", "zmx")
	if _, _, err := m.Spawn(SpawnRequest{Tile: "obj_z", Env: map[string]string{"ZMX_DIR": t.TempDir()}}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(m.Dir, "canvas-obj_z")); err != nil {
		t.Errorf("the session should be in Dir whatever the spawn's env says: %v", err)
	}
	if info, _ := os.Stat(m.Dir); info.Mode().Perm() != 0o700 {
		t.Errorf("a new directory is %v, want 0700", info.Mode().Perm())
	}
	if err := os.Chmod(m.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := m.List(); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(m.Dir); info.Mode().Perm() != 0o700 {
		t.Errorf("a directory others could read is %v, want 0700", info.Mode().Perm())
	}

	writable := filepath.Join(t.TempDir(), "zmx")
	if err := os.Mkdir(writable, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(writable, 0o777); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "elsewhere")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "zmx")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct{ dir, written string }{
		"others can write": {writable, writable},
		"a symlink":        {link, target},
	} {
		bad := &Manager{Zmx: m.Zmx, Dir: c.dir, Shell: m.Shell, Home: m.Home, Env: m.Env}
		if _, _, err := bad.Spawn(SpawnRequest{Tile: "obj_z"}); code(err) != "unavailable" || !strings.Contains(err.Error(), c.dir) {
			t.Errorf("%s: %v", name, err)
		}
		if entries, _ := os.ReadDir(c.written); len(entries) > 0 {
			t.Errorf("%s: zmx ran there", name)
		}
	}
	if err := secure(m.Dir, os.Getuid()+1); code(err) != "unavailable" || !strings.Contains(err.Error(), "belongs to uid") {
		t.Errorf("another user's directory: %v", err)
	}
}

// A session zmx found dead (it deletes the socket as it lists it) is gone: spawn starts the
// tile's session again instead of answering that it runs.
func TestSpawnReplacesASessionZmxFoundDead(t *testing.T) {
	m, state := fixture(t)
	if err := os.WriteFile(filepath.Join(state, "canvas-obj_g"), []byte("dead\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, created, err := m.Spawn(SpawnRequest{Tile: "obj_g", Labels: map[string]string{HomeLabel: "mac-1"}}); err != nil || !created {
		t.Fatalf("spawn: created %v, %v", created, err)
	}
	if got := record(t, state, "canvas-obj_g"); got["labels"][0] != "canvas.home=mac-1" {
		t.Errorf("the new session: %v", got)
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

// `zmx list` lines: other sessions are left out, labels kept, one that didn't answer in time
// marked unreachable, and one zmx found dead (and deleted) left out.
func TestParseListsCanvasSessions(t *testing.T) {
	out := "  name=dev\tpid=1\tclients=1\tcreated=1\tcwd=file://h/\n" +
		"→ name=canvas-obj_2\tpid=22\tclients=1\tcreated=1\tcwd=file://h/\tcmd=bash -l\tended=5\texit_code=0\tcanvas.home=mac-1\tcanvas.tile=obj_2\n" +
		"  name=canvas-obj_1\terr=Timeout\tstatus=unreachable\n" +
		"  name=canvas-obj_3\terr=ConnectionRefused\tstatus=cleaning up\n"
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
