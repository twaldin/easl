package router

import (
	"fmt"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
)

func (f *fixture) as(c Conn, method string, params map[string]any) map[string]any {
	f.seq++
	reply := f.router.HandleConn(map[string]any{"id": fmt.Sprintf("r%d", f.seq), "method": method, "params": params}, c)
	if reply == nil {
		return nil
	}
	return reply.(map[string]any)
}

func attachDrawing(f *fixture, c *scriptedClient, identity, host string, focused bool, serves ...string) {
	f.t.Helper()
	names := make([]any, len(serves))
	for i, s := range serves {
		names[i] = s
	}
	params := map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash,
		"app": "0.2.0", "host": host, "identity": identity,
		"serves": names, "boards": []any{f.board.ID()},
	}
	if focused {
		params["focused"] = f.board.ID()
	}
	reply := f.as(c, "client.attach", params)
	if reply["ok"] != true {
		f.t.Fatalf("client.attach: %v", reply)
	}
}

func browserFrame() map[string]any {
	return map[string]any{"x": 0.0, "y": 0.0, "w": 600.0, "h": 400.0}
}

func drawingOfResult(t *testing.T, object map[string]any) (string, string) {
	t.Helper()
	props, _ := object["props"].(map[string]any)
	machine, _ := props["drawingMachine"].(map[string]any)
	id, _ := machine["id"].(string)
	host, _ := machine["host"].(string)
	return id, host
}

func TestCreatorStampsItsDrawingMachineAndALaterGetKeepsIt(t *testing.T) {
	f := newFixture(t)
	home := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", true, "browser.call", "object.reload")
	created := f.as(home, "object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})
	if created["ok"] != true {
		t.Fatalf("create: %v", created)
	}
	object := created["result"].(map[string]any)["object"].(map[string]any)
	id, host := drawingOfResult(t, object)
	if id != "mch_home" || host != "home" {
		t.Fatalf("created drawingMachine %s %s", id, host)
	}
	if _, ok := created["result"].(map[string]any)["warnings"]; ok {
		t.Fatalf("drawingMachine was warned as unknown: %v", created["result"])
	}
	again := f.result("object.get", map[string]any{"id": object["id"]})["object"].(map[string]any)
	id, host = drawingOfResult(t, again)
	if id != "mch_home" || host != "home" || again["rev"] != object["rev"] {
		t.Fatalf("second get %v rev %v", again["props"], again["rev"])
	}
}

func TestHeadlessCreateUsesTheEarliestEligibleMac(t *testing.T) {
	f := newFixture(t)
	first := &scriptedClient{router: f.router}
	later := &scriptedClient{router: f.router, replies: []map[string]any{{"ok": true, "result": map[string]any{"loaded": true}}}}
	attachDrawing(f, first, "mch_first", "studio", false, "browser.call")
	attachDrawing(f, later, "mch_later", "laptop", true, "browser.call", "object.reload")
	created := f.result("object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})
	id, host := drawingOfResult(t, created["object"].(map[string]any))
	if id != "mch_first" || host != "studio" {
		t.Fatalf("headless create drew on %s %s, want the earliest", id, host)
	}
	page := created["object"].(map[string]any)["id"].(string)
	code, message := errorOf(f.call("object.reload", map[string]any{"id": page}))
	if code != "unavailable" || message != "draws on studio, which does not serve object.reload" {
		t.Fatalf("reload followed focus or the wrong Mac: %s %q", code, message)
	}
	if len(later.asked) != 0 {
		t.Fatalf("reload was sent to the focused client %v", later.asked)
	}
}

func TestReloadAndBrowserCallStayOnTheDrawingIdentity(t *testing.T) {
	f := newFixture(t)
	home := &scriptedClient{router: f.router, replies: []map[string]any{
		{"ok": true, "result": map[string]any{"url": "https://example.com/now"}},
		{"ok": true, "result": map[string]any{"loaded": true, "url": "https://example.com/now"}},
	}}
	other := &scriptedClient{router: f.router, replies: []map[string]any{
		{"ok": true, "result": map[string]any{"url": "https://wrong.example/"}},
	}}
	attachDrawing(f, home, "mch_home", "home", false, "browser.call", "object.reload")
	attachDrawing(f, other, "mch_other", "work", true, "browser.call", "object.reload")
	page := f.result("object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})["object"].(map[string]any)["id"].(string)
	called := f.result("browser.call", map[string]any{
		"id": page, "method": "browser.navigate", "params": map[string]any{"url": "https://example.com/now"},
	})
	if called["url"] != "https://example.com/now" {
		t.Fatalf("browser.call %v", called)
	}
	if len(other.asked) != 0 || len(home.asked) != 1 || home.asked[0]["method"] != "browser.call" {
		t.Fatalf("forwarded home %v other %v", home.asked, other.asked)
	}
	if got := home.asked[0]["params"].(map[string]any)["method"]; got != "browser.navigate" {
		t.Fatalf("forwarded method %v", home.asked[0])
	}
	if reloaded := f.result("object.reload", map[string]any{"id": page}); reloaded["loaded"] != true || len(other.asked) != 0 {
		t.Fatalf("reload followed focus: other %v result %v", other.asked, reloaded)
	}
}

func TestOfflineDrawingMachineIsNotRetriedOnAnotherClient(t *testing.T) {
	f := newFixture(t)
	home := &conn{}
	other := &scriptedClient{router: f.router}
	attached := f.as(home, "client.attach", map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash,
		"app": "0.2.0", "host": "home", "identity": "mch_home",
		"serves": []any{"browser.call", "object.reload"}, "boards": []any{f.board.ID()},
	})
	if attached["ok"] != true {
		t.Fatalf("attach: %v", attached)
	}
	attachDrawing(f, other, "mch_other", "work", true, "browser.call", "object.reload")
	page := f.result("object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})["object"].(map[string]any)["id"].(string)
	home.close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && f.router.clients.HasIdentity("mch_home", f.board.ID()) {
		time.Sleep(10 * time.Millisecond)
	}
	if f.router.clients.HasIdentity("mch_home", f.board.ID()) {
		t.Fatal("the drawing Mac stayed attached after it hung up")
	}
	code, message := errorOf(f.call("browser.call", map[string]any{
		"id": page, "method": "browser.url.get", "params": map[string]any{},
	}))
	if code != "unavailable" || message != "draws on home, which is offline" {
		t.Fatalf("offline call: %s %q", code, message)
	}
	code, message = errorOf(f.call("object.reload", map[string]any{"id": page}))
	if code != "unavailable" || message != "draws on home, which is offline" {
		t.Fatalf("offline reload: %s %q", code, message)
	}
	if len(other.asked) != 0 {
		t.Fatalf("dropped call was retried on %v", other.asked)
	}
	got := f.result("object.get", map[string]any{"id": page})["object"].(map[string]any)
	id, host := drawingOfResult(t, got)
	if id != "mch_home" || host != "home" {
		t.Fatalf("disconnect migrated the page to %s %s", id, host)
	}
}

func TestFirstEligibleAttachmentFillsExistingTilesAndLegacyClientsDoNot(t *testing.T) {
	f := newFixture(t)
	page := f.result("object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})["object"].(map[string]any)
	if _, ok := page["props"].(map[string]any)["drawingMachine"]; ok {
		t.Fatal("a create with nobody attached invented an owner")
	}
	legacy := &scriptedClient{router: f.router}
	f.as(legacy, "client.attach", map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash,
		"host": "old", "serves": []any{"browser.call", "object.reload"}, "boards": []any{f.board.ID()}, "focused": f.board.ID(),
	})
	page = f.result("object.get", map[string]any{"id": page["id"]})["object"].(map[string]any)
	if _, ok := page["props"].(map[string]any)["drawingMachine"]; ok {
		t.Fatal("a legacy client became the drawing owner")
	}
	home := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", false, "browser.call")
	page = f.result("object.get", map[string]any{"id": page["id"]})["object"].(map[string]any)
	id, host := drawingOfResult(t, page)
	if id != "mch_home" || host != "home" {
		t.Fatalf("first eligible attachment filled %s %s", id, host)
	}
	if page["rev"] != 1.0 {
		t.Fatalf("filling the owner bumped rev to %v", page["rev"])
	}
}

func TestExplicitDrawingMachineIsKeptAndABadShapeIsRejected(t *testing.T) {
	f := newFixture(t)
	home := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", true, "browser.call")
	created := f.result("object.create", map[string]any{
		"type": "browser",
		"props": map[string]any{
			"url": "https://example.com/", "drawingMachine": map[string]any{"id": "mch_kept", "host": "kept"},
		},
		"frame": browserFrame(),
	})
	id, host := drawingOfResult(t, created["object"].(map[string]any))
	if id != "mch_kept" || host != "kept" {
		t.Fatalf("explicit owner became %s %s", id, host)
	}
	code, message := errorOf(f.call("object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/", "drawingMachine": map[string]any{"id": "not-an-id"}},
		"frame": browserFrame(),
	}))
	if code != "invalid_params" || message == "" {
		t.Fatalf("bad drawingMachine: %s %q", code, message)
	}
	page := created["object"].(map[string]any)["id"].(string)
	updated := f.result("object.update", map[string]any{"id": page, "props": map[string]any{"drawingMachine": map[string]any{"id": "mch_moved", "host": "moved"}}})
	id, _ = drawingOfResult(t, updated["object"].(map[string]any))
	if id != "mch_moved" {
		t.Fatalf("an explicit update was refused: %s", id)
	}
}

func TestBatchAndOpenURLDefaultTheDrawingMachine(t *testing.T) {
	f := newFixture(t)
	home := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", true, "browser.call")
	batch := f.result("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": map[string]any{
			"type": "browser", "props": map[string]any{"url": "https://example.com/batch"}, "frame": browserFrame(),
		}},
	}})
	created := batch["results"].([]any)[0].(map[string]any)["object"].(map[string]any)
	id, _ := drawingOfResult(t, created)
	if id != "mch_home" {
		t.Fatalf("batch create owner %s", id)
	}
	opened := f.result("view.open_url", map[string]any{"url": "https://example.com/opened"})
	id, host := drawingOfResult(t, opened["object"].(map[string]any))
	if id != "mch_home" || host != "home" || opened["existing"] != false {
		t.Fatalf("open_url %v existing %v", opened["object"], opened["existing"])
	}
}

func TestBrowserReportCreditsTheDrawingMacAndRejectsAnyoneElse(t *testing.T) {
	f := newFixture(t)
	events := &conn{}
	f.on(events, "events.subscribe", map[string]any{"board": f.board.ID(), "events": []any{"client.changed"}})
	home := &scriptedClient{router: f.router}
	other := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", true, "browser.call")
	attachDrawing(f, other, "mch_other", "work", false, "browser.call")
	created := f.as(home, "object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})
	if created["ok"] != true {
		t.Fatalf("create: %v", created)
	}
	page := created["result"].(map[string]any)["object"].(map[string]any)
	id := page["id"].(string)
	code, message := errorOf(f.as(other, "browser.report", map[string]any{"id": id, "url": "https://evil.example/"}))
	if code != "unavailable" || message != "only the drawing Mac may report "+id {
		t.Fatalf("other reporter: %s %q", code, message)
	}
	code, _ = errorOf(f.as(home, "browser.report", map[string]any{"id": id, "url": "https://example.com/next", "actor": "user", "caller": "obj_nope"}))
	if code != "invalid_params" {
		t.Fatalf("caller and actor together: %s", code)
	}
	terminal := f.result("object.create", map[string]any{"type": "terminal", "props": map[string]any{}, "frame": browserFrame()})["object"].(map[string]any)["id"].(string)
	reported := f.as(home, "browser.report", map[string]any{"id": id, "url": "https://example.com/next", "caller": terminal, "pageTitle": "Next"})
	if reported["ok"] != true {
		t.Fatalf("report: %v", reported)
	}
	object := reported["result"].(map[string]any)["object"].(map[string]any)
	if object["props"].(map[string]any)["url"] != "https://example.com/next" || object["props"].(map[string]any)["pageTitle"] != "Next" {
		t.Fatalf("reported props %v", object["props"])
	}
	if object["rev"] != 2.0 {
		t.Fatalf("url report rev %v, want 2", object["rev"])
	}
	if object["updatedBy"].(map[string]any)["tile"] != terminal {
		t.Fatalf("url credit %v", object["updatedBy"])
	}
	titleOnly := f.as(home, "browser.report", map[string]any{"id": id, "pageTitle": "Renamed", "actor": "system"})
	if titleOnly["ok"] != true {
		t.Fatalf("title report: %v", titleOnly)
	}
	renamed := titleOnly["result"].(map[string]any)["object"].(map[string]any)
	if renamed["rev"] != 2.0 || renamed["props"].(map[string]any)["pageTitle"] != "Renamed" {
		t.Fatalf("title report rev %v props %v", renamed["rev"], renamed["props"])
	}
	var snapshots int
	for _, event := range events.messages() {
		if event["event"] != "client.changed" {
			continue
		}
		snapshots++
		data := event["data"].(map[string]any)
		if _, ok := data["clients"]; !ok || len(data) != 1 {
			t.Fatalf("client.changed data %v", data)
		}
	}
	if snapshots < 2 {
		t.Fatalf("attach did not publish a full snapshot (%d)", snapshots)
	}
}

func TestUnassignedBrowserReloadNamesTheMissingMac(t *testing.T) {
	f := newFixture(t)
	page := f.result("object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})["object"].(map[string]any)["id"].(string)
	code, message := errorOf(f.call("object.reload", map[string]any{"id": page}))
	if code != "unavailable" || message != page+" has no drawing Mac yet" {
		t.Fatalf("unassigned reload: %s %q", code, message)
	}
	code, message = errorOf(f.call("browser.call", map[string]any{"id": page, "method": "browser.url.get", "params": map[string]any{}}))
	if code != "unavailable" || message != page+" has no drawing Mac yet" {
		t.Fatalf("unassigned call: %s %q", code, message)
	}
}

func TestNewestLinkOfOneIdentityServesTheCall(t *testing.T) {
	f := newFixture(t)
	older := &scriptedClient{router: f.router, replies: []map[string]any{{"ok": true, "result": map[string]any{"url": "old"}}}}
	newer := &scriptedClient{router: f.router, replies: []map[string]any{{"ok": true, "result": map[string]any{"url": "new"}}}}
	attachDrawing(f, older, "mch_home", "home", true, "browser.call")
	page := f.result("object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})["object"].(map[string]any)["id"].(string)
	attachDrawing(f, newer, "mch_home", "home", false, "browser.call")
	got := f.result("browser.call", map[string]any{"id": page, "method": "browser.url.get", "params": map[string]any{}})
	if got["url"] != "new" || len(older.asked) != 0 {
		t.Fatalf("newest link did not win: %v older %v", got, older.asked)
	}
}

func TestInvalidPageReportDoesNotCommitItsURL(t *testing.T) {
	f := newFixture(t)
	home := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", false, "browser.call")
	page := f.result("object.create", map[string]any{
		"type": "browser", "props": map[string]any{"url": "https://example.com/"}, "frame": browserFrame(),
	})["object"].(map[string]any)["id"].(string)
	code, _ := errorOf(f.as(home, "browser.report", map[string]any{
		"id": page, "url": "https://example.com/uncommitted", "pageTitle": 42.0,
	}))
	if code != "invalid_params" {
		t.Fatalf("invalid report returned %s", code)
	}
	object := f.result("object.get", map[string]any{"id": page})["object"].(map[string]any)
	if object["props"].(map[string]any)["url"] != "https://example.com/" || object["rev"] != 1.0 {
		t.Fatalf("invalid report changed the page: %v", object)
	}
}
