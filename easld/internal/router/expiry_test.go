package router

import (
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
)

func cleanupExpiryFixture(t *testing.T, f *fixture) {
	t.Helper()
	t.Cleanup(func() {
		f.router.reg.Mu.Lock()
		for _, b := range f.router.reg.SortedBoards() {
			b.StopQuestionExpiry()
		}
		f.router.reg.Mu.Unlock()
		f.router.reg.Flush()
	})
}

func TestObjectExpiryBoundaryNormalizesAndPreservesOmittedDeadline(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	p := note(0, map[string]any{"markdown": "temporary"})
	p["expires"] = "2099-01-02t05:04:05.125+02:00"
	created := f.result("object.create", p)
	id := idOf(created)
	if got := created["object"].(map[string]any)["expires"]; got != "2099-01-02T03:04:05.125Z" {
		t.Fatalf("normalized expiry = %v", got)
	}
	updated := f.result("object.update", map[string]any{"id": id, "props": map[string]any{"markdown": "revised"}})
	if got := updated["object"].(map[string]any)["expires"]; got != "2099-01-02T03:04:05.125Z" {
		t.Fatalf("omitted expiry changed = %v", got)
	}
	cleared := f.result("object.update", map[string]any{"id": id, "expires": nil})
	if got := cleared["object"].(map[string]any); got["expires"] != nil || got["rev"] != 3.0 || got["props"].(map[string]any)["markdown"] != "revised" {
		t.Fatalf("clear expiry = %v", got)
	}
}

func TestObjectExpiryRelativeNormalizationUsesOneRequestClock(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	before := time.Now()
	ops := []any{}
	for _, key := range []string{"one", "two"} {
		p := note(0, map[string]any{"markdown": key, "key": key})
		p["expiresIn"] = "1.5h"
		ops = append(ops, map[string]any{"method": "object.create", "params": p})
	}
	result := f.result("object.batch", map[string]any{"ops": ops})
	after := time.Now()
	results := result["results"].([]any)
	first := results[0].(map[string]any)["object"].(map[string]any)
	second := results[1].(map[string]any)["object"].(map[string]any)
	at, err := time.Parse(time.RFC3339Nano, first["expires"].(string))
	if err != nil || at.Before(before.Add(90*time.Minute)) || at.After(after.Add(90*time.Minute)) || first["expires"] != second["expires"] || first["expiresIn"] != nil {
		t.Fatalf("relative batch expiry = %v and %v, parse error %v", first, second, err)
	}
	p := map[string]any{"key": "upsert", "type": "note", "props": map[string]any{"markdown": "new"}, "expiresIn": "1.25d"}
	created := f.result("object.upsert", p)
	id := idOf(created)
	original := created["object"].(map[string]any)["expires"]
	p = map[string]any{"key": "upsert", "type": "note", "props": map[string]any{"markdown": "preserved"}}
	kept := f.result("object.upsert", p)
	if idOf(kept) != id || kept["object"].(map[string]any)["expires"] != original || kept["created"] != false {
		t.Fatalf("upsert failed to preserve deadline: %v", kept)
	}
	p["expires"] = nil
	cleared := f.result("object.upsert", p)
	if object := cleared["object"].(map[string]any); object["expires"] != nil || object["props"].(map[string]any)["markdown"] != "preserved" {
		t.Fatalf("upsert failed to clear deadline: %v", cleared)
	}
}

func TestObjectExpiryInvalidBoundaryInputsDoNotMutate(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	id := idOf(f.result("object.create", note(0, map[string]any{"markdown": "keep", "key": "kept"})))
	bad := []map[string]any{
		{"expires": "tomorrow"}, {"expires": "2099-01-01"}, {"expires": "2099-01-01T00:00:00"},
		{"expires": "2099-02-30T00:00:00Z"}, {"expires": "2099-01-01T00:00:00+24:00"}, {"expires": 10.0},
		{"expiresIn": nil}, {"expiresIn": 10.0}, {"expiresIn": "-1s"}, {"expiresIn": "1e3s"}, {"expiresIn": ".5h"},
		{"expiresIn": "1h30m"}, {"expiresIn": "1w"}, {"expiresIn": "NaNs"}, {"expiresIn": "9223372037s"},
		{"expiresIn": "9999999999999999999999999999999999999999999999d"},
		{"expires": nil, "expiresIn": "1h"},
	}
	for _, method := range []string{"object.create", "object.update", "object.upsert", "object.batch"} {
		for index, fields := range bad {
			t.Run(method+"/"+strconv.Itoa(index), func(t *testing.T) {
				params := note(0, map[string]any{"markdown": "rejected"})
				switch method {
				case "object.update":
					params = map[string]any{"id": id, "props": map[string]any{"markdown": "rejected"}}
				case "object.upsert":
					params["key"] = "kept"
				}
				for key, value := range fields {
					params[key] = value
				}
				if method == "object.batch" {
					params = map[string]any{"ops": []any{
						map[string]any{"method": "object.create", "params": note(0, map[string]any{"markdown": "never created"})},
						map[string]any{"method": "object.create", "params": params},
					}}
				}
				f.router.reg.Mu.Lock()
				before := f.board.Snapshot()
				cursor := f.board.Activity.Cursor()
				f.router.reg.Mu.Unlock()
				reply := f.call(method, params)
				if code, _ := errorOf(reply); code != "invalid_params" {
					t.Fatalf("%s accepted %v: %v", method, fields, reply)
				}
				f.router.reg.Mu.Lock()
				unchanged := reflect.DeepEqual(before, f.board.Snapshot()) && cursor == f.board.Activity.Cursor()
				f.router.reg.Mu.Unlock()
				if !unchanged {
					t.Fatalf("%s mutated the board on invalid expiry %v", method, fields)
				}
			})
		}
	}
}

func TestObjectExpiryRevisionRejectionAndViewerUndoKeepDeadline(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	p := note(0, map[string]any{"markdown": "keep"})
	p["expires"] = "2099-01-01T00:00:00Z"
	id := idOf(f.result("object.create", p))
	reply := f.call("object.update", map[string]any{"id": id, "rev": 0.0, "expires": nil})
	if code, _ := errorOf(reply); code != "conflict" {
		t.Fatalf("stale revision accepted: %v", reply)
	}
	got := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	if got["rev"] != 1.0 || got["expires"] != "2099-01-01T00:00:00Z" {
		t.Fatalf("revision rejection changed object: %v", got)
	}
	f.result("object.update", map[string]any{"id": id, "expires": nil, "viewer": testViewer, "step": 1.0})
	undo := f.result("board.undo", map[string]any{"viewer": testViewer, "step": 1.0})
	changed := undo["changed"].([]any)
	if len(changed) != 1 || changed[0].(map[string]any)["expires"] != "2099-01-01T00:00:00Z" || undo["pushed"] != true {
		t.Fatalf("expiry undo = %v", undo)
	}
	redo := f.result("board.redo", map[string]any{"viewer": testViewer, "step": 1.0})
	changed = redo["changed"].([]any)
	if len(changed) != 1 || changed[0].(map[string]any)["expires"] != nil || changed[0].(map[string]any)["props"].(map[string]any)["markdown"] != "keep" {
		t.Fatalf("expiry redo = %v", redo)
	}
	f.result("object.update", map[string]any{"id": id, "expires": "2099-02-01T00:00:00Z", "viewer": testViewer, "step": 2.0})
	f.result("object.update", map[string]any{"id": id, "expires": "2099-03-01T00:00:00Z"})
	guarded := f.result("board.undo", map[string]any{"viewer": testViewer, "step": 2.0})
	if !reflect.DeepEqual(guarded["kept"], []any{id}) || !reflect.DeepEqual(guarded["changed"], []any{}) {
		t.Fatalf("undo overwrote another expiry edit: %v", guarded)
	}
}

func TestObjectExpiryZeroDurationDeletesAfterTheRequest(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	deleted := make(chan string, 4)
	f.router.reg.Mu.Lock()
	f.router.reg.Hook = func(_ *board.Board, event model.Event) {
		if event.Name == board.EventObjectDeleted {
			deleted <- event.Data.(map[string]any)["id"].(string)
		}
	}
	f.router.reg.Mu.Unlock()
	p := note(0, map[string]any{"markdown": "zero"})
	p["expiresIn"] = "0s"
	created := f.result("object.create", p)
	id := idOf(created)
	if created["object"].(map[string]any)["expires"] == nil {
		t.Fatalf("zero duration did not store an absolute deadline: %v", created)
	}
	select {
	case got := <-deleted:
		if got != id {
			t.Fatalf("deleted %s, want %s", got, id)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("zero duration object never expired")
	}
	if code, _ := errorOf(f.call("object.get", map[string]any{"id": id})); code != "not_found" {
		t.Fatalf("zero duration object still exists: %s", code)
	}
}

func TestObjectExpiryNullCancelsTheApiTimer(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	p := note(0, map[string]any{"markdown": "keep"})
	p["expiresIn"] = "0.25s"
	created := f.result("object.create", p)
	id := idOf(created)
	at, err := time.Parse(time.RFC3339Nano, created["object"].(map[string]any)["expires"].(string))
	if err != nil {
		t.Fatal(err)
	}
	f.result("object.update", map[string]any{"id": id, "expires": nil})
	time.Sleep(time.Until(at) + 50*time.Millisecond)
	got := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	if got["expires"] != nil || got["props"].(map[string]any)["markdown"] != "keep" || got["rev"] != 2.0 {
		t.Fatalf("null cancellation did not keep the object: %v", got)
	}
}

func TestObjectExpiryBatchUpsertAndUpdateCarryAbsoluteDeadlines(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	create := map[string]any{"key": "scratch", "type": "note", "props": map[string]any{"markdown": "one"}, "expires": "2099-01-01T00:00:00Z"}
	update := map[string]any{"id": "$0", "expires": "2099-02-01T00:00:00Z"}
	clear := map[string]any{"key": "scratch", "type": "note", "props": map[string]any{"markdown": "two"}, "expires": nil}
	results := f.result("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.upsert", "params": create},
		map[string]any{"method": "object.update", "params": update},
		map[string]any{"method": "object.upsert", "params": clear},
	}})["results"].([]any)
	first := results[0].(map[string]any)["object"].(map[string]any)
	second := results[1].(map[string]any)["object"].(map[string]any)
	last := results[2].(map[string]any)["object"].(map[string]any)
	if first["expires"] != "2099-01-01T00:00:00Z" || second["expires"] != "2099-02-01T00:00:00Z" ||
		first["id"] != last["id"] || last["expires"] != nil || last["props"].(map[string]any)["markdown"] != "two" || last["rev"] != 3.0 {
		t.Fatalf("batch expiry was not carried through each write: %v", results)
	}
}

func TestCleanupDurationAcceptsFractionalSecondsMinutesHoursAndDays(t *testing.T) {
	for _, tc := range []struct {
		value string
		want  time.Duration
	}{
		{"0s", 0},
		{"00.5s", 500 * time.Millisecond},
		{"0.25m", 15 * time.Second},
		{"1.5h", 90 * time.Minute},
		{"1.25d", 30 * time.Hour},
	} {
		got, err := parseCleanupDuration(tc.value, "expiresIn")
		if err != nil || got != tc.want {
			t.Fatalf("%s = %v, %v; want %v", tc.value, got, err, tc.want)
		}
	}
}
