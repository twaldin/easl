package board

import (
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestArchivedAnswerDoesNotAnchorLaterPlacement(t *testing.T) {
	b := New("brd", "/r")
	caller := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 100, 100), "", "")
	b.Create(model.Note, map[string]any{"markdown": "visible answer"}, frame(124, 0, 100, 100), "", caller.ID)
	b.Create(model.Question, map[string]any{"question": "old answer", "status": "answered", "archived": true, "keep": true}, frame(5000, 0, 200, 100), "", caller.ID)
	if got := b.Place(100, 100, caller.ID, nil, true); got != (model.Frame{X: 124, Y: 124, W: 100, H: 100}) {
		t.Fatalf("placement stacked beside archived answer: %v", got)
	}
}

func TestLoadingArchivedGroupDropsHistoricalMemberBounds(t *testing.T) {
	b := New("brd", "/r")
	q := b.Create(model.Question, map[string]any{"question": "answer", "status": "answered", "keep": true}, frame(500, 0, 200, 100), "", "")
	inner := b.Create(model.Group, map[string]any{"members": []any{q.ID}}, nil, "", "")
	outer := b.Create(model.Group, map[string]any{"members": []any{inner.ID}}, nil, "", "")
	if _, err := b.Update(q.ID, nil, nil, nil, map[string]any{"archived": true}, "", ""); err != nil {
		t.Fatal(err)
	}
	snapshot := b.Snapshot()
	for i, o := range snapshot.Objects {
		if o.Type == model.Group {
			snapshot.Objects[i].Frame.W, snapshot.Objects[i].Frame.H = 9000, 9000
		}
	}
	reopened := FromSnapshot(snapshot)
	for _, original := range []model.Object{inner, outer} {
		got := reopened.Objects()[original.ID]
		if got.Frame != (model.Frame{X: original.Frame.X, Y: original.Frame.Y}) {
			t.Errorf("reloaded all-hidden group retained historical space: %v", got.Frame)
		}
	}
	if _, err := reopened.Update(q.ID, nil, nil, nil, map[string]any{"archived": nil}, "", ""); err != nil {
		t.Fatal(err)
	}
	for _, original := range []model.Object{inner, outer} {
		if got := reopened.Objects()[original.ID].Frame; got != original.Frame {
			t.Errorf("reloaded group did not refit on unarchive: %v, want %v", got, original.Frame)
		}
	}
}

func TestGroupsWithoutHiddenMembersKeepTheirExistingEmptySemantics(t *testing.T) {
	b := New("brd", "/r")
	arrow := b.Create(model.Arrow, map[string]any{"from": map[string]any{"point": []any{0.0, 0.0}}, "to": map[string]any{"point": []any{100.0, 100.0}}}, frame(0, 0, 100, 100), "", "")
	for _, members := range [][]any{{}, {"obj_missing"}, {arrow.ID}} {
		want := model.Frame{X: 200, Y: 300, W: 400, H: 500}
		group := b.Create(model.Group, map[string]any{"members": members}, &want, "", "")
		if group.Frame != want {
			t.Errorf("group without hidden members changed its frame: %v, members %v", group.Frame, members)
		}
	}
}
