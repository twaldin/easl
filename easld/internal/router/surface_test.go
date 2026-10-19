package router

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
)

// surfaceViewer is a viewer's connection, which also carries relayed event lines as they are
// (server.Conn.SendLine).
type surfaceViewer struct {
	*conn
	lines chan string
}

func newSurfaceViewer(t *testing.T, f *fixture, events ...any) *surfaceViewer {
	t.Helper()
	v := &surfaceViewer{conn: &conn{}, lines: make(chan string, 16)}
	t.Cleanup(v.close)
	if len(events) > 0 {
		f.as(v, "events.subscribe", map[string]any{"board": f.board.ID(), "events": events})
	}
	return v
}

func (v *surfaceViewer) SendLine(line []byte) bool {
	if !v.IsOpen() {
		return false
	}
	v.lines <- string(line)
	return true
}

func (v *surfaceViewer) relayed() []string {
	var out []string
	for len(v.lines) > 0 {
		out = append(out, <-v.lines)
	}
	return out
}

// closed is the reason of each closed notice easld sent v, by stream.
func (v *surfaceViewer) closed() map[string]any {
	out := map[string]any{}
	for _, m := range v.messages() {
		if data, _ := m["data"].(map[string]any); m["event"] == "surface.notice" && data["kind"] == "closed" {
			out[data["stream"].(string)] = data["reason"]
		}
	}
	return out
}

var allSurfaceEvents = []any{"surface.frame", "surface.dialog", "surface.notice"}

// attachDrawer is a Mac that draws identity's browser tiles on the fixture's board.
func attachDrawer(t *testing.T, f *fixture, identity string) *diagramPeer {
	t.Helper()
	peer := &diagramPeer{conn: &conn{}, incoming: make(chan map[string]any, 64)}
	t.Cleanup(peer.close)
	reply := f.as(peer, "client.attach", map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash, "host": "home", "identity": identity,
		"serves": []any{"browser.call", "surface.stream", "surface.ack", "surface.input", "surface.answer", "surface.stop"},
		"boards": []any{f.board.ID()},
	})
	if reply["ok"] != true {
		t.Fatalf("client.attach: %v", reply)
	}
	return peer
}

func surfaceTile(f *fixture, machine string) string {
	return idOf(f.result("object.create", map[string]any{
		"type": "browser", "frame": browserFrame(),
		"props": map[string]any{"url": "https://example.com/", "drawingMachine": map[string]any{"id": machine, "host": "home"}},
	}))
}

// onSurface is v's surface call, answered once it is.
func (f *fixture) onSurface(v *surfaceViewer, method string, params map[string]any) <-chan map[string]any {
	done := make(chan map[string]any, 1)
	go func() {
		done <- f.router.HandleConn(map[string]any{"id": method, "method": method, "params": params}, v).(map[string]any)
	}()
	return done
}

func surfaceReply(t *testing.T, done <-chan map[string]any) map[string]any {
	t.Helper()
	select {
	case reply := <-done:
		return reply
	case <-time.After(5 * time.Second):
		t.Fatal("no reply")
		return nil
	}
}

func answerSurface(f *fixture, drawer *diagramPeer, request map[string]any, result any) {
	f.router.clients.Answer(drawer, map[string]any{"id": request["id"], "ok": true, "result": result})
}

// liveSurface is v's stream of tile, which drawer answered as stream.
func liveSurface(t *testing.T, f *fixture, v *surfaceViewer, drawer *diagramPeer, tile, stream string) {
	t.Helper()
	opened := f.onSurface(v, "surface.stream", map[string]any{"id": tile})
	answerSurface(f, drawer, diagramMessage(t, drawer.incoming), map[string]any{"stream": stream})
	if reply := surfaceReply(t, opened); reply["ok"] != true {
		t.Fatalf("open %s: %v", stream, reply)
	}
}

func expectSurfaceStop(t *testing.T, drawer *diagramPeer, stream string) {
	t.Helper()
	if request := diagramMessage(t, drawer.incoming); request["method"] != "surface.stop" || !reflect.DeepEqual(request["params"], map[string]any{"stream": stream}) {
		t.Fatalf("the drawing Mac was asked %v, want surface.stop of %s", request, stream)
	}
}

func surfaceFrame(board, stream string) string {
	return `{"event":"surface.frame","board":"` + board + `","data":{"stream":"` + stream + `","seq":1,"data":"iVBORw0K\/Gg=="}}`
}

// A viewer streams a tile through easld as on a Mac host: a malformed request, a tile that isn't
// a browser or has no Mac online, and a viewer that doesn't hear surface.frame on the tile's
// board are refused before any Mac is asked. A frame-only viewer opens, and its Mac learns it
// hears nothing else. Its ack reaches the Mac while the boards are busy.
func TestSurfaceStreamThroughEasldIsCheckedThenGoesToTheDrawingMac(t *testing.T) {
	f := newFixture(t)
	drawer := attachDrawer(t, f, "mch_home")
	page := surfaceTile(f, "mch_home")
	offline := surfaceTile(f, "mch_gone")
	text := idOf(f.result("object.create", note(0, map[string]any{"markdown": "not a page"})))
	viewer := newSurfaceViewer(t, f)
	f.as(viewer, "events.subscribe", map[string]any{"events": []any{"surface.frame"}})
	board := f.board.ID()
	for _, c := range []struct {
		params        map[string]any
		code, message string
	}{
		{map[string]any{"id": page}, "invalid_params", fmt.Sprintf("subscribe this connection to surface.frame on board %s (events.subscribe) before surface.stream", board)},
		{map[string]any{"id": page, "scale": 0.0}, "invalid_params", "scale must be above 0 and at most 2.0"},
		{map[string]any{"id": page, "format": "gif"}, "invalid_params", "format must be jpeg or png"},
		{map[string]any{"id": "page"}, "invalid_params", "id page is not an object id"},
	} {
		if code, message := errorOf(f.as(viewer, "surface.stream", c.params)); code != c.code || message != c.message {
			t.Errorf("%v: %s %q, want %s %q", c.params, code, message, c.code, c.message)
		}
	}
	f.as(viewer, "events.subscribe", map[string]any{"board": board, "events": []any{"surface.frame"}})
	for _, c := range []struct {
		id, code, message string
	}{
		{text, "not_found", text + " is not a browser tile"},
		{offline, "unavailable", "draws on home, which is offline"},
	} {
		if code, message := errorOf(f.as(viewer, "surface.stream", map[string]any{"id": c.id})); code != c.code || message != c.message {
			t.Errorf("%s: %s %q, want %s %q", c.id, code, message, c.code, c.message)
		}
	}
	if code, message := errorOf(f.call("surface.stream", map[string]any{"id": page})); code != "unsupported" {
		t.Errorf("a connection that can't carry lines: %s %q", code, message)
	}
	if len(drawer.incoming) != 0 {
		t.Fatalf("a refused open reached the Mac: %v", <-drawer.incoming)
	}

	observer := newSurfaceViewer(t, f, allSurfaceEvents...)
	params := map[string]any{"id": page, "scale": 2.0, "format": "png"}
	opened := f.onSurface(viewer, "surface.stream", params)
	request := diagramMessage(t, drawer.incoming)
	if request["method"] != "surface.stream" || !reflect.DeepEqual(request["params"], params) || !reflect.DeepEqual(request["surfaceEvents"], []string{"surface.frame"}) {
		t.Fatalf("the Mac was asked %v", request)
	}
	answered := map[string]any{"stream": "str_1", "size": map[string]any{"w": 600.0, "h": 400.0}, "scale": 2.0}
	answerSurface(f, drawer, request, answered)
	if reply := surfaceReply(t, opened); reply["ok"] != true || !reflect.DeepEqual(reply["result"], answered) {
		t.Fatalf("open: %v", reply)
	}

	f.router.reg.Mu.Lock()
	acked := f.onSurface(viewer, "surface.ack", map[string]any{"stream": "str_1", "frame": 0.0})
	request = diagramMessage(t, drawer.incoming)
	answerSurface(f, drawer, request, map[string]any{})
	reply := surfaceReply(t, acked)
	f.router.reg.Mu.Unlock()
	if request["method"] != "surface.ack" || !reflect.DeepEqual(request["params"], map[string]any{"stream": "str_1", "frame": 0.0}) || reply["ok"] != true {
		t.Fatalf("ack reached the Mac as %v and answered %v", request, reply)
	}

	dialog := `{"event":"surface.dialog","board":"` + board + `","data":{"stream":"str_1","dialog":"dlg_1","kind":"confirm","origin":"x"}}`
	f.router.surfaces.Push(drawer, []byte(surfaceFrame(board, "str_1")))
	f.router.surfaces.Push(drawer, []byte(dialog))
	if got := viewer.relayed(); !reflect.DeepEqual(got, []string{surfaceFrame(board, "str_1")}) {
		t.Fatalf("the frame-only viewer got %v", got)
	}
	if got, messages := observer.relayed(), observer.messages(); len(got) != 0 || len(messages) != 1 {
		t.Fatalf("another subscriber of the board got %v, and was sent %v besides its subscription", got, messages)
	}
}

// Moving a tile's drawing away and back while a stream of it opens doesn't revive that open:
// the Mac's stream is stopped as it answers. A live stream ends with "drawing moved". A new
// open goes live.
func TestMovingTheDrawingAwayAndBackEndsItsStreamsForGood(t *testing.T) {
	f := newFixture(t)
	drawer := attachDrawer(t, f, "mch_home")
	page := surfaceTile(f, "mch_home")
	viewer := newSurfaceViewer(t, f, allSurfaceEvents...)
	liveSurface(t, f, viewer, drawer, page, "str_1")
	opened := f.onSurface(viewer, "surface.stream", map[string]any{"id": page})
	request := diagramMessage(t, drawer.incoming)
	for _, machine := range []string{"mch_away", "mch_home"} {
		f.result("object.update", map[string]any{"id": page, "props": map[string]any{"drawingMachine": map[string]any{"id": machine, "host": "home"}}})
	}
	expectSurfaceStop(t, drawer, "str_1")
	answerSurface(f, drawer, request, map[string]any{"stream": "str_2"})
	if code, message := errorOf(surfaceReply(t, opened)); code != "unavailable" || message != page+"'s stream ended as it opened: drawing moved" {
		t.Fatalf("the open answered %s %q", code, message)
	}
	expectSurfaceStop(t, drawer, "str_2")
	if got := viewer.closed(); !reflect.DeepEqual(got, map[string]any{"str_1": "drawing moved"}) {
		t.Fatalf("closed notices %v", got)
	}
	for _, stream := range []string{"str_1", "str_2"} {
		f.router.surfaces.Push(drawer, []byte(surfaceFrame(f.board.ID(), stream)))
	}
	if got := viewer.relayed(); len(got) != 0 {
		t.Fatalf("ended streams relayed %v", got)
	}
	liveSurface(t, f, viewer, drawer, page, "str_3")
}

// Closing a board ends its streams, live and opening; opening it again revives none.
func TestBoardCloseEndsStreamsAndReopeningRevivesNone(t *testing.T) {
	f := newFixture(t)
	drawer := attachDrawer(t, f, "mch_home")
	page := surfaceTile(f, "mch_home")
	viewer := newSurfaceViewer(t, f, allSurfaceEvents...)
	liveSurface(t, f, viewer, drawer, page, "str_1")
	opened := f.onSurface(viewer, "surface.stream", map[string]any{"id": page})
	request := diagramMessage(t, drawer.incoming)
	f.result("board.close", map[string]any{"board": f.board.ID()})
	f.result("board.open", map[string]any{"root": f.board.Root()})
	answerSurface(f, drawer, request, map[string]any{"stream": "str_2"})
	if code, _ := errorOf(surfaceReply(t, opened)); code != "unavailable" {
		t.Fatalf("the open answered %s", code)
	}
	for _, stream := range []string{"str_1", "str_2"} {
		done := f.onSurface(viewer, "surface.ack", map[string]any{"stream": stream, "frame": 0.0})
		if code, _ := errorOf(surfaceReply(t, done)); code != "not_found" {
			t.Fatalf("reopened board revived %s: %s", stream, code)
		}
		f.router.surfaces.Push(drawer, []byte(surfaceFrame(f.board.ID(), stream)))
	}
	if len(viewer.relayed()) != 0 {
		t.Fatal("reopened board relayed a retired stream")
	}
	if got := viewer.closed(); !reflect.DeepEqual(got, map[string]any{"str_1": "board closed"}) {
		t.Fatalf("closed notices %v", got)
	}
}

// Deleting a streamed tile ends its stream.
func TestDeletingATileEndsItsStream(t *testing.T) {
	f := newFixture(t)
	drawer := attachDrawer(t, f, "mch_home")
	page := surfaceTile(f, "mch_home")
	viewer := newSurfaceViewer(t, f, allSurfaceEvents...)
	liveSurface(t, f, viewer, drawer, page, "str_1")
	f.result("object.delete", map[string]any{"id": page})
	expectSurfaceStop(t, drawer, "str_1")
	if got := viewer.closed(); !reflect.DeepEqual(got, map[string]any{"str_1": "tile closed"}) {
		t.Fatalf("closed notices %v", got)
	}
	if code, _ := errorOf(f.as(viewer, "surface.ack", map[string]any{"stream": "str_1", "frame": 0.0})); code != "not_found" {
		t.Fatalf("an ack of the deleted tile's stream: %s", code)
	}
}

// A stream belongs to the link it was opened on: a newer link of the same Mac ends it (the stop
// goes to the old link) and takes the next open, the old link's pushes for that one go nowhere,
// and the newer link going away ends it too.
func TestAStreamEndsWithTheLinkItWasOpenedOn(t *testing.T) {
	f := newFixture(t)
	old := attachDrawer(t, f, "mch_home")
	page := surfaceTile(f, "mch_home")
	viewer := newSurfaceViewer(t, f, allSurfaceEvents...)
	liveSurface(t, f, viewer, old, page, "str_1")
	newer := attachDrawer(t, f, "mch_home")
	expectSurfaceStop(t, old, "str_1")
	if got := viewer.closed(); !reflect.DeepEqual(got, map[string]any{"str_1": "drawing machine offline"}) {
		t.Fatalf("closed notices %v", got)
	}
	liveSurface(t, f, viewer, newer, page, "str_2")
	f.router.surfaces.Push(old, []byte(surfaceFrame(f.board.ID(), "str_2")))
	f.router.surfaces.Push(newer, []byte(surfaceFrame(f.board.ID(), "str_2")))
	if got := viewer.relayed(); !reflect.DeepEqual(got, []string{surfaceFrame(f.board.ID(), "str_2")}) {
		t.Fatalf("relayed %v, want the newer link's frame only", got)
	}
	newer.close()
	for deadline := time.Now().Add(5 * time.Second); viewer.closed()["str_2"] != "drawing machine offline"; {
		if time.Now().After(deadline) {
			t.Fatalf("closed notices %v after the link went away", viewer.closed())
		}
		time.Sleep(5 * time.Millisecond)
	}
	if len(old.incoming) != 0 {
		t.Fatalf("the old link was asked %v", <-old.incoming)
	}
}
