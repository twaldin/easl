package board

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func TestCreationAuthorNamePrecedence(t *testing.T) {
	b := New("brd_author", "/tmp")
	terminal := b.Create(model.Terminal, map[string]any{"name": "  Named  ", "title": "Title", "agent": map[string]any{"kind": "omp"}}, nil, "", "")
	if terminal.AuthorName == nil || *terminal.AuthorName != "you" {
		t.Fatalf("user snapshot = %v", terminal.APIJSON())
	}
	for _, c := range []struct {
		patch map[string]any
		want  string
	}{
		{nil, "Named"},
		{map[string]any{"name": nil}, "Title"},
		{map[string]any{"title": nil}, "omp"},
		{map[string]any{"agent": nil}, "Terminal"},
	} {
		if c.patch != nil {
			if _, err := b.Update(terminal.ID, nil, nil, nil, c.patch, "", ""); err != nil {
				t.Fatal(err)
			}
		}
		for _, typ := range []model.ObjectType{model.Note, model.Terminal, model.Code, model.Group} {
			o := b.Create(typ, map[string]any{}, nil, "", terminal.ID)
			if o.AuthorName == nil || *o.AuthorName != c.want || o.APIJSON()["authorName"] != c.want {
				t.Fatalf("%s snapshot = %v, want %q", typ, o.APIJSON(), c.want)
			}
		}
	}
}

func TestAuthorSnapshotCrossBoardRenameRemovalAndRestart(t *testing.T) {
	dir := t.TempDir()
	firstRoot, secondRoot := filepath.Join(dir, "first"), filepath.Join(dir, "second")
	for _, root := range []string{firstRoot, secondRoot} {
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	reg := NewRegistry(filepath.Join(dir, "boards"), time.Hour, "")
	defer reg.Flush()
	reg.Mu.Lock()
	defer reg.Mu.Unlock()
	first, err := reg.Open(firstRoot)
	if err != nil {
		t.Fatal(err)
	}
	second, err := reg.Open(secondRoot)
	if err != nil {
		t.Fatal(err)
	}
	terminal := first.Create(model.Terminal, map[string]any{"name": "Captured"}, nil, "", "")
	output := second.Create(model.Note, nil, nil, "", terminal.ID)
	if _, err := first.Update(terminal.ID, nil, nil, nil, map[string]any{"name": "Renamed"}, "", ""); err != nil {
		t.Fatal(err)
	}
	if err := first.Delete(terminal.ID, ""); err != nil {
		t.Fatal(err)
	}
	if err := reg.Close(second.ID(), nil); err != nil {
		t.Fatal(err)
	}
	reloaded, err := reg.Open(secondRoot)
	if err != nil {
		t.Fatal(err)
	}
	stored := reloaded.Objects()[output.ID]
	if stored.AuthorName == nil || *stored.AuthorName != "Captured" {
		t.Fatalf("reload = %v", stored.FileJSON())
	}
	wire, err := json.Marshal(stored.APIJSON())
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(wire, &fields); err != nil {
		t.Fatal(err)
	}
	replicated, err := model.ObjectFromJSON(fields)
	if err != nil || replicated.AuthorName == nil || *replicated.AuthorName != "Captured" {
		t.Fatalf("replication = %+v, %v", replicated, err)
	}
}

func TestLegacyAuthorSnapshotStaysAbsentAndUnknownFieldsSurvive(t *testing.T) {
	b := New("brd_legacy", "/tmp")
	o := b.Create(model.Note, nil, nil, "", "")
	file := o.FileJSON()
	delete(file, "authorName")
	legacy, err := model.ObjectFromJSON(file)
	if err != nil {
		t.Fatal(err)
	}
	legacy.Unknown = map[string]any{"future": "kept", "authorName": "must not backfill"}
	b = FromSnapshot(&store.Snapshot{ID: b.ID(), Root: b.Root(), Objects: []model.Object{legacy}})
	updated, err := b.Update(o.ID, nil, nil, nil, map[string]any{"markdown": "edit"}, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if updated.AuthorName != nil || updated.APIJSON()["authorName"] != nil || updated.FileJSON()["authorName"] != nil || updated.FileJSON()["future"] != "kept" {
		t.Fatalf("legacy changed = %v", updated.FileJSON())
	}
}
