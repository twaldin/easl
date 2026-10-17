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

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/store"
)

func closeEntries(names map[string]string) []any {
	ids := make([]string, 0, len(names))
	for id := range names {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	entries := make([]any, 0, len(ids))
	for _, id := range ids {
		entries = append(entries, map[string]any{"id": id, "name": names[id]})
	}
	return entries
}

func TestBoardCloseAnnouncesAvailabilityAndReopenOnTheSameSubscription(t *testing.T) {
	f := newFixture(t)
	subscriber := &conn{}
	f.on(subscriber, "events.subscribe", map[string]any{"board": f.board.ID(), "events": []any{"board.closed", "board.opened"}})
	before := len(subscriber.messages())
	f.result("board.close", map[string]any{})
	want := []map[string]any{{"event": "board.closed", "board": f.board.ID(), "data": map[string]any{}}}
	if got := subscriber.messages()[before:]; !reflect.DeepEqual(got, want) {
		t.Fatalf("close signal %v, want %v", got, want)
	}
	f.result("board.open", map[string]any{"root": f.board.Root()})
	want = append(want, map[string]any{"event": "board.opened", "board": f.board.ID(), "data": map[string]any{}})
	if got := subscriber.messages()[before:]; !reflect.DeepEqual(got, want) {
		t.Fatalf("reopen signal %v, want %v", got, want)
	}
}

func TestBoardCloseKeepsSessionsThroughSweepsRestartAndReopen(t *testing.T) {
	f, state := restorable(t)
	id, root := f.board.ID(), f.board.Root()
	named := idOf(f.result("object.create", terminal(map[string]any{"name": "worker", "title": "not the name"})))
	titled := idOf(f.result("object.create", terminal(map[string]any{"name": "", "title": "shell"})))
	plain := idOf(f.result("object.create", terminal(map[string]any{})))
	hosted := idOf(f.result("object.create", terminal(map[string]any{"host": "mac", "name": "hosted"})))
	noteID := idOf(f.result("object.create", note(900, map[string]any{"markdown": "latest unsaved change"})))
	otherRoot := t.TempDir()
	otherID := f.result("board.open", map[string]any{"root": otherRoot})["board"].(string)
	before := map[string]string{}
	for _, tile := range []string{named, titled, plain} {
		path := filepath.Join(state, session.Prefix+tile)
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		content = append(content, "mark=original session\n"...)
		if err := os.WriteFile(path, content, 0o600); err != nil {
			t.Fatal(err)
		}
		before[tile] = string(content)
	}
	want := map[string]any{"board": id, "root": root, "kept": closeEntries(map[string]string{named: "worker", titled: "shell", plain: "Terminal", hosted: "hosted"}), "ended": []any{}}
	if got := f.result("board.close", map[string]any{"board": id}); !reflect.DeepEqual(got, want) {
		t.Fatalf("close result %v, want %v", got, want)
	}
	if code, _ := errorOf(f.call("board.get", map[string]any{"board": id})); code != "not_found" {
		t.Fatalf("closed board.get: %s", code)
	}
	if code, _ := errorOf(f.call("board.close", map[string]any{"board": id})); code != "not_found" {
		t.Fatalf("second close: %s", code)
	}
	listed, err := store.ReadReopened(f.router.Reopens)
	if want := []store.Reopened{{Root: store.Standardized(otherRoot), Board: otherID}}; err != nil || !reflect.DeepEqual(listed, want) {
		t.Fatalf("reopen list %v, %v; want %v", listed, err, want)
	}
	found := false
	for _, entry := range f.result("board.list", map[string]any{})["boards"].([]any) {
		info := entry.(map[string]any)
		if info["board"] == id {
			found = true
			if info["open"] != false || info["objects"] != float64(5) {
				t.Fatalf("closed catalog entry %v", info)
			}
		}
	}
	if !found {
		t.Fatal("closing deleted the stored board from the catalog")
	}
	f.router.SweepOrphans()
	f.router.SweepOrphans()
	again, errs := restart(t, f)
	if len(errs) != 0 {
		t.Fatal(errs)
	}
	if code, _ := errorOf(again.call("board.get", map[string]any{"board": id})); code != "not_found" {
		t.Fatalf("restart reopened closed board: %s", code)
	}
	again.router.SweepOrphans()
	again.router.SweepOrphans()
	opened := again.result("board.open", map[string]any{"root": root})
	if opened["board"] != id || opened["objects"] != float64(5) {
		t.Fatalf("reopen %v", opened)
	}
	for _, tile := range []string{named, titled, plain, hosted} {
		object := again.result("object.get", map[string]any{"id": tile})["object"].(map[string]any)
		if object["id"] != tile || object["type"] != "terminal" {
			t.Fatalf("restored terminal %v", object)
		}
	}
	if props := again.result("object.get", map[string]any{"id": noteID})["object"].(map[string]any)["props"].(map[string]any); props["markdown"] != "latest unsaved change" {
		t.Fatalf("latest change wasn't saved: %v", props)
	}
	for tile, want := range before {
		if data, err := os.ReadFile(filepath.Join(state, session.Prefix+tile)); err != nil || string(data) != want {
			t.Errorf("kept session %s changed: %q, %v", tile, data, err)
		}
	}
}

func TestBoardCloseEndsOnlyOwnedSessionsAndRemovesTheirTerminals(t *testing.T) {
	f, state := restorable(t)
	local := idOf(f.result("object.create", terminal(map[string]any{"name": "local"})))
	gone := idOf(f.result("object.create", terminal(map[string]any{"title": "already exited"})))
	hosted := idOf(f.result("object.create", terminal(map[string]any{"host": "mac", "name": "hosted"})))
	noteID := idOf(f.result("object.create", note(900, map[string]any{"markdown": "keep the note"})))
	hostedSession := "labels=canvas.board=" + f.board.ID() + " canvas.home=mac canvas.tile=" + hosted + "\n"
	if err := os.WriteFile(filepath.Join(state, session.Prefix+hosted), []byte(hostedSession), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(state, session.Prefix+gone)); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(state, "logs", session.Prefix+local+".log")
	spool := filepath.Join(f.router.reg.AgentReports, local)
	if err := os.MkdirAll(spool, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(spool, "report.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(log, []byte("terminal output"), 0o600); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"board": f.board.ID(), "root": f.board.Root(), "kept": closeEntries(map[string]string{hosted: "hosted"}), "ended": closeEntries(map[string]string{local: "local", gone: "already exited"})}
	if got := f.result("board.close", map[string]any{"endSessions": true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("end close %v, want %v", got, want)
	}
	if got := sessions(t, state); !reflect.DeepEqual(got, []string{hosted}) {
		t.Fatalf("sessions after ending the owned terminals: %v", got)
	}
	if data, err := os.ReadFile(filepath.Join(state, session.Prefix+hosted)); err != nil || string(data) != hostedSession {
		t.Fatalf("hosted session changed: %q, %v", data, err)
	}
	for _, path := range []string{log, spool} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("ended session artifact %s remains: %v", path, err)
		}
	}
	opened := f.result("board.open", map[string]any{"root": f.board.Root()})
	if opened["objects"] != float64(2) {
		t.Fatalf("reopened ended board %v", opened)
	}
	for _, tile := range []string{local, gone} {
		if code, _ := errorOf(f.call("object.get", map[string]any{"id": tile})); code != "not_found" {
			t.Errorf("ended terminal %s came back: %s", tile, code)
		}
	}
	if got := f.result("object.get", map[string]any{"id": hosted})["object"].(map[string]any); got["type"] != "terminal" {
		t.Fatalf("hosted terminal was removed: %v", got)
	}
	if got := f.result("object.get", map[string]any{"id": noteID})["object"].(map[string]any)["props"].(map[string]any)["markdown"]; got != "keep the note" {
		t.Fatalf("nonterminal changed: %v", got)
	}
}

func TestBoardCloseValidatesDispositionAndNonownershipBeforeChangingAnything(t *testing.T) {
	f := newFixture(t)
	tile := idOf(f.result("object.create", terminal(map[string]any{"name": "kept"})))
	for _, value := range []any{nil, "true", 1.0, []any{}, map[string]any{}} {
		if code, message := errorOf(f.call("board.close", map[string]any{"endSessions": value})); code != "invalid_params" {
			t.Errorf("endSessions %v: %s %q", value, code, message)
		}
	}
	if code, message := errorOf(f.call("board.close", map[string]any{"endSessions": true})); code != "unsupported" {
		t.Fatalf("nonowner end close: %s %q", code, message)
	}
	if got := f.result("object.get", map[string]any{"id": tile})["object"].(map[string]any); got["id"] != tile {
		t.Fatalf("refusal lost terminal %v", got)
	}
	f.router.Reopens = filepath.Join(t.TempDir(), "open-boards.json")
	original := []byte(`[{"root":"/owned-elsewhere","board":"brd_elsewhere"}]`)
	if err := os.WriteFile(f.router.Reopens, original, 0o600); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"board": f.board.ID(), "root": f.board.Root(), "kept": closeEntries(map[string]string{tile: "kept"}), "ended": []any{}}
	if got := f.result("board.close", map[string]any{"endSessions": false}); !reflect.DeepEqual(got, want) {
		t.Fatalf("nonowner keep %v", got)
	}
	if data, err := os.ReadFile(f.router.Reopens); err != nil || string(data) != string(original) {
		t.Fatalf("nonowner changed restore policy: %q, %v", data, err)
	}
	if code, message := errorOf(f.call("board.close", map[string]any{})); code != "not_found" {
		t.Fatalf("empty frontmost: %s %q", code, message)
	}
}

func TestBoardCloseRejectsMalformedTargetWithoutClosingDefaultBoard(t *testing.T) {
	for _, value := range []any{nil, "", true, 42.0, []any{}, map[string]any{}} {
		t.Run(fmt.Sprintf("%T-%v", value, value), func(t *testing.T) {
			f := newFixture(t)
			tile := idOf(f.result("object.create", terminal(map[string]any{"name": "must stay open"})))
			if code, message := errorOf(f.call("board.close", map[string]any{"board": value})); code != "invalid_params" {
				t.Fatalf("malformed target closed or selected the default board: %s %q", code, message)
			}
			if got := f.result("object.get", map[string]any{"id": tile})["object"].(map[string]any); got["id"] != tile {
				t.Fatalf("malformed target lost the terminal: %v", got)
			}
		})
	}
}

func TestBoardCloseUsesCanonicalIdentityAndForgetsMergedReopenEntries(t *testing.T) {
	f, _ := restorable(t)
	canonical := f.board.ID()
	f.board.Repo = &store.RepoRecord{CommonDir: t.TempDir(), Merged: []string{"brd_legacy"}}
	if err := store.WriteReopened(f.router.Reopens, []store.Reopened{{Root: f.board.Root(), Board: canonical}, {Root: f.board.Root(), Board: "brd_legacy"}}); err != nil {
		t.Fatal(err)
	}
	if got := f.result("board.close", map[string]any{"board": "brd_legacy", "endSessions": false}); !reflect.DeepEqual(got, map[string]any{"board": canonical, "root": f.board.Root(), "kept": []any{}, "ended": []any{}}) {
		t.Fatalf("alias close %v", got)
	}
	if code, _ := errorOf(f.call("board.get", map[string]any{"board": canonical})); code != "not_found" {
		t.Fatalf("canonical board stayed open: %s", code)
	}
	if list, err := store.ReadReopened(f.router.Reopens); err != nil || len(list) != 0 {
		t.Fatalf("canonical board remains in reopen list: %v, %v", list, err)
	}
}

func TestBoardClosePersistenceFailuresLeaveTheBoardOpen(t *testing.T) {
	for _, boundary := range []string{"board save", "reopen read", "reopen write"} {
		t.Run(boundary, func(t *testing.T) {
			f, state := restorable(t)
			tile := idOf(f.result("object.create", terminal(map[string]any{"name": "still running"})))
			switch boundary {
			case "board save":
				if err := os.Mkdir(f.router.reg.Store.Path(f.board.ID()), 0o700); err != nil {
					t.Fatal(err)
				}
			case "reopen read":
				if err := os.WriteFile(f.router.Reopens, []byte("not json"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "reopen write":
				f.router.Reopens = filepath.Join(t.TempDir(), "open-boards.json") + string(os.PathSeparator)
			}
			code, message := errorOf(f.call("board.close", map[string]any{}))
			if code != "unavailable" || !strings.Contains(message, "board remains open; ended terminals []") {
				t.Fatalf("failed close: %s %q", code, message)
			}
			if boundary == "reopen write" && !strings.Contains(message, "can't record the boards to reopen") {
				t.Fatalf("didn't reach the reopen write: %s", message)
			}
			if got := f.result("board.get", map[string]any{})["board"]; got != f.board.ID() {
				t.Fatalf("failed close evicted board: %v", got)
			}
			if got := sessions(t, state); !reflect.DeepEqual(got, []string{tile}) {
				t.Fatalf("failed keep close ended sessions: %v", got)
			}
			if boundary == "board save" {
				if listed, err := store.ReadReopened(f.router.Reopens); err != nil || !reflect.DeepEqual(listed, []store.Reopened{{Root: f.board.Root(), Board: f.board.ID()}}) {
					t.Fatalf("failed save changed reopen state: %v, %v", listed, err)
				}
			}
		})
	}
}

func TestBoardCloseReportsEndedSessionsWhenTheFinalSaveFails(t *testing.T) {
	f, state := restorable(t)
	tile := idOf(f.result("object.create", terminal(map[string]any{"name": "ended before save"})))
	if err := os.Mkdir(f.router.reg.Store.Path(f.board.ID()), 0o700); err != nil {
		t.Fatal(err)
	}
	code, message := errorOf(f.call("board.close", map[string]any{"endSessions": true}))
	if code != "unavailable" || !strings.Contains(message, "board remains open; ended terminals ["+tile+"]") {
		t.Fatalf("failed final save hid destructive effects: %s %q", code, message)
	}
	if got := f.result("board.get", map[string]any{})["board"]; got != f.board.ID() {
		t.Fatalf("failed final save evicted board: %v", got)
	}
	if code, _ := errorOf(f.call("object.get", map[string]any{"id": tile})); code != "not_found" {
		t.Fatalf("confirmed ended terminal remains: %s", code)
	}
	if got := sessions(t, state); len(got) != 0 {
		t.Fatalf("ended session came back: %v", got)
	}
	if listed, err := store.ReadReopened(f.router.Reopens); err != nil || !reflect.DeepEqual(listed, []store.Reopened{{Root: f.board.Root(), Board: f.board.ID()}}) {
		t.Fatalf("failed final save changed reopen state: %v, %v", listed, err)
	}
}

func TestBoardCloseReportsPartialEndsAndRetainsTheFailedTerminal(t *testing.T) {
	for _, failure := range []string{"unreachable", "foreign"} {
		t.Run(failure, func(t *testing.T) {
			f, state := restorable(t)
			one := idOf(f.result("object.create", terminal(map[string]any{"name": "one"})))
			two := idOf(f.result("object.create", terminal(map[string]any{"name": "two"})))
			ordered := sortedPair(one, two)
			failed := ordered[1]
			labels := "canvas.board=" + f.board.ID() + " canvas.home=" + session.Label(f.router.Owns.Home) + " canvas.tile=" + failed
			if failure == "unreachable" {
				labels += " status=unreachable"
			} else {
				labels = strings.Replace(labels, "canvas.home="+session.Label(f.router.Owns.Home), "canvas.home=foreign", 1)
			}
			original := "labels=" + labels + "\n"
			if err := os.WriteFile(filepath.Join(state, session.Prefix+failed), []byte(original), 0o600); err != nil {
				t.Fatal(err)
			}
			code, message := errorOf(f.call("board.close", map[string]any{"endSessions": true}))
			if code != "unavailable" || !strings.Contains(message, "ended terminals ["+ordered[0]+"]") || !strings.Contains(message, failed) {
				t.Fatalf("partial close: %s %q", code, message)
			}
			if got := f.result("board.get", map[string]any{})["board"]; got != f.board.ID() {
				t.Fatalf("failed end evicted board: %v", got)
			}
			if code, _ := errorOf(f.call("object.get", map[string]any{"id": ordered[0]})); code != "not_found" {
				t.Fatalf("confirmed ended terminal stayed: %s", code)
			}
			if got := f.result("object.get", map[string]any{"id": failed})["object"].(map[string]any); got["id"] != failed {
				t.Fatalf("failed terminal removed: %v", got)
			}
			if got := sessions(t, state); !reflect.DeepEqual(got, []string{failed}) {
				t.Fatalf("partial session effects %v", got)
			}
			if data, _ := os.ReadFile(filepath.Join(state, session.Prefix+failed)); string(data) != original {
				t.Fatalf("failed session changed: %q", data)
			}
			if listed, err := store.ReadReopened(f.router.Reopens); err != nil || !reflect.DeepEqual(listed, []store.Reopened{{Root: f.board.Root(), Board: f.board.ID()}}) {
				t.Fatalf("partial end changed reopen state: %v, %v", listed, err)
			}
		})
	}
}

func TestBoardCloseRequiresObservedSessionExit(t *testing.T) {
	f, state := owning(t)
	tile := idOf(f.result("object.create", terminal(map[string]any{})))
	wrapper := filepath.Join(t.TempDir(), "zmx")
	script := "#!/bin/sh\n[ \"$1\" = kill ] && exit 0\nexec '" + f.router.Sessions.Zmx + "' \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions.Zmx = wrapper
	before := unlistedWithin
	unlistedWithin = 30 * time.Millisecond
	defer func() { unlistedWithin = before }()
	if code, message := errorOf(f.call("board.close", map[string]any{"endSessions": true})); code != "unavailable" || !strings.Contains(message, "didn't confirm") || !strings.Contains(message, "ended terminals []") {
		t.Fatalf("unobserved kill: %s %q", code, message)
	}
	if got := sessions(t, state); !reflect.DeepEqual(got, []string{tile}) {
		t.Fatalf("unconfirmed session %v", got)
	}
	if got := f.result("object.get", map[string]any{"id": tile})["object"].(map[string]any); got["id"] != tile {
		t.Fatalf("unconfirmed terminal removed: %v", got)
	}
}

func TestBoardCloseDoesNotSuppressAnExistingWaitersGrace(t *testing.T) {
	f, state := owning(t)
	tile := f.agentTerminal("", map[string]any{"name": "silent"})
	f.router.FirstReportGrace = time.Hour
	waiting := &conn{}
	if reply := f.on(waiting, "agent.wait", map[string]any{"target": tile}); reply != nil {
		t.Fatalf("silent terminal answered before its grace: %v", reply)
	}
	wrapper := filepath.Join(t.TempDir(), "zmx")
	script := "#!/bin/sh\nif [ \"$1\" = kill ]; then : > \"$ZMX_DIR/.grace-kill\"; while [ ! -e \"$ZMX_DIR/.grace-release\" ]; do sleep 0.01; done; exit 1; fi\nexec '" + f.router.Sessions.Zmx + "' \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions.Zmx = wrapper
	release := filepath.Join(state, ".grace-release")
	defer os.WriteFile(release, nil, 0o600)
	closed := make(chan map[string]any, 1)
	go func() {
		closed <- f.router.HandleConn(map[string]any{"id": "close", "method": "board.close", "params": map[string]any{"endSessions": true}}, &conn{}).(map[string]any)
	}()
	waitCloseFile(t, filepath.Join(state, ".grace-kill"))
	f.router.reg.Mu.Lock()
	if len(f.router.waiters) != 1 {
		f.router.reg.Mu.Unlock()
		t.Fatal("the existing wait was lost before its grace")
	}
	w := f.router.waiters[0]
	w.firstReportDeadline = time.Now().Add(-time.Second)
	f.router.recheck(w)
	f.router.reg.Mu.Unlock()
	sent := waiting.messages()
	if len(sent) != 1 {
		t.Errorf("close suppressed the existing wait's expired grace: %v", sent)
	} else if code, _ := errorOf(sent[0]); code != "unavailable" {
		t.Errorf("silent terminal grace: %v", sent[0])
	}
	if err := os.WriteFile(release, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case reply := <-closed:
		if code, _ := errorOf(reply); code != "unavailable" {
			t.Fatalf("the failed kill closed the board: %v", reply)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("failed close did not finish")
	}
	if got := f.result("object.get", map[string]any{"id": tile})["object"].(map[string]any); got["id"] != tile {
		t.Fatalf("failed close lost the waiting terminal: %v", got)
	}
}

func TestBoardCloseFinishesWaitsAndReleasesInboxHoldsWithoutClosingSubscriptions(t *testing.T) {
	f := newFixture(t)
	tile := f.agentTerminal("", map[string]any{"name": "worker"})
	f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working", "protocol": 1.0})
	message := f.result("agent.prompt", map[string]any{"target": tile, "text": "retained message"})["message"]
	holder, inbox, waiting, subscriber := &conn{}, &conn{}, &conn{}, &conn{}
	defer holder.close()
	defer waiting.close()
	if got := f.on(holder, "agent.inbox", map[string]any{"tile": tile})["result"].(map[string]any)["messages"].([]any); len(got) != 1 {
		t.Fatalf("initial inbox offer %v", got)
	}
	if got := f.on(inbox, "agent.inbox", map[string]any{"tile": tile, "waitMs": 60000.0}); got != nil {
		t.Fatalf("held inbox did not wait: %v", got)
	}
	if got := f.on(waiting, "agent.wait", map[string]any{"target": tile, "until": []any{"idle"}, "timeoutMs": 60000.0}); got != nil {
		t.Fatalf("working terminal did not wait: %v", got)
	}
	f.on(subscriber, "events.subscribe", map[string]any{"board": f.board.ID()})
	before := len(subscriber.messages())
	f.result("board.close", map[string]any{})
	for label, c := range map[string]*conn{"inbox": inbox, "agent.wait": waiting} {
		messages := c.messages()
		if len(messages) != 1 {
			t.Fatalf("%s close response %v", label, messages)
		}
		if code, _ := errorOf(messages[0]); code != "not_found" {
			t.Errorf("%s answered %v", label, messages[0])
		}
	}
	if got := len(subscriber.messages()); got != before || !subscriber.IsOpen() {
		t.Fatalf("close changed subscription: %v", subscriber.messages())
	}
	f.result("board.open", map[string]any{"root": f.board.Root()})
	messages := f.result("agent.inbox", map[string]any{"tile": tile})["messages"].([]any)
	if len(messages) != 1 || messages[0].(map[string]any)["id"] != message {
		t.Fatalf("reopen lost message or kept stale connection hold: %v", messages)
	}
	f.result("object.update", map[string]any{"id": tile, "props": map[string]any{"name": "reopened"}})
	events := subscriber.messages()
	if len(events) != before+1 || events[len(events)-1]["event"] != "object.updated" {
		t.Fatalf("subscription did not resume on reopen: %v", events)
	}
}

func waitCloseFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("operation did not reach %s", path)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestBoardCloseSerializesSessionWorkAndRejectsConcurrentMutation(t *testing.T) {
	f, state := owning(t)
	tile := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	mention := f.result("tray.stage", map[string]any{"target": map[string]any{"kind": "object", "object": tile}})["mention"].(map[string]any)["id"].(string)
	wrapper := filepath.Join(t.TempDir(), "zmx")
	script := "#!/bin/sh\nif [ \"$1\" = kill ]; then : > \"$ZMX_DIR/.close-kill\"; while [ ! -e \"$ZMX_DIR/.close-release\" ]; do sleep 0.01; done; fi\nexec '" + f.router.Sessions.Zmx + "' \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions.Zmx = wrapper
	release := filepath.Join(state, ".close-release")
	defer os.WriteFile(release, nil, 0o600)
	f.router.reg.Mu.Lock()
	running, resume := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-resume:
		default:
			close(resume)
		}
	}()
	f.router.queueSession(func() { close(running); <-resume })
	f.router.reg.Mu.Unlock()
	<-running
	done := make(chan map[string]any, 1)
	go func() {
		done <- f.router.HandleConn(map[string]any{"id": "close", "method": "board.close", "params": map[string]any{"endSessions": true}}, &conn{}).(map[string]any)
	}()
	select {
	case reply := <-done:
		t.Fatalf("close passed the earlier lifecycle job: %v", reply)
	case <-time.After(30 * time.Millisecond):
	}
	close(resume)
	waitCloseFile(t, filepath.Join(state, ".close-kill"))
	if got := f.result("system.ping", map[string]any{})["app"]; got != "easl" {
		t.Fatalf("session kill held registry lock: %v", got)
	}
	for method, params := range map[string]map[string]any{
		"object.create": terminal(map[string]any{}),
		"board.open":    {"root": f.board.Root()},
		"agent.restart": {"target": tile, "mode": "fresh", "force": true},
		"board.close":   {},
		"tray.unstage":  {"id": mention},
	} {
		if code, message := errorOf(f.call(method, params)); code != "conflict" || !strings.Contains(message, "is closing") {
			t.Errorf("%s during close: %s %q", method, code, message)
		}
	}
	f.router.reg.Mu.Lock()
	tray := f.board.Tray()
	f.router.reg.Mu.Unlock()
	if len(tray) != 1 || tray[0].ID != mention {
		t.Errorf("closing board's tray changed: %v", tray)
	}
	if err := os.WriteFile(release, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case reply := <-done:
		if reply["ok"] != true || !reflect.DeepEqual(reply["result"].(map[string]any)["ended"], closeEntries(map[string]string{tile: "worker"})) {
			t.Fatalf("serialized close %v", reply)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("close did not finish")
	}
}

func TestBoardCloseRefusesAnInFlightAgentRestart(t *testing.T) {
	f, state := owning(t)
	tile := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	wrapper := filepath.Join(t.TempDir(), "zmx")
	script := "#!/bin/sh\nif [ \"$1\" = kill ]; then : > \"$ZMX_DIR/.restart-kill\"; while [ ! -e \"$ZMX_DIR/.restart-release\" ]; do sleep 0.01; done; fi\nexec '" + f.router.Sessions.Zmx + "' \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions.Zmx = wrapper
	release := filepath.Join(state, ".restart-release")
	defer os.WriteFile(release, nil, 0o600)
	done := make(chan map[string]any, 1)
	go func() {
		done <- f.router.HandleConn(map[string]any{"id": "restart", "method": "agent.restart", "params": map[string]any{"target": tile, "mode": "fresh", "force": true}}, &conn{}).(map[string]any)
	}()
	waitCloseFile(t, filepath.Join(state, ".restart-kill"))
	for _, params := range []map[string]any{{}, {"endSessions": true}} {
		if code, message := errorOf(f.call("board.close", params)); code != "conflict" || !strings.Contains(message, tile+" is restarting") {
			t.Errorf("close during restart: %s %q", code, message)
		}
	}
	if err := os.WriteFile(release, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case reply := <-done:
		if reply["ok"] != true {
			t.Fatalf("restart %v", reply)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("restart did not finish")
	}
	if got := f.result("board.get", map[string]any{})["board"]; got != f.board.ID() {
		t.Fatalf("close refusal lost board: %v", got)
	}
}

func TestAClosedBoardCannotSaveOrBroadcastOverItsReopenedReplacement(t *testing.T) {
	f := newFixture(t)
	tile := idOf(f.result("object.create", note(0, map[string]any{"markdown": "before close"})))
	old := f.board
	subscriber := &conn{}
	f.on(subscriber, "events.subscribe", map[string]any{"board": old.ID()})
	f.result("board.close", map[string]any{})
	f.result("board.open", map[string]any{"root": old.Root()})
	f.result("object.update", map[string]any{"id": tile, "props": map[string]any{"markdown": "reopened value"}})
	before := len(subscriber.messages())
	f.router.reg.Mu.Lock()
	old.Create(model.Note, map[string]any{"markdown": "stale callback"}, &model.Frame{X: 900, Y: 0, W: 200, H: 100}, "", "")
	f.router.reg.Mu.Unlock()
	f.router.reg.Flush()
	if got := len(subscriber.messages()); got != before {
		t.Fatalf("stale board broadcast after close: %v", subscriber.messages())
	}
	snap, err := f.router.reg.Store.Read(old.ID())
	if err != nil || snap == nil || len(snap.Objects) != 1 || snap.Objects[0].Props["markdown"] != "reopened value" {
		t.Fatalf("stale board overwrote replacement: %+v, %v", snap, err)
	}
	if got := f.result("object.get", map[string]any{"id": tile})["object"].(map[string]any)["props"].(map[string]any)["markdown"]; got != "reopened value" {
		t.Fatalf("reopened object changed: %v", got)
	}
}

func TestBoardCloseDoesNotCreateAReopenFileWithoutOwnership(t *testing.T) {
	f := newFixture(t)
	f.router.Reopens = filepath.Join(t.TempDir(), "open-boards.json")
	f.result("board.close", map[string]any{})
	if _, err := os.Stat(f.router.Reopens); !os.IsNotExist(err) {
		t.Fatalf("nonowning close wrote reopen file: %v", err)
	}
	if code, message := errorOf(f.call("board.close", map[string]any{"board": "brd_missing"})); code != "not_found" || message != "board brd_missing" {
		t.Fatalf("unknown board: %s %q", code, message)
	}
}
