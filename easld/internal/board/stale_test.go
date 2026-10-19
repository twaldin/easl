package board

import (
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func TestStaleListsEveryReasonInOrderWithoutChangingTheBoard(t *testing.T) {
	now := time.Date(2001, 1, 8, 0, 0, 0, 0, time.UTC)
	old := now.Add(-8 * 24 * time.Hour)
	format := store.Format
	user := model.Actor{Kind: "user"}
	gone := model.Actor{Kind: "agent", Tile: "obj_missing"}
	live := model.Actor{Kind: "agent", Tile: "obj_live"}
	objects := []model.Object{
		{ID: "obj_all", Type: model.Terminal, CreatedBy: gone, CreatedAt: old, UpdatedAt: old, Expires: &now, Props: map[string]any{"title": "All reasons\nignored", "key": "scratch"}},
		{ID: "obj_creator", Type: model.Note, CreatedBy: gone, CreatedAt: now, UpdatedAt: now, Props: map[string]any{"markdown": "# Orphan\nbody"}},
		{ID: "obj_expired", Type: model.Image, CreatedBy: user, CreatedAt: now, UpdatedAt: now, Expires: &now, Props: map[string]any{"caption": "Expired image"}},
		{ID: "obj_exited", Type: model.Terminal, CreatedBy: user, CreatedAt: now, UpdatedAt: now, Props: map[string]any{"name": "Done"}},
		{ID: "obj_untouched", Type: model.Shape, CreatedBy: user, CreatedAt: old, UpdatedAt: old, Props: map[string]any{"text": "Old\nsecond line"}},
		{ID: "obj_fresh", Type: model.Note, CreatedBy: user, CreatedAt: now, UpdatedAt: now, Props: map[string]any{"markdown": "Fresh"}},
		{ID: "obj_live", Type: model.Terminal, CreatedBy: user, CreatedAt: now, UpdatedAt: now, Props: map[string]any{"name": "Live"}},
		{ID: "obj_live_child", Type: model.Note, CreatedBy: live, CreatedAt: now, UpdatedAt: now, Props: map[string]any{"markdown": "Agent is here"}},
		{ID: "obj_boundary", Type: model.Note, CreatedBy: user, CreatedAt: old, UpdatedAt: now.Add(-7 * 24 * time.Hour), Props: map[string]any{"markdown": "Exactly seven days"}},
	}
	b := FromSnapshot(&store.Snapshot{Format: &format, ID: "brd", Root: "/r", Revision: 42, Objects: objects})
	before := b.Snapshot()
	cursor := b.Activity.Cursor()
	events := 0
	b.OnEvent = func(model.Event) { events++ }
	got := b.Stale(now, 7*24*time.Hour, map[string]bool{"obj_all": true, "obj_exited": true, "obj_fresh": true})
	want := []any{
		map[string]any{"id": "obj_all", "type": "terminal", "title": "All reasons", "key": "scratch", "createdBy": map[string]any{"kind": "agent", "tile": "obj_missing"}, "updatedAt": -86400.0, "reasons": []any{"creator-gone", "expired", "untouched", "exited"}},
		map[string]any{"id": "obj_creator", "type": "note", "title": "Orphan", "createdBy": map[string]any{"kind": "agent", "tile": "obj_missing"}, "updatedAt": 604800.0, "reasons": []any{"creator-gone"}},
		map[string]any{"id": "obj_exited", "type": "terminal", "title": "Done", "createdBy": map[string]any{"kind": "user"}, "updatedAt": 604800.0, "reasons": []any{"exited"}},
		map[string]any{"id": "obj_expired", "type": "image", "title": "Expired image", "createdBy": map[string]any{"kind": "user"}, "updatedAt": 604800.0, "reasons": []any{"expired"}},
		map[string]any{"id": "obj_untouched", "type": "shape", "title": "Old", "createdBy": map[string]any{"kind": "user"}, "updatedAt": -86400.0, "reasons": []any{"untouched"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("stale objects = %#v, want %#v", got, want)
	}
	if !reflect.DeepEqual(before, b.Snapshot()) || b.Activity.Cursor() != cursor || events != 0 || b.Revision() != 42 {
		t.Fatalf("stale listing changed board state or emitted %d events", events)
	}
}

func TestStaleCreatorMustStillBeATerminalOnThisBoard(t *testing.T) {
	b := New("brd", "/r")
	wrongType := b.Create(model.Note, map[string]any{"markdown": "not a terminal"}, nil, "", "")
	o := b.Create(model.Note, map[string]any{"markdown": "owned"}, nil, "", wrongType.ID)
	got := b.Stale(time.Now(), 7*24*time.Hour, nil)
	if len(got) != 1 || got[0].(map[string]any)["id"] != o.ID || !reflect.DeepEqual(got[0].(map[string]any)["reasons"], []any{"creator-gone"}) {
		t.Fatalf("nonterminal creator wasn't classified as gone: %v", got)
	}
}
