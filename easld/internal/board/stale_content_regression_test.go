package board

import (
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func agedContentBoard(objects ...model.Object) (*Board, time.Time) {
	now := time.Now().UTC().Truncate(time.Second)
	old := now.Add(-8 * 24 * time.Hour)
	for i := range objects {
		objects[i].Rev = 1
		objects[i].CreatedBy = model.Actor{Kind: "user"}
		objects[i].CreatedAt = old.Add(-24 * time.Hour)
		objects[i].UpdatedAt = old
	}
	format := store.Format
	return FromSnapshot(&store.Snapshot{Format: &format, ID: "brd_content", Root: "/r", Objects: objects}), now
}

func assertUntouched(t *testing.T, b *Board, now time.Time, id string, want bool) {
	t.Helper()
	found := false
	for _, value := range b.Stale(now, 7*24*time.Hour, nil) {
		entry := value.(map[string]any)
		if entry["id"] != id {
			continue
		}
		for _, reason := range entry["reasons"].([]any) {
			found = found || reason == "untouched"
		}
		if entry["updatedAt"] != model.APITime(b.Objects()[id].UpdatedAt) {
			t.Fatalf("stale result changed updatedAt: %v", entry)
		}
	}
	if found != want {
		t.Fatalf("object %s untouched = %v, want %v; stale = %v", id, found, want, b.Stale(now, 7*24*time.Hour, nil))
	}
}

func TestStaleContentAgeSurvivesMoveResizeAndReload(t *testing.T) {
	b, now := agedContentBoard(model.Object{ID: "obj_note", Type: model.Note, Frame: model.Frame{W: 200, H: 100}, Props: map[string]any{"markdown": "old draft"}})
	before := b.Objects()["obj_note"]
	assertUntouched(t, b, now, before.ID, true)
	for _, next := range []*model.Frame{frame(400, 50, 200, 100), frame(400, 50, 500, 300)} {
		moved, err := b.Update(before.ID, nil, next, nil, nil, "", "")
		if err != nil {
			t.Fatal(err)
		}
		if !moved.UpdatedAt.After(before.UpdatedAt) || moved.Frame != *next {
			t.Fatalf("layout write did not preserve normal mutation semantics: %+v", moved)
		}
		assertUntouched(t, b, now, before.ID, true)
	}
	data, err := b.Snapshot().Encode()
	if err != nil {
		t.Fatal(err)
	}
	saved, err := store.DecodeSnapshot(data)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Format == nil || *saved.Format != 3 {
		t.Fatalf("additive content timestamp changed board format: %v", saved.Format)
	}
	b = FromSnapshot(saved)
	assertUntouched(t, b, now, before.ID, true)
	if _, err := b.Update(before.ID, nil, nil, nil, map[string]any{"markdown": "edited draft"}, "", ""); err != nil {
		t.Fatal(err)
	}
	assertUntouched(t, b, now, before.ID, false)
}

func TestStaleContentAgeIgnoresGroupMembershipAndLayout(t *testing.T) {
	b, now := agedContentBoard(
		model.Object{ID: "obj_note", Type: model.Note, Frame: model.Frame{W: 200, H: 100}, Props: map[string]any{"markdown": "draft"}},
		model.Object{ID: "obj_group", Type: model.Group, Props: map[string]any{"title": "Plan", "members": []any{"obj_note"}}},
	)
	group := b.Objects()["obj_group"]
	if _, err := b.Update("obj_note", nil, frame(500, 200, 300, 150), nil, nil, "", ""); err != nil {
		t.Fatal(err)
	}
	if got := b.Objects()[group.ID]; got.Frame == group.Frame || !got.UpdatedAt.After(group.UpdatedAt) {
		t.Fatalf("group did not refit: %+v", got)
	}
	assertUntouched(t, b, now, group.ID, true)
	if _, err := b.Update(group.ID, nil, nil, nil, map[string]any{"members": []any{}}, "", ""); err != nil {
		t.Fatal(err)
	}
	assertUntouched(t, b, now, group.ID, true)
	if _, err := b.Update(group.ID, nil, nil, nil, map[string]any{"title": "New plan"}, "", ""); err != nil {
		t.Fatal(err)
	}
	assertUntouched(t, b, now, group.ID, false)
}

func TestStaleContentAgeIgnoresBookkeepingAndNoOpWrites(t *testing.T) {
	cases := []struct {
		name         string
		typ          model.ObjectType
		props, patch map[string]any
	}{
		{"note no-op", model.Note, map[string]any{"markdown": "draft"}, map[string]any{"markdown": "draft"}},
		{"terminal", model.Terminal, map[string]any{"name": "shell"}, map[string]any{"title": "busy", "lifecycle": map[string]any{"state": "working"}, "agent": map[string]any{"state": "idle"}}},
		{"browser", model.Browser, map[string]any{"url": "https://example.com"}, map[string]any{"pageTitle": "Page"}},
		{"browser URL no-op", model.Browser, map[string]any{"url": "https://example.com"}, map[string]any{"url": "https://example.com"}},
		{"follow", model.Code, map[string]any{"followOf": "obj_terminal", "path": "old.go"}, map[string]any{"path": "new.go", "range": map[string]any{"start": 2.0, "end": 3.0}, "lastAction": "edit", "lastChanges": []any{}, "history": []any{}}},
		{"diagram", model.Diagram, map[string]any{"path": "main.go", "symbol": "main"}, map[string]any{"graph": map[string]any{"nodes": []any{}}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b, now := agedContentBoard(model.Object{ID: "obj_old", Type: tc.typ, Frame: model.Frame{W: 200, H: 100}, Props: tc.props})
			if _, err := b.Update("obj_old", nil, nil, nil, tc.patch, "", ""); err != nil {
				t.Fatal(err)
			}
			assertUntouched(t, b, now, "obj_old", true)
			z, expiry := 20.0, now.Add(time.Hour)
			if _, err := b.Update("obj_old", nil, nil, &z, nil, "", "", Expiry{At: &expiry}); err != nil {
				t.Fatal(err)
			}
			assertUntouched(t, b, now, "obj_old", true)
		})
	}
}

func TestStaleContentAgeTracksArrowEndpointsNotBoundTargetMoves(t *testing.T) {
	b, now := agedContentBoard(
		model.Object{ID: "obj_from", Type: model.Shape, Frame: model.Frame{W: 160, H: 100}, Props: map[string]any{"kind": "rect"}},
		model.Object{ID: "obj_to", Type: model.Shape, Frame: model.Frame{X: 400, W: 160, H: 100}, Props: map[string]any{"kind": "rect"}},
		model.Object{ID: "obj_arrow", Type: model.Arrow, Props: map[string]any{"from": map[string]any{"object": "obj_from"}, "to": map[string]any{"object": "obj_to"}}},
	)
	props := model.Clone(b.Objects()["obj_arrow"].Props)
	path := b.ArrowPaths([]string{"obj_arrow"})["obj_arrow"]
	if _, err := b.Update("obj_to", nil, frame(700, 300, 160, 100), nil, nil, "", ""); err != nil {
		t.Fatal(err)
	}
	if reflect.DeepEqual(path, b.ArrowPaths([]string{"obj_arrow"})["obj_arrow"]) || !reflect.DeepEqual(props, b.Objects()["obj_arrow"].Props) {
		t.Fatal("bound target move should reroute without rewriting arrow props")
	}
	assertUntouched(t, b, now, "obj_arrow", true)
	if err := b.Delete("obj_to", ""); err != nil {
		t.Fatal(err)
	}
	assertUntouched(t, b, now, "obj_arrow", false)
}

func TestStaleContentAgeSurvivesLayoutUndoRedoAndRollback(t *testing.T) {
	b, now := agedContentBoard(model.Object{ID: "obj_note", Type: model.Note, Frame: model.Frame{W: 200, H: 100}, Props: map[string]any{"markdown": "draft"}})
	viewerMove(t, b, viewerA, 1, "obj_note", frame(300, 50, 200, 100))
	for _, redo := range []bool{false, true} {
		replayOf(t, b, viewerA, 1, redo)
		assertUntouched(t, b, now, "obj_note", true)
	}
	rollback := errors.New("rollback")
	if err := b.Atomically(func() error {
		if _, err := b.Update("obj_note", nil, frame(900, 0, 200, 100), nil, nil, "", ""); err != nil {
			return err
		}
		return rollback
	}); !errors.Is(err, rollback) {
		t.Fatalf("rollback = %v", err)
	}
	assertUntouched(t, b, now, "obj_note", true)
	viewerWrite(t, b, viewerA, 2, func() error {
		_, err := b.Update("obj_note", nil, nil, nil, map[string]any{"markdown": "revised"}, "", "")
		return err
	})
	for _, redo := range []bool{false, true} {
		replayOf(t, b, viewerA, 2, redo)
		assertUntouched(t, b, now, "obj_note", false)
	}
}

func TestStaleContentAgePreservesDeletedObjectAgeOnUndo(t *testing.T) {
	b, now := agedContentBoard(model.Object{ID: "obj_note", Type: model.Note, Frame: model.Frame{W: 200, H: 100}, Props: map[string]any{"markdown": "draft"}})
	viewerWrite(t, b, viewerA, 1, func() error { return b.Delete("obj_note", "") })
	replayOf(t, b, viewerA, 1, false)
	assertUntouched(t, b, now, "obj_note", true)
}

func TestStaleContentAgeTreatsArrowCoordinatesAsGeometry(t *testing.T) {
	for _, tc := range []struct {
		patch     map[string]any
		untouched bool
	}{
		{map[string]any{"from": map[string]any{"point": []any{10.0, 20.0}}}, true},
		{map[string]any{"to": map[string]any{"point": []any{300.0, 200.0}}}, true},
		{map[string]any{"to": map[string]any{"object": "obj_target"}}, false},
		{map[string]any{"label": "Updated relationship"}, false},
		{map[string]any{"color": "red"}, false},
	} {
		b, now := agedContentBoard(
			model.Object{ID: "obj_arrow", Type: model.Arrow, Props: map[string]any{
				"from": map[string]any{"point": []any{0.0, 0.0}},
				"to":   map[string]any{"point": []any{100.0, 100.0}},
			}},
			model.Object{ID: "obj_target", Type: model.Shape, Frame: model.Frame{W: 160, H: 100}, Props: map[string]any{"kind": "rect"}},
		)
		if _, err := b.Translate([]string{"obj_arrow"}, 50, 25, ""); err != nil {
			t.Fatal(err)
		}
		assertUntouched(t, b, now, "obj_arrow", true)
		if _, err := b.Update("obj_arrow", nil, nil, nil, tc.patch, "", ""); err != nil {
			t.Fatal(err)
		}
		assertUntouched(t, b, now, "obj_arrow", tc.untouched)
	}
}
