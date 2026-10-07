package router

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/session/zmxtest"
)

// An easld that owns a terminal restarts it itself, with no client attached: it ends the old
// session, and once zmx no longer lists it, the messages queued for the killed agent bounce and
// the relaunch starts in a new session (the same labels): resumed with the recorded model and
// thinking level in place of the command's, its prompt left out. The tile runs the relaunch's
// command from then on (what a reboot resumes), its agent is what it was without the killed
// process's draft and pid, and its lifecycle is unknown until the new agent reports. A fresh
// restart of a terminal whose session is already gone starts it anew.
func TestAnOwnedTerminalRestartsWithoutAClient(t *testing.T) {
	f, state := owning(t)
	term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp", "--model", "opus", "fix it"}})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false, "pid": float64(os.Getpid())})
	f.result("agent.report_session", map[string]any{"tile": term, "kind": "omp", "sessionId": "s1", "model": "anthropic/claude-opus-4-5", "thinking": "high"})
	f.result("agent.prompt", map[string]any{"target": "worker", "text": "Nightly failed.", "from": "machine-watch"})
	path := filepath.Join(state, session.Prefix+term)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(before, "mark=the old session\n"...), 0o600); err != nil {
		t.Fatal(err)
	}

	got := f.result("agent.restart", map[string]any{"target": "worker", "mode": "resume", "force": true})
	argv := []any{"omp", "--model=anthropic/claude-opus-4-5", "--thinking=high", "--resume=s1"}
	if !reflect.DeepEqual(got["command"], argv) || got["agent"].(map[string]any)["tile"] != term {
		t.Errorf("result %v", got)
	}
	relaunched, err := zmxtest.Read(state, session.Prefix+term)
	if err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); strings.Contains(string(data), "mark=the old session") {
		t.Error("the old session wasn't ended")
	}
	if want := []string{"/bin/sh", "-l", "-c", `'omp' '--model=anthropic/claude-opus-4-5' '--thinking=high' '--resume=s1'; exec '/bin/sh' -l`}; !reflect.DeepEqual(unpathed(t, relaunched.Args), want) {
		t.Errorf("relaunch %q, want %q", relaunched.Args, want)
	}
	if want := "canvas.board=" + f.board.ID() + " canvas.home=" + session.Label(f.router.Owns.Home) + " canvas.tile=" + term; relaunched.Labels != want || relaunched.Env["EASL_TILE_ID"] != term {
		t.Errorf("labels %q, env %v", relaunched.Labels, relaunched.Env)
	}
	props := f.result("object.get", map[string]any{"id": term})["object"].(map[string]any)["props"].(map[string]any)
	if want := []any{"omp", "--model=anthropic/claude-opus-4-5", "--thinking=high"}; !reflect.DeepEqual(props["command"], want) {
		t.Errorf("command %v, want %v", props["command"], want)
	}
	if want := map[string]any{"kind": "omp", "protocol": 1.0, "sessionId": "s1", "model": "anthropic/claude-opus-4-5", "thinking": "high"}; !reflect.DeepEqual(props["agent"], want) {
		t.Errorf("agent %v, want %v", props["agent"], want)
	}
	if _, present := props["lifecycle"]; present {
		t.Errorf("lifecycle %v", props["lifecycle"])
	}
	if got := f.bounced(); !reflect.DeepEqual(got, []string{"undelivered to worker@root: Nightly failed. (from machine-watch)"}) {
		t.Errorf("bounced %q", got)
	}
	if len(f.router.restarts) != 0 {
		t.Errorf("still held: %v", f.router.restarts)
	}

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	got = f.result("agent.restart", map[string]any{"target": term, "mode": "fresh", "args": []any{"--plan", "p.md"}, "force": true})
	if want := []any{"omp", "--model=anthropic/claude-opus-4-5", "--thinking=high", "--plan", "p.md"}; !reflect.DeepEqual(got["command"], want) {
		t.Errorf("fresh: %v", got["command"])
	}
	if relaunched, err := zmxtest.Read(state, session.Prefix+term); err != nil || len(relaunched.Args) != 4 || !strings.HasPrefix(unpathed(t, relaunched.Args)[3], `'omp' '--model=anthropic/claude-opus-4-5' '--thinking=high' '--plan' 'p.md'; exec`) {
		t.Errorf("fresh relaunch %q (%v)", relaunched.Args, err)
	}
	if agent := f.agentProps(term).(map[string]any); agent["sessionId"] != nil {
		t.Errorf("a fresh start keeps the old session: %v", agent)
	}
}

// The killed agent's release, sent as it exits after the restart recorded the relaunch, leaves
// the relaunch's record (Board.relaunchedAgents): the session it resumes, its model and thinking
// level, its command. Once the relaunched agent has reported (its session or a lifecycle), a
// release is its own and clears the tile as ever.
func TestTheKilledAgentsLateReleaseLeavesTheRelaunch(t *testing.T) {
	for _, first := range []string{"agent.report_session", "agent.report"} {
		f, _ := owning(t)
		term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
		f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false})
		f.result("agent.report_session", map[string]any{"tile": term, "kind": "omp", "sessionId": "s1", "sessionPath": "/s1.jsonl", "model": "anthropic/claude-opus-4-5", "thinking": "high"})
		f.result("agent.restart", map[string]any{"target": "worker", "mode": "resume", "force": true})
		relaunched := f.agentProps(term)

		f.result("agent.release", map[string]any{"tile": term, "kind": "omp"})
		if got := f.agentProps(term); !reflect.DeepEqual(got, relaunched) || got.(map[string]any)["sessionPath"] != "/s1.jsonl" {
			t.Errorf("%s: the killed agent's release left %v, want %v", first, got, relaunched)
		}
		if command := f.result("object.get", map[string]any{"id": term})["object"].(map[string]any)["props"].(map[string]any)["command"]; !reflect.DeepEqual(command, []any{"omp", "--model=anthropic/claude-opus-4-5", "--thinking=high"}) {
			t.Errorf("%s: command %v", first, command)
		}

		if first == "agent.report_session" {
			f.result(first, map[string]any{"tile": term, "kind": "omp", "sessionId": "s1"})
		} else {
			f.result(first, map[string]any{"tile": term, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false})
		}
		f.result("agent.release", map[string]any{"tile": term, "kind": "omp"})
		if got := f.agentProps(term); got != nil {
			t.Errorf("after %s, the relaunched agent's release left %v", first, got)
		}
	}
}

// What stops an owned restart leaves the terminal as it was, unheld: a session of the tile's
// name easld doesn't own isn't ended (its message stays queued), a relaunch that can't start is
// logged in the board's history (the old session is gone by then), a hosted terminal's restart
// is its Mac's, and the checks before any of that are the same as a client's restart.
func TestAnOwnedRestartThatCantGoThroughSaysWhy(t *testing.T) {
	f, state := owning(t)
	term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false})
	f.result("agent.report_session", map[string]any{"tile": term, "kind": "omp", "sessionId": "s1"})
	if code, message := errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "fresh", "args": []any{1.0}})); code != "invalid_params" || message != "args is an array of strings" {
		t.Errorf("args: %s %s", code, message)
	}
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "working", "protocol": 1.0, "draft": false})
	if code, _ := errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "resume"})); code != "conflict" {
		t.Errorf("working: %s", code)
	}

	f.result("agent.prompt", map[string]any{"target": "worker", "text": "hi", "from": "script"})
	path := filepath.Join(state, session.Prefix+term)
	foreign := "labels=canvas.board=" + f.board.ID() + " canvas.home=mac-1 canvas.tile=" + term + "\n"
	if err := os.WriteFile(path, []byte(foreign), 0o600); err != nil {
		t.Fatal(err)
	}
	code, message := errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "resume", "force": true}))
	if code != "conflict" || !strings.Contains(message, "belongs to another easl instance") {
		t.Errorf("another home's session: %s %s", code, message)
	}
	if data, _ := os.ReadFile(path); string(data) != foreign || len(f.board.Messages(term)) != 1 || len(f.router.restarts) != 0 {
		t.Errorf("after it: session %q, queued %d, held %v", data, len(f.board.Messages(term)), f.router.restarts)
	}

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	f.result("object.update", map[string]any{"id": term, "props": map[string]any{"cwd": filepath.Join(t.TempDir(), "gone")}})
	if code, message := errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "resume", "force": true})); code != "invalid_params" || !strings.Contains(message, "is not a directory") {
		t.Errorf("a relaunch that can't start: %s %s", code, message)
	}
	if said := terminalHistory(f); len(said) != 1 || !strings.Contains(said[0], "easld couldn't start its relaunch: cwd ") {
		t.Errorf("history %q", said)
	}

	hosted := f.agentTerminal("", map[string]any{"name": "away", "host": "deckbox", "command": []any{"omp"}})
	if code, message := errorOf(f.call("agent.restart", map[string]any{"target": hosted, "mode": "fresh", "force": true})); code != "unavailable" || message != noApp(f.board.ID()) {
		t.Errorf("hosted: %s %s", code, message)
	}
}

// A zmx whose listing stalls once the session is ended holds the restart (and every start and
// end queued behind it) no longer than its wait: the listing is cut off at the deadline, nothing
// is relaunched, the board's history says why, and the terminal is no longer held.
func TestAStalledListingEndsAnOwnedRestartAtItsDeadline(t *testing.T) {
	f, state := owning(t)
	term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false})
	// Once a session is killed, every listing hangs (exec: the process the deadline kills).
	stalling := filepath.Join(t.TempDir(), "zmx")
	script := "#!/bin/sh\ncase \"$1\" in\nkill) : > \"$ZMX_DIR/.stalled\" ;;\nlist) [ -e \"$ZMX_DIR/.stalled\" ] && exec sleep 30 ;;\nesac\nexec '" + f.router.Sessions.Zmx + "' \"$@\"\n"
	if err := os.WriteFile(stalling, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions.Zmx = stalling
	t.Cleanup(func() { unlistedWithin = 3 * time.Second })
	unlistedWithin = 300 * time.Millisecond

	start := time.Now()
	code, message := errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "fresh", "force": true}))
	if took := time.Since(start); took > 3*time.Second {
		t.Errorf("the restart took %s: the stalled listing wasn't cut off at the deadline", took)
	}
	if code != "unavailable" || message != "terminal "+term+": zmx didn't confirm within 300ms that its session ended: nothing was relaunched" {
		t.Errorf("%s %s", code, message)
	}
	if _, err := os.Stat(filepath.Join(state, session.Prefix+term)); !os.IsNotExist(err) {
		t.Errorf("a session of the terminal: %v", err)
	}
	if said := terminalHistory(f); len(said) != 1 || !strings.Contains(said[0], "easld couldn't relaunch it: zmx didn't confirm within 300ms") {
		t.Errorf("history %q", said)
	}
	if len(f.router.restarts) != 0 {
		t.Errorf("still held: %v", f.router.restarts)
	}
}

// A board opening while agent.restart holds one of its terminals doesn't start that terminal's
// session: its restart, queued behind, starts the relaunch. Once the hold is gone, a terminal
// without a session gets one as the board opens.
func TestAReconcileLeavesARestartingTerminalToItsRestart(t *testing.T) {
	f, state := owning(t)
	term := f.agentTerminal("", map[string]any{"command": []any{"omp"}})
	if err := os.Remove(filepath.Join(state, session.Prefix+term)); err != nil {
		t.Fatal(err)
	}
	reconcile := func() {
		f.router.reg.Mu.Lock()
		f.router.opened(f.board, f.board.Root())
		queued := f.router.queuedSessions()
		f.router.reg.Mu.Unlock()
		f.router.waitSessions(queued)
	}
	f.router.reg.Mu.Lock()
	f.router.restarts[term] = 1
	f.router.reg.Mu.Unlock()
	reconcile()
	if got := sessions(t, state); len(got) != 0 {
		t.Fatalf("a held terminal's session started: %v", got)
	}
	f.router.reg.Mu.Lock()
	delete(f.router.restarts, term)
	f.router.reg.Mu.Unlock()
	reconcile()
	if got := sessions(t, state); !reflect.DeepEqual(got, []string{term}) {
		t.Fatalf("sessions %v", got)
	}
}

// On an easld that owns its terminals, agent.list says of each terminal not hosted whether its
// session runs (live), on open and closed boards alike: without one (or with only another
// home's or board's of its name), a pid its agent reported is no process of it any more and
// isn't listed; with one, the reported pid stays. A hosted terminal's session is its Mac's to
// say. An easld that doesn't own its terminals says nothing of them.
func TestAgentListSaysWhichOwnedSessionsRun(t *testing.T) {
	f, state := owning(t)
	running := f.agentTerminal("", map[string]any{"name": "running"})
	gone := f.agentTerminal("", map[string]any{"name": "gone"})
	foreign := f.agentTerminal("", map[string]any{"name": "foreign"})
	hosted := f.agentTerminal("", map[string]any{"name": "hosted", "host": "deckbox"})
	for _, tile := range []string{running, gone, foreign} {
		f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "pid": float64(os.Getpid())})
	}
	if err := os.Remove(filepath.Join(state, session.Prefix+gone)); err != nil {
		t.Fatal(err)
	}
	labels := "labels=canvas.board=brd_other canvas.home=" + session.Label(f.router.Owns.Home) + " canvas.tile=" + foreign + "\n"
	if err := os.WriteFile(filepath.Join(state, session.Prefix+foreign), []byte(labels), 0o600); err != nil {
		t.Fatal(err)
	}
	closedID, _ := f.openBoard("closed")
	closed := f.agentTerminal(closedID, map[string]any{"name": "closed"})
	f.closeBoard(closedID)

	for tile, want := range map[string]map[string]any{
		running: {"live": true, "pid": float64(os.Getpid())},
		gone:    {"live": false},
		foreign: {"live": false},
		hosted:  {},
		closed:  {"live": true},
	} {
		entry := f.listed(tile)
		for _, key := range []string{"live", "pid"} {
			if !reflect.DeepEqual(entry[key], want[key]) {
				t.Errorf("%s: %s %v, want %v", entry["name"], key, entry[key], want[key])
			}
		}
	}

	plain := newFixture(t)
	tile := plain.agentTerminal("", map[string]any{})
	if entry := plain.listed(tile); entry["live"] != nil {
		t.Errorf("an easld not owning its terminals: %v", entry)
	}
}
