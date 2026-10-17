package board

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func legacyAnchorSnapshot(root, id string, objects ...model.Object) *store.Snapshot {
	format := store.Format
	at := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	for i := range objects {
		objects[i].Rev = 7
		objects[i].CreatedAt, objects[i].UpdatedAt = at, at
		objects[i].CreatedBy = model.Actor{Kind: "user"}
		objects[i].Frame = model.Frame{X: float64(i * 300), W: 200, H: 100}
	}
	return &store.Snapshot{Format: &format, ID: id, Root: root, Revision: 19, Objects: objects,
		Unknown: map[string]any{"futureState": map[string]any{"kept": "yes"}}}
}

func TestRegistryLoadScrubsPersistedAnchorsBeforeOpening(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "inside.rs"), []byte("inside anchor\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	const markdown = "Authored prose anchor=\"keep prose\"\r\n\r\n> - ~~~rs file=../outside.rs#L1 anchor=\"LEAKED_NOTE_ANCHOR_7a91\"  \r\n>   authored body anchor=\"keep body\"\r\n>   ~~~\r\n\r\n```rs file=inside.rs#L1 anchor=\"inside anchor\"\r\n```\r\n\r\n```rs file=missing.rs#L1 anchor=\"missing anchor\"\r\n```\r\n"
	const clean = "Authored prose anchor=\"keep prose\"\r\n\r\n> - ~~~rs file=../outside.rs#L1   \r\n>   authored body anchor=\"keep body\"\r\n>   ~~~\r\n\r\n```rs file=inside.rs#L1 anchor=\"inside anchor\"\r\n```\r\n\r\n```rs file=missing.rs#L1 anchor=\"missing anchor\"\r\n```\r\n"
	reg := NewRegistry(t.TempDir(), time.Hour, "")
	id := store.PathID(root)
	snap := legacyAnchorSnapshot(root, id,
		model.Object{ID: "obj_note", Type: model.Note, Props: map[string]any{"markdown": markdown, "caption": "authored caption"}},
		model.Object{ID: "obj_code", Type: model.Code, Props: map[string]any{"path": "../outside.rs", "anchor": "LEAKED_CODE_ANCHOR_7a91", "range": model.LineRange{Start: 1, End: 1}.JSON(), "caption": "keep caption"}},
		model.Object{ID: "obj_inside", Type: model.Code, Props: map[string]any{"path": "inside.rs", "anchor": "inside anchor"}},
		model.Object{ID: "obj_missing", Type: model.Code, Props: map[string]any{"path": "missing.rs", "anchor": "missing anchor"}},
	)
	if err := reg.Store.Write(snap); err != nil {
		t.Fatal(err)
	}
	snap.Objects[0].Props["markdown"] = clean
	delete(snap.Objects[1].Props, "anchor")
	opened := false
	reg.Opened = func(b *Board, _ string) {
		opened = true
		if b.objects["obj_note"].Props["markdown"] != clean || b.objects["obj_code"].Props["anchor"] != nil {
			t.Error("opened callback observed persisted legacy anchors")
		}
	}
	reg.Mu.Lock()
	b, err := reg.Open(root)
	reg.Mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if !opened || b.Revision() != 19 {
		t.Fatalf("open = %v, revision = %d", opened, b.Revision())
	}
	for _, expected := range snap.Objects {
		if got := b.objects[expected.ID]; !reflect.DeepEqual(got.FileJSON(), expected.FileJSON()) {
			t.Errorf("loaded %s = %#v, want %#v", expected.ID, got.FileJSON(), expected.FileJSON())
		}
	}
	if len(b.history.open) != 0 || len(b.history.openUpdates) != 0 {
		t.Fatalf("normalization recorded history: %+v", b.history)
	}
	entries := b.Activity.Entries()
	if len(entries) != 1 || entries[0].Kind != KindRestart || entries[0].Rev != 19 {
		t.Fatalf("normalization recorded activity: %+v", entries)
	}
	disk, err := reg.Store.Read(id)
	if err != nil || disk == nil {
		t.Fatalf("read normalized board: %v", err)
	}
	if !reflect.DeepEqual(disk.JSON(), snap.JSON()) {
		t.Fatalf("disk state changed beyond anchors: %#v, want %#v", disk.JSON(), snap.JSON())
	}
	data, err := os.ReadFile(reg.Store.Path(id))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("LEAKED_")) {
		t.Fatalf("disk retained legacy anchor: %s", data)
	}
	fixed := time.Unix(1234567890, 0)
	if err := os.Chtimes(reg.Store.Path(id), fixed, fixed); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(reg.Store.Path(id))
	if err != nil {
		t.Fatal(err)
	}
	again := NewRegistry(reg.Store.Dir, time.Hour, "")
	again.Mu.Lock()
	reloaded, err := again.Open(root)
	again.Mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(reg.Store.Path(id))
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) || !after.ModTime().Equal(before.ModTime()) || reloaded.Revision() != 19 {
		t.Fatal("a second load rewrote normalized metadata or changed its revision")
	}
}

func TestRegistryLoadPropagatesAnchorNormalizationSaveFailure(t *testing.T) {
	root := t.TempDir()
	reg := NewRegistry(t.TempDir(), time.Hour, "")
	id := store.PathID(root)
	snap := legacyAnchorSnapshot(root, "blocked/nested", model.Object{ID: "obj_code", Type: model.Code, Props: map[string]any{"path": "../outside.rs", "anchor": "legacy"}})
	data, err := snap.Encode()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(reg.Store.Path(id), data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(reg.Store.Dir, "blocked"), []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}
	reg.Mu.Lock()
	b, err := reg.Open(root)
	reg.Mu.Unlock()
	if b != nil || err == nil || !strings.Contains(err.Error(), "save normalized board") || len(reg.Boards()) != 0 {
		t.Fatalf("failed normalization save published a board: %v, %v, %v", b, err, reg.Boards())
	}
	after, readErr := os.ReadFile(reg.Store.Path(id))
	if readErr != nil || !bytes.Equal(after, data) {
		t.Fatalf("failed normalization changed original disk state: %q, %v", after, readErr)
	}
}

