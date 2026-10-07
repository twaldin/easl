package router

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/session/zmxtest"
	"github.com/twaldin/easl/easld/internal/store"
)

// restorable is owning's router recording the boards it opens in a reopen list, its own board
// on it.
func restorable(t *testing.T) (f *fixture, state string) {
	f, state = owning(t)
	f.router.Reopens = filepath.Join(t.TempDir(), "open-boards.json")
	if err := store.WriteRoots(f.router.Reopens, []string{f.board.Root()}); err != nil {
		t.Fatal(err)
	}
	return f, state
}

// restart is easld started again over f's state (its board files, its sessions, its spool, its
// reopen list): no board open but those Restore reopens, whose sessions it has started by the
// time restart returns.
func restart(t *testing.T, f *fixture) (*fixture, []error) {
	t.Helper()
	old := f.router
	old.reg.Flush()
	reg := board.NewRegistry(old.reg.Store.Dir, time.Hour, old.reg.AgentReports)
	r := New(reg)
	r.Sessions, r.Owns, r.Reopens = old.Sessions, old.Owns, old.Reopens
	errs := r.Restore()
	reg.Mu.Lock()
	queued := r.queuedSessions()
	b, _ := reg.Board(f.board.ID())
	reg.Mu.Unlock()
	r.waitSessions(queued)
	return &fixture{t: t, router: r, board: b, conn: &conn{}}, errs
}

// terminalHistory is what the board's history says of its terminals' sessions.
func terminalHistory(f *fixture) []string {
	var said []string
	for _, e := range f.result("board.history", map[string]any{"kinds": []any{"restart"}})["entries"].([]any) {
		if e := e.(map[string]any); e["actor"] == "system" && e["type"] == "terminal" {
			said = append(said, e["summary"].(string))
		}
	}
	return said
}

// Reconciling a board easld reopens: each owned terminal without a session of its own gets one,
// resuming the agent it recorded with the options of its own command, else running that command
// (an agent released, one easl can't resume); a running session is left alone (an easld restart
// starts nothing), and so is one that doesn't answer; another home's session of the tile's name
// is not taken over, and the history says so; a hosted terminal's session is its Mac's.
func TestRestoreStartsTheMissingSessionsAndNothingElse(t *testing.T) {
	f, state := restorable(t)
	home := session.Label(f.router.Owns.Home)
	resumed := []string{"/bin/sh", "-l", "-c", `'omp' '--model' 'opus' '--resume=s1'; exec '/bin/sh' -l`}
	cases := []struct {
		name  string
		props map[string]any
		// report is the agent.report_session the terminal's agent sent; release, its agent.release.
		report  map[string]any
		release bool
		// before is the tile's session when easld starts again: "running" (its own, as it was),
		// "gone" (a reboot), "foreign" (another home's of its name), "unreachable" (its own, not
		// answering).
		before string
		// want is the command of the session it then has; nil when easld leaves it as it was.
		want []string
	}{
		{name: "running", props: map[string]any{"command": []any{"omp", "--model", "opus"}}, report: map[string]any{"kind": "omp", "sessionId": "s1"}, before: "running"},
		{name: "resumed", props: map[string]any{"command": []any{"omp", "--model", "opus", "fix it"}}, report: map[string]any{"kind": "omp", "sessionId": "s1"}, before: "gone", want: resumed},
		{name: "released", props: map[string]any{"command": []any{"claude", "--model", "opus"}}, report: map[string]any{"kind": "claude", "sessionId": "u-1"}, release: true, before: "gone",
			want: []string{"/bin/sh", "-l", "-c", `'claude' '--model' 'opus'; exec '/bin/sh' -l`}},
		{name: "not resumable", props: map[string]any{"command": []any{"aider"}}, report: map[string]any{"kind": "aider", "sessionId": "x"}, before: "gone",
			want: []string{"/bin/sh", "-l", "-c", `'aider'; exec '/bin/sh' -l`}},
		{name: "shell", props: map[string]any{}, before: "gone", want: []string{"/bin/sh", "-l"}},
		{name: "foreign", props: map[string]any{}, before: "foreign"},
		{name: "unreachable", props: map[string]any{}, before: "unreachable"},
	}
	tiles := map[string]string{}
	files := map[string]string{}
	for _, c := range cases {
		tile := idOf(f.result("object.create", terminal(c.props)))
		tiles[c.name] = tile
		if c.report != nil {
			report := map[string]any{"tile": tile}
			for k, v := range c.report {
				report[k] = v
			}
			f.result("agent.report_session", report)
		}
		if c.release {
			f.result("agent.release", map[string]any{"tile": tile, "kind": c.report["kind"]})
		}
		path := filepath.Join(state, session.Prefix+tile)
		labels := "canvas.board=" + f.board.ID() + " canvas.home=" + home + " canvas.tile=" + tile
		switch c.before {
		case "running":
			files[c.name] = "labels=" + labels + "\nmark=still the first\n"
		case "foreign":
			files[c.name] = "labels=canvas.board=" + f.board.ID() + " canvas.home=mac-1 canvas.tile=" + tile + "\n"
		case "unreachable":
			files[c.name] = "labels=" + labels + " status=unreachable\n"
		case "gone":
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.WriteFile(path, []byte(files[c.name]), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	f.result("object.create", terminal(map[string]any{"host": "deckbox"}))
	before := len(sessions(t, state))

	again, errs := restart(t, f)
	if len(errs) != 0 || again.board == nil {
		t.Fatalf("restore: %v, board %v", errs, again.board)
	}
	if got := sessions(t, state); len(got) != len(cases) || len(got) != before+4 {
		t.Errorf("sessions %v after the restore, want one per owned terminal", got)
	}
	for _, c := range cases {
		name := session.Prefix + tiles[c.name]
		if c.want == nil {
			if data, _ := os.ReadFile(filepath.Join(state, name)); string(data) != files[c.name] {
				t.Errorf("%s: its session was started again or changed: %q", c.name, data)
			}
			continue
		}
		got, err := zmxtest.Read(state, name)
		if err != nil {
			t.Errorf("%s: no session: %v", c.name, err)
			continue
		}
		if !reflect.DeepEqual(got.Args, c.want) {
			t.Errorf("%s: command %q, want %q", c.name, got.Args, c.want)
		}
		if want := "canvas.board=" + f.board.ID() + " canvas.home=" + home + " canvas.tile=" + tiles[c.name]; got.Labels != want {
			t.Errorf("%s: labels %q", c.name, got.Labels)
		}
	}
	said := terminalHistory(again)
	if len(said) != 1 || !strings.Contains(said[0], "easld couldn't start its session: session "+session.Prefix+tiles["foreign"]+" belongs to another easl instance") {
		t.Errorf("history %q", said)
	}

	// Started again with every session running, easld starts none.
	snapshot := map[string]string{}
	for _, tile := range sessions(t, state) {
		data, _ := os.ReadFile(filepath.Join(state, session.Prefix+tile))
		snapshot[tile] = string(data) + "mark=after the restore\n"
		if err := os.WriteFile(filepath.Join(state, session.Prefix+tile), []byte(snapshot[tile]), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	third, _ := restart(t, again)
	for tile, want := range snapshot {
		if data, _ := os.ReadFile(filepath.Join(state, session.Prefix+tile)); string(data) != want {
			t.Errorf("%s was started again: %q", tile, data)
		}
	}
	if said := terminalHistory(third); len(said) != 1 {
		t.Errorf("history %q", said)
	}
}

// A board easld owns is listed to reopen once, when it opens; a root gone by easld's next start
// is dropped from the list (its board isn't reopened), a board file easld can't read is kept on
// it. Without --own-terminals nothing is listed.
func TestTheBoardsToReopenAreThoseOpenedWhileOwning(t *testing.T) {
	f, _ := restorable(t)
	dir := t.TempDir()
	other, gone, unreadable := filepath.Join(dir, "other"), filepath.Join(dir, "gone"), filepath.Join(dir, "unreadable")
	for _, root := range []string{other, gone, unreadable} {
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f.result("board.open", map[string]any{"root": other})
	f.result("board.open", map[string]any{"root": other})
	f.result("board.open", map[string]any{"root": gone})
	roots, err := store.ReadRoots(f.router.Reopens)
	if err != nil || !reflect.DeepEqual(roots, []string{f.board.Root(), store.Standardized(other), store.Standardized(gone)}) {
		t.Fatalf("listed %q (%v)", roots, err)
	}
	if err := os.RemoveAll(gone); err != nil {
		t.Fatal(err)
	}
	newer := fmt.Sprintf(`{"format":99,"id":%q,"root":%q,"revision":1,"objects":[]}`, store.PathID(store.Standardized(unreadable)), store.Standardized(unreadable))
	if err := os.WriteFile(f.router.reg.Store.Path(store.PathID(store.Standardized(unreadable))), []byte(newer), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteRoots(f.router.Reopens, append(roots, store.Standardized(unreadable))); err != nil {
		t.Fatal(err)
	}
	again, errs := restart(t, f)
	if len(errs) != 2 || !strings.Contains(errs[0].Error(), "is gone") || !strings.Contains(errs[1].Error(), "newer") {
		t.Errorf("errors %v", errs)
	}
	if open := again.router.reg.SortedBoards(); len(open) != 2 {
		t.Errorf("%d boards open, want %s's and %s's", len(open), f.board.Root(), other)
	}
	roots, _ = store.ReadRoots(f.router.Reopens)
	if want := []string{f.board.Root(), store.Standardized(other), store.Standardized(unreadable)}; !reflect.DeepEqual(roots, want) {
		t.Errorf("listed %q after the restore, want %q", roots, want)
	}

	plain := newFixture(t)
	plain.router.Reopens = filepath.Join(t.TempDir(), "open-boards.json")
	plain.result("board.open", map[string]any{"root": other})
	if _, err := os.Stat(plain.router.Reopens); !os.IsNotExist(err) {
		t.Errorf("an easld not owning its terminals listed a board: %v", err)
	}
}

// A session of easld's home whose open board has no owned terminal for it (easld was down when
// it was deleted, zmx refused to end it) ends at the second sweep that finds it so, with its log,
// its spooled reports and an entry in the board's history; one started again under its name in
// between waits for the next. Another home's session, one of a board that isn't open, one that
// doesn't answer and every terminal's own are left alone.
func TestSessionsLeftWithoutTheirTerminalEndAfterAGrace(t *testing.T) {
	f, state := owning(t)
	home := session.Label(f.router.Owns.Home)
	tile := idOf(f.result("object.create", terminal(map[string]any{})))
	hosted := idOf(f.result("object.create", terminal(map[string]any{"host": "deckbox"})))
	ours := func(board, tile string) string {
		return "labels=canvas.board=" + board + " canvas.home=" + home + " canvas.tile=" + tile + "\n"
	}
	planted := map[string]string{
		"obj_orphan":   ours(f.board.ID(), "obj_orphan"),
		"obj_again":    ours(f.board.ID(), "obj_again") + "pid=1\n",
		"obj_mac":      "labels=canvas.board=" + f.board.ID() + " canvas.home=mac-1 canvas.tile=obj_mac\n",
		"obj_closed":   ours("brd_closed", "obj_closed"),
		"obj_silent":   strings.TrimSuffix(ours(f.board.ID(), "obj_silent"), "\n") + " status=unreachable\n",
		"obj_mislabel": ours(f.board.ID(), "obj_other"),
		// A terminal now hosted runs its session on its Mac's behalf: easld's own is left over.
		hosted: ours(f.board.ID(), hosted),
	}
	for tile, content := range planted {
		if err := os.WriteFile(filepath.Join(state, session.Prefix+tile), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	log := filepath.Join(state, "logs", session.Prefix+"obj_orphan.log")
	spool := filepath.Join(f.router.reg.AgentReports, "obj_orphan")
	for _, path := range []string{log, filepath.Join(spool, "1-1-r.json")} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	all := append([]string{tile}, "obj_again", "obj_closed", "obj_mac", "obj_mislabel", "obj_orphan", "obj_silent", hosted)

	f.router.SweepOrphans()
	if got := sessions(t, state); len(got) != len(all) {
		t.Fatalf("the first sweep ended some: %v", got)
	}
	// obj_again started again under its name since.
	if err := os.WriteFile(filepath.Join(state, session.Prefix+"obj_again"), []byte(ours(f.board.ID(), "obj_again")+"pid=2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.router.SweepOrphans()
	left := map[string]bool{}
	for _, tile := range sessions(t, state) {
		left[tile] = true
	}
	if left["obj_orphan"] || left[hosted] || !left["obj_again"] || !left[tile] || !left["obj_mac"] || !left["obj_closed"] || !left["obj_silent"] || !left["obj_mislabel"] {
		t.Errorf("after the second sweep: %v", left)
	}
	for _, path := range []string{log, spool} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("%s is still there: %v", path, err)
		}
	}
	if data, _ := os.ReadFile(filepath.Join(state, session.Prefix+"obj_mac")); string(data) != planted["obj_mac"] {
		t.Errorf("another home's session changed: %q", data)
	}
	f.router.SweepOrphans()
	if got := sessions(t, state); len(got) != len(all)-3 {
		t.Errorf("after the third sweep: %v", got)
	}
	said := terminalHistory(f)
	if len(said) != 3 || !strings.Contains(said[0], "easld ended session "+session.Prefix) || !strings.Contains(strings.Join(said, "\n"), "easld ended session canvas-obj_again: no terminal on this board has it any more") {
		t.Errorf("history %q", said)
	}
}
