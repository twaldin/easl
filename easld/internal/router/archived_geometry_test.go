package router

import (
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

func closedGeometryQuestion(f *fixture, frame model.Frame) string {
	f.t.Helper()
	id := idOf(f.result("object.create", map[string]any{
		"type": "question", "props": questionProps(map[string]any{"keep": true, "key": "ARCHIVE-Q"}), "frame": frame.JSON(),
	}))
	f.result("object.update", map[string]any{
		"id": id, "frame": frame.JSON(), "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}},
	})
	return id
}

func TestArchivedQuestionDoesNotOverlapANoteInAnyCheckScope(t *testing.T) {
	f := newFixture(t)
	q := closedGeometryQuestion(f, model.Frame{W: 460, H: 148})
	n := idOf(f.result("object.create", map[string]any{
		"type": "note", "props": map[string]any{"markdown": "note"}, "frame": (model.Frame{X: 100, Y: 40, W: 200, H: 100}).JSON(),
	}))
	if got := f.result("layout.check", map[string]any{})["overlaps"].([]any); len(got) != 1 {
		t.Fatalf("visible question overlap = %v", got)
	}
	before := f.object(q)
	f.result("object.update", map[string]any{"id": q, "props": map[string]any{"archived": true}})
	for _, params := range []map[string]any{
		{}, {"ids": []any{q}}, {"ids": []any{n}}, {"rect": (model.Frame{W: 460, H: 148}).JSON()},
	} {
		if got := f.result("layout.check", params)["overlaps"].([]any); len(got) != 0 {
			t.Errorf("check %v reports archived overlap %v", params, got)
		}
	}
	got := f.object(q)
	if !model.Equal(got["frame"], before["frame"]) || !model.Equal(propsOf(got)["answer"], propsOf(before)["answer"]) || propsOf(got)["archived"] != true {
		t.Fatalf("archived question is not readable unchanged: %v", got)
	}
	if found := f.result("object.find", map[string]any{"key": "ARCHIVE-Q"}); idOf(found) != q {
		t.Fatalf("archived key lookup = %v", found)
	}
	for _, params := range []map[string]any{{"type": "question"}, {"type": "question", "status": "answered"}, {"keyPrefix": "ARCHIVE-"}} {
		found := f.result("object.find", params)["objects"].([]any)
		if len(found) != 1 || found[0].(map[string]any)["id"] != q {
			t.Errorf("archived lookup %v = %v", params, found)
		}
	}
}

func TestArchivedQuestionHasNoSpatialGraphEdgesInEitherDirection(t *testing.T) {
	for name, frame := range map[string]model.Frame{
		"overlaps":   {X: 100, Y: 40, W: 200, H: 100},
		"encloses":   {X: -10, Y: -10, W: 500, H: 300},
		"enclosedBy": {X: 20, Y: 20, W: 100, H: 50},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			q := closedGeometryQuestion(f, frame)
			n := idOf(f.result("object.create", note(0, map[string]any{"markdown": "note"})))
			before := f.result("object.get", map[string]any{"id": q, "as": "graph"})["graph"].(map[string]any)
			if edges := before[name].([]any); len(edges) != 1 || edges[0] != n {
				t.Fatalf("visible %s = %v", name, before)
			}
			f.result("object.update", map[string]any{"id": q, "props": map[string]any{"archived": true}})
			for _, id := range []string{q, n} {
				graph := f.result("object.get", map[string]any{"id": id, "as": "graph"})["graph"].(map[string]any)
				for _, key := range []string{"encloses", "enclosedBy", "overlaps"} {
					if edges := graph[key].([]any); len(edges) != 0 {
						t.Errorf("%s %s includes archived geometry: %v", id, key, edges)
					}
				}
			}
		})
	}
}

func TestAutomaticPlacementReusesArchivedQuestionSpace(t *testing.T) {
	f := newFixture(t)
	ideal := model.Frame{X: -100, Y: -50, W: 200, H: 100}
	q := closedGeometryQuestion(f, ideal)
	create := func() map[string]any {
		return f.result("object.create", map[string]any{
			"type": "note", "props": map[string]any{"markdown": "note"}, "frame": map[string]any{"w": 200.0, "h": 100.0},
		})
	}
	visible := create()
	if model.Equal(visible["object"].(map[string]any)["frame"], ideal.JSON()) {
		t.Fatal("placement did not avoid the visible question")
	}
	f.result("object.delete", map[string]any{"id": idOf(visible)})
	f.result("object.update", map[string]any{"id": q, "props": map[string]any{"archived": true}})
	placed := create()["object"].(map[string]any)
	if !model.Equal(placed["frame"], ideal.JSON()) {
		t.Fatalf("placement avoided archived question: %v, want %v", placed["frame"], ideal)
	}
}

func TestUnknownArchiveAndHiddenPropsDoNotHideNotes(t *testing.T) {
	f := newFixture(t)
	f.result("object.create", note(0, map[string]any{"markdown": "one", "archived": true, "hidden": true}))
	f.result("object.create", note(50, map[string]any{"markdown": "two"}))
	if got := f.result("layout.check", map[string]any{})["overlaps"].([]any); len(got) != 1 {
		t.Fatalf("unknown props hid visible note geometry: %v", got)
	}
}

func TestSizeFitDoesNotAvoidArchivedQuestion(t *testing.T) {
	f := newFixture(t)
	q := closedGeometryQuestion(f, model.Frame{X: 60, W: 200, H: 200})
	original := model.Frame{W: 40, H: 100}
	n := idOf(f.result("object.create", map[string]any{
		"type": "note", "props": map[string]any{"markdown": "note"}, "frame": original.JSON(),
	}))
	fit := func() model.Frame {
		o := f.result("object.update", map[string]any{"id": n, "size": "fit", "frame": map[string]any{"w": 200.0}})["object"].(map[string]any)
		return model.FrameFromJSON(o["frame"])
	}
	if got := fit(); got.X != -160 || got.Y != 0 {
		t.Fatalf("visible fit = %v, want top-right growth clear of question", got)
	}
	f.result("object.update", map[string]any{"id": n, "frame": original.JSON()})
	f.result("object.update", map[string]any{"id": q, "props": map[string]any{"archived": true}})
	if got := fit(); got.X != 0 || got.Y != 0 || got.W != 200 {
		t.Fatalf("fit avoided archived question: %v", got)
	}
}

func TestGroupsRefitWhenQuestionVisibilityChangesWithoutMoving(t *testing.T) {
	f := newFixture(t)
	q := closedGeometryQuestion(f, model.Frame{X: 500, W: 200, H: 100})
	n := idOf(f.result("object.create", note(0, map[string]any{"markdown": "note"})))
	group := func(members ...any) string {
		return idOf(f.result("object.create", map[string]any{"type": "group", "props": map[string]any{"members": members, "title": "Group"}}))
	}
	mixed, inner := group(n, q), group(q)
	outer := group(inner)
	before := map[string]model.Frame{}
	for _, id := range []string{mixed, inner, outer} {
		before[id] = model.FrameFromJSON(f.object(id)["frame"])
	}
	qFrame := f.object(q)["frame"]
	f.result("object.update", map[string]any{"id": q, "props": map[string]any{"archived": true}})
	if got := model.FrameFromJSON(f.object(mixed)["frame"]); got != (model.Frame{X: -24, Y: -56, W: 248, H: 180}) {
		t.Errorf("mixed group retained archived member bounds: %v", got)
	}
	for _, id := range []string{inner, outer} {
		want := model.Frame{X: before[id].X, Y: before[id].Y}
		if got := model.FrameFromJSON(f.object(id)["frame"]); got != want {
			t.Errorf("all-hidden group %s = %v, want %v", id, got, want)
		}
		graph := f.result("object.get", map[string]any{"id": id, "as": "graph"})["graph"].(map[string]any)
		for _, key := range []string{"encloses", "enclosedBy", "overlaps"} {
			if got := graph[key].([]any); len(got) != 0 {
				t.Errorf("collapsed group %s %s = %v", id, key, got)
			}
		}
	}
	ideal := model.Frame{X: 476, Y: -56, W: 20, H: 20}
	if got := f.board.PlaceIdeal(ideal); got != ideal {
		t.Errorf("collapsed groups still occupy placement space: %v", got)
	}
	if !model.Equal(f.object(q)["frame"], qFrame) {
		t.Fatal("archiving moved or resized the question")
	}
	f.result("object.update", map[string]any{"id": q, "props": map[string]any{"archived": nil}})
	for _, id := range []string{mixed, inner, outer} {
		if got := model.FrameFromJSON(f.object(id)["frame"]); got != before[id] {
			t.Errorf("unarchived group %s = %v, want %v", id, got, before[id])
		}
	}
	if !model.Equal(f.object(q)["frame"], qFrame) {
		t.Fatal("unarchiving moved or resized the question")
	}
}

func TestDeletingAnArchivedQuestionStillDetachesItsArrow(t *testing.T) {
	f := newFixture(t)
	q := closedGeometryQuestion(f, model.Frame{W: 200, H: 100})
	n := idOf(f.result("object.create", note(500, map[string]any{"markdown": "note"})))
	arrow := idOf(f.result("object.create", map[string]any{"type": "arrow", "props": map[string]any{
		"from": map[string]any{"object": q}, "to": map[string]any{"object": n},
	}}))
	visible := f.board.ArrowPaths([]string{arrow})[arrow]
	if len(visible) < 2 {
		t.Fatal("visible arrow has no route")
	}
	f.result("object.update", map[string]any{"id": q, "props": map[string]any{"archived": true}})
	if paths := f.board.ArrowPaths([]string{arrow}); len(paths) != 0 {
		t.Fatalf("archived arrow still has a drawn path: %v", paths)
	}
	graph := f.result("object.get", map[string]any{"id": q, "as": "graph"})["graph"].(map[string]any)
	if out := graph["arrowsOut"].([]any); len(out) != 1 || out[0].(map[string]any)["arrow"] != arrow {
		t.Fatalf("archiving removed the stored arrow relationship: %v", graph)
	}
	f.result("object.delete", map[string]any{"id": q})
	props := propsOf(f.object(arrow))
	want := map[string]any{"point": []any{visible[0].X, visible[0].Y}}
	if !model.Equal(props["from"], want) || !model.Equal(props["to"], map[string]any{"object": n}) {
		t.Fatalf("deleting archived question left a broken binding: %v", props)
	}
}
