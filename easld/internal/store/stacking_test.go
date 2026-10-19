package store

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestRawRepositoryMergeInputsMigrateBeforeBeingSavedAsFormat3(t *testing.T) {
	one, two, three := 1, 2, 3
	cases := []struct {
		name   string
		format *int
	}{
		{"missing", nil},
		{"one", &one},
		{"two", &two},
		{"three", &three},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			repo, boards := filepath.Join(dir, "repo"), filepath.Join(dir, "boards")
			common := repository(t, repo)
			objects := func(prefix string) []model.Object {
				shape := adoptedObject(prefix+"_shape", model.Shape, 0, map[string]any{"kind": "rect"})
				note := adoptedObject(prefix+"_note", model.Note, 0, map[string]any{"markdown": "tile"})
				shape.Z, note.Z = -10, 100
				shape.Rev, note.Rev = 7, 7
				return []model.Object{shape, note}
			}
			existing := &Snapshot{Format: c.format, ID: RepoID(common), Root: Standardized(repo), Revision: 19,
				Objects: objects("obj_existing"), Repo: &RepoRecord{CommonDir: common, Worktrees: []WorktreeRecord{}}}
			sub := filepath.Join(repo, "sub")
			source := &Snapshot{Format: c.format, ID: PathID(sub), Root: Standardized(sub), Revision: 19, Objects: objects("obj_source")}
			s := New(boards, time.Hour, nil)
			for _, snapshot := range []*Snapshot{existing, source} {
				if err := s.Write(snapshot); err != nil {
					t.Fatal(err)
				}
			}
			sourceBytes, err := os.ReadFile(s.Path(source.ID))
			if err != nil {
				t.Fatal(err)
			}

			s.Loading(existing.ID, common, adoptedAt)
			merged := readStored(t, s, existing.ID)
			var ids []string
			var z []float64
			for _, o := range merged.Objects {
				if o.Type == model.Group {
					continue
				}
				ids = append(ids, o.ID)
				z = append(z, o.Z)
				wantHeight := 100.0
				if o.Type == model.Note && (c.format == nil || *c.format < 2) {
					wantHeight = 126
				}
				if o.Frame.H != wantHeight || o.Rev != 7 || !o.CreatedAt.Equal(adoptedAt) || !o.UpdatedAt.Equal(adoptedAt) {
					t.Fatalf("merge changed title height or edit metadata: %+v; want height %v, rev 7", o, wantHeight)
				}
			}
			wantIDs := []string{"obj_existing_note", "obj_existing_shape", "obj_source_note", "obj_source_shape"}
			wantZ := []float64{1, 2, 3, 4}
			if c.format != nil && *c.format == 3 {
				wantIDs = []string{"obj_existing_shape", "obj_existing_note", "obj_source_shape", "obj_source_note"}
				wantZ = []float64{-10, 100, 101, 211}
			}
			if merged.Format == nil || *merged.Format != 3 || merged.Revision != 20 || !reflect.DeepEqual(ids, wantIDs) || !reflect.DeepEqual(z, wantZ) {
				t.Fatalf("merged format %v rev %d order %v z %v; want format 3 rev 20 order %v z %v", merged.Format, merged.Revision, ids, z, wantIDs, wantZ)
			}
			backup, err := os.ReadFile(filepath.Join(boards, BackupFolder, source.ID+".json"))
			if err != nil || string(backup) != string(sourceBytes) {
				t.Fatalf("merge changed the raw source backup: %v", err)
			}
			again := New(boards, time.Hour, nil)
			again.Loading(existing.ID, common, adoptedAt)
			if got := readStored(t, again, existing.ID); !reflect.DeepEqual(got.JSON(), merged.JSON()) {
				t.Fatal("reopening migrated repository changed its saved state")
			}
		})
	}
}
