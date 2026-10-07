package router

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/session/zmxtest"
)

// owning is a router that owns its boards' terminals (--own-terminals), its sessions run by the
// fake zmx in `state`.
func owning(t *testing.T) (f *fixture, state string) {
	f = newFixture(t)
	dir := t.TempDir()
	zmx, err := zmxtest.Install(dir)
	if err != nil {
		t.Fatal(err)
	}
	state = filepath.Join(dir, "sessions")
	if err := os.MkdirAll(filepath.Join(state, "logs"), 0o700); err != nil {
		t.Fatal(err)
	}
	// easld started in an easl tile: that tile's cmux variables are in its environment.
	f.router.Sessions = &session.Manager{Zmx: zmx, Dir: state, Shell: "/bin/sh", Home: dir, Env: []string{"PATH=/usr/bin:/bin", "CMUX_SOCKET_PATH=/old/cmux.sock", "CMUX_SOCKET_PASSWORD=secret"}}
	f.router.Owns = &session.Owner{Socket: "/home/u/.local/state/easl/easl.sock", Home: "/home/u/.local/state/easl", Resources: session.Resources("/home/u")}
	f.router.reg.AgentReports = filepath.Join(dir, "agent-reports")
	return f, state
}

// sessions are the tiles whose sessions the fake zmx runs.
func sessions(t *testing.T, state string) []string {
	t.Helper()
	entries, err := os.ReadDir(state)
	if err != nil {
		t.Fatal(err)
	}
	var tiles []string
	for _, e := range entries {
		if tile, ok := strings.CutPrefix(e.Name(), session.Prefix); ok && !e.IsDir() {
			tiles = append(tiles, tile)
		}
	}
	return tiles
}

func terminal(props map[string]any) map[string]any {
	return map[string]any{"type": "terminal", "props": props, "frame": map[string]any{"x": 0.0, "y": 0.0, "w": 600.0, "h": 400.0}}
}

// A terminal created on a board easld owns runs its command in a session easld starts by the
// time the create is answered: labelled with the board, the tile and easld's home, in the
// terminal's cwd (else the board's root), with the variables of the shared fixture (easld's
// socket, the board's root, easl's bin before easld's PATH). A hosted terminal's session is its
// Mac's to start.
func TestAnOwnedTerminalsSessionStartsWithItsVariablesAndLabels(t *testing.T) {
	f, state := owning(t)
	cwd := t.TempDir()
	tile := idOf(f.result("object.create", terminal(map[string]any{"cwd": cwd, "command": []any{"omp", "--model", "it's"}})))
	shell := idOf(f.result("object.create", terminal(map[string]any{})))
	f.result("object.create", terminal(map[string]any{"host": "deckbox"}))
	if got := sessions(t, state); !reflect.DeepEqual(got, sortedPair(tile, shell)) {
		t.Fatalf("sessions %v, want %s and %s only", got, tile, shell)
	}
	got, err := zmxtest.Read(state, session.Prefix+tile)
	if err != nil {
		t.Fatal(err)
	}
	board := f.board.ID()
	if want := "canvas.board=" + board + " canvas.home=_home_u_.local_state_easl canvas.tile=" + tile; got.Labels != want {
		t.Errorf("labels %q, want %q", got.Labels, want)
	}
	if real, _ := filepath.EvalSymlinks(cwd); got.Cwd != real && got.Cwd != cwd {
		t.Errorf("cwd %s, want %s", got.Cwd, cwd)
	}
	for key, want := range f.router.Owns.Env(board, tile, f.board.Root()) {
		if key == "PATH" {
			want += ":/usr/bin:/bin"
		}
		if got.Env[key] != want {
			t.Errorf("%s=%q, want %q", key, got.Env[key], want)
		}
	}
	if got.Env["EASL_SOCKET"] != "/home/u/.local/state/easl/easl.sock" || got.Env["EASL_BOARD_ROOT"] != f.board.Root() {
		t.Errorf("env %v", got.Env)
	}
	for key := range got.Env {
		if strings.HasPrefix(key, "CMUX_") {
			t.Errorf("the session inherited easld's %s", key)
		}
	}
	if want := []string{"/bin/sh", "-l", "-c", `'omp' '--model' 'it'"'"'s'; exec '/bin/sh' -l`}; !reflect.DeepEqual(got.Args, want) {
		t.Errorf("command %q, want %q", got.Args, want)
	}
	plain, _ := zmxtest.Read(state, session.Prefix+shell)
	if real, _ := filepath.EvalSymlinks(f.board.Root()); (plain.Cwd != real && plain.Cwd != f.board.Root()) || strings.Join(plain.Args, " ") != "/bin/sh -l" {
		t.Errorf("a terminal without cwd or command: %+v", plain)
	}
}

func sortedPair(a, b string) []string {
	if b < a {
		return []string{b, a}
	}
	return []string{a, b}
}

// A batch that fails puts back what it did, so the terminal it created never had a session; one
// that succeeds starts its terminals'.
func TestAFailedBatchStartsNoSession(t *testing.T) {
	f, state := owning(t)
	reply := f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": terminal(map[string]any{"name": "doomed"})},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "obj_missing", "props": map[string]any{}}},
	}})
	if code, _ := errorOf(reply); code != "not_found" || len(f.board.Objects()) != 0 {
		t.Fatalf("batch: %v, objects %d", reply, len(f.board.Objects()))
	}
	if got := sessions(t, state); len(got) != 0 {
		t.Fatalf("a failed batch started %v", got)
	}
	result := f.result("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": terminal(map[string]any{"name": "kept"})},
	}})
	created := result["results"].([]any)[0].(map[string]any)["object"].(map[string]any)["id"].(string)
	if got := sessions(t, state); !reflect.DeepEqual(got, []string{created}) {
		t.Fatalf("sessions %v, want %s", got, created)
	}
}

// Deleting an owned terminal, alone or in a batch, ends its session, zmx's log of it and the
// reports spooled for it; a batch that fails after deleting one leaves it running. A session
// already gone (exited, or its daemon died) leaves its log, which the delete takes too.
func TestADeleteEndsTheSessionItsLogAndItsSpool(t *testing.T) {
	f, state := owning(t)
	tile := idOf(f.result("object.create", terminal(map[string]any{})))
	kept := idOf(f.result("object.create", terminal(map[string]any{})))
	exited := idOf(f.result("object.create", terminal(map[string]any{})))
	if err := os.Remove(filepath.Join(state, session.Prefix+exited)); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(state, "logs", session.Prefix+tile+".log")
	exitedLog := filepath.Join(state, "logs", session.Prefix+exited+".log")
	spool := filepath.Join(f.router.reg.AgentReports, tile)
	for _, path := range []string{log, exitedLog, filepath.Join(spool, "1-1-r.json")} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	reply := f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.delete", "params": map[string]any{"id": kept}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "obj_missing", "props": map[string]any{}}},
	}})
	if code, _ := errorOf(reply); code != "not_found" {
		t.Fatalf("batch: %v", reply)
	}
	f.result("object.delete", map[string]any{"id": tile})
	f.result("object.delete", map[string]any{"id": exited})
	if got := sessions(t, state); !reflect.DeepEqual(got, []string{kept}) {
		t.Fatalf("sessions %v, want only %s, whose delete was put back", got, kept)
	}
	for _, path := range []string{log, exitedLog, spool} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("%s is still there: %v", path, err)
		}
	}
	for _, e := range f.result("board.history", map[string]any{"kinds": []any{"restart"}})["entries"].([]any) {
		if e := e.(map[string]any); e["type"] == "terminal" {
			t.Errorf("a session already gone is no failure: %v", e["summary"])
		}
	}
	f.result("object.batch", map[string]any{"ops": []any{map[string]any{"method": "object.delete", "params": map[string]any{"id": kept}}}})
	if got := sessions(t, state); len(got) != 0 {
		t.Fatalf("sessions %v after the batch deleted %s", got, kept)
	}
}

// A session of the tile's name labelled with another home (a Mac's offload, a board copied into
// another home) is neither taken over nor ended: the board's history says why.
func TestAnotherHomesSessionIsLeftAlone(t *testing.T) {
	f, state := owning(t)
	tile := idOf(f.result("object.create", terminal(map[string]any{})))
	name := session.Prefix + tile
	foreign := "labels=canvas.board=" + f.board.ID() + " canvas.home=mac-1 canvas.tile=" + tile + "\n"
	if err := os.WriteFile(filepath.Join(state, name), []byte(foreign), 0o600); err != nil {
		t.Fatal(err)
	}
	f.result("object.delete", map[string]any{"id": tile})
	if data, _ := os.ReadFile(filepath.Join(state, name)); string(data) != foreign {
		t.Fatalf("another home's session was ended or changed: %q", data)
	}

	// The same for a spawn: a terminal whose name another home's session has.
	other := model.Object{ID: "obj_other", Type: model.Terminal, Props: map[string]any{"name": "copy"}}
	taken := strings.Replace(foreign, tile, other.ID, 1)
	if err := os.WriteFile(filepath.Join(state, session.Prefix+other.ID), []byte(taken), 0o600); err != nil {
		t.Fatal(err)
	}
	f.router.reg.Mu.Lock()
	f.router.terminals(f.board, []model.Object{other}, nil)
	queued := f.router.queuedSessions()
	f.router.reg.Mu.Unlock()
	f.router.waitSessions(queued)
	if data, _ := os.ReadFile(filepath.Join(state, session.Prefix+other.ID)); string(data) != taken {
		t.Fatalf("another home's session was taken over: %q", data)
	}

	entries := f.result("board.history", map[string]any{"kinds": []any{"restart"}})["entries"].([]any)
	var said []string
	for _, e := range entries {
		if e := e.(map[string]any); e["actor"] == "system" && e["type"] == "terminal" {
			said = append(said, e["summary"].(string))
		}
	}
	if len(said) != 2 || !strings.Contains(said[0], "easld couldn't end its session: session "+name+" belongs to another easl instance") ||
		!strings.Contains(said[1], `terminal "copy": easld couldn't start its session: session canvas-obj_other belongs to another easl instance`) {
		t.Errorf("history %q", said)
	}
}
