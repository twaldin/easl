package board

import (
	"errors"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func TestContentTimestampCreationCloneAndAPIFileRoundTrips(t *testing.T) {
	b := New("brd_content", "/r")
	o := b.Create(model.Note, map[string]any{"markdown": "new"}, nil, "", "")
	if !o.ContentUpdatedAt.Equal(o.CreatedAt) || !o.UpdatedAt.Equal(o.CreatedAt) {
		t.Fatalf("creation timestamps = %+v", o)
	}
	o.ContentUpdatedAt = o.ContentUpdatedAt.Truncate(time.Second)
	for name, value := range map[string]map[string]any{"api": o.APIJSON(), "file": o.FileJSON()} {
		t.Run(name, func(t *testing.T) {
			decoded, err := model.ObjectFromJSON(value)
			if err != nil {
				t.Fatal(err)
			}
			if model.FileTime(decoded.ContentUpdatedAt) != model.FileTime(o.ContentUpdatedAt) {
				t.Fatalf("content timestamp lost in %s roundtrip: %+v", name, decoded)
			}
			if name == "api" && decoded.APIJSON()["contentUpdatedAt"] != value["contentUpdatedAt"] {
				t.Fatal("API mirror changed content timestamp")
			}
		})
	}
}

func TestContentTimestampLegacyFallbackUsesUpdatedAtAndFreezesOnFirstMove(t *testing.T) {
	b, now := agedContentBoard(model.Object{ID: "obj_note", Type: model.Note, Frame: model.Frame{W: 200, H: 100}, Props: map[string]any{"markdown": "old"}})
	legacy := b.Objects()["obj_note"]
	legacy.UpdatedAt = now
	b = FromSnapshot(&store.Snapshot{ID: b.ID(), Root: b.Root(), Objects: []model.Object{legacy}})
	if o := b.Objects()[legacy.ID]; !o.ContentUpdatedAt.IsZero() || !o.ContentTime().Equal(now) {
		t.Fatalf("legacy fallback = %+v", o)
	}
	assertUntouched(t, b, now, legacy.ID, false)
	moved, err := b.Update(legacy.ID, nil, frame(200, 50, 200, 100), nil, nil, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !moved.ContentUpdatedAt.Equal(now) || !moved.UpdatedAt.After(now) {
		t.Fatalf("first legacy move did not freeze previous updatedAt: %+v", moved)
	}
	for _, value := range []any{nil, model.FileTime(now)} {
		file := legacy.FileJSON()
		file["contentUpdatedAt"] = value
		decoded, err := model.ObjectFromJSON(file)
		if err != nil || !decoded.ContentTime().Equal(now) {
			t.Fatalf("optional timestamp %v: %+v, %v", value, decoded, err)
		}
	}
}

func TestContentTimestampAuthoredRollbackRestoresContentAge(t *testing.T) {
	b, now := agedContentBoard(model.Object{ID: "obj_note", Type: model.Note, Frame: model.Frame{W: 200, H: 100}, Props: map[string]any{"markdown": "old"}})
	before := b.Objects()["obj_note"]
	rollback := errors.New("rollback")
	if err := b.Atomically(func() error {
		if _, err := b.Update("obj_note", nil, nil, nil, map[string]any{"markdown": "temporary"}, "", ""); err != nil {
			return err
		}
		return rollback
	}); !errors.Is(err, rollback) {
		t.Fatal(err)
	}
	o := b.Objects()["obj_note"]
	if o.Props["markdown"] != "old" || !o.ContentUpdatedAt.Equal(before.UpdatedAt) || !o.UpdatedAt.After(before.UpdatedAt) {
		t.Fatalf("authored rollback did not restore content and its age: %+v", o)
	}
	assertUntouched(t, b, now, o.ID, true)
}

func TestContentTimestampQuietWritesPreserveContentAge(t *testing.T) {
	b, now := agedContentBoard(model.Object{ID: "obj_browser", Type: model.Browser, Frame: model.Frame{W: 200, H: 100}, Props: map[string]any{"url": "https://example.com"}})
	before := b.Objects()["obj_browser"]
	if err := b.WriteBookkeeping(before.ID, map[string]any{"pageTitle": "Observed page"}); err != nil {
		t.Fatal(err)
	}
	assertUntouched(t, b, now, before.ID, true)
	if err := b.WriteQuiet(before.ID, map[string]any{"drawingMachine": "local"}); err != nil {
		t.Fatal(err)
	}
	assertUntouched(t, b, now, before.ID, true)
	if got := b.Objects()[before.ID]; !got.UpdatedAt.Equal(before.UpdatedAt) || got.Rev != before.Rev {
		t.Fatalf("quiet write changed existing write semantics: %+v", got)
	}
}
