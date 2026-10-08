package router

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

type conn struct {
	mu     sync.Mutex
	sent   []map[string]any
	closed bool
	done   chan struct{}
}

func (c *conn) Send(v any) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sent = append(c.sent, v.(map[string]any))
	return true
}

func (c *conn) IsOpen() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.closed
}

func (c *conn) Done() <-chan struct{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.done == nil {
		c.done = make(chan struct{})
	}
	return c.done
}

// close is the client hanging up.
func (c *conn) close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.done == nil {
		c.done = make(chan struct{})
	}
	if !c.closed {
		c.closed = true
		close(c.done)
	}
}

func (c *conn) messages() []map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]map[string]any(nil), c.sent...)
}

type fixture struct {
	t      *testing.T
	router *Router
	board  *board.Board
	conn   *conn
	seq    int
}

func newFixture(t *testing.T) *fixture {
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	reg := board.NewRegistry(filepath.Join(dir, "boards"), time.Hour, "")
	r := New(reg)
	reg.Mu.Lock()
	b, err := reg.Open(root)
	reg.Mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	return &fixture{t: t, router: r, board: b, conn: &conn{}}
}

// A board file easld can't read (a newer app's format, or one that doesn't decode) isn't opened,
// and stays as it was through board.close and shutdown: the app would have started it empty and
// overwritten it.
func TestBoardFileEasldCantReadIsNeverOverwritten(t *testing.T) {
	dir := t.TempDir()
	reg := board.NewRegistry(filepath.Join(dir, "boards"), time.Millisecond, "")
	f := &fixture{t: t, router: New(reg), conn: &conn{}}
	for name, file := range map[string]string{
		"newer":    `{"format":3,"id":"%s","root":"%s","revision":7,"objects":[],"canvasLayers":[{"id":"l1"}]}`,
		"corrupt":  `{"format":2,"id":"%s","root":"%s","revision":7,"objects":[{"id":"obj_x","type":"hologram"}]}`,
		"truncate": `{"format":2,"id":"%s","root":"%s","revi`,
	} {
		root := filepath.Join(dir, name)
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatal(err)
		}
		id := store.PathID(root)
		path := reg.Store.Path(id)
		content := fmt.Sprintf(file, id, root)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		code, message := errorOf(f.call("board.open", map[string]any{"root": root}))
		if code != "unavailable" || !strings.Contains(message, path) || !strings.Contains(message, "left as it is") {
			t.Errorf("%s: board.open answered %s: %s", name, code, message)
		}
		if name == "newer" && !strings.Contains(message, "format 3, newer than the 2") {
			t.Errorf("newer: %s", message)
		}
		f.call("board.close", map[string]any{"board": id})
		reg.Flush()
		if data, _ := os.ReadFile(path); string(data) != content {
			t.Errorf("%s: the board file changed:\n%s", name, data)
		}
	}
}

func (f *fixture) call(method string, params map[string]any) map[string]any {
	return f.on(f.conn, method, params)
}

// on calls method over c; nil when the reply is deferred.
func (f *fixture) on(c *conn, method string, params map[string]any) map[string]any {
	f.seq++
	reply := f.router.HandleConn(map[string]any{"id": fmt.Sprintf("r%d", f.seq), "method": method, "params": params}, c)
	if reply == nil {
		return nil
	}
	return reply.(map[string]any)
}

func (f *fixture) result(method string, params map[string]any) map[string]any {
	f.t.Helper()
	reply := f.call(method, params)
	if reply["ok"] != true {
		f.t.Fatalf("%s: %v", method, reply["error"])
	}
	return reply["result"].(map[string]any)
}

func errorOf(reply map[string]any) (string, string) {
	e, _ := reply["error"].(map[string]any)
	code, _ := e["code"].(string)
	message, _ := e["message"].(string)
	return code, message
}

func idOf(result map[string]any) string {
	return result["object"].(map[string]any)["id"].(string)
}

func note(x float64, props map[string]any) map[string]any {
	return map[string]any{"type": "note", "props": props, "frame": map[string]any{"x": x, "y": 0.0, "w": 200.0, "h": 100.0}}
}

func upsertOp(key, typ string, props map[string]any) any {
	return map[string]any{"method": "object.upsert", "params": map[string]any{"key": key, "type": typ, "props": props}}
}

func (f *fixture) found(key string) string {
	reply := f.call("object.find", map[string]any{"key": key})
	if code, _ := errorOf(reply); code == "not_found" {
		return ""
	}
	return idOf(reply["result"].(map[string]any))
}

func TestUnknownAndMissingParamsNameWhatTheMethodTakes(t *testing.T) {
	f := newFixture(t)
	code, message := errorOf(f.call("layout.translate", map[string]any{"ids": []any{"x"}, "delta": 3.0}))
	if code != "invalid_params" || message != "unknown param delta; missing dx, dy; layout.translate takes ids (required), dx (required), dy (required), caller" {
		t.Fatalf("%s: %s", code, message)
	}
	if _, message := errorOf(f.call("system.ping", map[string]any{"unexpected": true})); message != "unknown param unexpected; system.ping takes no params" {
		t.Fatal(message)
	}
	reply := f.router.HandleConn(map[string]any{"id": "x", "params": map[string]any{}}, f.conn).(map[string]any)
	if _, message := errorOf(reply); message != "missing method" || reply["id"] != "x" {
		t.Fatalf("%v", reply)
	}
}

// board.open_remote opens a window of the Mac app's: easld checks its params as the app does,
// then answers unsupported.
func TestOpeningARemoteBoardIsTheMacAppsOnly(t *testing.T) {
	f := newFixture(t)
	if code, message := errorOf(f.call("board.open_remote", map[string]any{"host": "work"})); code != "invalid_params" || !strings.Contains(message, "missing board") {
		t.Fatalf("%s: %s", code, message)
	}
	code, message := errorOf(f.call("board.open_remote", map[string]any{"host": "work", "board": "brd_1"}))
	if code != "unsupported" || !strings.Contains(message, "Mac app") {
		t.Fatalf("%s: %s", code, message)
	}
}

// Ported from KeyTests.swift.
func TestAKeyAnotherObjectHoldsIsAConflictNamingIt(t *testing.T) {
	f := newFixture(t)
	first := idOf(f.result("object.create", note(0, map[string]any{"markdown": "a", "key": "REL-1"})))
	code, message := errorOf(f.call("object.create", note(300, map[string]any{"markdown": "b", "key": "REL-1"})))
	if code != "conflict" || !strings.Contains(message, first) || len(f.board.Objects()) != 1 {
		t.Fatalf("%s %s", code, message)
	}
	second := idOf(f.result("object.create", note(300, map[string]any{"markdown": "b"})))
	if code, _ := errorOf(f.call("object.update", map[string]any{"id": second, "props": map[string]any{"key": "REL-1"}})); code != "conflict" {
		t.Fatal(code)
	}
	if code, _ := errorOf(f.call("object.update", map[string]any{"id": second, "props": map[string]any{"key": ""}})); code != "invalid_params" {
		t.Fatal(code)
	}
	f.result("object.update", map[string]any{"id": first, "props": map[string]any{"key": nil}})
	f.result("object.update", map[string]any{"id": second, "props": map[string]any{"key": "REL-1"}})
	if f.found("REL-1") != second {
		t.Fatal("find doesn't answer the new holder")
	}
}

func TestUpsertingAgainKeepsTheIdAndChangesOnlyProps(t *testing.T) {
	f := newFixture(t)
	created := f.result("object.upsert", map[string]any{"key": "REL-7", "type": "note", "props": map[string]any{"markdown": "open"}, "frame": map[string]any{"x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0}})
	if created["created"] != true {
		t.Fatal("not created")
	}
	id := idOf(created)
	f.result("object.update", map[string]any{"id": id, "frame": map[string]any{"x": 500.0, "y": 40.0}})
	again := f.result("object.upsert", map[string]any{"key": "REL-7", "type": "note", "props": map[string]any{"markdown": "merged"}})
	if again["created"] != false || idOf(again) != id || len(f.board.Objects()) != 1 {
		t.Fatalf("%v", again)
	}
	o := f.board.Objects()[id]
	if o.Props["markdown"] != "merged" || o.Props["key"] != "REL-7" || o.Frame != (model.Frame{X: 500, Y: 40, W: 200, H: 100}) {
		t.Fatalf("%+v", o)
	}
	code, message := errorOf(f.call("object.upsert", map[string]any{"key": "REL-7", "type": "group", "props": map[string]any{"members": []any{}}}))
	if code != "conflict" || message != `key "REL-7" is held by `+id+", a note, not a group" {
		t.Fatalf("%s %s", code, message)
	}
}

func TestABatchOfUpsertsRunTwiceUpdatesTheSameObjects(t *testing.T) {
	f := newFixture(t)
	run := func(status string) []string {
		reply := f.result("object.batch", map[string]any{"ops": []any{
			upsertOp("REL-1/status", "shape", map[string]any{"kind": "rect", "text": status}),
			upsertOp("REL-1/pr", "shape", map[string]any{"kind": "rect", "text": "PR #1"}),
			upsertOp("REL-1", "group", map[string]any{"members": []any{"$0", "$1"}, "title": "REL-1 " + status}),
			upsertOp("REL-1/status", "shape", map[string]any{"kind": "rect", "text": status + "!"}),
			map[string]any{"method": "layout.stack", "params": map[string]any{"ids": []any{"$3", "$1"}, "origin": map[string]any{"x": 0.0, "y": 0.0}}},
		}})
		results := reply["results"].([]any)
		ids := make([]string, 4)
		for i := range ids {
			ids[i] = idOf(results[i].(map[string]any))
		}
		return ids
	}
	// Shapes, not notes: a note without a frame height is measured, which needs AppKit.
	first := run("open")
	if first[3] != first[0] {
		t.Fatal("the second upsert of a key made another object")
	}
	revision := f.board.Revision()
	second := run("merged")
	if !reflect.DeepEqual(second, first) || len(f.board.Objects()) != 3 || f.board.Revision() != revision+1 {
		t.Fatalf("%v %v objects %d rev %d", first, second, len(f.board.Objects()), f.board.Revision())
	}
	if f.board.Objects()[first[0]].Props["text"] != "merged!" {
		t.Fatal("not updated")
	}
}

func TestAFailedBatchLeavesNoKeyBehind(t *testing.T) {
	f := newFixture(t)
	reply := f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.upsert", "params": map[string]any{"key": "REL-2", "type": "shape", "props": map[string]any{"kind": "rect"}}},
		map[string]any{"method": "object.create", "params": note(0, map[string]any{"markdown": "copy", "key": "REL-2"})},
	}})
	code, message := errorOf(reply)
	if code != "conflict" || !strings.HasPrefix(message, "op 1 (object.create): ") || len(f.board.Objects()) != 0 || f.found("REL-2") != "" {
		t.Fatalf("%s %s objects %d", code, message, len(f.board.Objects()))
	}
	later := idOf(f.result("object.create", note(0, map[string]any{"markdown": "later", "key": "REL-2"})))
	if f.found("REL-2") != later {
		t.Fatal("the key isn't free")
	}
}

func TestBatchReferencesNameEarlierOpsOnly(t *testing.T) {
	f := newFixture(t)
	_, message := errorOf(f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.update", "params": map[string]any{"id": "$1", "props": map[string]any{}}},
		map[string]any{"method": "object.create", "params": note(0, map[string]any{"markdown": "x"})},
	}}))
	if message != "op 0 (object.update): $1 must name an earlier create or upsert op" {
		t.Fatal(message)
	}
	if len(f.board.Objects()) != 0 {
		t.Fatal("a failed batch left objects")
	}
	// "$-1" is a reference naming no op; a number past Int is no reference at all (Swift's Int()).
	for text, want := range map[string]string{
		"$-1":                   "op 1 (object.update): $-1 must name an earlier create or upsert op",
		"$18446744073709551615": "op 1 (object.update): object $18446744073709551615 on board " + f.board.ID(),
	} {
		_, message := errorOf(f.call("object.batch", map[string]any{"ops": []any{
			map[string]any{"method": "object.create", "params": note(0, map[string]any{"markdown": "x"})},
			map[string]any{"method": "object.update", "params": map[string]any{"id": text, "props": map[string]any{}}},
		}}))
		if message != want {
			t.Errorf("%s: %s", text, message)
		}
	}
}

// A move past what a Double holds is made (as in the app), but its reply is JSONEncoder's
// error, and the board file keeps the last state it could write.
func TestAFrameOutOfRangeIsAnErrorReply(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", map[string]any{"type": "shape", "props": map[string]any{"kind": "rect"}, "frame": map[string]any{"x": 1e308, "y": 0.0, "w": 10.0, "h": 10.0}}))
	code, message := errorOf(f.call("layout.translate", map[string]any{"ids": []any{id}, "dx": 1e308, "dy": 0.0}))
	if code != "invalid_params" || message != "Unable to encode Double.infinity directly in JSON." {
		t.Fatalf("%s %s", code, message)
	}
	_, message = errorOf(f.call("board.export", map[string]any{"path": "out/board.json"}))
	if !strings.HasSuffix(message, "out/board.json: The data couldn’t be written because it isn’t in the correct format.") {
		t.Fatal(message)
	}
}

func TestKeyPrefixListsInKeyOrder(t *testing.T) {
	f := newFixture(t)
	for _, key := range []string{"REL-20", "OPS-1", "REL-3"} {
		f.result("object.upsert", map[string]any{"key": key, "type": "shape", "props": map[string]any{"kind": "rect"}})
	}
	listed := f.result("object.find", map[string]any{"keyPrefix": "REL-"})["objects"].([]any)
	var keys []any
	for _, o := range listed {
		keys = append(keys, o.(map[string]any)["props"].(map[string]any)["key"])
	}
	if !reflect.DeepEqual(keys, []any{"REL-20", "REL-3"}) {
		t.Fatal(keys)
	}
	if code, _ := errorOf(f.call("object.find", map[string]any{})); code != "invalid_params" {
		t.Fatal(code)
	}
}

func TestAgentWaitAnswersWhenTheTerminalGetsThereOrTimesOut(t *testing.T) {
	f := newFixture(t)
	term := idOf(f.result("object.create", map[string]any{"type": "terminal", "props": map[string]any{}, "frame": map[string]any{"x": 0.0, "y": 0.0, "w": 1000.0, "h": 620.0}}))
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "working"})
	waiting := &conn{}
	if reply := f.router.HandleConn(map[string]any{"id": "w1", "method": "agent.wait", "params": map[string]any{"target": term}}, waiting); reply != nil {
		t.Fatalf("answered at once: %v", reply)
	}
	timing := &conn{}
	f.router.HandleConn(map[string]any{"id": "w2", "method": "agent.wait", "params": map[string]any{"target": term, "until": []any{"blocked"}, "timeoutMs": 50.0}}, timing)
	f.result("agent.report", map[string]any{"tile": term, "kind": "omp", "state": "idle"})
	sent := waiting.messages()
	if len(sent) != 1 || sent[0]["id"] != "w1" || sent[0]["ok"] != true {
		t.Fatalf("w1: %v", sent)
	}
	if state := sent[0]["result"].(map[string]any)["agent"].(map[string]any)["lifecycle"].(map[string]any)["state"]; state != "done" {
		t.Fatalf("state %v", state)
	}
	time.Sleep(200 * time.Millisecond)
	got := timing.messages()
	if len(got) != 1 {
		t.Fatalf("w2: %v", got)
	}
	if code, message := errorOf(got[0]); code != "timeout" || message != term+" did not reach blocked in time" {
		t.Fatalf("%s %s", code, message)
	}
	_, message := errorOf(f.call("agent.wait", map[string]any{"target": term, "until": []any{"sleeping"}}))
	if message != `unknown state string("sleeping") in until; one of blocked, done, idle, unknown, working` {
		t.Fatal(message)
	}
}

func TestHistoryKindsAndCursors(t *testing.T) {
	f := newFixture(t)
	f.result("object.create", note(0, map[string]any{"markdown": "hello"}))
	page := f.result("board.history", map[string]any{"kinds": []any{"created"}})
	entries := page["entries"].([]any)
	if len(entries) != 1 || entries[0].(map[string]any)["summary"] != `created note "hello" at (0, 0) 200×100` {
		t.Fatalf("%v", entries)
	}
	if _, message := errorOf(f.call("board.history", map[string]any{"kinds": []any{"exploded"}})); message != `unknown history kind string("exploded")` {
		t.Fatal(message)
	}
	restarted := f.result("board.history", map[string]any{"since": 999.0})
	// A cursor this log never issued (easld restarted): everything it has, flagged.
	if restarted["restarted"] != true || len(restarted["entries"].([]any)) != 2 {
		t.Fatalf("%v", restarted)
	}
}

// Ported from ApiRouterTests.openingAUrlShowsItBesideTheCallerAndReusesTheTile (easld has no
// window to show the tile in).
func TestOpeningAUrlShowsItBesideTheCallerAndReusesTheTile(t *testing.T) {
	f := newFixture(t)
	caller := idOf(f.result("object.create", map[string]any{"type": "terminal", "props": map[string]any{}, "frame": map[string]any{"x": 0.0, "y": 0.0, "w": 600.0, "h": 400.0}}))
	browsers := func() int {
		n := 0
		for _, o := range f.board.Objects() {
			if o.Type == model.Browser {
				n++
			}
		}
		return n
	}

	first := f.result("view.open_url", map[string]any{"url": "http://127.0.0.1:8000/x.html", "caller": caller})
	tile := idOf(first)
	o := f.board.Objects()[tile]
	if first["existing"] != false || o.Type != model.Browser || o.Props["url"] != "http://127.0.0.1:8000/x.html" {
		t.Fatalf("first: %v", first)
	}
	if o.CreatedBy != model.ActorFor(caller) {
		t.Errorf("created by %v, want the caller", o.CreatedBy)
	}

	again := f.result("view.open_url", map[string]any{"url": "HTTP://127.0.0.1:8000/x.html", "caller": caller})
	if idOf(again) != tile || again["existing"] != true || browsers() != 1 {
		t.Fatalf("again: %v (%d browser tiles)", again, browsers())
	}

	for _, refused := range []string{"file:///etc/hosts", "mailto:a@b.c", "example.com", "/tmp/x.html"} {
		code, message := errorOf(f.call("view.open_url", map[string]any{"url": refused, "caller": caller}))
		if code != "invalid_params" || message != "view.open_url opens http and https addresses, not "+refused {
			t.Errorf("%s: %s %s", refused, code, message)
		}
	}
	if browsers() != 1 {
		t.Errorf("%d browser tiles after refusals, want 1", browsers())
	}
}

// namedTerminal creates a terminal tile named name ("" for none) on board ("" for the
// fixture's).
func (f *fixture) namedTerminal(name, board string) string {
	f.t.Helper()
	props := map[string]any{}
	if name != "" {
		props["name"] = name
	}
	params := map[string]any{"type": "terminal", "props": props, "frame": map[string]any{"x": 0.0, "y": 0.0, "w": 600.0, "h": 400.0}}
	if board != "" {
		params["board"] = board
	}
	return idOf(f.result("object.create", params))
}

// messagesOf is what an agent.inbox reply hands out.
func messagesOf(t *testing.T, reply map[string]any) []map[string]any {
	t.Helper()
	if reply["ok"] != true {
		t.Fatalf("agent.inbox: %v", reply["error"])
	}
	var out []map[string]any
	for _, m := range reply["result"].(map[string]any)["messages"].([]any) {
		out = append(out, m.(map[string]any))
	}
	return out
}

// addressed is the agent entry of the terminal target names (as caller, "" for none), or the
// failure as "code: message".
func (f *fixture) addressed(target, caller string) (map[string]any, string) {
	params := map[string]any{"target": target, "until": []any{"blocked", "done", "idle", "unknown", "working"}}
	if caller != "" {
		params["caller"] = caller
	}
	c := &conn{}
	if reply := f.on(c, "agent.wait", params); reply != nil {
		code, message := errorOf(reply)
		return nil, code + ": " + message
	}
	return c.messages()[0]["result"].(map[string]any)["agent"].(map[string]any), ""
}

// A prompt to a terminal whose integration takes messages is queued, not typed: agent.inbox
// hands it out with its sender and mentions resolved, the connection that took it holds it
// until it acks it or hangs up, and agent.wait and agent.read final see the turn it starts.
func TestAMessageWaitsOutOfBandUntilItsIntegrationAcksIt(t *testing.T) {
	f := newFixture(t)
	reviewer := f.namedTerminal("reviewer", "")
	lead := f.namedTerminal("lead", "")
	attached := idOf(f.result("object.create", note(2000, map[string]any{"markdown": "The cache key must include the locale."})))
	f.result("agent.report", map[string]any{"tile": reviewer, "kind": "omp", "state": "idle", "protocol": 1.0})
	sent := f.result("agent.prompt", map[string]any{"target": "reviewer", "text": "Check the key.", "caller": lead, "mentions": []any{map[string]any{"object": attached}}})
	id, _ := sent["message"].(string)
	if sent["delivery"] != "message" || sent["waitable"] != true || !strings.HasPrefix(id, "msg_") || len(sent["mentions"].([]any)) != 1 {
		t.Fatalf("%v", sent)
	}
	waiter := &conn{}
	if reply := f.on(waiter, "agent.wait", map[string]any{"target": "reviewer", "caller": lead}); reply != nil {
		t.Fatalf("agent.wait answered while the message was queued: %v", reply)
	}
	if _, message := errorOf(f.call("agent.read", map[string]any{"target": reviewer, "final": true})); message != reviewer+" is still in its turn (prompted): agent.wait for it, then read final" {
		t.Fatal(message)
	}

	integration, other := &conn{}, &conn{}
	got := messagesOf(t, f.on(integration, "agent.inbox", map[string]any{"tile": reviewer}))
	if len(got) != 1 || got[0]["id"] != id || got[0]["text"] != "Check the key." || got[0]["attribution"] != "agent" || got[0]["when"] != "now" {
		t.Fatalf("%v", got)
	}
	if from := got[0]["from"]; !reflect.DeepEqual(from, map[string]any{"tile": lead, "name": "lead", "address": "lead@root", "board": f.board.ID()}) {
		t.Errorf("from %v", from)
	}
	context, _ := got[0]["context"].(string)
	if !strings.Contains(context, "Attached by terminal "+lead+` "lead" to its prompt to you (agent.prompt):`) || !strings.Contains(context, "The cache key must include the locale.") {
		t.Errorf("context:\n%s", context)
	}
	if got := messagesOf(t, f.on(other, "agent.inbox", map[string]any{"tile": reviewer})); len(got) != 0 {
		t.Fatalf("offered while another connection holds it: %v", got)
	}
	integration.close()
	if got := messagesOf(t, f.on(other, "agent.inbox", map[string]any{"tile": reviewer})); len(got) != 1 || got[0]["id"] != id {
		t.Fatalf("not offered again once its holder closed: %v", got)
	}

	if got := messagesOf(t, f.on(other, "agent.inbox", map[string]any{"tile": reviewer, "ack": []any{id}, "started": true})); len(got) != 0 {
		t.Fatalf("acked, still offered: %v", got)
	}
	if len(waiter.messages()) != 0 {
		t.Fatalf("agent.wait answered before the turn the message started: %v", waiter.messages())
	}
	f.result("agent.report", map[string]any{"tile": reviewer, "kind": "omp", "state": "working", "protocol": 1.0})
	f.result("agent.report", map[string]any{"tile": reviewer, "kind": "omp", "state": "idle", "protocol": 1.0, "final": "Done."})
	answered := waiter.messages()
	if len(answered) != 1 || answered[0]["ok"] != true {
		t.Fatalf("%v", answered)
	}
	if state := answered[0]["result"].(map[string]any)["agent"].(map[string]any)["lifecycle"].(map[string]any)["state"]; state != "done" {
		t.Fatalf("state %v", state)
	}
	if text := f.result("agent.read", map[string]any{"target": reviewer, "final": true})["text"]; text != "Done." {
		t.Fatal(text)
	}

	f.result("agent.prompt", map[string]any{"target": reviewer, "text": "Still there?", "caller": lead})
	f.result("agent.release", map[string]any{"tile": reviewer, "kind": "omp"})
	if got := messagesOf(t, f.on(other, "agent.inbox", map[string]any{"tile": reviewer})); len(got) != 0 {
		t.Fatalf("a released agent's messages stayed: %v", got)
	}
}

// A message whose delivery started a turn holds agent.wait for that turn as a typed prompt
// does, and fails it when no turn starts within the grace.
func TestAStartedDeliveryThatStartsNoTurnFailsTheWait(t *testing.T) {
	f := newFixture(t)
	f.router.PromptStartGrace = 50 * time.Millisecond
	reviewer := f.namedTerminal("reviewer", "")
	f.result("agent.report", map[string]any{"tile": reviewer, "kind": "omp", "state": "idle", "protocol": 1.0})
	id := f.result("agent.prompt", map[string]any{"target": reviewer, "text": "/compact"})["message"]
	waiter := &conn{}
	f.on(waiter, "agent.wait", map[string]any{"target": reviewer})
	f.call("agent.inbox", map[string]any{"tile": reviewer})
	f.call("agent.inbox", map[string]any{"tile": reviewer, "ack": []any{id}, "started": true})
	time.Sleep(300 * time.Millisecond)
	answered := waiter.messages()
	if len(answered) != 1 {
		t.Fatalf("%v", answered)
	}
	if code, message := errorOf(answered[0]); code != "unavailable" || !strings.HasPrefix(message, reviewer+"'s last agent.prompt started no turn within 0.05 s") {
		t.Fatalf("%s %s", code, message)
	}
}

// A script's message (`from`, or no caller) is the user's, named by its label; a long poll is
// answered by the next message queued; a terminal without a message integration is typed into
// by a client (none is attached here).
func TestAScriptsMessageIsTheUsersAndALongPollTakesIt(t *testing.T) {
	f := newFixture(t)
	reviewer := f.namedTerminal("reviewer", "")
	lead := f.namedTerminal("lead", "")
	f.result("agent.report", map[string]any{"tile": reviewer, "kind": "omp", "state": "idle", "protocol": 1.0})
	poll := &conn{}
	if reply := f.on(poll, "agent.inbox", map[string]any{"tile": reviewer, "waitMs": 10000.0}); reply != nil {
		t.Fatalf("answered with nothing queued: %v", reply)
	}
	labelled := f.result("agent.prompt", map[string]any{"target": "reviewer@root", "text": "Nightly build failed.", "caller": lead, "from": "machine-watch", "when": "next-turn"})
	answered := poll.messages()
	if len(answered) != 1 {
		t.Fatalf("the long poll wasn't answered: %v", answered)
	}
	got := messagesOf(t, answered[0])
	if len(got) != 1 || got[0]["id"] != labelled["message"] || got[0]["attribution"] != "user" || got[0]["when"] != "next-turn" ||
		!reflect.DeepEqual(got[0]["from"], map[string]any{"name": "machine-watch"}) || got[0]["context"] != nil {
		t.Fatalf("%v", got)
	}
	unnamed := f.result("agent.prompt", map[string]any{"target": reviewer, "text": "ping"})
	fromLead := f.result("agent.prompt", map[string]any{"target": reviewer, "text": "bye", "caller": lead})
	f.result("object.delete", map[string]any{"id": lead})
	got = messagesOf(t, f.on(poll, "agent.inbox", map[string]any{"tile": reviewer, "ack": []any{labelled["message"]}}))
	if len(got) != 2 || got[0]["id"] != unnamed["message"] || got[0]["attribution"] != "user" || !reflect.DeepEqual(got[0]["from"], map[string]any{"name": "script"}) {
		t.Fatalf("%v", got)
	}
	if got[1]["id"] != fromLead["message"] || got[1]["attribution"] != "agent" || !reflect.DeepEqual(got[1]["from"], map[string]any{"tile": lead, "name": lead}) {
		t.Fatalf("a closed sender: %v", got[1])
	}

	for _, c := range []struct {
		params map[string]any
		want   string
	}{
		{map[string]any{"target": reviewer, "text": "x", "when": "later"}, `invalid_params: when is "now" (the default) or "next-turn"`},
		{map[string]any{"target": reviewer, "text": "x", "from": "  "}, `invalid_params: from is a sender label such as "machine-watch"`},
	} {
		if code, message := errorOf(f.call("agent.prompt", c.params)); code+": "+message != c.want {
			t.Errorf("%v: %s: %s", c.params, code, message)
		}
	}
	if code, message := errorOf(f.call("agent.inbox", map[string]any{"tile": reviewer, "waitMs": 70000.0})); message != "waitMs is from 0 to 60000" {
		t.Errorf("%s %s", code, message)
	}

	typed := f.namedTerminal("typed", "")
	f.result("agent.report", map[string]any{"tile": typed, "kind": "claude", "state": "working"})
	if code, message := errorOf(f.call("agent.prompt", map[string]any{"target": typed, "text": "after this", "when": "next-turn"})); code != "conflict" ||
		message != typed+` is in its turn and its integration takes no messages, so typed text would join that turn; agent.wait for it and send again, or send with when: "now"` {
		t.Fatalf("%s %s", code, message)
	}
	if code, _ := errorOf(f.call("agent.prompt", map[string]any{"target": typed, "text": "now then"})); code != "unavailable" {
		t.Fatalf("a typed prompt with no client to type it: %s", code)
	}
}

// A message sent again with its id (agent.prompt `message`: a sender whose call timed out) is
// that message: queued once, delivered once. An id that isn't one is refused.
func TestAMessageSentAgainWithItsIdIsQueuedOnce(t *testing.T) {
	f := newFixture(t)
	reviewer := f.namedTerminal("reviewer", "")
	lead := f.namedTerminal("lead", "")
	f.result("agent.report", map[string]any{"tile": reviewer, "kind": "omp", "state": "idle", "protocol": 1.0})
	params := map[string]any{"target": "reviewer", "text": "Check the key.", "caller": lead, "message": "msg_write_toolu_01"}
	first := f.result("agent.prompt", params)
	again := f.result("agent.prompt", params)
	if first["message"] != "msg_write_toolu_01" || first["duplicate"] != nil {
		t.Fatalf("first: %v", first)
	}
	if again["message"] != "msg_write_toolu_01" || again["duplicate"] != true || again["delivery"] != "message" || again["submittedAt"] != first["submittedAt"] {
		t.Fatalf("again: %v", again)
	}
	got := messagesOf(t, f.call("agent.inbox", map[string]any{"tile": reviewer}))
	if len(got) != 1 || got[0]["id"] != "msg_write_toolu_01" || got[0]["text"] != "Check the key." {
		t.Fatalf("%v", got)
	}
	if code, message := errorOf(f.call("agent.prompt", map[string]any{"target": reviewer, "text": "x", "message": "not an id"})); code != "invalid_params" ||
		message != "message is the id the message gets, the same on every attempt to send it: msg_ and 8 to 64 letters, digits, _ or -" {
		t.Fatalf("%s %s", code, message)
	}
}

// A composer's prompt (a remote board's viewer) is the user's, typed as the app's composer types
// it: `from` and `when` are refused before the target is looked up, and it is never queued as a
// message, even for a terminal whose integration takes them (a client types it; none is attached).
func TestAComposersPromptTakesNoFromOrWhenAndIsTyped(t *testing.T) {
	f := newFixture(t)
	reviewer := f.namedTerminal("reviewer", "")
	f.result("agent.report", map[string]any{"tile": reviewer, "kind": "omp", "state": "idle", "protocol": 1.0})
	for _, c := range []struct {
		params map[string]any
		want   string
	}{
		{map[string]any{"target": reviewer, "text": "x", "composer": true, "from": "machine-watch"}, "invalid_params: a composer's prompt is the user's: it takes no from"},
		{map[string]any{"target": reviewer, "text": "x", "composer": true, "when": "next-turn"}, "invalid_params: a composer's prompt is typed as the user sends it: it takes no when"},
		{map[string]any{"target": "nobody", "text": "x", "composer": true, "when": "now"}, "invalid_params: a composer's prompt is typed as the user sends it: it takes no when"},
	} {
		if code, message := errorOf(f.call("agent.prompt", c.params)); code+": "+message != c.want {
			t.Errorf("%v: %s: %s", c.params, code, message)
		}
	}
	if code, message := errorOf(f.call("agent.prompt", map[string]any{"target": reviewer, "text": "fix the build", "composer": true})); code != "unavailable" {
		t.Fatalf("a composer's prompt with no client to type it: %s %s", code, message)
	}
	if got := f.board.Messages(reviewer); len(got) != 0 {
		t.Fatalf("queued as a message: %v", got)
	}
}

// name@board, the caller's board first, a renamed terminal's old name until another takes it,
// ambiguity, and boards found by name only while their root folder exists.
func TestAgentAddresses(t *testing.T) {
	f := newFixture(t)
	reviewer := f.namedTerminal("reviewer", "")
	lead := f.namedTerminal("lead", "")
	otherRoot := filepath.Join(filepath.Dir(f.board.Root()), "other")
	if err := os.MkdirAll(otherRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	other := f.result("board.open", map[string]any{"root": otherRoot})["board"].(string)
	elsewhere := f.namedTerminal("reviewer", other)
	tile := func(target, caller string) string {
		t.Helper()
		agent, failure := f.addressed(target, caller)
		if agent == nil {
			return failure
		}
		return agent["tile"].(string)
	}

	for _, c := range []struct{ target, caller, want string }{
		{"reviewer@other", "", elsewhere},
		{"reviewer@" + f.board.ID(), "", reviewer},
		{"reviewer", lead, reviewer},
		{"reviewer", elsewhere, elsewhere},
		{"reviewer", "", "ambiguous: reviewer matches 2 terminals: reviewer@other (" + elsewhere + "), reviewer@root (" + reviewer + "); address one as name@board, or by its tile id"},
		{"nobody@root", "", "not_found: no terminal tile named nobody on board root"},
		{"reviewer@nowhere", "", "not_found: no open board named nowhere (open boards: other, root)"},
		{"nobody", lead, "not_found: no terminal tile named or with id nobody"},
	} {
		if got := tile(c.target, c.caller); got != c.want {
			t.Errorf("%s (caller %q): %s, want %s", c.target, c.caller, got, c.want)
		}
	}

	f.result("object.update", map[string]any{"id": reviewer, "props": map[string]any{"name": "critic"}})
	if got := tile("reviewer", lead); got != reviewer {
		t.Errorf("by its old name: %s", got)
	}
	if agent, _ := f.addressed(reviewer, ""); agent["address"] != "critic@root" || !reflect.DeepEqual(agent["aliases"], []any{"reviewer"}) {
		t.Errorf("renamed: %v", agent)
	}
	taken := f.namedTerminal("reviewer", "")
	if got := tile("reviewer", lead); got != taken {
		t.Errorf("the name's new holder: %s", got)
	}
	if agent, _ := f.addressed(reviewer, ""); agent["aliases"] != nil {
		t.Errorf("the taken alias stayed: %v", agent["aliases"])
	}
	f.result("object.update", map[string]any{"id": taken, "props": map[string]any{"name": "gone"}})
	f.result("object.delete", map[string]any{"id": taken})
	if got := tile("reviewer", lead); got != elsewhere {
		t.Errorf("a deleted terminal's alias stayed: %s", got)
	}

	if err := os.RemoveAll(otherRoot); err != nil {
		t.Fatal(err)
	}
	if got := tile("reviewer@other", ""); got != "not_found: no open board named other (open boards: root)" {
		t.Errorf("a board whose folder is gone, by name: %s", got)
	}
	if got := tile("reviewer@"+other, ""); got != elsewhere {
		t.Errorf("a board whose folder is gone, by id: %s", got)
	}
}

// bounced is what the board.history `message` entries on the fixture's board say.
func (f *fixture) bounced() []string {
	var out []string
	for _, e := range f.result("board.history", map[string]any{"board": f.board.ID(), "kinds": []any{"message"}})["entries"].([]any) {
		out = append(out, e.(map[string]any)["summary"].(string))
	}
	return out
}

func texts(messages []board.Message) []string {
	var out []string
	for _, m := range messages {
		out = append(out, m.Text)
	}
	return out
}

// A message whose receiver's agent session ends before its integration takes it bounces: back to
// a sending terminal whose integration takes messages, as a message from easl; a plain
// terminal's or a script's into the receiver's board.history. A release ends that session, and
// so do another session or another agent reported in the tile, and a report without protocol.
func TestAMessageWhoseReceiversSessionEndsBounces(t *testing.T) {
	f := newFixture(t)
	reviewer := f.namedTerminal("reviewer", "")
	lead := f.namedTerminal("lead", "")
	shell := f.namedTerminal("shell", "")
	report := func(tile, kind string, protocol any) {
		f.result("agent.report", map[string]any{"tile": tile, "kind": kind, "state": "idle", "protocol": protocol})
	}
	report(reviewer, "omp", 1.0)
	report(lead, "omp", 1.0)
	f.result("agent.prompt", map[string]any{"target": "reviewer", "text": "Check the cache key.\nThen the locale.", "caller": lead})
	f.result("agent.prompt", map[string]any{"target": "reviewer", "text": "From a plain shell.", "caller": shell})
	f.result("agent.prompt", map[string]any{"target": "reviewer", "text": "Nightly failed.", "from": "machine-watch"})
	f.result("agent.release", map[string]any{"tile": reviewer, "kind": "omp"})

	back := messagesOf(t, f.on(&conn{}, "agent.inbox", map[string]any{"tile": lead}))
	if len(back) != 1 || back[0]["text"] != "undelivered to reviewer@root: Check the cache key.…" ||
		!reflect.DeepEqual(back[0]["from"], map[string]any{"name": "easl"}) || back[0]["attribution"] != "user" {
		t.Fatalf("the lead's bounce: %v", back)
	}
	want := []string{"undelivered to reviewer@root: From a plain shell. (from shell@root)", "undelivered to reviewer@root: Nightly failed. (from machine-watch)"}
	if got := f.bounced(); !reflect.DeepEqual(got, want) {
		t.Fatalf("history: %q", got)
	}
	if len(f.board.Messages(reviewer)) != 0 {
		t.Fatalf("still queued: %v", f.board.Messages(reviewer))
	}

	f.board.AckMessages([]string{back[0]["id"].(string)}, lead)
	report(reviewer, "omp", 1.0)
	f.result("agent.report_session", map[string]any{"tile": reviewer, "kind": "omp", "sessionId": "ses_1"})
	for _, end := range []struct {
		text string
		end  func()
	}{
		{"a new conversation", func() {
			f.result("agent.report_session", map[string]any{"tile": reviewer, "kind": "omp", "sessionId": "ses_2"})
		}},
		{"another agent", func() { report(reviewer, "codex", 1.0) }},
		{"no protocol", func() { report(reviewer, "omp", 1.0); report(reviewer, "omp", nil) }},
	} {
		report(reviewer, "omp", 1.0)
		f.result("agent.prompt", map[string]any{"target": reviewer, "text": end.text, "caller": lead})
		end.end()
		if got := texts(f.board.Messages(lead)); !reflect.DeepEqual(got, []string{"undelivered to reviewer@root: " + end.text}) {
			t.Errorf("%s: %q", end.text, got)
		}
		f.board.AckMessages([]string{f.board.Messages(lead)[0].ID}, lead)
	}
	// The same session reported again ends nothing.
	report(reviewer, "omp", 1.0)
	f.result("agent.report_session", map[string]any{"tile": reviewer, "kind": "omp", "sessionId": "ses_3"})
	f.result("agent.prompt", map[string]any{"target": reviewer, "text": "kept", "caller": lead})
	f.result("agent.report_session", map[string]any{"tile": reviewer, "kind": "omp", "sessionId": "ses_3"})
	report(reviewer, "omp", 1.0)
	if got := texts(f.board.Messages(reviewer)); !reflect.DeepEqual(got, []string{"kept"}) {
		t.Fatalf("%q", got)
	}
}

// A failed batch that deleted a terminal puts back its queue and old names; deleted for good,
// its queue bounces under the name it had.
func TestAFailedBatchPutsBackTheQueueAndOldNamesOfATerminalItDeleted(t *testing.T) {
	f := newFixture(t)
	reviewer := f.namedTerminal("reviewer", "")
	lead := f.namedTerminal("lead", "")
	for _, tile := range []string{reviewer, lead} {
		f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "protocol": 1.0})
	}
	f.result("object.update", map[string]any{"id": reviewer, "props": map[string]any{"name": "critic"}})
	f.result("agent.prompt", map[string]any{"target": "reviewer", "text": "one", "caller": lead})
	queued := f.board.Messages(reviewer)
	failed := f.call("object.batch", map[string]any{"board": f.board.ID(), "ops": []any{
		map[string]any{"method": "object.delete", "params": map[string]any{"id": reviewer}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "obj_missing", "props": map[string]any{"x": 1.0}}},
	}})
	if code, _ := errorOf(failed); code == "" {
		t.Fatalf("the batch applied: %v", failed)
	}
	if got := f.board.Messages(reviewer); len(queued) != 1 || !reflect.DeepEqual(got, queued) {
		t.Fatalf("queue %v, want %v", got, queued)
	}
	if got := f.board.Aliases(reviewer); !reflect.DeepEqual(got, []string{"reviewer"}) {
		t.Fatalf("aliases %v", got)
	}
	if len(f.board.Messages(lead)) != 0 {
		t.Fatalf("bounced: %v", f.board.Messages(lead))
	}
	f.result("object.delete", map[string]any{"id": reviewer})
	if got := texts(f.board.Messages(lead)); !reflect.DeepEqual(got, []string{"undelivered to critic@root: one"}) {
		t.Fatalf("%q", got)
	}
}

// On each board a bare name is its current name, else its alias; matches on two boards are
// ambiguous even when one is an alias.
func TestABareNameIsEachBoardsCurrentNameElseItsAlias(t *testing.T) {
	f := newFixture(t)
	renamed := f.namedTerminal("reviewer", "")
	lead := f.namedTerminal("lead", "")
	otherRoot := filepath.Join(filepath.Dir(f.board.Root()), "other")
	if err := os.MkdirAll(otherRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	other := f.result("board.open", map[string]any{"root": otherRoot})["board"].(string)
	elsewhere := f.namedTerminal("reviewer", other)
	scout := f.namedTerminal("scout", other)
	f.result("object.update", map[string]any{"id": renamed, "props": map[string]any{"name": "critic"}})
	for _, c := range []struct{ caller, want string }{
		{"", "ambiguous: reviewer matches 2 terminals: critic@root (" + renamed + "), reviewer@other (" + elsewhere + "); address one as name@board, or by its tile id"},
		{lead, renamed},
		{scout, elsewhere},
	} {
		agent, failure := f.addressed("reviewer", c.caller)
		if agent != nil {
			failure = agent["tile"].(string)
		}
		if failure != c.want {
			t.Errorf("caller %q: %s, want %s", c.caller, failure, c.want)
		}
	}
}

// A terminal's address reaches it alone: name@<board id> where open boards' folders share a
// name or its board's folder is gone, its tile id where its name is shared on its board. A
// message's reply address is the same.
func TestAnAddressReachesItsTerminalAlone(t *testing.T) {
	f := newFixture(t)
	parent := filepath.Dir(f.board.Root())
	open := func(dir string) string {
		root := filepath.Join(parent, dir)
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatal(err)
		}
		return f.result("board.open", map[string]any{"root": root})["board"].(string)
	}
	first, second, archived := open("a/client"), open("b/client"), open("gone")
	if err := os.RemoveAll(filepath.Join(parent, "gone")); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		f.namedTerminal("reviewer", first): "reviewer@" + first,
		f.namedTerminal("lead", second):    "lead@" + second,
		f.namedTerminal("scout", archived): "scout@" + archived,
		f.namedTerminal("solo", ""):        "solo@root",
	}
	twin := f.namedTerminal("twin", "")
	f.namedTerminal("twin", "")
	want[twin] = twin
	for _, a := range f.result("agent.list", map[string]any{})["agents"].([]any) {
		agent := a.(map[string]any)
		tile := agent["tile"].(string)
		address, ok := want[tile]
		if !ok {
			continue
		}
		if agent["address"] != address {
			t.Errorf("%s: address %v, want %s", tile, agent["address"], address)
		}
		if reached, failure := f.addressed(address, ""); reached == nil || reached["tile"] != tile {
			t.Errorf("%s doesn't reach %s: %v %s", address, tile, reached, failure)
		}
	}

	receiver := f.namedTerminal("receiver", "")
	f.result("agent.report", map[string]any{"tile": receiver, "kind": "omp", "state": "idle", "protocol": 1.0})
	var lead string
	for tile, address := range want {
		if address == "lead@"+second {
			lead = tile
		}
	}
	f.result("agent.prompt", map[string]any{"target": receiver, "text": "hi", "caller": lead})
	got := messagesOf(t, f.on(&conn{}, "agent.inbox", map[string]any{"tile": receiver}))
	if len(got) != 1 || got[0]["from"].(map[string]any)["address"] != "lead@"+second {
		t.Fatalf("%v", got)
	}
}

// Queued messages are saved with the board: easld started again offers them.
func TestQueuedMessagesSurviveARestart(t *testing.T) {
	f := newFixture(t)
	reviewer := f.namedTerminal("reviewer", "")
	lead := f.namedTerminal("lead", "")
	f.result("agent.report", map[string]any{"tile": reviewer, "kind": "omp", "state": "working", "protocol": 1.0})
	f.result("agent.prompt", map[string]any{"target": "reviewer", "text": "Check the key.", "caller": lead})
	f.result("agent.prompt", map[string]any{"target": "reviewer", "text": "Nightly failed.", "from": "machine-watch", "when": "next-turn"})
	queued := f.board.Messages(reviewer)
	f.router.reg.Flush()

	again := board.NewRegistry(filepath.Join(filepath.Dir(f.board.Root()), "boards"), time.Hour, "")
	again.Mu.Lock()
	b, err := again.Open(f.board.Root())
	again.Mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	got := b.Messages(reviewer)
	if len(got) != 2 {
		t.Fatalf("%v", got)
	}
	for i, m := range got {
		was := queued[i]
		if m.ID != was.ID || m.Text != was.Text || m.From != was.From || m.Label != was.Label || m.When != was.When || !m.QueuedAt.Equal(was.QueuedAt.Truncate(time.Second)) {
			t.Errorf("%d: %+v, want %+v", i, m, was)
		}
	}
	r := New(again)
	offered := messagesOf(t, r.HandleConn(map[string]any{"id": "1", "method": "agent.inbox", "params": map[string]any{"tile": reviewer}}, &conn{}).(map[string]any))
	if len(offered) != 2 || offered[0]["text"] != "Check the key." || offered[1]["when"] != "next-turn" {
		t.Fatalf("%v", offered)
	}
}
