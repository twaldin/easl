package router

import (
	"reflect"
	"testing"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/store"
)

func assertBrowserIntent(t *testing.T, object map[string]any, url any, rev float64, intent any) {
	t.Helper()
	props := object["props"].(map[string]any)
	if props["url"] != url || object["rev"] != rev || !reflect.DeepEqual(props["urlIntent"], intent) {
		t.Fatalf("browser state: url %v rev %v intent %v, want url %v rev %v intent %v", props["url"], object["rev"], props["urlIntent"], url, rev, intent)
	}
}

func TestBrowserURLIntentSeparatesAssignmentsFromReports(t *testing.T) {
	for _, method := range []string{"object.update", "object.upsert"} {
		t.Run(method, func(t *testing.T) {
			f := newFixture(t)
			home := &scriptedClient{router: f.router}
			attachDrawing(f, home, "mch_home", "home", true, "browser.call")
			agent := idOf(f.result("object.create", map[string]any{"type": "terminal", "props": map[string]any{}, "frame": browserFrame()}))
			createMethod := "object.create"
			create := map[string]any{
				"type": "browser", "frame": browserFrame(),
				"props": map[string]any{"url": "https://example.com/initial", "urlIntent": map[string]any{"url": "https://forged.example/", "rev": 99.0}},
			}
			if method == "object.upsert" {
				createMethod = method
				create["key"] = "page"
			}
			created := f.result(createMethod, create)["object"].(map[string]any)
			assertBrowserIntent(t, created, "https://example.com/initial", 1, nil)
			id := created["id"].(string)
			assign := func(props map[string]any) map[string]any {
				params := map[string]any{"props": props}
				if _, explicit := props["url"]; explicit {
					params["caller"] = agent
				}
				if method == "object.upsert" {
					params["key"], params["type"] = "page", "browser"
				} else {
					params["id"] = id
				}
				return f.result(method, params)["object"].(map[string]any)
			}
			first := assign(map[string]any{"url": "https://example.com/requested", "urlIntent": nil})
			intent := map[string]any{"url": "https://example.com/requested", "rev": 2.0, "actor": map[string]any{"kind": "agent", "tile": agent}}
			assertBrowserIntent(t, first, "https://example.com/requested", 2, intent)
			report := f.as(home, "browser.report", map[string]any{"id": id, "url": "https://example.com/redirected", "pageTitle": "Redirected", "actor": "user"})
			if report["ok"] != true {
				t.Fatalf("report: %v", report)
			}
			observed := report["result"].(map[string]any)["object"].(map[string]any)
			assertBrowserIntent(t, observed, "https://example.com/redirected", 3, intent)
			if !reflect.DeepEqual(first["updatedBy"], map[string]any{"kind": "agent", "tile": agent}) || !reflect.DeepEqual(observed["updatedBy"], map[string]any{"kind": "user"}) {
				t.Fatalf("assignment and observation credit: %v %v", first["updatedBy"], observed["updatedBy"])
			}
			if observed["props"].(map[string]any)["pageTitle"] != "Redirected" {
				t.Fatalf("observed title: %v", observed)
			}
			moved := f.result("object.update", map[string]any{"id": id, "frame": map[string]any{"x": 250.0}})["object"].(map[string]any)
			assertBrowserIntent(t, moved, "https://example.com/redirected", 4, intent)
			renamed := assign(map[string]any{
				"title": "Research", "profile": "research", "drawingMachine": map[string]any{"id": "mch_home", "host": "renamed"},
				"urlIntent": map[string]any{"url": "https://forged.example/", "rev": 100.0},
			})
			assertBrowserIntent(t, renamed, "https://example.com/redirected", 5, intent)
			cleared := assign(map[string]any{"urlIntent": nil})
			assertBrowserIntent(t, cleared, "https://example.com/redirected", 6, intent)
			next := assign(map[string]any{"url": "https://example.com/redirected"})
			assertBrowserIntent(t, next, "https://example.com/redirected", 7, map[string]any{"url": "https://example.com/redirected", "rev": 7.0, "actor": map[string]any{"kind": "agent", "tile": agent}})
		})
	}
}

func TestBrowserURLRemovalAndNonStringReplacementClearIntent(t *testing.T) {
	for _, replacement := range []any{nil, 42.0} {
		name := "removed"
		if replacement != nil {
			name = "non-string"
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			id := idOf(f.result("object.create", map[string]any{"type": "browser", "props": map[string]any{"url": "about:blank"}, "frame": browserFrame()}))
			f.result("object.update", map[string]any{"id": id, "props": map[string]any{"url": "https://example.com/assigned"}})
			updated := f.result("object.update", map[string]any{"id": id, "props": map[string]any{
				"url": replacement, "urlIntent": map[string]any{"url": "https://forged.example/", "rev": 99.0},
			}})["object"].(map[string]any)
			assertBrowserIntent(t, updated, replacement, 3, nil)
			if _, present := updated["props"].(map[string]any)["url"]; present != (replacement != nil) {
				t.Fatalf("URL removal: %v", updated)
			}
			forged := f.result("object.update", map[string]any{"id": id, "props": map[string]any{"urlIntent": map[string]any{"url": "https://forged.example/", "rev": 100.0}}})["object"].(map[string]any)
			assertBrowserIntent(t, forged, replacement, 4, nil)
		})
	}
}

func TestBrowserURLIntentBatchOrderingAndRollback(t *testing.T) {
	f := newFixture(t)
	home := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", true, "browser.call")
	observer := idOf(f.result("object.create", map[string]any{"type": "terminal", "props": map[string]any{}, "frame": browserFrame()}))
	events := &conn{}
	f.on(events, "events.subscribe", map[string]any{"board": f.board.ID(), "events": []any{"object.created", "object.updated"}})
	beforeRevision := f.board.Revision()
	batch := f.result("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.upsert", "params": map[string]any{
			"key": "page", "type": "browser", "frame": browserFrame(),
			"props": map[string]any{"url": "about:blank", "urlIntent": map[string]any{"url": "https://forged.example/", "rev": 99.0}},
		}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "$0", "rev": 1.0, "props": map[string]any{"url": "https://example.com/first"}}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "$0", "rev": 2.0, "frame": map[string]any{"x": 200.0}}},
		map[string]any{"method": "object.upsert", "params": map[string]any{"key": "page", "type": "browser", "props": map[string]any{"url": "https://example.com/second"}}},
	}})
	results := batch["results"].([]any)
	if len(results) != 4 || results[0].(map[string]any)["created"] != true || results[3].(map[string]any)["created"] != false || batch["revision"] != float64(beforeRevision+1) {
		t.Fatalf("batch transitions: %v", batch)
	}
	id := idOf(results[0].(map[string]any))
	if idOf(results[3].(map[string]any)) != id {
		t.Fatalf("batch upsert replaced the browser: %v", batch)
	}
	intent := map[string]any{"url": "https://example.com/second", "rev": 4.0, "actor": map[string]any{"kind": "user"}}
	assertBrowserIntent(t, results[3].(map[string]any)["object"].(map[string]any), "https://example.com/second", 4, intent)
	type state struct {
		Event  string
		URL    any
		Rev    any
		Intent any
	}
	states := func(messages []map[string]any) []state {
		var out []state
		for _, event := range messages {
			if _, reply := event["ok"]; reply {
				continue
			}
			data := event["data"].(map[string]any)
			props := data["props"].(map[string]any)
			out = append(out, state{event["event"].(string), props["url"], data["rev"], props["urlIntent"]})
		}
		return out
	}
	want := []state{
		{"object.created", "about:blank", 1.0, nil},
		{"object.updated", "https://example.com/first", 2.0, map[string]any{"url": "https://example.com/first", "rev": 2.0, "actor": map[string]any{"kind": "user"}}},
		{"object.updated", "https://example.com/first", 3.0, map[string]any{"url": "https://example.com/first", "rev": 2.0, "actor": map[string]any{"kind": "user"}}},
		{"object.updated", "https://example.com/second", 4.0, intent},
	}
	if got := states(events.messages()); !reflect.DeepEqual(got, want) {
		t.Fatalf("batch event prefix: %v, want %v", got, want)
	}
	reported := f.as(home, "browser.report", map[string]any{"id": id, "url": "https://example.com/observed", "caller": observer})
	if reported["ok"] != true {
		t.Fatalf("report: %v", reported)
	}
	assertBrowserIntent(t, reported["result"].(map[string]any)["object"].(map[string]any), "https://example.com/observed", 5, intent)
	start := len(events.messages())
	failed := f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "rev": 5.0, "props": map[string]any{"url": "https://example.com/aborted"}}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "rev": 5.0, "props": map[string]any{"url": "https://example.com/stale"}}},
	}})
	code, _ := errorOf(failed)
	if code != "conflict" {
		t.Fatalf("failed batch: %v", failed)
	}
	want = []state{
		{"object.updated", "https://example.com/aborted", 6.0, map[string]any{"url": "https://example.com/aborted", "rev": 6.0, "actor": map[string]any{"kind": "user"}}},
		{"object.updated", "https://example.com/observed", 7.0, map[string]any{"url": "https://example.com/observed", "rev": 7.0, "actor": map[string]any{"kind": "agent", "tile": observer}}},
	}
	if got := states(events.messages()[start:]); !reflect.DeepEqual(got, want) {
		t.Fatalf("rollback event prefix: %v, want %v", got, want)
	}
	stored := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	assertBrowserIntent(t, stored, "https://example.com/observed", 7, map[string]any{"url": "https://example.com/observed", "rev": 7.0, "actor": map[string]any{"kind": "agent", "tile": observer}})
	next := f.result("object.update", map[string]any{"id": id, "rev": 7.0, "props": map[string]any{"url": "https://example.com/second"}})["object"].(map[string]any)
	assertBrowserIntent(t, next, "https://example.com/second", 8, map[string]any{"url": "https://example.com/second", "rev": 8.0, "actor": map[string]any{"kind": "user"}})
}

func TestBrowserURLIntentSurvivesBoardPersistence(t *testing.T) {
	f := newFixture(t)
	home := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", true, "browser.call")
	id := idOf(f.result("object.create", map[string]any{"type": "browser", "props": map[string]any{"url": "about:blank"}, "frame": browserFrame()}))
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{"url": "https://example.com/requested"}})
	report := f.as(home, "browser.report", map[string]any{"id": id, "url": "https://example.com/observed", "pageTitle": "Observed"})
	if report["ok"] != true {
		t.Fatalf("report: %v", report)
	}
	encoded, err := f.board.Snapshot().Encode()
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := store.DecodeSnapshot(encoded)
	if err != nil {
		t.Fatal(err)
	}
	reopened := board.FromSnapshot(snapshot)
	loaded, err := reopened.Object(id)
	if err != nil {
		t.Fatal(err)
	}
	intent := map[string]any{"url": "https://example.com/requested", "rev": 2.0, "actor": map[string]any{"kind": "user"}}
	assertBrowserIntent(t, loaded.APIJSON(), "https://example.com/observed", 3, intent)
	observed, err := reopened.ReportBrowserURL(id, "https://example.com/later", "", board.SystemActor)
	if err != nil {
		t.Fatal(err)
	}
	assertBrowserIntent(t, observed.APIJSON(), "https://example.com/later", 4, intent)
}

func TestBrowserURLRollbackCorrectsDocumentsWithoutPriorIntent(t *testing.T) {
	for _, test := range []struct {
		name    string
		initial any
		attempt string
		intent  any
	}{
		{"initial-document", "https://example.com/initial", "https://example.com/aborted", map[string]any{"url": "https://example.com/initial", "rev": 3.0}},
		{"same-document", "https://example.com/initial", "https://example.com/initial", map[string]any{"url": "https://example.com/initial", "rev": 3.0}},
		{"removed-document", nil, "https://example.com/aborted", nil},
		{"non-string-document", 42.0, "https://example.com/aborted", nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t)
			creator := idOf(f.result("object.create", map[string]any{"type": "terminal", "props": map[string]any{}, "frame": browserFrame()}))
			if intent, ok := test.intent.(map[string]any); ok {
				intent["actor"] = map[string]any{"kind": "agent", "tile": creator}
			}
			props := map[string]any{}
			if test.initial != nil {
				props["url"] = test.initial
			}
			id := idOf(f.result("object.create", map[string]any{"type": "browser", "props": props, "frame": browserFrame(), "caller": creator}))
			events := &conn{}
			f.on(events, "events.subscribe", map[string]any{"board": f.board.ID(), "events": []any{"object.updated"}})
			failed := f.call("object.batch", map[string]any{"ops": []any{
				map[string]any{"method": "object.update", "params": map[string]any{"id": id, "rev": 1.0, "props": map[string]any{"url": test.attempt}}},
				map[string]any{"method": "object.update", "params": map[string]any{"id": id, "rev": 1.0, "props": map[string]any{"title": "Stale"}}},
			}})
			if code, _ := errorOf(failed); code != "conflict" {
				t.Fatalf("failed batch: %v", failed)
			}
			messages := events.messages()
			if len(messages) != 2 {
				t.Fatalf("rollback events: %v", messages)
			}
			assertBrowserIntent(t, messages[0]["data"].(map[string]any), test.attempt, 2, map[string]any{"url": test.attempt, "rev": 2.0, "actor": map[string]any{"kind": "user"}})
			assertBrowserIntent(t, messages[1]["data"].(map[string]any), test.initial, 3, test.intent)
			stored := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
			assertBrowserIntent(t, stored, test.initial, 3, test.intent)
		})
	}
}

func TestBrowserUnrelatedRollbackPreservesRedirectedIntent(t *testing.T) {
	f := newFixture(t)
	home := &scriptedClient{router: f.router}
	attachDrawing(f, home, "mch_home", "home", true, "browser.call")
	id := idOf(f.result("object.create", map[string]any{"type": "browser", "props": map[string]any{"url": "about:blank"}, "frame": browserFrame()}))
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{"url": "https://example.com/requested"}})
	report := f.as(home, "browser.report", map[string]any{"id": id, "url": "https://example.com/redirected"})
	if report["ok"] != true {
		t.Fatalf("report: %v", report)
	}
	events := &conn{}
	f.on(events, "events.subscribe", map[string]any{"board": f.board.ID(), "events": []any{"object.updated"}})
	failed := f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "rev": 3.0, "frame": map[string]any{"x": 500.0}, "props": map[string]any{"title": "Temporary"}}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "rev": 3.0, "props": map[string]any{"title": "Stale"}}},
	}})
	if code, _ := errorOf(failed); code != "conflict" {
		t.Fatalf("failed batch: %v", failed)
	}
	messages := events.messages()
	if len(messages) != 2 {
		t.Fatalf("rollback events: %v", messages)
	}
	intent := map[string]any{"url": "https://example.com/requested", "rev": 2.0, "actor": map[string]any{"kind": "user"}}
	assertBrowserIntent(t, messages[0]["data"].(map[string]any), "https://example.com/redirected", 4, intent)
	assertBrowserIntent(t, messages[1]["data"].(map[string]any), "https://example.com/redirected", 5, intent)
	restored := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	if restored["frame"].(map[string]any)["x"] != 0.0 || restored["props"].(map[string]any)["title"] != nil {
		t.Fatalf("unrelated edits survived rollback: %v", restored)
	}
}
