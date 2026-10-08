package router

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/store"
)

// The sessions of a folder board's owned terminals, labelled with the folder board's id, stay
// theirs once the folder's repository board takes that board in: reopened, easld starts none
// over them and reports them live; a delete ends its session; a restart ends the old session and
// relaunches; the sweep ends one whose terminal is gone. Another home's session of a terminal's
// name stays another's, and so does a session of a board the repository board didn't take in.
func TestAnAdoptedFolderBoardsTerminalsKeepTheirSessions(t *testing.T) {
	f, state := restorable(t)
	folder := filepath.Join(t.TempDir(), "folder")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	folderID := f.result("board.open", map[string]any{"root": folder})["board"].(string)
	restarted := f.agentTerminal(folderID, map[string]any{"command": []any{"omp"}})
	deleted := f.agentTerminal(folderID, map[string]any{})
	foreign := f.agentTerminal(folderID, map[string]any{})
	f.result("agent.report", map[string]any{"tile": restarted, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false})
	marked := map[string]string{}
	for _, tile := range []string{restarted, deleted, foreign} {
		path := filepath.Join(state, session.Prefix+tile)
		data, err := os.ReadFile(path)
		if err != nil || !strings.Contains(string(data), "canvas.board="+folderID) {
			t.Fatalf("%s's session %q (%v)", tile, data, err)
		}
		marked[tile] = string(data) + "mark=the folder board's\n"
		if tile == foreign {
			marked[tile] = strings.ReplaceAll(marked[tile], "canvas.home="+session.Label(f.router.Owns.Home), "canvas.home=mac-1")
		}
		if err := os.WriteFile(path, []byte(marked[tile]), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	if err := os.WriteFile(filepath.Join(folder, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, folder, "init", "-q", "-b", "main")
	git(t, folder, "add", ".")
	git(t, folder, "commit", "-q", "-m", "init")
	repoID := store.RepoID(store.Containing(folder).CommonDir)

	again, _ := restart(t, f)
	b, ok := again.router.reg.Boards()[repoID]
	if !ok {
		t.Fatalf("the repository board isn't open: %v", again.router.reg.Boards())
	}
	for _, tile := range []string{restarted, deleted} {
		if data, _ := os.ReadFile(filepath.Join(state, session.Prefix+tile)); string(data) != marked[tile] {
			t.Errorf("%s's session was started again: %q", tile, data)
		}
	}
	history := again.result("board.history", map[string]any{"board": repoID, "kinds": []any{"restart"}})["entries"].([]any)
	var said []string
	for _, e := range history {
		if e := e.(map[string]any); e["actor"] == "system" && e["type"] == "terminal" {
			said = append(said, e["summary"].(string))
		}
	}
	if len(said) != 1 || !strings.Contains(said[0], session.Prefix+foreign+" belongs to another easl instance") {
		t.Errorf("history %q: only the foreign session is another's", said)
	}
	live := map[string]any{}
	for _, a := range again.result("agent.list", map[string]any{})["agents"].([]any) {
		a := a.(map[string]any)
		if a["board"] == b.ID() {
			live[a["tile"].(string)] = a["live"]
		}
	}
	if live[restarted] != true || live[deleted] != true || live[foreign] != false {
		t.Errorf("live %v", live)
	}

	again.result("object.delete", map[string]any{"id": deleted})
	if _, err := os.Stat(filepath.Join(state, session.Prefix+deleted)); !os.IsNotExist(err) {
		t.Errorf("the deleted terminal's session runs on: %v", err)
	}
	again.result("object.delete", map[string]any{"id": foreign})
	if data, _ := os.ReadFile(filepath.Join(state, session.Prefix+foreign)); string(data) != marked[foreign] {
		t.Errorf("another home's session was ended: %q", data)
	}
	again.result("agent.restart", map[string]any{"target": restarted, "mode": "fresh", "force": true})
	data, err := os.ReadFile(filepath.Join(state, session.Prefix+restarted))
	if err != nil || strings.Contains(string(data), "mark=the folder board's") || !strings.Contains(string(data), "canvas.board="+repoID) {
		t.Errorf("restarted session %q (%v)", data, err)
	}

	// A session of the folder board's whose terminal is gone is an orphan of the repository
	// board's; one of a board it didn't take in isn't its to end.
	home := session.Label(f.router.Owns.Home)
	for tile, board := range map[string]string{"obj_orphan": folderID, "obj_unmerged": "brd_other"} {
		labels := "labels=canvas.board=" + board + " canvas.home=" + home + " canvas.tile=" + tile + "\n"
		if err := os.WriteFile(filepath.Join(state, session.Prefix+tile), []byte(labels), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	again.router.SweepOrphans()
	again.router.SweepOrphans()
	left := map[string]bool{}
	for _, tile := range sessions(t, state) {
		left[tile] = true
	}
	if left["obj_orphan"] || !left["obj_unmerged"] || !left[restarted] || !left[foreign] {
		t.Errorf("after the sweeps: %v", left)
	}
}
