package board

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func TestContentTimestampCreationAndFileRoundTrip(t *testing.T) {
	b := New("brd_content", "/r")
	o := b.Create(model.Note, map[string]any{"markdown": "new"}, nil, "", "")
	if !o.ContentTime().Equal(o.CreatedAt) || !o.UpdatedAt.Equal(o.CreatedAt) {
		t.Fatalf("creation timestamps = %+v", o)
	}
	for _, key := range []string{"contentUpdatedAt", "contentRev"} {
		if _, present := o.APIJSON()[key]; present {
			t.Fatalf("private storage field %s leaked into API", key)
		}
	}
	decoded, err := model.ObjectFromJSON(o.FileJSON())
	if err != nil {
		t.Fatal(err)
	}
	if model.FileTime(decoded.ContentTime()) != model.FileTime(o.CreatedAt) {
		t.Fatalf("file roundtrip lost creation age: %+v", decoded)
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

func TestContentAgeFallsBackAfterReleasedHostRoundTrip(t *testing.T) {
	b, now := agedContentBoard(model.Object{ID: "obj_note", Type: model.Note, Frame: model.Frame{W: 200, H: 100}, Props: map[string]any{"markdown": "old"}})
	if _, err := b.Update("obj_note", nil, frame(100, 0, 200, 100), nil, nil, "", ""); err != nil {
		t.Fatal(err)
	}
	data, err := b.Snapshot().Encode()
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]any
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	object := saved["objects"].([]any)[0].(map[string]any)
	for _, marker := range []string{"retained", "absent"} {
		t.Run(marker, func(t *testing.T) {
			// Released hosts retain unknown fields, but only advance the normal write metadata.
			object["rev"] = object["rev"].(float64) + 1
			object["updatedAt"] = model.FileTime(now)
			object["props"].(map[string]any)["markdown"] = "edited by released host"
			if marker == "absent" {
				delete(object, "contentRev")
			}
			roundTrip, err := json.Marshal(saved)
			if err != nil {
				t.Fatal(err)
			}
			snapshot, err := store.DecodeSnapshot(roundTrip)
			if err != nil {
				t.Fatal(err)
			}
			reloaded := FromSnapshot(snapshot)
			assertUntouched(t, reloaded, now, "obj_note", false)
			assertUntouched(t, reloaded, now.Add(8*24*time.Hour), "obj_note", true)
			if _, err := reloaded.Update("obj_note", nil, frame(200, 0, 200, 100), nil, nil, "", ""); err != nil {
				t.Fatal(err)
			}
			assertUntouched(t, reloaded, now, "obj_note", false)
			assertUntouched(t, reloaded, now.Add(8*24*time.Hour), "obj_note", true)
		})
	}
}
