package board

import (
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func stackingSnapshot(format *int, root string) *store.Snapshot {
	at := time.Unix(1_760_000_000, 0).UTC()
	object := func(id string, kind model.ObjectType, z float64, props map[string]any) model.Object {
		return model.Object{ID: id, Type: kind, Frame: model.Frame{X: 0, Y: 0, W: 200, H: 100}, Z: z, Rev: 7,
			CreatedBy: model.Actor{Kind: "user"}, CreatedAt: at, UpdatedAt: at, Props: props}
	}
	return &store.Snapshot{Format: format, ID: "brd_stacking", Root: root, Revision: 19, Objects: []model.Object{
		object("obj_tile_z", model.Browser, 500, map[string]any{"url": "https://example.com"}),
		object("obj_shape_b", model.Shape, -40, map[string]any{"kind": "rect"}),
		object("obj_group_z", model.Group, 900, map[string]any{"members": []any{}}),
		object("obj_arrow", model.Arrow, -10, map[string]any{"from": map[string]any{"point": []any{0.0, 0.0}}, "to": map[string]any{"point": []any{200.0, 100.0}}}),
		object("obj_tile_low", model.Note, 200, map[string]any{"markdown": "tile"}),
		object("obj_text", model.Shape, 5, map[string]any{"kind": "text", "text": "label"}),
		object("obj_group_a", model.Group, 700, map[string]any{"members": []any{}}),
		object("obj_ink_a", model.Shape, -40, map[string]any{"kind": "ink", "points": []any{[]any{0.0, 0.0}, []any{200.0, 100.0}}}),
		object("obj_tile_a", model.Code, 500, map[string]any{"path": "a.swift"}),
	}}
}

func stackingIDs(objects []model.Object) []string {
	ids := make([]string, len(objects))
	for i, object := range objects {
		ids[i] = object.ID
	}
	return ids
}

func TestLegacySavedBoardsKeepVisibleTiersAndSameTierOrder(t *testing.T) {
	one, two := 1, 2
	for _, format := range []*int{nil, &one, &two} {
		root := t.TempDir()
		s := store.New(filepath.Join(root, "boards"), time.Hour, nil)
		original := stackingSnapshot(format, root)
		if err := s.Write(original); err != nil {
			t.Fatal(err)
		}
		stored, err := s.Read(original.ID)
		if err != nil {
			t.Fatal(err)
		}
		b := FromSnapshot(stored)
		saved := b.Snapshot()
		wantIDs := []string{"obj_group_a", "obj_group_z", "obj_tile_low", "obj_tile_a", "obj_tile_z", "obj_ink_a", "obj_shape_b", "obj_arrow", "obj_text"}
		if saved.Format == nil || *saved.Format != 3 || !reflect.DeepEqual(stackingIDs(saved.Objects), wantIDs) {
			t.Fatalf("saved format %v, order %v; want format 3, %v", saved.Format, stackingIDs(saved.Objects), wantIDs)
		}
		for i, o := range saved.Objects {
			if o.Z != float64(i+1) {
				t.Fatalf("%s z %v, want %d", o.ID, o.Z, i+1)
			}
		}
		if b.Revision() != 19 || len(b.Changed(19)) != 0 || len(b.history.open) != 0 || len(b.viewers) != 0 {
			t.Fatalf("migration recorded edits: revision %d, history %+v, viewers %v", b.Revision(), b.history, b.viewers)
		}
		for _, o := range original.Objects {
			got, err := b.Object(o.ID)
			if err != nil {
				t.Fatal(err)
			}
			o.Z = got.Z
			if (format == nil || *format < 2) && o.Type.IsTile() {
				o.Frame.H = 126
			}
			if !reflect.DeepEqual(got, o) {
				t.Fatalf("%s changed beyond format migration: %+v, want %+v", o.ID, got, o)
			}
		}
		reversed := stackingSnapshot(format, root)
		for i, j := 0, len(reversed.Objects)-1; i < j; i, j = i+1, j-1 {
			reversed.Objects[i], reversed.Objects[j] = reversed.Objects[j], reversed.Objects[i]
		}
		if !reflect.DeepEqual(FromSnapshot(reversed).Snapshot().JSON(), saved.JSON()) {
			t.Fatal("file object order changed migrated stacking")
		}
		if !reflect.DeepEqual(stored.JSON(), original.JSON()) {
			t.Fatal("loading mutated the source snapshot")
		}
		if err := s.Write(saved); err != nil {
			t.Fatal(err)
		}
		onDisk, err := s.Read(original.ID)
		if err != nil {
			t.Fatal(err)
		}
		reopened := FromSnapshot(onDisk)
		if !reflect.DeepEqual(reopened.Snapshot().JSON(), saved.JSON()) {
			t.Fatal("reopening changed the migrated board")
		}
	}
}

func TestFormat3KeepsLiteralZAcrossRestackingSavingAndReopening(t *testing.T) {
	format := 3
	root := t.TempDir()
	original := stackingSnapshot(&format, root)
	b := FromSnapshot(original)
	for _, o := range original.Objects {
		got, err := b.Object(o.ID)
		if err != nil || !reflect.DeepEqual(got, o) {
			t.Fatalf("format 3 changed %s: %+v, %v; want %+v", o.ID, got, err, o)
		}
	}
	want := []string{"obj_ink_a", "obj_shape_b", "obj_arrow", "obj_text", "obj_tile_low", "obj_tile_a", "obj_tile_z", "obj_group_a", "obj_group_z"}
	if got := stackingIDs(b.Snapshot().Objects); !reflect.DeepEqual(got, want) {
		t.Fatalf("literal z order %v, want %v", got, want)
	}
	z := -100.0
	if _, err := b.Update("obj_tile_low", nil, nil, &z, nil, "", ""); err != nil {
		t.Fatal(err)
	}
	s := store.New(filepath.Join(root, "boards"), time.Hour, nil)
	saved := b.Snapshot()
	if err := s.Write(saved); err != nil {
		t.Fatal(err)
	}
	onDisk, err := s.Read(b.ID())
	if err != nil {
		t.Fatal(err)
	}
	reopened := FromSnapshot(onDisk)
	if !reflect.DeepEqual(reopened.Snapshot().JSON(), saved.JSON()) {
		t.Fatal("reopening changed explicit z after a restack")
	}
	want = []string{"obj_tile_low", "obj_ink_a", "obj_shape_b", "obj_arrow", "obj_text", "obj_tile_a", "obj_tile_z", "obj_group_a", "obj_group_z"}
	if got := stackingIDs(reopened.Snapshot().Objects); !reflect.DeepEqual(got, want) {
		t.Fatalf("restacked order %v, want %v", got, want)
	}
	viewerWrite(t, reopened, viewerA, 1, func() error {
		z := -200.0
		_, err := reopened.Update("obj_shape_b", nil, nil, &z, nil, "", "")
		return err
	})
	if got := reopened.Snapshot().Objects[0].ID; got != "obj_shape_b" {
		t.Fatalf("reopened board did not restack: first %s", got)
	}
	if _, err := reopened.ReplayViewer(viewerA, 1, false); err != nil {
		t.Fatal(err)
	}
	shape, err := reopened.Object("obj_shape_b")
	if err != nil || shape.Z != -40 || reopened.Snapshot().Objects[0].ID != "obj_tile_low" {
		t.Fatalf("undo did not restore explicit stacking: shape %+v, %v", shape, err)
	}
}
