package board

import (
	"sync"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

type closeSaveLock struct {
	sync.Locker
	once      sync.Once
	attempted chan struct{}
	proceed   chan struct{}
}

func (lock *closeSaveLock) Lock() {
	lock.once.Do(func() {
		close(lock.attempted)
		<-lock.proceed
	})
	lock.Locker.Lock()
}

func TestCloseInvalidatesASaveAlreadyWaitingToSnapshotTheOldBoard(t *testing.T) {
	root := t.TempDir()
	reg := NewRegistry(t.TempDir(), time.Hour, "")
	gate := &closeSaveLock{Locker: &reg.Mu, attempted: make(chan struct{}), proceed: make(chan struct{})}
	defer func() {
		select {
		case <-gate.proceed:
		default:
			close(gate.proceed)
		}
	}()
	reg.Store = store.New(reg.Store.Dir, time.Millisecond, gate)
	reg.Mu.Lock()
	old, err := reg.Open(root)
	if err != nil {
		reg.Mu.Unlock()
		t.Fatal(err)
	}
	original := old.Create(model.Note, map[string]any{"markdown": "original"}, &model.Frame{X: 0, Y: 0, W: 200, H: 100}, "", "")
	reg.Mu.Unlock()
	select {
	case <-gate.attempted:
	case <-time.After(3 * time.Second):
		t.Fatal("the old board's save did not leave the debounce queue")
	}
	reg.Mu.Lock()
	if err := reg.Close(old.ID(), nil); err != nil {
		reg.Mu.Unlock()
		t.Fatal(err)
	}
	reopened, err := reg.Open(root)
	if err != nil {
		reg.Mu.Unlock()
		t.Fatal(err)
	}
	fresh := reopened.Create(model.Note, map[string]any{"markdown": "reopened"}, &model.Frame{X: 300, Y: 0, W: 200, H: 100}, "", "")
	stale := old.Create(model.Note, map[string]any{"markdown": "stale"}, &model.Frame{X: 600, Y: 0, W: 200, H: 100}, "", "")
	reg.Mu.Unlock()
	close(gate.proceed)
	reg.Flush()
	snap, err := reg.Store.Read(old.ID())
	if err != nil || snap == nil {
		t.Fatalf("saved replacement: %+v, %v", snap, err)
	}
	got := map[string]string{}
	for _, object := range snap.Objects {
		got[object.ID], _ = object.Props["markdown"].(string)
	}
	if len(got) != 2 || got[original.ID] != "original" || got[fresh.ID] != "reopened" || got[stale.ID] != "" {
		t.Fatalf("an old timer overwrote the reopened board: %v", got)
	}
}
