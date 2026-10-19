package board

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestObjectExpiryRestartSchedulesTheStoredFutureDeadline(t *testing.T) {
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
	at := time.Now().Add(250 * time.Millisecond)
	o := b.Create(model.Note, map[string]any{"markdown": "restart"}, nil, "", "", Expiry{At: &at})
	if err := first.Close(b.ID(), nil); err != nil {
		first.Mu.Unlock()
		t.Fatal(err)
	}
	first.Mu.Unlock()
	second := NewRegistry(path, time.Hour, "")
	events := make(chan model.Event, 16)
	second.Hook = func(_ *Board, event model.Event) { events <- event }
	second.Mu.Lock()
	reopened, err := second.Open(root)
	if err != nil {
		second.Mu.Unlock()
		t.Fatal(err)
	}
	stored := reopened.Objects()[o.ID]
	second.Mu.Unlock()
	t.Cleanup(func() { second.Mu.Lock(); reopened.StopQuestionExpiry(); second.Mu.Unlock(); second.Flush() })
	if stored.Expires == nil || !stored.Expires.Equal(at) || stored.Props["markdown"] != "restart" {
		t.Fatalf("restart lost deadline or object content: %+v", stored)
	}
	waitObjectDeleted(t, &timed{Board: reopened, mu: &second.Mu, events: events}, o.ID)
	first.Mu.Lock()
	closed := b.Objects()[o.ID]
	first.Mu.Unlock()
	if closed.ID != o.ID || closed.Props["markdown"] != "restart" {
		t.Fatalf("closed board's timer continued running: %+v", closed)
	}
}

func TestObjectAndQuestionExpiryShareTheirEarliestDeadline(t *testing.T) {
	b := newTimed()
	t.Cleanup(func() { b.mu.Lock(); b.StopQuestionExpiry(); b.mu.Unlock() })
	b.mu.Lock()
	at := time.Now().Add(80 * time.Millisecond)
	o := b.Create(model.Note, map[string]any{"markdown": "temporary"}, nil, "", "", Expiry{At: &at})
	q := ask(t, b.Board, expiring(time.Now().Add(180*time.Millisecond)), nil, "")
	b.mu.Unlock()
	waitObjectDeleted(t, b, o.ID)
	b.expired(t, q.ID, 3*time.Second)
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, exists := b.Objects()[o.ID]; exists || b.Objects()[q.ID].Props["status"] != "expired" {
		t.Fatalf("shared timer did not perform both operations: %v", b.Objects())
	}
}
