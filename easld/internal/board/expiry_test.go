package board

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

func waitObjectDeleted(t *testing.T, b *timed, id string) {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case e := <-b.events:
			data, _ := e.Data.(map[string]any)
			if e.Name == EventObjectDeleted && data["id"] == id {
				return
			}
		case <-deadline:
			t.Fatalf("%s was not deleted at its expiry", id)
		}
	}
}

func TestObjectExpiryTimerDeletesThroughNormalSystemPath(t *testing.T) {
	b := newTimed()
	t.Cleanup(func() { b.mu.Lock(); b.StopQuestionExpiry(); b.mu.Unlock() })
	b.mu.Lock()
	at := time.Now().Add(120 * time.Millisecond)
	o := b.Create(model.Note, map[string]any{"markdown": "temporary"}, nil, "", "", Expiry{At: &at})
	arrow := b.Create(model.Arrow, map[string]any{"from": map[string]any{"object": o.ID}, "to": map[string]any{"point": []any{400.0, 500.0}}}, nil, "", "")
	_, err := b.Stage(map[string]any{"kind": "object", "object": o.ID})
	if err != nil {
		b.mu.Unlock()
		t.Fatal(err)
	}
	if _, exists := b.Objects()[o.ID]; !exists {
		b.mu.Unlock()
		t.Fatal("expiry deleted an object inside its create")
	}
	b.mu.Unlock()
	waitObjectDeleted(t, b, o.ID)
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, exists := b.Objects()[o.ID]; exists || len(b.Tray()) != 0 {
		t.Fatalf("expired object or mention remains: %v, %v", b.Objects(), b.Tray())
	}
	if got := b.Objects()[arrow.ID].Props["from"].(map[string]any); got["object"] != nil || got["point"] == nil {
		t.Fatalf("expiry failed to detach the arrow: %v", got)
	}
	entries := b.Activity.Entries()
	found := false
	for _, entry := range entries {
		if entry.ID == o.ID && entry.Kind == KindDeleted {
			found = entry.Actor == SystemActor
		}
	}
	if !found {
		t.Fatalf("no system deletion in activity: %+v", entries)
	}
}

func TestObjectExpiryCancellationAndMovingLaterInvalidateWaitingTimer(t *testing.T) {
	b := newTimed()
	t.Cleanup(func() { b.mu.Lock(); b.StopQuestionExpiry(); b.mu.Unlock() })
	b.mu.Lock()
	soon := time.Now().Add(30 * time.Millisecond)
	cancelled := b.Create(model.Note, map[string]any{"markdown": "keep"}, nil, "", "", Expiry{At: &soon})
	moved := b.Create(model.Note, map[string]any{"markdown": "later"}, nil, "", "", Expiry{At: &soon})
	time.Sleep(60 * time.Millisecond)
	later := time.Now().Add(200 * time.Millisecond)
	if _, err := b.Update(cancelled.ID, nil, nil, nil, nil, "", "", Expiry{}); err != nil {
		b.mu.Unlock()
		t.Fatal(err)
	}
	if _, err := b.Update(moved.ID, nil, nil, nil, nil, "", "", Expiry{At: &later}); err != nil {
		b.mu.Unlock()
		t.Fatal(err)
	}
	b.mu.Unlock()
	time.Sleep(60 * time.Millisecond)
	b.mu.Lock()
	_, cancelledExists := b.Objects()[cancelled.ID]
	_, movedExists := b.Objects()[moved.ID]
	b.mu.Unlock()
	if !cancelledExists || !movedExists {
		t.Fatalf("old timer deleted cancelled=%v or moved=%v object", cancelledExists, movedExists)
	}
	waitObjectDeleted(t, b, moved.ID)
	b.mu.Lock()
	defer b.mu.Unlock()
	if got := b.Objects()[cancelled.ID]; got.ID != cancelled.ID || got.Expires != nil || got.Props["markdown"] != "keep" {
		t.Fatalf("cancelled object changed: %+v", got)
	}
}

func TestObjectExpiryRollbackRestoresDeadlineAndTimer(t *testing.T) {
	b := newTimed()
	t.Cleanup(func() { b.mu.Lock(); b.StopQuestionExpiry(); b.mu.Unlock() })
	b.mu.Lock()
	at := time.Now().Add(120 * time.Millisecond)
	o := b.Create(model.Note, map[string]any{"markdown": "original"}, nil, "", "", Expiry{At: &at})
	err := b.Atomically(func() error {
		_, err := b.Update(o.ID, nil, nil, nil, nil, "", "", Expiry{})
		if err != nil {
			return err
		}
		return InvalidParams("rollback")
	})
	restored := b.Objects()[o.ID]
	b.mu.Unlock()
	if err == nil || restored.Expires == nil || !restored.Expires.Equal(at) {
		t.Fatalf("rollback failed: %+v, %v", restored, err)
	}
	waitObjectDeleted(t, b, o.ID)
}

func TestObjectExpiryPersistsAcrossRestartAndExpiresSynchronouslyOnOpen(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "boards")
	first := NewRegistry(path, time.Hour, "")
	first.Mu.Lock()
	b, err := first.Open(root)
	if err != nil {
		first.Mu.Unlock()
		t.Fatal(err)
	}
	at := time.Now().Add(120 * time.Millisecond).UTC()
	o := b.Create(model.Note, map[string]any{"markdown": "closed"}, nil, "", "", Expiry{At: &at})
	kept := b.Create(model.Note, map[string]any{"markdown": "permanent"}, nil, "", "")
	if err := first.Close(b.ID(), nil); err != nil {
		first.Mu.Unlock()
		t.Fatal(err)
	}
	first.Mu.Unlock()
	saved, err := first.Store.Read(b.ID())
	if err != nil || saved == nil {
		t.Fatalf("read persisted board: %+v, %v", saved, err)
	}
	var deadline *time.Time
	for _, object := range saved.Objects {
		if object.ID == o.ID {
			deadline = object.Expires
		}
	}
	if deadline == nil || !deadline.Equal(at) {
		t.Fatalf("persisted expiry = %v, want %v", deadline, at)
	}
	time.Sleep(time.Until(at) + 30*time.Millisecond)
	second := NewRegistry(path, time.Hour, "")
	var deleted []string
	second.Hook = func(current *Board, e model.Event) {
		if e.Name == EventObjectDeleted {
			if registered, ok := second.Board(current.ID()); !ok || registered != current {
				t.Error("expiry fired before board registration")
			}
			deleted = append(deleted, e.Data.(map[string]any)["id"].(string))
		}
	}
	second.Mu.Lock()
	reopened, err := second.Open(root)
	if err != nil {
		second.Mu.Unlock()
		t.Fatal(err)
	}
	_, exists := reopened.Objects()[o.ID]
	permanent := reopened.Objects()[kept.ID]
	second.Mu.Unlock()
	defer second.Flush()
	if exists || permanent.Props["markdown"] != "permanent" || !reflect.DeepEqual(deleted, []string{o.ID}) {
		t.Fatalf("open retained due=%v, kept=%+v, deleted=%v", exists, permanent, deleted)
	}
}
