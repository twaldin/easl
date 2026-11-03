package board

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestSavedLegacyFailureGainsRunFieldsWithoutChangingItsTimestamp(t *testing.T) {
	b := New("brd", "/r")
	failure := strings.Repeat("界", 501)
	term := b.Create(model.Terminal, map[string]any{
		"agent":     map[string]any{"kind": "omp"},
		"lifecycle": map[string]any{"state": "idle", "seen": true, "error": failure, "message": failure},
	}, frame(0, 0, 1000, 620), "", "")
	snapshot := b.Snapshot()
	updated := time.Date(2026, 10, 28, 10, 11, 12, 345678901, time.FixedZone("offset", 3600))
	for i := range snapshot.Objects {
		if snapshot.Objects[i].ID == term.ID {
			snapshot.Objects[i].UpdatedAt = updated
		}
	}
	restored := FromSnapshot(snapshot)
	want := map[string]any{"state": "idle", "seen": true, "error": strings.Repeat("界", 499) + "…", "message": strings.Repeat("界", 499) + "…", "errorCount": 1.0, "errorSince": "2026-10-28T09:11:12.345678901Z"}
	if got := lifecycle(restored, term.ID); !reflect.DeepEqual(got, want) {
		t.Fatalf("migrated legacy failure: %v, want %v", got, want)
	}
	if got := lifecycle(FromSnapshot(restored.Snapshot()), term.ID); !reflect.DeepEqual(got, want) {
		t.Fatalf("second restore changed migrated failure: %v", got)
	}
	if err := restored.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "working"}); err != nil {
		t.Fatal(err)
	}
	if got := lifecycle(restored, term.ID); !reflect.DeepEqual(got, map[string]any{"state": "working", "seen": false}) {
		t.Fatalf("migrated legacy error did not clear on working: %v", got)
	}
}

func TestSavedExplicitFailureKeepsItsRunButDropsAnObsoleteBlocker(t *testing.T) {
	b := New("brd", "/r")
	term := b.Create(model.Terminal, map[string]any{
		"agent":     map[string]any{"kind": "omp", "protocol": 4.0},
		"lifecycle": map[string]any{"state": "blocked", "seen": false, "error": "provider refused", "errorCount": 3.0, "errorSince": "2026-10-27T12:00:00.123Z", "message": "Allow push?"},
	}, frame(0, 0, 1000, 620), "", "")
	restored := FromSnapshot(b.Snapshot())
	want := map[string]any{"state": "blocked", "seen": false, "error": "provider refused", "errorCount": 3.0, "errorSince": "2026-10-27T12:00:00.123Z", "message": "Allow push?", "restored": true}
	if got := lifecycle(restored, term.ID); !reflect.DeepEqual(got, want) {
		t.Fatalf("restore changed an explicit failure run: %v", got)
	}
	delete(want, "restored")
	protocol := 4
	want["state"] = "idle"
	want["message"] = "provider refused"
	if err := restored.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "idle", Protocol: &protocol}); err != nil {
		t.Fatal(err)
	}
	if got := lifecycle(restored, term.ID); !reflect.DeepEqual(got, want) {
		t.Fatalf("idle heartbeat kept an obsolete approval question: %v", got)
	}
	custom := "The provider needs attention"
	if err := restored.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "idle", Protocol: &protocol, Message: &custom}); err != nil {
		t.Fatal(err)
	}
	want["message"] = custom
	if err := restored.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "idle", Protocol: &protocol}); err != nil {
		t.Fatal(err)
	}
	if got := lifecycle(restored, term.ID); !reflect.DeepEqual(got, want) {
		t.Fatalf("idle heartbeat lost the current idle diagnostic: %v", got)
	}
	want["state"] = "working"
	delete(want, "message")
	if err := restored.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "working", Protocol: &protocol}); err != nil {
		t.Fatal(err)
	}
	if got := lifecycle(restored, term.ID); !reflect.DeepEqual(got, want) {
		t.Fatalf("working retained an obsolete custom message: %v", got)
	}
}
