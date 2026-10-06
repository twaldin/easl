package clients

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/server"
	"github.com/twaldin/easl/easld/internal/textmeasure"
)

// fakeConn is a client's connection: what the registry sends it is queued on sent, and hangUp
// closes it.
type fakeConn struct {
	sent chan map[string]any
	done chan struct{}
	once sync.Once
}

func newConn() *fakeConn {
	return &fakeConn{sent: make(chan map[string]any, 16), done: make(chan struct{})}
}

func (f *fakeConn) Send(v any) bool {
	select {
	case <-f.done:
		return false
	default:
	}
	f.sent <- v.(map[string]any)
	return true
}

func (f *fakeConn) Done() <-chan struct{} { return f.done }

func (f *fakeConn) hangUp() { f.once.Do(func() { close(f.done) }) }

// request is the next request the registry sent the client.
func (f *fakeConn) request(t *testing.T) map[string]any {
	t.Helper()
	select {
	case m := <-f.sent:
		return m
	case <-time.After(5 * time.Second):
		t.Fatal("the client was sent no request")
		return nil
	}
}

const board = "brd_a"

// current is an attachment built from the server's own schema version.
func current(app, host string, serves []string, boards []string, focused string) Attachment {
	return Attachment{Version: api.SchemaVersion, Schema: api.SchemaHash, App: app, Host: host, Serves: serves, Boards: boards, Focused: focused}
}

func attach(t *testing.T, r *Registry, conn Conn, a Attachment) *Client {
	t.Helper()
	c, err := r.Attach(conn, a)
	if err != nil {
		t.Fatalf("attach %+v: %v", a, err)
	}
	return c
}

func expectFailure(t *testing.T, failure *Failure, code, message string) {
	t.Helper()
	if failure == nil || failure.Code != code || failure.Message != message {
		t.Fatalf("got %+v, want %s %q", failure, code, message)
	}
}

func TestChooseTakesTheBoardsFocusThenTheLatestFocusThenTheLastAttached(t *testing.T) {
	r := New()
	serves := []string{"view.get", "text.measure"}
	boards := []string{"brd_a", "brd_b", "brd_c"}
	studio := attach(t, r, newConn(), current("0.2.0", "studio", serves, boards, "brd_a"))
	laptop := attach(t, r, newConn(), current("0.2.0", "laptop", serves, boards, "brd_b"))
	mini := attach(t, r, newConn(), current("0.2.0", "mini", serves, boards, ""))
	name := map[*Client]string{studio: "studio", laptop: "laptop", mini: "mini", nil: "none"}
	expect := func(method, board string, want *Client) {
		t.Helper()
		if got := r.Choose(method, board); got != want {
			t.Errorf("%s on %q: got %s, want %s", method, board, name[got], name[want])
		}
	}
	// studio's user focused brd_a: it serves brd_a though laptop's focus is later and mini
	// attached last.
	expect("view.get", "brd_a", studio)
	expect("view.get", "brd_b", laptop)
	// Nobody focused brd_c: the most recent focus on any board wins over the last attached.
	expect("view.get", "brd_c", laptop)
	expect("text.measure", "", laptop)

	// studio's user moves to brd_c; attaching again without `focused` keeps a client's focus.
	attach(t, r, studio.conn, current("0.2.0", "studio", serves, boards, "brd_c"))
	attach(t, r, laptop.conn, current("0.2.0", "laptop", serves, boards, ""))
	expect("view.get", "brd_c", studio)
	expect("view.get", "brd_b", laptop)
	// Nobody's focus is on brd_a any more: studio focused last.
	expect("view.get", "brd_a", studio)

	// Only clients that serve the method and show the board are candidates.
	attach(t, r, studio.conn, current("0.2.0", "studio", []string{"text.measure"}, boards, "brd_c"))
	expect("view.get", "brd_c", laptop)
	attach(t, r, laptop.conn, current("0.2.0", "laptop", serves, []string{"brd_a"}, ""))
	expect("view.get", "brd_c", mini)
	expect("view.render", "brd_c", nil)
	expect("view.get", "brd_z", nil)
}

func TestChooseTakesTheLastAttachedWhenNobodyFocused(t *testing.T) {
	r := New()
	serves := []string{"view.get"}
	attach(t, r, newConn(), current("0.2.0", "studio", serves, []string{board}, ""))
	laptop := attach(t, r, newConn(), current("0.2.0", "laptop", serves, []string{board}, ""))
	if got := r.Choose("view.get", board); got != laptop {
		t.Fatalf("got %+v, want the client attached last", got)
	}
}

func TestAttachRefusesAnOlderSchemaVersionAndTakesTheSameOrANewerOne(t *testing.T) {
	r := New()
	older := current("0.1.0", "studio", []string{"view.get"}, []string{board}, board)
	older.Version, older.Schema = api.SchemaVersion-1, "5a0c1d7e9b3f2a64"
	_, err := r.Attach(newConn(), older)
	failure, _ := err.(*Failure)
	expectFailure(t, failure, api.CodeUnavailable, fmt.Sprintf("easl 0.1.0 on studio is older than this board's server (schema version %d, the server's %d); update it", api.SchemaVersion-1, api.SchemaVersion))
	unnamed := Attachment{Version: api.SchemaVersion - 1, Schema: older.Schema, Serves: older.Serves}
	_, err = r.Attach(newConn(), unnamed)
	failure, _ = err.(*Failure)
	expectFailure(t, failure, api.CodeUnavailable, fmt.Sprintf("a client is older than this board's server (schema version %d, the server's %d); update it", api.SchemaVersion-1, api.SchemaVersion))
	if r.Clients() != 0 || r.Choose("view.get", board) != nil {
		t.Fatalf("a refused client attached: %d", r.Clients())
	}

	// The same version with another schema hash serves what both know: names this server
	// doesn't know are dropped.
	same := current("0.2.1", "laptop", []string{"view.get", "view.zoom"}, []string{board}, "")
	same.Schema = "0123456789abcdef"
	peer := attach(t, r, newConn(), same)
	if r.Choose("view.get", board) != peer || r.Choose("view.zoom", board) != nil {
		t.Errorf("the same version: %+v", peer)
	}

	// A newer client is taken too; it speaks the server's version.
	newer := current("0.3.0", "studio", []string{"view.render", "view.zoom"}, []string{board}, board)
	newer.Version, newer.Schema = api.SchemaVersion+1, "fedcba9876543210"
	next := attach(t, r, newConn(), newer)
	if r.Choose("view.render", board) != next || r.Choose("view.get", board) != peer || r.Clients() != 2 {
		t.Errorf("a newer version: %+v", next)
	}
}

func TestAttachRefusesAFocusOutsideItsBoards(t *testing.T) {
	r := New()
	_, err := r.Attach(newConn(), current("0.2.0", "studio", []string{"view.get"}, []string{"brd_a"}, "brd_b"))
	failure, _ := err.(*Failure)
	expectFailure(t, failure, api.CodeInvalidParams, "focused names brd_b, which isn't one of boards")
}

func TestCallRelaysTheClientsResultOrError(t *testing.T) {
	r := New()
	conn := newConn()
	c := attach(t, r, conn, current("0.2.0", "studio", []string{"view.get"}, []string{board}, board))
	other := newConn()
	attach(t, r, other, current("0.2.0", "laptop", []string{"view.get"}, []string{board}, ""))

	type outcome struct {
		result  any
		failure *Failure
	}
	call := func() chan outcome {
		out := make(chan outcome, 1)
		go func() {
			result, failure := r.Call(c, "view.get", map[string]any{"board": board}, 5*time.Second)
			out <- outcome{result, failure}
		}()
		return out
	}
	done := call()
	request := conn.request(t)
	if request["method"] != "view.get" || request["params"].(map[string]any)["board"] != board {
		t.Fatalf("request %v", request)
	}
	// Another client's line with the same id isn't the answer.
	r.Answer(other, map[string]any{"id": request["id"], "ok": true, "result": map[string]any{"from": "laptop"}})
	if !r.Answer(conn, map[string]any{"id": request["id"], "ok": true, "result": map[string]any{"visible": true}}) {
		t.Fatal("the answer wasn't taken")
	}
	got := <-done
	if got.failure != nil || got.result.(map[string]any)["visible"] != true {
		t.Fatalf("result %+v", got)
	}

	done = call()
	request = conn.request(t)
	r.Answer(conn, map[string]any{"id": request["id"], "ok": false, "error": map[string]any{"code": "conflict", "message": "the window is closing"}})
	got = <-done
	expectFailure(t, got.failure, "conflict", "the window is closing")

	// A line with `ok` that answers nothing forwarded is a request for the router.
	if r.Answer(conn, map[string]any{"id": "r1", "ok": true}) || r.Answer(conn, map[string]any{"id": "easld-1", "method": "board.get", "ok": true}) {
		t.Fatal("took a line that answers no forwarded call")
	}
}

func TestCallFailsUnavailableAtItsDeadlineAndDropsTheLateAnswer(t *testing.T) {
	r := New()
	conn := newConn()
	c := attach(t, r, conn, current("0.2.0", "studio", []string{"view.get"}, []string{board}, board))
	start := time.Now()
	_, failure := r.Call(c, "view.get", map[string]any{"board": board}, 50*time.Millisecond)
	if elapsed := time.Since(start); elapsed < 50*time.Millisecond {
		t.Errorf("gave up after %v", elapsed)
	}
	expectFailure(t, failure, api.CodeUnavailable, "easl 0.2.0 on studio (client "+c.ID+") didn't answer view.get within 0.05 s")
	request := conn.request(t)
	if !r.Answer(conn, map[string]any{"id": request["id"], "ok": true, "result": map[string]any{}}) {
		t.Fatal("the late answer went on to the router")
	}

	// The next call waits for its own answer.
	done := make(chan *Failure, 1)
	go func() {
		_, failure := r.Call(c, "view.get", map[string]any{"board": board}, 5*time.Second)
		done <- failure
	}()
	next := conn.request(t)
	if next["id"] == request["id"] {
		t.Fatalf("an id was used twice: %v", next["id"])
	}
	r.Answer(conn, map[string]any{"id": next["id"], "ok": true, "result": map[string]any{}})
	if failure := <-done; failure != nil {
		t.Fatal(failure)
	}
}

func TestCallFailsUnavailableWhenTheClientDisconnects(t *testing.T) {
	r := New()
	conn := newConn()
	c := attach(t, r, conn, current("0.2.0", "studio", []string{"view.render"}, []string{board}, board))
	done := make(chan *Failure, 1)
	go func() {
		_, failure := r.Call(c, "view.render", map[string]any{"board": board}, time.Minute)
		done <- failure
	}()
	conn.request(t)
	conn.hangUp()
	select {
	case failure := <-done:
		expectFailure(t, failure, api.CodeUnavailable, "easl 0.2.0 on studio (client "+c.ID+") disconnected before answering view.render")
	case <-time.After(5 * time.Second):
		t.Fatal("the call outlived its client")
	}
	// The client is gone: it isn't chosen, and a call already holding it fails at once.
	for deadline := time.Now().Add(5 * time.Second); r.Choose("view.render", board) != nil; {
		if time.Now().After(deadline) {
			t.Fatal("the client stayed attached")
		}
		time.Sleep(time.Millisecond)
	}
	_, failure := r.Call(c, "view.render", map[string]any{"board": board}, time.Minute)
	expectFailure(t, failure, api.CodeUnavailable, "easl 0.2.0 on studio (client "+c.ID+") disconnected before answering view.render")
}

func TestMeasureTextFallsBackToTheGlyphTableWhenTheClientMissesItsDeadline(t *testing.T) {
	r := New()
	r.MeasureDeadline = 50 * time.Millisecond
	conn := newConn()
	attach(t, r, conn, current("0.2.0", "studio", []string{"text.measure"}, nil, ""))
	items := []measure.TextItem{{Kind: "arrowLabel", Text: "input"}}
	got := r.MeasureText(items)
	if want := textmeasure.Approximate(items); got[0] != want[0] || !got[0].Approximate {
		t.Fatalf("got %+v, want the glyph table's %+v", got, want)
	}
	conn.request(t)

	// Answered in time, the client's size is exact, and an arrow label's is kept: asked once.
	r.MeasureDeadline = 5 * time.Second
	go func() {
		request := <-conn.sent
		r.Answer(conn, map[string]any{"id": request["id"], "ok": true, "result": map[string]any{"sizes": []any{map[string]any{"w": 61.0, "h": 26.0}}}})
	}()
	exact := measure.TextSize{W: 61, H: 26}
	if got := r.MeasureText(items); got[0] != exact {
		t.Fatalf("got %+v, want the client's %+v", got, exact)
	}
	if got := r.MeasureText(items); got[0] != exact || len(conn.sent) != 0 {
		t.Fatalf("got %+v, asked again: %d", got, len(conn.sent))
	}
}

// The client protocol over a real socket: a client's answer arrives while its own request waits
// for it (object.measure holding a board while the client measures). The server reads answers
// off the connection as they come, so the request gets the client's exact size, not the glyph
// table's after MeasureDeadline.
func TestAnAnswerIsNotQueuedBehindTheClientsOwnRequest(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "ecli")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	r := New()
	r.MeasureDeadline = time.Minute
	handle := func(req any, c *server.Conn) any {
		m := req.(map[string]any)
		switch m["method"] {
		case "attach":
			if _, err := r.Attach(c, current("0.2.0", "studio", []string{"text.measure"}, nil, "")); err != nil {
				return map[string]any{"id": m["id"], "ok": false, "error": map[string]any{"code": "internal", "message": err.Error()}}
			}
			return map[string]any{"id": m["id"], "ok": true, "result": map[string]any{}}
		default:
			size := r.MeasureText([]measure.TextItem{{Kind: "text", Text: "Label text"}})[0]
			return map[string]any{"id": m["id"], "ok": true, "result": map[string]any{"w": size.W, "h": size.H, "approximate": size.Approximate}}
		}
	}
	srv, err := server.Listen(filepath.Join(dir, "s.sock"), handle, func(c *server.Conn, line map[string]any) bool { return r.Answer(c, line) })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	nc, err := net.Dial("unix", srv.Path())
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	nc.SetDeadline(time.Now().Add(10 * time.Second))
	lines := bufio.NewScanner(nc)
	write := func(v any) {
		t.Helper()
		data, _ := json.Marshal(v)
		if _, err := nc.Write(append(data, '\n')); err != nil {
			t.Fatal(err)
		}
	}
	read := func() map[string]any {
		t.Helper()
		if !lines.Scan() {
			t.Fatalf("connection ended: %v", lines.Err())
		}
		var m map[string]any
		if err := json.Unmarshal(lines.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		return m
	}

	write(map[string]any{"id": "r1", "method": "attach"})
	if reply := read(); reply["ok"] != true {
		t.Fatalf("attach: %v", reply)
	}
	write(map[string]any{"id": "r2", "method": "object.measure"})
	request := read()
	if request["method"] != "text.measure" {
		t.Fatalf("expected the server's text.measure, got %v", request)
	}
	write(map[string]any{"id": request["id"], "ok": true, "result": map[string]any{"sizes": []any{map[string]any{"w": 98, "h": 28}}}})
	reply := read()
	result, _ := reply["result"].(map[string]any)
	if reply["id"] != "r2" || result["w"] != 98.0 || result["h"] != 28.0 || result["approximate"] != false {
		t.Fatalf("the client's own request got %v, want the size it answered", reply)
	}
}
