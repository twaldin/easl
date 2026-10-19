package router

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/session"
)

func TestBoardStaleUsesConfirmedSessionExitNotAgentReleaseOrIdle(t *testing.T) {
	f, state := owning(t)
	cleanupExpiryFixture(t, f)
	tiles := map[string]string{}
	for _, name := range []string{"gone", "ended", "released", "idle", "foreign", "unreachable", "hosted"} {
		props := map[string]any{"name": name}
		if name == "hosted" {
			props["host"] = "remote"
		}
		tiles[name] = idOf(f.result("object.create", terminal(props)))
	}
	f.result("agent.report", map[string]any{"tile": tiles["released"], "kind": "omp", "state": "working"})
	f.result("agent.release", map[string]any{"tile": tiles["released"], "kind": "omp"})
	f.result("agent.report", map[string]any{"tile": tiles["idle"], "kind": "omp", "state": "idle"})
	if err := os.Remove(filepath.Join(state, session.Prefix+tiles["gone"])); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"ended", "foreign", "unreachable"} {
		labels := f.router.Owns.Labels(f.board.ID(), tiles[name])
		if name == "foreign" {
			labels[session.HomeLabel] = "another-home"
		}
		parts := []string{}
		for key, value := range labels {
			parts = append(parts, key+"="+value)
		}
		if name == "ended" {
			parts = append(parts, "ended=10")
		}
		if name == "unreachable" {
			parts = append(parts, "status=unreachable")
		}
		if err := os.WriteFile(filepath.Join(state, session.Prefix+tiles[name]), []byte("labels="+strings.Join(parts, " ")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	creator := idOf(f.result("object.create", terminal(map[string]any{"name": "creator"})))
	p := note(0, map[string]any{"markdown": "Orphan", "key": "orphan"})
	p["caller"] = creator
	orphan := idOf(f.result("object.create", p))
	f.result("object.delete", map[string]any{"id": creator})
	f.result("object.create", note(0, map[string]any{"markdown": "Fresh user note"}))
	f.router.reg.Mu.Lock()
	before := f.board.Snapshot()
	cursor := f.board.Activity.Cursor()
	f.router.reg.Mu.Unlock()
	got := f.result("board.stale", map[string]any{})["objects"].([]any)
	ids := []string{}
	for _, value := range got {
		entry := value.(map[string]any)
		id := entry["id"].(string)
		ids = append(ids, id)
		wantReason := "exited"
		if id == orphan {
			wantReason = "creator-gone"
			if entry["key"] != "orphan" || entry["title"] != "Orphan" || !reflect.DeepEqual(entry["createdBy"], map[string]any{"kind": "agent", "tile": creator}) {
				t.Fatalf("orphan fields = %v", entry)
			}
		}
		if !reflect.DeepEqual(entry["reasons"], []any{wantReason}) {
			t.Fatalf("wrong reasons = %v", entry)
		}
	}
	want := []string{tiles["gone"], tiles["ended"], orphan}
	sort.Strings(want)
	if !reflect.DeepEqual(ids, want) {
		t.Fatalf("stale ids = %v, want %v", ids, want)
	}
	f.router.reg.Mu.Lock()
	unchanged := reflect.DeepEqual(before, f.board.Snapshot()) && cursor == f.board.Activity.Cursor()
	f.router.reg.Mu.Unlock()
	if !unchanged {
		t.Fatal("board.stale changed the board")
	}
	f.router.Sessions.Zmx = filepath.Join(t.TempDir(), "missing-zmx")
	unknown := f.result("board.stale", map[string]any{})["objects"].([]any)
	if len(unknown) != 1 || unknown[0].(map[string]any)["id"] != orphan {
		t.Fatalf("session lookup failure inferred exited terminals: %v", unknown)
	}
}

func TestBoardStaleDurationValidationAndZeroAge(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	id := idOf(f.result("object.create", note(0, map[string]any{"markdown": "Fresh"})))
	if got := f.result("board.stale", map[string]any{})["objects"]; !reflect.DeepEqual(got, []any{}) {
		t.Fatalf("fresh objects listed by default: %v", got)
	}
	for _, value := range []any{nil, 1.0, "-1s", ".5h", "1w", "7", "1e2s", "9223372037s"} {
		if code, _ := errorOf(f.call("board.stale", map[string]any{"olderThan": value})); code != "invalid_params" {
			t.Fatalf("olderThan %v was not rejected: %s", value, code)
		}
	}
	got := f.result("board.stale", map[string]any{"olderThan": "0s"})["objects"].([]any)
	if len(got) != 1 || got[0].(map[string]any)["id"] != id || !reflect.DeepEqual(got[0].(map[string]any)["reasons"], []any{"untouched"}) {
		t.Fatalf("zero age = %v", got)
	}
}

func TestBoardStaleDoesNotInferExitBeforeQueuedStart(t *testing.T) {
	f, _ := owning(t)
	cleanupExpiryFixture(t, f)
	f.router.holdSessions()
	t.Cleanup(func() {
		f.router.StartSessions()
		f.router.reg.Mu.Lock()
		queued := f.router.queuedSessions()
		f.router.reg.Mu.Unlock()
		f.router.waitSessions(queued)
	})
	f.router.reg.Mu.Lock()
	o := f.board.Create("terminal", map[string]any{"name": "starting"}, nil, "", "")
	f.router.reg.Mu.Unlock()
	got := f.result("board.stale", map[string]any{})["objects"]
	if !reflect.DeepEqual(got, []any{}) {
		t.Fatalf("terminal %s has not started, but stale returned %v", o.ID, got)
	}
}
