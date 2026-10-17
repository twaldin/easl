package router

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/jpeg"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
)

// A 1×1 PNG. view.render tests and the conformance scenarios share it.
const pixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

func sizeAnswer(w, h float64, approximate any) map[string]any {
	result := map[string]any{"w": w, "h": h}
	if approximate != nil {
		result["approximate"] = approximate
	}
	return map[string]any{"ok": true, "result": result}
}

func pixelAnswer() map[string]any {
	return map[string]any{"ok": true, "result": map[string]any{
		"data": pixelPNG, "format": "png", "width": 1.0, "height": 1.0, "scale": 2.0, "objects": []any{},
	}}
}

func htmlProps(body string) map[string]any {
	return map[string]any{"html": body}
}

func htmlCreate(body string, frame map[string]any) map[string]any {
	return map[string]any{"type": "html", "props": htmlProps(body), "frame": frame}
}

func frameOf(result map[string]any) map[string]any {
	return result["object"].(map[string]any)["frame"].(map[string]any)
}

func attachApp(f *fixture, app Conn, params map[string]any) string {
	f.t.Helper()
	if params == nil {
		params = map[string]any{}
	}
	params["version"] = float64(api.SchemaVersion)
	params["schema"] = api.SchemaHash
	if _, ok := params["serves"]; !ok {
		params["serves"] = []any{"object.measure", "view.render", "object.reload"}
	}
	if _, ok := params["boards"]; !ok {
		params["boards"] = []any{f.board.ID()}
	}
	attached := f.router.HandleConn(map[string]any{"id": "attach", "method": "client.attach", "params": params}, app).(map[string]any)
	if attached["ok"] != true {
		f.t.Fatalf("client.attach: %v", attached)
	}
	return attached["result"].(map[string]any)["client"].(string)
}

func askedParams(c *scriptedClient) []map[string]any {
	out := make([]map[string]any, len(c.asked))
	for i, req := range c.asked {
		out[i] = req["params"].(map[string]any)
	}
	return out
}

// gateClient answers one forwarded call after the test has used the board.
type gateClient struct {
	router  *Router
	reply   map[string]any
	got     chan struct{}
	release chan struct{}
}

func (c *gateClient) Send(v any) bool {
	request, _ := v.(map[string]any)
	if _, ok := request["method"]; !ok {
		return true
	}
	c.got <- struct{}{}
	<-c.release
	reply := map[string]any{}
	for k, val := range c.reply {
		reply[k] = val
	}
	reply["id"] = request["id"]
	c.router.clients.Answer(c, reply)
	return true
}

func (c *gateClient) IsOpen() bool          { return true }
func (c *gateClient) Done() <-chan struct{} { return nil }

func TestHTMLMeasureReturnsTheClientSizeWithoutLockingTheBoard(t *testing.T) {
	f := newFixture(t)
	code, message := errorOf(f.call("object.measure", map[string]any{"type": "html", "props": htmlProps("<p>Hi</p>")}))
	if code != "unavailable" || message != "an html page is measured by the app" {
		t.Fatalf("no client: %s %s", code, message)
	}
	other, _ := f.openBoard("other")
	elsewhere := &scriptedClient{router: f.router, replies: []map[string]any{sizeAnswer(1, 1, nil)}}
	attachApp(f, elsewhere, map[string]any{"serves": []any{"object.measure"}, "boards": []any{other}, "focused": other})
	code, message = errorOf(f.call("object.measure", map[string]any{"type": "html", "props": htmlProps("<p>Hi</p>")}))
	if code != "unavailable" || message != "an html page is measured by the app" || len(elsewhere.asked) != 0 {
		t.Fatalf("a client on another board: %s %s asked %d", code, message, len(elsewhere.asked))
	}

	gate := &gateClient{router: f.router, got: make(chan struct{}), release: make(chan struct{}), reply: sizeAnswer(640, 120, nil)}
	attachApp(f, gate, map[string]any{"app": "0.2.0", "host": "studio", "focused": f.board.ID()})
	done := make(chan map[string]any, 1)
	go func() {
		done <- f.call("object.measure", map[string]any{"type": "html", "props": htmlProps("<p>Hi</p>"), "width": 800.0})
	}()
	select {
	case <-gate.got:
	case <-time.After(2 * time.Second):
		t.Fatal("html measure did not reach the client")
	}
	side := f.router.HandleConn(map[string]any{"id": "side", "method": "object.create", "params": note(0, map[string]any{"markdown": "while measuring"})}, f.conn).(map[string]any)
	if side["ok"] != true {
		t.Fatalf("the board stayed locked during html measure: %v", side)
	}
	close(gate.release)
	var reply map[string]any
	select {
	case reply = <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("html measure did not finish")
	}
	if reply["ok"] != true || !reflect.DeepEqual(reply["result"], map[string]any{"w": 640.0, "h": 120.0}) {
		t.Fatalf("read-only measure = %v, want the client's size with no approximate", reply)
	}

	app := &scriptedClient{router: f.router, replies: []map[string]any{
		sizeAnswer(800, 210, false),
		sizeAnswer(800, 210, true),
		{"ok": false, "error": map[string]any{"code": "unavailable", "message": "the page didn't render"}},
		sizeAnswer(0, 10, nil),
		sizeAnswer(math.NaN(), 10, nil),
	}}
	attachApp(f, app, map[string]any{"app": "0.2.0", "host": "studio", "focused": f.board.ID()})
	props := map[string]any{"html": "<p>Hi</p>", "root": "sub", "zoom": 2.0}
	got := f.result("object.measure", map[string]any{"type": "html", "props": props, "width": 800.0})
	if !reflect.DeepEqual(got, map[string]any{"w": 800.0, "h": 210.0}) {
		t.Fatalf("exact = %v", got)
	}
	got = f.result("object.measure", map[string]any{"type": "html", "props": htmlProps("<p>Hi</p>")})
	if !reflect.DeepEqual(got, map[string]any{"w": 800.0, "h": 210.0, "approximate": true}) {
		t.Fatalf("approximate = %v", got)
	}
	code, message = errorOf(f.call("object.measure", map[string]any{"type": "html", "props": htmlProps("<p>Hi</p>")}))
	if code != "unavailable" || message != "the page didn't render" {
		t.Fatalf("client error: %s %s", code, message)
	}
	for _, label := range []string{"zero", "nan"} {
		code, message = errorOf(f.call("object.measure", map[string]any{"type": "html", "props": htmlProps("<p>Hi</p>")}))
		if code != "internal" || !strings.Contains(message, "not a positive finite size") {
			t.Fatalf("%s: %s %s", label, code, message)
		}
	}
	wantRoot := filepath.Join(f.board.Root(), "sub")
	if !reflect.DeepEqual(askedParams(app)[0], map[string]any{
		"board": f.board.ID(), "type": "html", "width": 800.0,
		"props": map[string]any{"html": "<p>Hi</p>", "root": wantRoot, "zoom": 2.0},
	}) {
		t.Fatalf("forwarded %#v", askedParams(app)[0])
	}
	if _, ok := askedParams(app)[1]["width"]; ok {
		t.Fatalf("an omitted width was forwarded: %#v", askedParams(app)[1])
	}
}

func TestHTMLFitUsesTheClientFrameAndRejectsAStaleInput(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", htmlCreate("<p>Hi</p>", map[string]any{"x": 10.0, "y": 20.0, "w": 400.0, "h": 300.0})))
	code, message := errorOf(f.call("object.update", map[string]any{"id": id, "size": "fit"}))
	if code != "unavailable" || message != "an html page is measured by the app" {
		t.Fatalf("update with no client: %s %s", code, message)
	}

	app := &scriptedClient{router: f.router, replies: []map[string]any{
		sizeAnswer(640, 180, nil),
		sizeAnswer(500, 90, nil),
		sizeAnswer(320, 70, nil),
		sizeAnswer(640, 80, nil),
	}}
	attachApp(f, app, map[string]any{"app": "0.2.0", "host": "studio", "focused": f.board.ID()})
	created := f.result("object.create", map[string]any{
		"type": "html", "size": "fit",
		"props": map[string]any{"html": "<p>Fit</p>", "zoom": 2.0},
		"frame": map[string]any{"x": 10000.0, "y": 0.0, "w": 800.0},
	})
	if !reflect.DeepEqual(frameOf(created), map[string]any{"x": 10000.0, "y": 0.0, "w": 640.0, "h": 180.0}) || created["approximate"] != nil {
		t.Fatalf("create fit = %v", created)
	}
	if askedParams(app)[0]["width"] != 800.0 || askedParams(app)[0]["props"].(map[string]any)["zoom"] != 2.0 {
		t.Fatalf("width was rewritten: %#v", askedParams(app)[0])
	}
	updated := f.result("object.update", map[string]any{"id": id, "size": "fit", "frame": map[string]any{"w": 500.0}})
	if !reflect.DeepEqual(frameOf(updated), map[string]any{"x": 10.0, "y": 20.0, "w": 500.0, "h": 90.0}) {
		t.Fatalf("update fit = %v", frameOf(updated))
	}
	batch := f.result("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": htmlCreate("<p>pending</p>", map[string]any{"x": 0.0, "y": 400.0, "w": 320.0, "h": 200.0})},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "$0", "size": "fit", "frame": map[string]any{"x": 0.0, "y": 400.0}}},
	}})
	fitted := batch["results"].([]any)[1].(map[string]any)
	if !reflect.DeepEqual(frameOf(fitted), map[string]any{"x": 0.0, "y": 400.0, "w": 320.0, "h": 70.0}) {
		t.Fatalf("pending ref fit = %v", frameOf(fitted))
	}
	if askedParams(app)[2]["props"].(map[string]any)["html"] != "<p>pending</p>" || askedParams(app)[2]["width"] != 320.0 {
		t.Fatalf("pending props = %#v", askedParams(app)[2])
	}
	upserted := f.result("object.upsert", map[string]any{
		"key": "page", "type": "html", "size": "fit", "props": htmlProps("<p>Upsert</p>"),
		"frame": map[string]any{"x": 0.0, "y": 1600.0, "w": 640.0},
	})
	if upserted["created"] != true || !reflect.DeepEqual(frameOf(upserted), map[string]any{"x": 0.0, "y": 1600.0, "w": 640.0, "h": 80.0}) {
		t.Fatalf("upsert fit = %v", upserted)
	}

	stale := &scriptedClient{router: f.router, replies: []map[string]any{sizeAnswer(900, 400, nil)}}
	stale.during = func() {
		f.result("object.update", map[string]any{"id": id, "props": map[string]any{"title": "moved"}})
	}
	attachApp(f, stale, map[string]any{"focused": f.board.ID()})
	before := f.board.Objects()[id].Frame
	code, message = errorOf(f.call("object.update", map[string]any{"id": id, "size": "fit"}))
	if code != "conflict" || !strings.Contains(message, id) || !strings.Contains(message, "changed while its html page was measured") {
		t.Fatalf("stale object: %s %s", code, message)
	}
	if f.board.Objects()[id].Frame != before || f.board.Objects()[id].Props["title"] != "moved" {
		t.Fatalf("stale fit wrote the frame: %+v", f.board.Objects()[id].Frame)
	}

	gone := &scriptedClient{router: f.router, replies: []map[string]any{sizeAnswer(640, 100, nil)}}
	gone.during = func() { f.call("board.close", map[string]any{"board": f.board.ID()}) }
	attachApp(f, gone, map[string]any{"boards": []any{f.board.ID()}, "focused": f.board.ID()})
	n := len(f.board.Objects())
	code, message = errorOf(f.call("object.create", map[string]any{
		"type": "html", "size": "fit", "props": htmlProps("<p>late</p>"),
		"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 400.0},
	}))
	if code != "conflict" || !strings.Contains(message, "changed identity") || len(f.board.Objects()) != n {
		t.Fatalf("replaced board: %s %s objects %d", code, message, len(f.board.Objects()))
	}
}

func TestHTMLBatchKeepsUnrelatedEditsAndConflictsOnReadObjects(t *testing.T) {
	f := newFixture(t)
	spare := idOf(f.result("object.create", note(0, map[string]any{"markdown": "spare"})))
	noteID := idOf(f.result("object.create", note(300, map[string]any{"markdown": "plan"})))
	app := &scriptedClient{router: f.router, replies: []map[string]any{
		sizeAnswer(640, 150, nil),
		sizeAnswer(640, 160, nil),
	}}
	var during int
	app.during = func() {
		during++
		if during == 1 {
			f.result("object.update", map[string]any{"id": spare, "props": map[string]any{"markdown": "spare moved"}})
			return
		}
		f.result("object.update", map[string]any{"id": noteID, "props": map[string]any{"markdown": "note moved"}})
	}
	attachApp(f, app, map[string]any{"focused": f.board.ID()})
	ok := f.result("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": map[string]any{
			"type": "html", "size": "fit", "props": htmlProps("<p>batch</p>"),
			"frame": map[string]any{"x": 0.0, "y": 800.0, "w": 640.0},
		}},
	}})
	if frameOf(ok["results"].([]any)[0].(map[string]any))["h"] != 150.0 || f.board.Objects()[spare].Props["markdown"] != "spare moved" {
		t.Fatalf("unrelated edit failed the batch: %v", ok)
	}
	code, message := errorOf(f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.update", "params": map[string]any{"id": noteID, "props": map[string]any{"markdown": "batch text"}}},
		map[string]any{"method": "object.create", "params": map[string]any{
			"type": "html", "size": "fit", "props": htmlProps("<p>second</p>"),
			"frame": map[string]any{"x": 0.0, "y": 1200.0, "w": 640.0},
		}},
	}}))
	if code != "conflict" || !strings.Contains(message, noteID) || !strings.Contains(message, "changed while its html page was measured") {
		t.Fatalf("read object: %s %s", code, message)
	}
	if f.board.Objects()[noteID].Props["markdown"] != "note moved" {
		t.Fatalf("the batch applied over the newer note: %v", f.board.Objects()[noteID].Props["markdown"])
	}
	for _, o := range f.board.Objects() {
		if o.Type == "html" && o.Props["html"] == "<p>second</p>" {
			t.Fatal("the conflicted batch created the html tile")
		}
	}
}

func TestViewRenderWritesTheDaemonFileAndRelaysTargetErrors(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", note(0, map[string]any{"markdown": "draw"})))
	code, message := errorOf(f.call("view.render", map[string]any{"target": id}))
	if code != "unavailable" || !strings.Contains(message, "view.render is drawn by the app, as the user sees the board") {
		t.Fatalf("no client: %s %s", code, message)
	}

	jpg := jpegBytes(t)
	jpegAnswer := map[string]any{"ok": true, "result": map[string]any{
		"data": base64.StdEncoding.EncodeToString(jpg), "format": "jpeg", "width": 1.0, "height": 1.0, "scale": 1.0, "objects": []any{},
	}}
	app := &scriptedClient{router: f.router, replies: []map[string]any{
		pixelAnswer(),
		jpegAnswer,
		jpegAnswer,
		pixelAnswer(),
		{"ok": false, "error": map[string]any{"code": "unavailable", "message": id + " is only a host picture: view.render cannot draw it"}},
		{"ok": true, "result": map[string]any{"data": "not-base64", "format": "png", "width": 1.0, "height": 1.0}},
		{"ok": true, "result": map[string]any{"data": pixelPNG + "!", "format": "png", "width": 1.0, "height": 1.0}},
		{"ok": true, "result": map[string]any{"data": pixelPNG, "format": "png", "width": 9.0, "height": 1.0}},
	}}
	attachApp(f, app, map[string]any{"app": "0.2.0", "host": "studio", "focused": f.board.ID()})

	inline := f.result("view.render", map[string]any{"target": id, "inline": true, "scale": 2.0})
	if inline["data"] != pixelPNG || inline["format"] != "png" || inline["width"] != 1.0 || inline["path"] != nil {
		t.Fatalf("inline = %v", inline)
	}
	if _, ok := askedParams(app)[0]["out"]; ok || askedParams(app)[0]["inline"] != true || askedParams(app)[0]["format"] != "png" {
		t.Fatalf("inline forward = %#v", askedParams(app)[0])
	}

	out := filepath.Join(t.TempDir(), "shot.jpeg")
	wrote := f.result("view.render", map[string]any{"target": id, "out": out, "format": "png"})
	if wrote["path"] != out || wrote["format"] != "jpeg" || wrote["data"] != nil {
		t.Fatalf("file render = %v", wrote)
	}
	if data, err := os.ReadFile(out); err != nil || !bytes.Equal(data, jpg) {
		t.Fatalf("wrote %d bytes, err %v", len(data), err)
	}
	if _, ok := askedParams(app)[1]["out"]; ok || askedParams(app)[1]["format"] != "jpeg" || askedParams(app)[1]["inline"] != true {
		t.Fatalf("jpeg forward = %#v", askedParams(app)[1])
	}

	scratch := f.result("view.render", map[string]any{"target": id, "format": "jpeg"})
	path, _ := scratch["path"].(string)
	if scratch["format"] != "jpeg" || !strings.HasPrefix(path, filepath.Join(os.TempDir(), "easl-renders")) || filepath.Ext(path) != ".jpg" {
		t.Fatalf("scratch = %v", scratch)
	}
	t.Cleanup(func() { os.Remove(path) })
	if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, jpg) {
		t.Fatalf("scratch bytes: %v %d", err, len(data))
	}

	missing := filepath.Join(t.TempDir(), "missing", "shot.png")
	code, message = errorOf(f.call("view.render", map[string]any{"target": id, "out": missing}))
	if code != "unavailable" || !strings.Contains(message, "cannot write "+missing) {
		t.Fatalf("missing dir: %s %s", code, message)
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatalf("a failed write left %s", missing)
	}

	code, message = errorOf(f.call("view.render", map[string]any{"target": id, "out": filepath.Join(t.TempDir(), "nope.png")}))
	if code != "unavailable" || message != id+" is only a host picture: view.render cannot draw it" {
		t.Fatalf("host picture: %s %s", code, message)
	}
	code, message = errorOf(f.call("view.render", map[string]any{"target": id, "inline": true}))
	if code != "internal" || !strings.Contains(message, "not base64") {
		t.Fatalf("bad base64: %s %s", code, message)
	}
	code, message = errorOf(f.call("view.render", map[string]any{"target": id, "inline": true}))
	if code != "internal" || !strings.Contains(message, "not base64") {
		t.Fatalf("bad base64 after the image header: %s %s", code, message)
	}
	code, message = errorOf(f.call("view.render", map[string]any{"target": id, "inline": true}))
	if code != "internal" || !strings.Contains(message, "1×1") || !strings.Contains(message, "not 9×1") {
		t.Fatalf("wrong size: %s %s", code, message)
	}
}

func TestInlineRenderRejectsSeparatelyPaddedFragments(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", note(0, map[string]any{"markdown": "draw"})))
	png, err := base64.StdEncoding.DecodeString(pixelPNG)
	if err != nil {
		t.Fatal(err)
	}
	raw := base64.StdEncoding.EncodeToString(png[:4]) + base64.StdEncoding.EncodeToString(png[4:])
	app := &scriptedClient{router: f.router, replies: []map[string]any{
		{"ok": true, "result": map[string]any{"data": raw, "format": "png", "width": 1.0, "height": 1.0}},
	}}
	attachApp(f, app, nil)
	code, message := errorOf(f.call("view.render", map[string]any{"target": id, "inline": true}))
	if code != "internal" || !strings.Contains(message, "not base64") {
		t.Fatalf("separately padded fragments: %s %s", code, message)
	}
}

func jpegBytes(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 1, 1)), nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestClientListReportsAttachedClients(t *testing.T) {
	f := newFixture(t)
	if got := f.result("client.list", map[string]any{}); len(got["clients"].([]any)) != 0 {
		t.Fatalf("empty = %v", got)
	}
	second, _ := f.openBoard("second")
	studio := &conn{}
	mini := &conn{}
	studioID := attachApp(f, studio, map[string]any{
		"app": "0.2.0", "host": "studio", "focused": f.board.ID(),
		"serves": []any{"view.render", "object.measure", "view.zoom"},
		"boards": []any{second, f.board.ID()},
	})
	miniID := attachApp(f, mini, map[string]any{
		"serves": []any{"object.measure"}, "boards": []any{f.board.ID()},
	})
	attachApp(f, studio, map[string]any{
		"app": "0.2.0", "host": "studio",
		"serves": []any{"view.render", "object.measure"},
		"boards": []any{f.board.ID(), second},
	})
	boards := []string{f.board.ID(), second}
	sort.Strings(boards)
	want := []any{
		map[string]any{"id": studioID, "app": "0.2.0", "host": "studio", "focused": f.board.ID(), "boards": boards, "serves": []string{"object.measure", "view.render"}},
		map[string]any{"id": miniID, "boards": []string{f.board.ID()}, "serves": []string{"object.measure"}},
	}
	if studioID > miniID {
		want[0], want[1] = want[1], want[0]
	}
	got := f.result("client.list", map[string]any{})["clients"]
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("clients = %#v\nwant %#v", got, want)
	}
}
