package router

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
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
	if err := store.WriteReopened(f.router.Reopens, []store.Reopened{{Root: f.board.Root(), Board: f.board.ID()}}); err != nil {
		t.Fatal(err)
	}
	return f, state
}

// restored is easld started again over f's state (its board files, its sessions, its spool, its
// reopen list): no board open but those Restore reopens. The sessions Restore queued start once
// serve runs (easld serving), which returns when they have.
func restored(t *testing.T, f *fixture) (again *fixture, errs []error, serve func()) {
	t.Helper()
	old := f.router
	old.reg.Flush()
	reg := board.NewRegistry(old.reg.Store.Dir, time.Hour, old.reg.AgentReports)
	r := New(reg)
	r.Sessions, r.Owns, r.Reopens = old.Sessions, old.Owns, old.Reopens
	errs = r.Restore()
	reg.Mu.Lock()
	b, _ := reg.Board(f.board.ID())
	reg.Mu.Unlock()
	serve = func() {
		r.StartSessions()
		reg.Mu.Lock()
		queued := r.queuedSessions()
		reg.Mu.Unlock()
		r.waitSessions(queued)
	}
	return &fixture{t: t, router: r, board: b, conn: &conn{}}, errs, serve
}

// restart is restored, serving.
func restart(t *testing.T, f *fixture) (*fixture, []error) {
	t.Helper()
	again, errs, serve := restored(t, f)
	serve()
	return again, errs
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

	again, errs, serve := restored(t, f)
	if len(errs) != 0 || again.board == nil {
		t.Fatalf("restore: %v, board %v", errs, again.board)
	}
	// Every board is loaded, but nothing starts until easld serves (its agents report to it).
	time.Sleep(200 * time.Millisecond)
	l := &again.router.lifecycle
	l.mu.Lock()
	queued, done := l.queued, l.done
	l.mu.Unlock()
	if got := sessions(t, state); len(got) != before || queued == 0 || done != 0 {
		t.Fatalf("before easld served: sessions %v, %d of %d session jobs run", got, done, queued)
	}
	serve()
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
		if !reflect.DeepEqual(unpathed(t, got.Args), c.want) {
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

// A board easld owns is listed to reopen once, when it opens, by its id and the directory it was
// opened from. At easld's next start it reopens from that directory while it opens the board,
// else from its own root as its board file has it (a repository's main checkout once the
// worktree it was opened from is removed, also when another repository took that worktree's
// path, whose board is never this one's), else from a live worktree of its repository, which
// is listed only then (a bare repository, `proj/.bare`, whose own root `proj` opens another
// board). A board nothing opens any more is dropped from the list, and a board file easld can't
// read is kept on it. Without --own-terminals nothing is listed.
func TestTheBoardsToReopenAreThoseOpenedWhileOwning(t *testing.T) {
	f, _ := restorable(t)
	dir := t.TempDir()
	repo := func(path string) {
		t.Helper()
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "a.txt"), []byte("a\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		git(t, path, "init", "-q", "-b", "main")
		git(t, path, "add", ".")
		git(t, path, "commit", "-q", "-m", "init")
	}
	gone, unreadable, proj := filepath.Join(dir, "gone"), filepath.Join(dir, "unreadable"), filepath.Join(dir, "proj")
	for _, root := range []string{gone, unreadable, proj} {
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	repo(filepath.Join(dir, "src"))
	git(t, dir, "clone", "-q", "--bare", filepath.Join(dir, "src"), filepath.Join(proj, ".bare"))
	work, work2 := filepath.Join(proj, "work"), filepath.Join(proj, "work2")
	git(t, filepath.Join(proj, ".bare"), "worktree", "add", "-q", work)
	git(t, filepath.Join(proj, ".bare"), "worktree", "add", "-q", "-b", "two", work2)
	// Two repositories opened from a feature worktree, later from the main checkout too.
	merged, mergedFeature, reused, reusedFeature := filepath.Join(dir, "merged"), filepath.Join(dir, "merged-feature"), filepath.Join(dir, "reused"), filepath.Join(dir, "reused-feature")
	repo(merged)
	repo(reused)
	git(t, merged, "worktree", "add", "-q", "-b", "feature", mergedFeature)
	git(t, reused, "worktree", "add", "-q", "-b", "feature", reusedFeature)

	id := func(root string) string {
		board := f.result("board.open", map[string]any{"root": root})["board"].(string)
		// Something on it, so its board file is saved.
		f.result("object.create", map[string]any{"board": board, "type": "note", "props": map[string]any{"markdown": "kept"}, "frame": map[string]any{"x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0}})
		return board
	}
	goneID, bareID, mergedID, reusedID := id(gone), id(work), id(mergedFeature), id(reusedFeature)
	id(merged)
	id(reused)
	if bare, _ := f.router.reg.Board(bareID); bare == nil || bare.Root() != store.Standardized(proj) || store.PathID(bare.Root()) == bareID {
		t.Fatalf("the bare repository's board: %v", bare)
	}
	listed, err := store.ReadReopened(f.router.Reopens)
	at := func(root, board string) store.Reopened {
		return store.Reopened{Root: store.Standardized(root), Board: board}
	}
	want := []store.Reopened{at(f.board.Root(), f.board.ID()), at(gone, goneID), at(work, bareID), at(mergedFeature, mergedID), at(reusedFeature, reusedID)}
	if err != nil || !reflect.DeepEqual(listed, want) {
		t.Fatalf("listed %v (%v), want %v", listed, err, want)
	}

	if err := os.RemoveAll(gone); err != nil {
		t.Fatal(err)
	}
	git(t, merged, "worktree", "remove", mergedFeature)
	git(t, reused, "worktree", "remove", reusedFeature)
	git(t, filepath.Join(proj, ".bare"), "worktree", "remove", work)
	repo(reusedFeature)
	newer := fmt.Sprintf(`{"format":99,"id":%q,"root":%q,"revision":1,"objects":[]}`, store.PathID(store.Standardized(unreadable)), store.Standardized(unreadable))
	if err := os.WriteFile(f.router.reg.Store.Path(store.PathID(store.Standardized(unreadable))), []byte(newer), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteReopened(f.router.Reopens, append(listed, at(unreadable, store.PathID(store.Standardized(unreadable))))); err != nil {
		t.Fatal(err)
	}
	listedWorktrees := map[string]int{}
	t.Cleanup(func() { worktreesOf = store.Worktrees })
	worktreesOf = func(commonDir string) []store.Worktree {
		listedWorktrees[commonDir]++
		return store.Worktrees(commonDir)
	}
	again, errs := restart(t, f)
	if len(listedWorktrees) != 1 {
		t.Errorf("worktrees listed for %v: only the bare repository's own root doesn't open its board", listedWorktrees)
	}
	for commonDir, n := range listedWorktrees {
		if filepath.Base(commonDir) != ".bare" || n != 1 {
			t.Errorf("worktrees of %s listed %d times", commonDir, n)
		}
	}
	said := make([]string, len(errs))
	for i, err := range errs {
		said[i] = err.Error()
	}
	// A worktree as its repository lists it: git records its path with symlinks resolved.
	var listedWork2 string
	for _, w := range store.Worktrees(store.Containing(work2).CommonDir) {
		if filepath.Base(w.Toplevel) == "work2" {
			listedWork2 = w.Toplevel
		}
	}
	if len(said) != 5 || !strings.Contains(said[0], goneID+" is no longer reopened: no directory opens it any more") ||
		!strings.Contains(said[1], bareID+" reopened from "+listedWork2+":") ||
		!strings.Contains(said[2], mergedID+" reopened from "+store.Standardized(merged)) ||
		!strings.Contains(said[3], reusedID+" reopened from "+store.Standardized(reused)) || !strings.Contains(said[4], "newer") {
		t.Errorf("errors %q", said)
	}
	var open []string
	for _, b := range again.router.reg.SortedBoards() {
		open = append(open, b.ID())
	}
	if !reflect.DeepEqual(open, sortedStrings(f.board.ID(), bareID, mergedID, reusedID)) {
		t.Errorf("open after the restart: %v, want %s's, the bare repository's and the two repositories'", open, f.board.Root())
	}
	listed, _ = store.ReadReopened(f.router.Reopens)
	want = []store.Reopened{want[0], {Root: listedWork2, Board: bareID}, at(merged, mergedID), at(reused, reusedID), at(unreadable, store.PathID(store.Standardized(unreadable)))}
	if !reflect.DeepEqual(listed, want) {
		t.Errorf("listed %v after the restore, want %v", listed, want)
	}

	plain := newFixture(t)
	plain.router.Reopens = filepath.Join(t.TempDir(), "open-boards.json")
	plain.result("board.open", map[string]any{"root": merged})
	if _, err := os.Stat(plain.router.Reopens); !os.IsNotExist(err) {
		t.Errorf("an easld not owning its terminals listed a board: %v", err)
	}
}

func sortedStrings(list ...string) []string {
	sort.Strings(list)
	return list
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

// The sweeps found an orphan run by one process; by the time it is ended another runs under its
// name (session.spawn and session.kill don't wait for sweeps). That one isn't the orphan: it,
// its log and the reports spooled for its tile stay, and the history says nothing.
func TestAnOrphanStartedAgainAsItIsEndedSurvives(t *testing.T) {
	f, state := owning(t)
	labels := f.router.Owns.Labels(f.board.ID(), "obj_raced")
	content := "labels=canvas.board=" + f.board.ID() + " canvas.home=" + labels[session.HomeLabel] + " canvas.tile=obj_raced\npid=3\n"
	path := filepath.Join(state, session.Prefix+"obj_raced")
	log := filepath.Join(state, "logs", session.Prefix+"obj_raced.log")
	spooled := filepath.Join(f.router.reg.AgentReports, "obj_raced", "1-1-r.json")
	for file, data := range map[string]string{path: content, log: "x", spooled: "{}"} {
		if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	found := session.Session{Name: session.Prefix + "obj_raced", Tile: "obj_raced", PID: 2, Labels: labels}
	f.router.reap(f.board, found, true)
	if data, _ := os.ReadFile(path); string(data) != content {
		t.Errorf("the session started again was ended: %q", data)
	}
	for _, file := range []string{log, spooled} {
		if _, err := os.Stat(file); err != nil {
			t.Errorf("%s was taken: %v", file, err)
		}
	}
	if said := terminalHistory(f); len(said) != 0 {
		t.Errorf("history %q", said)
	}
	found.PID = 3
	f.router.reap(f.board, found, true)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("the orphan itself is still there: %v", err)
	}
}

// An orphan zmx won't end is tried again at every sweep, but the board's history says so once
// for that process, and again for another one.
func TestAnOrphanThatWontEndIsLoggedOnce(t *testing.T) {
	f, state := owning(t)
	refusing := strings.Replace(zmxtest.Script, `rm "$state/$2"; echo "killed session $2"`, `echo "error: refused"; exit 1`, 1)
	if refusing == zmxtest.Script {
		t.Fatal("the fake zmx's kill changed: refuse it another way")
	}
	zmx := filepath.Join(t.TempDir(), "zmx")
	if err := os.WriteFile(zmx, []byte(refusing), 0o755); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions.Zmx = zmx
	labels := f.router.Owns.Labels(f.board.ID(), "obj_stuck")
	content := "labels=canvas.board=" + f.board.ID() + " canvas.home=" + labels[session.HomeLabel] + " canvas.tile=obj_stuck\n"
	if err := os.WriteFile(filepath.Join(state, session.Prefix+"obj_stuck"), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	stuck := session.Session{Name: session.Prefix + "obj_stuck", Tile: "obj_stuck", PID: 4242, Labels: labels}
	for range 3 {
		f.router.reap(f.board, stuck, true)
	}
	if said := terminalHistory(f); len(said) != 1 || !strings.Contains(said[0], "easld couldn't end session canvas-obj_stuck") {
		t.Errorf("history %q", said)
	}
	if err := os.WriteFile(filepath.Join(state, session.Prefix+"obj_stuck"), []byte(content+"pid=7\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	stuck.PID = 7
	f.router.reap(f.board, stuck, true)
	if said := terminalHistory(f); len(said) != 2 {
		t.Errorf("another process that won't end: history %q", said)
	}
}
