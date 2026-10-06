package router

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"

	"github.com/twaldin/easl/easld/internal/api"
)

// agentTerminal creates a terminal tile with props on a board (the fixture's when boardID is "").
func (f *fixture) agentTerminal(boardID string, props map[string]any) string {
	f.t.Helper()
	params := map[string]any{"type": "terminal", "props": props, "frame": map[string]any{"x": 50000.0 + 700*float64(f.seq), "y": 50000.0, "w": 600.0, "h": 400.0}}
	if boardID != "" {
		params["board"] = boardID
	}
	return idOf(f.result("object.create", params))
}

// openBoard opens a fresh directory named name as a board: its id and root.
func (f *fixture) openBoard(name string) (string, string) {
	f.t.Helper()
	dir := filepath.Join(f.t.TempDir(), name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		f.t.Fatal(err)
	}
	opened := f.result("board.open", map[string]any{"root": dir})
	return opened["board"].(string), opened["root"].(string)
}

// closeBoard closes a board as quitting its window does: saved, then no longer open.
func (f *fixture) closeBoard(id string) {
	f.router.reg.Mu.Lock()
	defer f.router.reg.Mu.Unlock()
	f.router.reg.Close(id)
}

func (f *fixture) agentProps(id string) any {
	f.t.Helper()
	return f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)["props"].(map[string]any)["agent"]
}

// listed is tile's agent.list entry.
func (f *fixture) listed(tile string) map[string]any {
	f.t.Helper()
	for _, a := range f.result("agent.list", map[string]any{})["agents"].([]any) {
		if entry := a.(map[string]any); entry["tile"] == tile {
			return entry
		}
	}
	f.t.Fatalf("%s isn't in agent.list", tile)
	return nil
}

func TestAReportKeepsDraftAndPidAndOneWithoutThemForgetsThem(t *testing.T) {
	f := newFixture(t)
	term := f.agentTerminal("", map[string]any{})
	events := &conn{}
	f.router.HandleConn(map[string]any{"id": "s", "method": "events.subscribe", "params": map[string]any{"events": []any{"object.updated"}}}, events)
	pid := float64(os.Getpid())
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "draft": true, "pid": pid})
	updates := 0
	for _, m := range events.messages() {
		if m["event"] == "object.updated" {
			updates++
		}
	}
	if updates != 1 {
		t.Errorf("a report with draft and pid made %d updates, want the one that merges kind", updates)
	}
	if agent := f.agentProps(term); !reflect.DeepEqual(agent, map[string]any{"kind": "omp", "draft": true, "pid": pid}) {
		t.Fatalf("props.agent %v", agent)
	}
	if entry := f.listed(term); entry["draft"] != true || entry["pid"] != pid {
		t.Fatalf("listed %v", entry)
	}

	// A report without draft forgets it; a pid whose process is gone is kept but not listed.
	gone := float64(1 << 30)
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "working", "pid": gone})
	if agent := f.agentProps(term); !reflect.DeepEqual(agent, map[string]any{"kind": "omp", "pid": gone}) {
		t.Fatalf("props.agent after a report without draft %v", agent)
	}
	entry := f.listed(term)
	if _, has := entry["draft"]; has {
		t.Errorf("draft listed after a report without it: %v", entry)
	}
	if _, has := entry["pid"]; has {
		t.Errorf("a dead process's pid listed: %v", entry)
	}

	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle"})
	if agent := f.agentProps(term); !reflect.DeepEqual(agent, map[string]any{"kind": "omp"}) {
		t.Fatalf("props.agent after a report without pid %v", agent)
	}
}

// A hosted terminal's processes are its host's: the pid its integration reports names no process
// here, whatever runs under that number on this machine, on an open board or a closed one.
func TestAHostedTerminalHasNoPidOfThisMachine(t *testing.T) {
	f := newFixture(t)
	builds, _ := f.openBoard("builds")
	local := f.agentTerminal(builds, map[string]any{})
	hosted := f.agentTerminal(builds, map[string]any{"host": "deckbox"})
	pid := float64(os.Getpid())
	for _, term := range []string{local, hosted} {
		f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "pid": pid})
	}
	for _, when := range []string{"open", "closed"} {
		if when == "closed" {
			f.closeBoard(builds)
		}
		if entry := f.listed(local); entry["pid"] != pid {
			t.Errorf("%s: the local terminal's pid %v, want %v", when, entry["pid"], pid)
		}
		if entry := f.listed(hosted); entry["pid"] != nil {
			t.Errorf("%s: the hosted terminal listed with this machine's pid %v", when, entry["pid"])
		}
	}
}

func TestReportSessionKeepsTheModelAndThinkingAReportLeavesOut(t *testing.T) {
	f := newFixture(t)
	term := f.agentTerminal("", map[string]any{})
	f.result("agent.report_session", map[string]any{"tile": term, "kind": "omp", "sessionId": "s1", "model": "anthropic/claude-opus-4-5", "thinking": "high"})
	f.result("agent.report_session", map[string]any{"tile": term, "kind": "omp", "sessionPath": "/tmp/s1.jsonl", "model": ""})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle"})
	want := map[string]any{"kind": "omp", "sessionId": "s1", "sessionPath": "/tmp/s1.jsonl", "model": "anthropic/claude-opus-4-5", "thinking": "high"}
	if agent := f.agentProps(term); !reflect.DeepEqual(agent, want) {
		t.Fatalf("props.agent %v, want %v", agent, want)
	}
	f.result("agent.report_session", map[string]any{"tile": term, "kind": "omp", "thinking": "low"})
	if entry := f.listed(term); entry["model"] != "anthropic/claude-opus-4-5" || entry["thinking"] != "low" {
		t.Fatalf("listed %v", entry)
	}
}

func TestAgentListAddsTheTerminalsOfClosedBoardsAsSaved(t *testing.T) {
	f := newFixture(t)
	here := f.agentTerminal("", map[string]any{"name": "here"})
	builds, buildsRoot := f.openBoard("builds")
	worker := f.agentTerminal(builds, map[string]any{"name": "builder"})
	asking := f.agentTerminal(builds, map[string]any{})
	resting := f.agentTerminal(builds, map[string]any{})
	f.result("agent.report", map[string]any{"tile": worker, "kind": "omp", "state": "working", "draft": true})
	f.result("agent.report_session", map[string]any{"tile": worker, "kind": "omp", "sessionId": "s1", "model": "m", "thinking": "high"})
	f.result("agent.report", map[string]any{"tile": asking, "kind": "codex", "state": "blocked", "message": "Allow push?"})
	f.result("agent.report", map[string]any{"tile": resting, "kind": "claude", "state": "idle"})
	// Closed, saved, and open again: listed once, as open.
	other, otherRoot := f.openBoard("other")
	shell := f.agentTerminal(other, map[string]any{})
	f.closeBoard(other)
	f.result("board.open", map[string]any{"root": otherRoot})
	f.closeBoard(builds)

	agents := f.result("agent.list", map[string]any{})["agents"].([]any)
	open := map[string]string{f.board.ID(): here, other: shell}
	var order []string
	for _, id := range sorted(f.board.ID(), other) {
		order = append(order, open[id])
	}
	order = append(order, sorted(worker, asking, resting)...)
	var got []string
	for _, a := range agents {
		got = append(got, a.(map[string]any)["tile"].(string))
	}
	if !reflect.DeepEqual(got, order) {
		t.Fatalf("agent.list lists %v, want open boards' terminals first, then closed ones', each by board then tile id: %v", got, order)
	}
	for _, a := range agents[:2] {
		if entry := a.(map[string]any); entry["open"] != true || entry["focused"] != false {
			t.Errorf("open board's terminal %v", entry)
		}
	}
	want := map[string]map[string]any{
		worker: {
			"tile": worker, "board": builds, "root": buildsRoot, "kind": "omp", "sessionId": "s1", "name": "builder",
			"open": false, "focused": false, "draft": true, "model": "m", "thinking": "high", "address": "builder@builds",
			"lifecycle": map[string]any{"state": "working", "seen": false, "restored": true},
		},
		asking: {
			"tile": asking, "board": builds, "root": buildsRoot, "kind": "codex", "open": false, "focused": false, "address": asking,
			"lifecycle": map[string]any{"state": "blocked", "seen": false, "message": "Allow push?", "restored": true},
		},
		resting: {
			"tile": resting, "board": builds, "root": buildsRoot, "kind": "claude", "open": false, "focused": false, "address": resting,
			"lifecycle": map[string]any{"state": "idle", "seen": false},
		},
	}
	for _, a := range agents[2:] {
		entry := a.(map[string]any)
		if w := want[entry["tile"].(string)]; !reflect.DeepEqual(entry, w) {
			t.Errorf("closed board's terminal\n got %v\nwant %v", entry, w)
		}
	}
}

func sorted(ids ...string) []string {
	sort.Strings(ids)
	return ids
}

// noApp is agent.restart's answer when its checks pass and no client shows the board.
func noApp(boardID string) string {
	return "no app shows board " + boardID + ": agent.restart kills and relaunches the terminal's session through its live surface"
}

func TestRestartRefusesWhatARestartWouldLoseInOrder(t *testing.T) {
	f := newFixture(t)
	term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	f.result("agent.report_session", map[string]any{"tile": term, "kind": "omp", "sessionPath": "/tmp/s.jsonl"})
	restart := func(force bool) (string, string) {
		return errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "resume", "force": force}))
	}
	forwarded := noApp(f.board.ID())
	steps := []struct {
		report        map[string]any
		code, message string
	}{
		{map[string]any{"state": "blocked", "message": "Allow rm?", "draft": true},
			"conflict", term + " is blocked, waiting on its user (“Allow rm?”): restarting would drop that dialog; force: true restarts anyway"},
		{map[string]any{"state": "blocked", "draft": true},
			"conflict", term + " is blocked, waiting on its user: restarting would drop that dialog; force: true restarts anyway"},
		{map[string]any{"state": "working", "draft": true},
			"conflict", term + " is working: restarting would kill its turn. Wait for it (agent.wait), or force: true restarts anyway"},
		{map[string]any{"state": "idle", "draft": true},
			"conflict", term + "'s input editor holds a draft the user hasn't sent: restarting would lose it; force: true restarts anyway"},
		{map[string]any{"state": "idle"},
			"conflict", "nothing in " + term + " reports whether its input holds a draft the user hasn't sent (omp's easl extension does), so restarting could lose one; force: true restarts anyway"},
		{map[string]any{"state": "idle", "draft": false}, "unavailable", forwarded},
	}
	for _, s := range steps {
		s.report["tile"], s.report["kind"] = term, "omp"
		f.result("agent.report", s.report)
		if code, message := restart(false); code != s.code || message != s.message {
			t.Errorf("after %v: %s %q, want %s %q", s.report, code, message, s.code, s.message)
		}
		if code, message := restart(true); code != "unavailable" || message != forwarded {
			t.Errorf("forced after %v: %s %q", s.report, code, message)
		}
	}

	// A turn restored from before easld last closed is a turn all the same.
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "working"})
	root := f.board.Root()
	f.closeBoard(f.board.ID())
	f.result("board.open", map[string]any{"root": root})
	if code, message := restart(false); code != "conflict" || message != term+" is working: restarting would kill its turn. Wait for it (agent.wait), or force: true restarts anyway" {
		t.Errorf("restored working: %s %q", code, message)
	}
}

func TestRestartChecksTargetThenModeThenArgsBeforeRefusing(t *testing.T) {
	f := newFixture(t)
	term := f.agentTerminal("", map[string]any{})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "blocked"})
	blocked := term + " is blocked, waiting on its user: restarting would drop that dialog; force: true restarts anyway"
	for _, c := range []struct {
		params        map[string]any
		code, message string
	}{
		{map[string]any{"target": "nobody", "mode": "sideways"}, "not_found", "no terminal tile named or with id nobody"},
		{map[string]any{"target": term, "mode": "restart", "args": 3.0}, "invalid_params", "mode is resume or fresh, not restart"},
		{map[string]any{"target": term, "mode": 3.0}, "invalid_params", "missing mode"},
		{map[string]any{"target": term, "mode": "fresh", "args": "--plan"}, "invalid_params", "args is an array of strings"},
		{map[string]any{"target": term, "mode": "fresh", "args": []any{"--plan", 1.0}}, "invalid_params", "args is an array of strings"},
		{map[string]any{"target": term, "mode": "fresh", "args": nil}, "conflict", blocked},
		{map[string]any{"target": term, "mode": "fresh", "args": []any{"--plan"}}, "conflict", blocked},
	} {
		if code, message := errorOf(f.call("agent.restart", c.params)); code != c.code || message != c.message {
			t.Errorf("%v: %s %q, want %s %q", c.params, code, message, c.code, c.message)
		}
	}
}

func TestRestartNeedsASessionToResumeAndAnAgentOrCommandToStartAnew(t *testing.T) {
	f := newFixture(t)
	const forwarded = "" // the checks pass: on to a client, of which there is none
	noSession := " has no recorded agent session to resume (its agent never reported one, or it exited); mode fresh starts it anew"
	noAgent := " runs no known agent and has no command to relaunch"
	for _, c := range []struct {
		name          string
		props         map[string]any
		session       map[string]any // agent.report_session params, nil for none
		kind          string         // agent.report kind, "" for none
		resume, fresh string         // the message after the tile id, or forwarded
	}{
		{"a bare shell", map[string]any{}, nil, "", noSession, noAgent},
		{"a command, no agent", map[string]any{"command": []any{"/bin/cat"}}, nil, "", noSession, forwarded},
		{"omp, no session", map[string]any{}, nil, "omp", noSession, forwarded},
		{"omp with its session path", map[string]any{}, map[string]any{"kind": "omp", "sessionPath": "/tmp/s.jsonl"}, "", forwarded, forwarded},
		{"codex with only a session path", map[string]any{}, map[string]any{"kind": "codex", "sessionPath": "/tmp/s.jsonl"}, "", noSession, forwarded},
		{"codex with its session id", map[string]any{}, map[string]any{"kind": "codex", "sessionId": "c1"}, "", forwarded, forwarded},
		{"an agent easl can't relaunch", map[string]any{}, map[string]any{"kind": "aider", "sessionId": "a1"}, "", noSession, noAgent},
	} {
		term := f.agentTerminal("", c.props)
		if c.session != nil {
			c.session["tile"] = term
			f.result("agent.report_session", c.session)
		}
		if c.kind != "" {
			f.result("agent.report", map[string]any{"tile": term, "kind": c.kind, "state": "idle"})
		}
		for mode, want := range map[string]string{"resume": c.resume, "fresh": c.fresh} {
			code, message := errorOf(f.call("agent.restart", map[string]any{"target": term, "mode": mode, "force": true}))
			if want == forwarded {
				want = noApp(f.board.ID())
			} else {
				want = term + want
			}
			if code != "unavailable" || message != want {
				t.Errorf("%s, %s: %s %q, want unavailable %q", c.name, mode, code, message, want)
			}
		}
	}
}

// scriptedClient is a Mac client (client.attach) that answers the calls easld forwards it with
// replies, in order, and keeps what it was asked.
type scriptedClient struct {
	router  *Router
	replies []map[string]any // answers without their id: {"ok": true, "result": …} or {"ok": false, "error": …}
	asked   []map[string]any
	during  func() // runs as each call reaches the client, before it answers
}

func (c *scriptedClient) Send(v any) bool {
	request := v.(map[string]any)
	if _, isCall := request["method"]; isCall {
		c.asked = append(c.asked, request)
		if c.during != nil {
			c.during()
		}
		reply := c.replies[0]
		c.replies = c.replies[1:]
		reply["id"] = request["id"]
		c.router.clients.Answer(c, reply)
	}
	return true
}

func (c *scriptedClient) IsOpen() bool          { return true }
func (c *scriptedClient) Done() <-chan struct{} { return nil }

func TestRestartGoesToTheBoardsClientWithTheTileResolved(t *testing.T) {
	f := newFixture(t)
	term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "draft": false})
	relaunched := map[string]any{"agent": map[string]any{"tile": term, "kind": "omp"}, "command": []any{"omp", "--plan"}}
	app := &scriptedClient{router: f.router, replies: []map[string]any{
		{"ok": true, "result": relaunched},
		{"ok": false, "error": map[string]any{"code": "conflict", "message": term + " has keyboard focus: the user may be typing in it; force: true restarts anyway"}},
	}}
	attached := f.router.HandleConn(map[string]any{"id": "a", "method": "client.attach", "params": map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash, "serves": []any{"agent.restart"}, "boards": []any{f.board.ID()},
	}}, app).(map[string]any)
	if attached["ok"] != true {
		t.Fatalf("client.attach: %v", attached)
	}

	if got := f.result("agent.restart", map[string]any{"target": "worker", "mode": "fresh", "args": []any{"--plan"}}); !reflect.DeepEqual(got, relaunched) {
		t.Errorf("the client's result isn't the caller's: %v", got)
	}
	if code, message := errorOf(f.call("agent.restart", map[string]any{"target": term, "mode": "fresh"})); code != "conflict" || message != term+" has keyboard focus: the user may be typing in it; force: true restarts anyway" {
		t.Errorf("the client's error isn't the caller's: %s %q", code, message)
	}
	// easld's own refusal comes first: nothing goes to the client.
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "working"})
	if code, _ := errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "fresh"})); code != "conflict" {
		t.Errorf("working: %s", code)
	}

	want := []map[string]any{
		{"method": "agent.restart", "params": map[string]any{"target": term, "mode": "fresh", "args": []any{"--plan"}}},
		{"method": "agent.restart", "params": map[string]any{"target": term, "mode": "fresh"}},
	}
	if len(app.asked) != len(want) {
		t.Fatalf("the client was asked %d times, want %d: %v", len(app.asked), len(want), app.asked)
	}
	for i, asked := range app.asked {
		if asked["method"] != want[i]["method"] || !reflect.DeepEqual(asked["params"], want[i]["params"]) {
			t.Errorf("call %d: %v, want %v", i, asked, want[i])
		}
	}
}

// What was queued for an agent the client restarts is no poll's while the client works, and
// bounces once it has relaunched it; a restart the client refuses leaves the queue as it was.
func TestRestartBouncesWhatWasQueuedOnceTheClientRelaunchedTheAgent(t *testing.T) {
	f := newFixture(t)
	term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false})
	f.result("agent.prompt", map[string]any{"target": "worker", "text": "Nightly failed.", "from": "machine-watch"})
	app := &scriptedClient{router: f.router, replies: []map[string]any{
		{"ok": false, "error": map[string]any{"code": "conflict", "message": term + " has keyboard focus: the user may be typing in it; force: true restarts anyway"}},
		{"ok": true, "result": map[string]any{"agent": map[string]any{"tile": term}, "command": []any{"omp"}}},
	}}
	var polled [][]map[string]any
	app.during = func() {
		polled = append(polled, messagesOf(t, f.on(&conn{}, "agent.inbox", map[string]any{"tile": term})))
	}
	attached := f.router.HandleConn(map[string]any{"id": "a", "method": "client.attach", "params": map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash, "serves": []any{"agent.restart"}, "boards": []any{f.board.ID()},
	}}, app).(map[string]any)
	if attached["ok"] != true {
		t.Fatalf("client.attach: %v", attached)
	}

	if code, _ := errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "fresh"})); code != "conflict" {
		t.Fatalf("the client's refusal: %s", code)
	}
	if got := texts(f.board.Messages(term)); !reflect.DeepEqual(got, []string{"Nightly failed."}) || len(f.bounced()) != 0 {
		t.Fatalf("refused: queued %q, bounced %q", got, f.bounced())
	}
	// The old agent's integration takes it, and dies with the restart: its hold goes with it.
	old := &conn{}
	if offered := messagesOf(t, f.on(old, "agent.inbox", map[string]any{"tile": term})); len(offered) != 1 {
		t.Fatalf("refused, the message is offered again: %v", offered)
	}
	old.close()

	f.result("agent.restart", map[string]any{"target": "worker", "mode": "fresh"})
	if got := f.bounced(); !reflect.DeepEqual(got, []string{"undelivered to worker@root: Nightly failed. (from machine-watch)"}) {
		t.Fatalf("relaunched: bounced %q", got)
	}
	if len(f.board.Messages(term)) != 0 {
		t.Fatalf("still queued: %q", texts(f.board.Messages(term)))
	}
	if len(polled) != 2 || len(polled[0]) != 0 || len(polled[1]) != 0 {
		t.Fatalf("a poll took a message while the client restarted the agent: %v", polled)
	}
}

// A message its integration delivered as a new turn is a prompt whose turn hasn't started, as
// agent.wait counts it, until the agent reports working or the grace runs out: restarting would
// lose it.
func TestRestartWaitsForAPromptsTurnToStartAsAgentWaitDoes(t *testing.T) {
	f := newFixture(t)
	term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false})
	id := f.result("agent.prompt", map[string]any{"target": "worker", "text": "Nightly failed.", "from": "machine-watch"})["message"]
	f.call("agent.inbox", map[string]any{"tile": term})
	f.call("agent.inbox", map[string]any{"tile": term, "ack": []any{id}, "started": true})
	restart := func() (string, string) {
		return errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "fresh"}))
	}
	if code, message := restart(); code != "conflict" || message != term+" was just prompted and hasn't started that turn: restarting would lose the prompt. Wait for it (agent.wait), or force: true restarts anyway" {
		t.Errorf("delivered, its turn not started: %s %q", code, message)
	}
	f.router.PromptStartGrace = 0
	if _, message := restart(); message != noApp(f.board.ID()) {
		t.Errorf("a prompt that started no turn within the grace never will: %q", message)
	}
}

// While a client restarts a terminal nothing else reaches it: a prompt sent meanwhile is refused
// (it would reach a session about to be killed, or the relaunched agent), no poll takes what is
// queued, and another restart of it is refused rather than racing it. The restart holding the
// terminal lets it go when it ends, refused or done.
func TestNothingReachesATerminalWhileAClientRestartsIt(t *testing.T) {
	f := newFixture(t)
	term := f.agentTerminal("", map[string]any{"name": "worker", "command": []any{"omp"}})
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle", "protocol": 1.0, "draft": false})
	f.result("agent.prompt", map[string]any{"target": "worker", "text": "Nightly failed.", "from": "machine-watch"})
	app := &scriptedClient{router: f.router, replies: []map[string]any{
		{"ok": false, "error": map[string]any{"code": "conflict", "message": term + " has keyboard focus: the user may be typing in it; force: true restarts anyway"}},
		{"ok": true, "result": map[string]any{"agent": map[string]any{"tile": term}, "command": []any{"omp"}}},
	}}
	type meanwhile struct {
		prompt, restart [2]string
		polled          int
	}
	var seen []meanwhile
	app.during = func() {
		var m meanwhile
		m.prompt[0], m.prompt[1] = errorOf(f.call("agent.prompt", map[string]any{"target": "worker", "text": "Also this.", "from": "machine-watch"}))
		m.restart[0], m.restart[1] = errorOf(f.call("agent.restart", map[string]any{"target": "worker", "mode": "fresh", "force": true}))
		m.polled = len(messagesOf(t, f.on(&conn{}, "agent.inbox", map[string]any{"tile": term})))
		seen = append(seen, m)
	}
	attached := f.router.HandleConn(map[string]any{"id": "a", "method": "client.attach", "params": map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash, "serves": []any{"agent.restart"}, "boards": []any{f.board.ID()},
	}}, app).(map[string]any)
	if attached["ok"] != true {
		t.Fatalf("client.attach: %v", attached)
	}
	fresh := map[string]any{"target": "worker", "mode": "fresh"}

	if code, _ := errorOf(f.call("agent.restart", fresh)); code != "conflict" {
		t.Fatalf("the client's refusal: %s", code)
	}
	if got := texts(f.board.Messages(term)); !reflect.DeepEqual(got, []string{"Nightly failed."}) {
		t.Fatalf("refused: queued %q", got)
	}
	if sent := f.result("agent.prompt", map[string]any{"target": "worker", "text": "Now this.", "from": "machine-watch"}); sent["delivery"] != "message" {
		t.Fatalf("refused, the terminal takes prompts again: %v", sent)
	}

	f.result("agent.restart", fresh)
	want := []string{"undelivered to worker@root: Nightly failed. (from machine-watch)", "undelivered to worker@root: Now this. (from machine-watch)"}
	if got := f.bounced(); !reflect.DeepEqual(sorted(got...), want) {
		t.Fatalf("relaunched: bounced %q, want %q", got, want)
	}
	restarting := [2]string{"conflict", term + " is restarting (agent.restart): nothing reaches it until its agent is relaunched; send again once it reports"}
	busy := [2]string{"conflict", term + " is already restarting (another agent.restart): wait for that one to finish"}
	if len(seen) != 2 {
		t.Fatalf("the client was asked %d times, want 2", len(seen))
	}
	for i, m := range seen {
		if m.prompt != restarting || m.restart != busy || m.polled != 0 {
			t.Errorf("restart %d, meanwhile: prompt %q, restart %q, a poll took %d", i, m.prompt, m.restart, m.polled)
		}
	}
	if len(app.asked) != 2 {
		t.Errorf("the client was asked %d times: a restart refused meanwhile reached it", len(app.asked))
	}
	if sent := f.result("agent.prompt", map[string]any{"target": "worker", "text": "Welcome back.", "from": "machine-watch"}); sent["delivery"] != "message" {
		t.Errorf("relaunched, the terminal takes prompts again: %v", sent)
	}
}
