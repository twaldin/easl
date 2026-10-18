package router

import (
	"reflect"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

const testViewer = "vw_window01"

func TestObjectUpdateZRestacks(t *testing.T) {
	f := newFixture(t)
	low := idOf(f.result("object.create", note(0, map[string]any{"markdown": "low"})))
	high := idOf(f.result("object.create", note(300, map[string]any{"markdown": "high"})))
	updated := f.result("object.update", map[string]any{"id": low, "z": 5.0})
	if z := updated["object"].(map[string]any)["z"]; z != 5.0 {
		t.Fatalf("result z %v, want 5", z)
	}
	if lowZ, highZ := f.board.Objects()[low].Z, f.board.Objects()[high].Z; lowZ != 5 || highZ != 2 {
		t.Fatalf("z low %v high %v, want 5 over 2", lowZ, highZ)
	}
	if code, message := errorOf(f.call("object.update", map[string]any{"id": low, "z": "top"})); code != "invalid_params" || message != "z must be a finite number" {
		t.Fatalf("%s: %s", code, message)
	}
}

func TestViewerWithoutStepIsInvalid(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", note(0, map[string]any{"markdown": "plan"})))
	code, message := errorOf(f.call("object.update", map[string]any{"id": id, "frame": map[string]any{"x": 300.0}, "viewer": testViewer}))
	if code != "invalid_params" || message != "viewer and step come together: a remote window's edit names both" {
		t.Fatalf("%s: %s", code, message)
	}
	if x := f.board.Objects()[id].Frame.X; x != 0 {
		t.Fatalf("the refused update moved the note to x %v", x)
	}
}

func TestViewerInsideABatchOpIsInvalidAndNothingChanges(t *testing.T) {
	f := newFixture(t)
	code, message := errorOf(f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": note(0, map[string]any{"markdown": "plan"})},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "$0", "z": 9.0, "viewer": testViewer, "step": 1.0}},
	}}))
	if code != "invalid_params" || message != "op 1 (object.update): viewer and step mark a remote window's own edit; they aren't allowed inside object.batch" {
		t.Fatalf("%s: %s", code, message)
	}
	if n := len(f.board.Objects()); n != 0 {
		t.Fatalf("the refused batch left %d objects", n)
	}
}

func TestBoardUndoAndRedoReplayAViewersOwnSteps(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", note(0, map[string]any{"markdown": "plan"})))
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{"markdown": "plan v2"}})
	nothing := map[string]any{"changed": []any{}, "deleted": []any{}, "kept": []any{}, "pushed": false}
	if got := f.result("board.undo", map[string]any{"viewer": testViewer, "step": 1.0}); !reflect.DeepEqual(got, nothing) {
		t.Fatalf("undo with no viewer step recorded: %v", got)
	}

	f.result("object.update", map[string]any{"id": id, "frame": map[string]any{"x": 300.0, "y": 40.0}, "viewer": testViewer, "step": 1.0})
	frameAfter := func(method string, want map[string]any) {
		t.Helper()
		got := f.result(method, map[string]any{"viewer": testViewer, "step": 1.0})
		changed, _ := got["changed"].([]any)
		if got["step"] != 1.0 || got["pushed"] != true || len(changed) != 1 || !reflect.DeepEqual(got["deleted"], []any{}) || !reflect.DeepEqual(got["kept"], []any{}) {
			t.Fatalf("%s: %v", method, got)
		}
		object := changed[0].(map[string]any)
		if object["id"] != id || !reflect.DeepEqual(object["frame"], want) || object["props"].(map[string]any)["markdown"] != "plan v2" {
			t.Fatalf("%s changed %v", method, object)
		}
	}
	frameAfter("board.undo", map[string]any{"x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0})
	frameAfter("board.redo", map[string]any{"x": 300.0, "y": 40.0, "w": 200.0, "h": 100.0})
	if got := f.board.Objects()[id].Frame; got != (model.Frame{X: 300, Y: 40, W: 200, H: 100}) {
		t.Fatalf("after redo %v", got)
	}

	f.result("object.delete", map[string]any{"id": id, "viewer": testViewer, "step": 2.0})
	restored := f.result("board.undo", map[string]any{"viewer": testViewer, "step": 2.0})
	if changed, _ := restored["changed"].([]any); restored["step"] != 2.0 || len(changed) != 1 || changed[0].(map[string]any)["id"] != id {
		t.Fatalf("undo of the delete: %v", restored)
	}
	if _, back := f.board.Objects()[id]; !back {
		t.Fatal("the deleted note isn't back")
	}

	created := idOf(f.result("object.create", map[string]any{"type": "note", "props": map[string]any{"markdown": "scratch"}, "frame": map[string]any{"x": 600.0, "y": 0.0, "w": 200.0, "h": 100.0}, "viewer": testViewer, "step": 3.0}))
	removed := f.result("board.undo", map[string]any{"viewer": testViewer, "step": 3.0})
	if removed["step"] != 3.0 || !reflect.DeepEqual(removed["deleted"], []any{created}) || !reflect.DeepEqual(removed["changed"], []any{}) {
		t.Fatalf("undo of the create: %v", removed)
	}
	if _, left := f.board.Objects()[created]; left {
		t.Fatal("the created note is still there")
	}
}

func TestARetiredViewerReplayNamesOnlyTheRequestedStepAndLeavesLiveEditsAlone(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", note(0, map[string]any{"markdown": "plan"})))
	f.result("object.update", map[string]any{"id": id, "frame": map[string]any{"x": 300.0}, "viewer": testViewer, "step": 1.0})
	undone := f.result("board.undo", map[string]any{"viewer": testViewer, "step": 2.0})
	if undone["step"] != 1.0 || undone["pushed"] != true || undone["retired"] != nil {
		t.Fatalf("aliased undo %v", undone)
	}
	f.result("board.redo", map[string]any{"viewer": testViewer, "step": 1.0})
	revision := f.board.Objects()[id].Rev
	want := map[string]any{"step": 2.0, "changed": []any{}, "deleted": []any{}, "kept": []any{}, "pushed": false, "retired": true}
	if got := f.result("board.undo", map[string]any{"viewer": testViewer, "step": 2.0}); !reflect.DeepEqual(got, want) {
		t.Fatalf("retired replay %v, want %v", got, want)
	}
	if got := f.board.Objects()[id]; got.Rev != revision || got.Frame.X != 300 {
		t.Fatalf("retired replay changed the note: rev %d, x %v", got.Rev, got.Frame.X)
	}
	undo := f.result("board.undo", map[string]any{"viewer": testViewer, "step": 1.0})
	if changed, _ := undo["changed"].([]any); undo["step"] != 1.0 || undo["pushed"] != true || undo["retired"] != nil || len(changed) != 1 {
		t.Fatalf("live undo below the receipt floor %v", undo)
	}
	if x := f.board.Objects()[id].Frame.X; x != 0 {
		t.Fatalf("live undo left x %v, want 0", x)
	}
}
