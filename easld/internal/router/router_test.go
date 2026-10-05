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
)

type conn struct {
	mu   sync.Mutex
	sent []map[string]any
}

func (c *conn) Send(v any) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sent = append(c.sent, v.(map[string]any))
	return true
}

func (c *conn) IsOpen() bool { return true }

// Done never closes: the test connections stay open.
func (c *conn) Done() <-chan struct{} { return nil }

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
	b := reg.Open(root)
	reg.Mu.Unlock()
	return &fixture{t: t, router: r, board: b, conn: &conn{}}
}

func (f *fixture) call(method string, params map[string]any) map[string]any {
	f.seq++
	reply := f.router.HandleConn(map[string]any{"id": fmt.Sprintf("r%d", f.seq), "method": method, "params": params}, f.conn)
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
