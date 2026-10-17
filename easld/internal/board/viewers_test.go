package board

import (
	"errors"
	"fmt"
	"reflect"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

const (
	viewerA   = "vw_viewerAA"
	viewerB   = "vw_viewerBB"
	agentTile = "obj_agent"
)

func viewerWrite(t *testing.T, b *Board, viewer string, step int, write func() error) {
	t.Helper()
	if err := b.AsViewerEdit(&ViewerEdit{Viewer: viewer, Step: step}, write); err != nil {
		t.Fatal(err)
	}
}

func viewerMove(t *testing.T, b *Board, viewer string, step int, id string, to *model.Frame) {
	t.Helper()
	viewerWrite(t, b, viewer, step, func() error {
		_, err := b.Update(id, nil, to, nil, nil, "", "")
		return err
	})
}

func agentWrite(t *testing.T, b *Board, id string, to *model.Frame, props map[string]any) {
	t.Helper()
	if _, err := b.Update(id, nil, to, nil, props, agentTile, ""); err != nil {
		t.Fatal(err)
	}
}

type replayed struct {
	step                   int
	changed, deleted, kept []string
	pushed                 bool
}

func replayOf(t *testing.T, b *Board, viewer string, step int, redo bool) replayed {
	t.Helper()
	r, err := b.ReplayViewer(viewer, step, redo)
	if err != nil {
		t.Fatal(err)
	}
	out := replayed{changed: []string{}, deleted: append([]string{}, r.Deleted...), kept: append([]string{}, r.Kept...), pushed: r.Pushed}
	if r.Step != nil {
		out.step = *r.Step
	}
	for _, o := range r.Changed {
		out.changed = append(out.changed, o.ID)
	}
	return out
}

func TestViewerUndoRevertsItsMoveAndKeepsAnAgentsLaterEdit(t *testing.T) {
	b := New("brd", "/r")
	n := b.Create(model.Note, map[string]any{"markdown": "plan"}, frame(0, 0, 200, 100), "", "")
	viewerMove(t, b, viewerA, 1, n.ID, frame(300, 40, 200, 100))
	agentWrite(t, b, n.ID, nil, map[string]any{"markdown": "plan, revised"})
	want := replayed{step: 1, changed: []string{n.ID}, deleted: []string{}, kept: []string{}, pushed: true}
	if got := replayOf(t, b, viewerA, 1, false); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo %+v, want %+v", got, want)
	}
	if got := b.Objects()[n.ID]; got.Frame != (model.Frame{X: 0, Y: 0, W: 200, H: 100}) || got.Props["markdown"] != "plan, revised" {
		t.Fatalf("after undo: frame %v, markdown %v", got.Frame, got.Props["markdown"])
	}
	if got := replayOf(t, b, viewerA, 1, true); !reflect.DeepEqual(got, want) {
		t.Fatalf("redo %+v, want %+v", got, want)
	}
	if got := b.Objects()[n.ID]; got.Frame != (model.Frame{X: 300, Y: 40, W: 200, H: 100}) || got.Props["markdown"] != "plan, revised" {
		t.Fatalf("after redo: frame %v, markdown %v", got.Frame, got.Props["markdown"])
	}
}

func TestViewerUndoKeepsAFieldChangedSinceAndARetryUndoesNothingMore(t *testing.T) {
	b := New("brd", "/r")
	n := b.Create(model.Note, map[string]any{"markdown": "plan"}, frame(0, 0, 200, 100), "", "")
	viewerWrite(t, b, viewerA, 1, func() error {
		_, err := b.Update(n.ID, nil, nil, nil, map[string]any{"markdown": "draft"}, "", "")
		return err
	})
	viewerMove(t, b, viewerA, 2, n.ID, frame(300, 0, 200, 100))
	agentWrite(t, b, n.ID, frame(500, 0, 200, 100), nil)
	rev := b.Objects()[n.ID].Rev
	want := replayed{step: 2, changed: []string{}, deleted: []string{}, kept: []string{n.ID}, pushed: false}
	for _, attempt := range []string{"undo", "retry"} {
		if got := replayOf(t, b, viewerA, 2, false); !reflect.DeepEqual(got, want) {
			t.Fatalf("%s %+v, want %+v", attempt, got, want)
		}
	}
	if got := b.Objects()[n.ID]; got.Rev != rev || got.Frame.X != 500 || got.Props["markdown"] != "draft" {
		t.Fatalf("the note changed: rev %d (was %d), x %v, markdown %v", got.Rev, rev, got.Frame.X, got.Props["markdown"])
	}
}

func TestViewerUndoRevertsOnlyTheFieldsStillAsItsStepLeftThem(t *testing.T) {
	b := New("brd", "/r")
	n := b.Create(model.Note, map[string]any{"markdown": "plan"}, frame(0, 0, 200, 100), "", "")
	viewerWrite(t, b, viewerA, 1, func() error {
		_, err := b.Update(n.ID, nil, frame(300, 0, 200, 100), nil, map[string]any{"markdown": "plan v2"}, "", "")
		return err
	})
	agentWrite(t, b, n.ID, nil, map[string]any{"markdown": "agent's plan"})
	undone := replayed{step: 1, changed: []string{n.ID}, deleted: []string{}, kept: []string{n.ID}, pushed: true}
	if got := replayOf(t, b, viewerA, 1, false); !reflect.DeepEqual(got, undone) {
		t.Fatalf("undo %+v, want %+v", got, undone)
	}
	if got := b.Objects()[n.ID]; got.Frame.X != 0 || got.Props["markdown"] != "agent's plan" {
		t.Fatalf("after undo: x %v, markdown %v", got.Frame.X, got.Props["markdown"])
	}
	redone := replayed{step: 1, changed: []string{n.ID}, deleted: []string{}, kept: []string{}, pushed: true}
	if got := replayOf(t, b, viewerA, 1, true); !reflect.DeepEqual(got, redone) {
		t.Fatalf("redo %+v, want %+v", got, redone)
	}
	if got := b.Objects()[n.ID]; got.Frame.X != 300 || got.Props["markdown"] != "agent's plan" {
		t.Fatalf("after redo: x %v, markdown %v", got.Frame.X, got.Props["markdown"])
	}
}

func TestEachViewerUndoesOnlyItsOwnStep(t *testing.T) {
	b := New("brd", "/r")
	first := b.Create(model.Note, map[string]any{"markdown": "a"}, frame(0, 0, 200, 100), "", "")
	second := b.Create(model.Note, map[string]any{"markdown": "b"}, frame(0, 200, 200, 100), "", "")
	viewerMove(t, b, viewerA, 1, first.ID, frame(300, 0, 200, 100))
	viewerMove(t, b, viewerB, 1, second.ID, frame(300, 200, 200, 100))
	if got, want := replayOf(t, b, viewerA, 1, false), (replayed{step: 1, changed: []string{first.ID}, deleted: []string{}, kept: []string{}, pushed: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("A's undo %+v, want %+v", got, want)
	}
	if x1, x2 := b.Objects()[first.ID].Frame.X, b.Objects()[second.ID].Frame.X; x1 != 0 || x2 != 300 {
		t.Fatalf("after A's undo: first x %v, second x %v", x1, x2)
	}
	if got, want := replayOf(t, b, viewerB, 1, false), (replayed{step: 1, changed: []string{second.ID}, deleted: []string{}, kept: []string{}, pushed: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("B's undo %+v, want %+v", got, want)
	}
	if x := b.Objects()[second.ID].Frame.X; x != 0 {
		t.Fatalf("after B's undo: second x %v", x)
	}
}

func TestViewerUndoOfACreateRemovesItUnlessSomeoneEditedIt(t *testing.T) {
	b := New("brd", "/r")
	var scratch, draft model.Object
	viewerWrite(t, b, viewerA, 1, func() error {
		scratch = b.Create(model.Note, map[string]any{"markdown": "scratch"}, frame(0, 0, 200, 100), "", "")
		return nil
	})
	if got, want := replayOf(t, b, viewerA, 1, false), (replayed{step: 1, changed: []string{}, deleted: []string{scratch.ID}, kept: []string{}, pushed: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo %+v, want %+v", got, want)
	}
	if _, ok := b.Objects()[scratch.ID]; ok {
		t.Fatal("the created note is still there")
	}
	viewerWrite(t, b, viewerA, 2, func() error {
		draft = b.Create(model.Note, map[string]any{"markdown": "draft"}, frame(0, 0, 200, 100), "", "")
		return nil
	})
	agentWrite(t, b, draft.ID, nil, map[string]any{"markdown": "agent's draft"})
	if got, want := replayOf(t, b, viewerA, 2, false), (replayed{step: 2, changed: []string{}, deleted: []string{}, kept: []string{draft.ID}, pushed: false}); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo of the edited create %+v, want %+v", got, want)
	}
	if got := b.Objects()[draft.ID]; got.Props["markdown"] != "agent's draft" {
		t.Fatalf("the edited note: %v", got.Props)
	}
}

func TestViewerUndoOfADeleteRecreatesItWhereNothingTookItsPlace(t *testing.T) {
	b := New("brd", "/r")
	a := b.Create(model.Shape, map[string]any{"kind": "rect"}, frame(0, 0, 160, 100), "", "")
	c := b.Create(model.Shape, map[string]any{"kind": "rect"}, frame(400, 0, 160, 100), "", "")
	arrow := b.Create(model.Arrow, map[string]any{"from": map[string]any{"object": a.ID}, "to": map[string]any{"object": c.ID}}, frame(0, 0, 0, 0), "", "")
	agentWrite(t, b, c.ID, nil, map[string]any{"text": "target"})
	if _, err := b.Stage(map[string]any{"kind": "object", "object": c.ID}); err != nil {
		t.Fatal(err)
	}
	viewerWrite(t, b, viewerA, 1, func() error { return b.Delete(c.ID, "") })
	if to := b.Objects()[arrow.ID].Props["to"].(map[string]any); to["object"] != nil || len(b.Tray()) != 0 {
		t.Fatalf("the delete left the arrow bound (%v) or the mention staged (%v)", to, b.Tray())
	}
	if got, want := replayOf(t, b, viewerA, 1, false), (replayed{step: 1, changed: []string{c.ID, arrow.ID}, deleted: []string{}, kept: []string{}, pushed: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo %+v, want %+v", got, want)
	}
	back := b.Objects()[c.ID]
	if back.Z != 2 || back.Rev != 3 || back.Props["text"] != "target" {
		t.Fatalf("recreated z %v rev %d props %v, want z 2, rev 3, text target", back.Z, back.Rev, back.Props)
	}
	if to := b.Objects()[arrow.ID].Props["to"]; !reflect.DeepEqual(to, map[string]any{"object": c.ID}) {
		t.Fatalf("arrow end %v, want bound to %s again", to, c.ID)
	}
	if tray := b.Tray(); len(tray) != 1 || tray[0].Target["object"] != c.ID {
		t.Fatalf("tray %v, want the mention of %s back", tray, c.ID)
	}

	keyed := New("brd", "/r")
	release := keyed.Create(model.Note, map[string]any{"markdown": "release", "key": "REL-1"}, frame(0, 0, 200, 100), "", "")
	viewerWrite(t, keyed, viewerA, 1, func() error { return keyed.Delete(release.ID, "") })
	taker := keyed.Create(model.Note, map[string]any{"markdown": "another", "key": "REL-1"}, frame(300, 0, 200, 100), "", agentTile)
	if got, want := replayOf(t, keyed, viewerA, 1, false), (replayed{step: 1, changed: []string{}, deleted: []string{}, kept: []string{release.ID}, pushed: false}); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo with the key taken %+v, want %+v", got, want)
	}
	if _, back := keyed.Objects()[release.ID]; back {
		t.Fatal("recreated while another object holds its key")
	}
	if holder, _, _ := keyed.Holder("REL-1"); holder.ID != taker.ID {
		t.Fatalf("REL-1 held by %s, want %s", holder.ID, taker.ID)
	}

	orphaned := New("brd", "/r")
	parent := orphaned.Create(model.Shape, map[string]any{"kind": "rect"}, frame(0, 0, 400, 300), "", "")
	child := orphaned.Create(model.Note, map[string]any{"markdown": "inside"}, frame(20, 20, 200, 100), parent.ID, "")
	viewerWrite(t, orphaned, viewerA, 1, func() error { return orphaned.Delete(child.ID, "") })
	if err := orphaned.Delete(parent.ID, agentTile); err != nil {
		t.Fatal(err)
	}
	if got, want := replayOf(t, orphaned, viewerA, 1, false), (replayed{step: 1, changed: []string{child.ID}, deleted: []string{}, kept: []string{}, pushed: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo with the parent gone %+v, want %+v", got, want)
	}
	if got := orphaned.Objects()[child.ID]; got.Parent != "" || got.Props["markdown"] != "inside" {
		t.Fatalf("recreated with parent %q, props %v", got.Parent, got.Props)
	}
}

func TestViewerUndoOfATerminalDeleteReportsItCreated(t *testing.T) {
	b := New("brd", "/r")
	var reports [][2][]string
	b.OnTerminals = func(created, ended []model.Object) {
		ids := func(list []model.Object) []string {
			out := []string{}
			for _, o := range list {
				out = append(out, o.ID)
			}
			return out
		}
		reports = append(reports, [2][]string{ids(created), ids(ended)})
	}
	term := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	viewerWrite(t, b, viewerA, 1, func() error { return b.Delete(term.ID, "") })
	if got, want := replayOf(t, b, viewerA, 1, false), (replayed{step: 1, changed: []string{term.ID}, deleted: []string{}, kept: []string{}, pushed: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo %+v, want %+v", got, want)
	}
	want := [][2][]string{{{term.ID}, {}}, {{}, {term.ID}}, {{term.ID}, {}}}
	if !reflect.DeepEqual(reports, want) {
		t.Fatalf("reports %v, want %v", reports, want)
	}
}

func TestARetriedViewerUndoAnswersWhatTheFirstDid(t *testing.T) {
	b := New("brd", "/r")
	n := b.Create(model.Note, map[string]any{"markdown": "plan"}, frame(0, 0, 200, 100), "", "")
	viewerMove(t, b, viewerA, 1, n.ID, frame(300, 0, 200, 100))
	want := replayed{step: 1, changed: []string{n.ID}, deleted: []string{}, kept: []string{}, pushed: true}
	if got := replayOf(t, b, viewerA, 1, false); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo %+v, want %+v", got, want)
	}
	agentWrite(t, b, n.ID, nil, map[string]any{"markdown": "plan, revised"})
	rev := b.Objects()[n.ID].Rev
	retry, err := b.ReplayViewer(viewerA, 1, false)
	if err != nil {
		t.Fatal(err)
	}
	if retry.Step == nil || *retry.Step != 1 || len(retry.Changed) != 1 || retry.Changed[0].Props["markdown"] != "plan, revised" || retry.Changed[0].Frame.X != 0 || !retry.Pushed {
		t.Fatalf("retry %+v", retry)
	}
	if got := b.Objects()[n.ID].Rev; got != rev {
		t.Fatalf("the retry wrote: rev %d, was %d", got, rev)
	}
	if got := replayOf(t, b, viewerA, 1, true); !reflect.DeepEqual(got, want) {
		t.Fatalf("redo %+v, want %+v", got, want)
	}
	if x := b.Objects()[n.ID].Frame.X; x != 300 {
		t.Fatalf("after redo x %v", x)
	}
	if got := replayOf(t, b, viewerA, 1, false); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo after redo %+v, want %+v", got, want)
	}
	if x := b.Objects()[n.ID].Frame.X; x != 0 {
		t.Fatalf("undo after redo left x %v", x)
	}
}

func TestViewerUndoOfAStepThatNeverLandedUndoesTheLatestBelowIt(t *testing.T) {
	b := New("brd", "/r")
	n := b.Create(model.Note, map[string]any{"markdown": "plan"}, frame(0, 0, 200, 100), "", "")
	viewerMove(t, b, viewerA, 1, n.ID, frame(300, 0, 200, 100))
	stale := 1
	err := b.AsViewerEdit(&ViewerEdit{Viewer: viewerA, Step: 2}, func() error {
		_, err := b.Update(n.ID, &stale, frame(600, 0, 200, 100), nil, nil, "", "")
		return err
	})
	if err == nil {
		t.Fatal("a write at a stale rev applied")
	}
	want := replayed{step: 1, changed: []string{n.ID}, deleted: []string{}, kept: []string{}, pushed: true}
	if got := replayOf(t, b, viewerA, 2, false); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo %+v, want %+v", got, want)
	}
	if x := b.Objects()[n.ID].Frame.X; x != 0 {
		t.Fatalf("after undo x %v", x)
	}
	rev := b.Objects()[n.ID].Rev
	if got := replayOf(t, b, viewerA, 2, false); !reflect.DeepEqual(got, want) {
		t.Fatalf("retry %+v, want %+v", got, want)
	}
	if got := b.Objects()[n.ID].Rev; got != rev {
		t.Fatalf("the retry wrote: rev %d, was %d", got, rev)
	}
}

func TestALateWriteJoinsItsOwnStep(t *testing.T) {
	b := New("brd", "/r")
	first := b.Create(model.Note, map[string]any{"markdown": "one"}, frame(0, 0, 200, 100), "", "")
	second := b.Create(model.Note, map[string]any{"markdown": "two"}, frame(0, 200, 200, 100), "", "")
	viewerWrite(t, b, viewerA, 1, func() error {
		_, err := b.Update(first.ID, nil, nil, nil, map[string]any{"markdown": "one, edited"}, "", "")
		return err
	})
	viewerMove(t, b, viewerA, 2, second.ID, frame(300, 200, 200, 100))
	viewerMove(t, b, viewerA, 1, first.ID, frame(300, 0, 200, 100))
	if got, want := replayOf(t, b, viewerA, 2, false), (replayed{step: 2, changed: []string{second.ID}, deleted: []string{}, kept: []string{}, pushed: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo of 2 %+v, want %+v", got, want)
	}
	if one, two := b.Objects()[first.ID], b.Objects()[second.ID]; two.Frame.X != 0 || one.Frame.X != 300 || one.Props["markdown"] != "one, edited" {
		t.Fatalf("after undo of 2: second x %v, first x %v markdown %v", two.Frame.X, one.Frame.X, one.Props["markdown"])
	}
	if got, want := replayOf(t, b, viewerA, 1, false), (replayed{step: 1, changed: []string{first.ID}, deleted: []string{}, kept: []string{}, pushed: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("undo of 1 %+v, want %+v", got, want)
	}
	if one := b.Objects()[first.ID]; one.Frame.X != 0 || one.Props["markdown"] != "one" {
		t.Fatalf("after undo of 1: x %v, markdown %v", one.Frame.X, one.Props["markdown"])
	}
}

func TestANewViewerStepClearsRedo(t *testing.T) {
	b := New("brd", "/r")
	n := b.Create(model.Note, map[string]any{"markdown": "plan"}, frame(0, 0, 200, 100), "", "")
	viewerMove(t, b, viewerA, 1, n.ID, frame(300, 0, 200, 100))
	replayOf(t, b, viewerA, 1, false)
	viewerMove(t, b, viewerA, 2, n.ID, frame(0, 300, 200, 100))
	if got, want := replayOf(t, b, viewerA, 1, true), (replayed{changed: []string{}, deleted: []string{}, kept: []string{}}); !reflect.DeepEqual(got, want) {
		t.Fatalf("redo %+v, want %+v", got, want)
	}
	if got := b.Objects()[n.ID].Frame; got != (model.Frame{X: 0, Y: 300, W: 200, H: 100}) {
		t.Fatalf("frame %v", got)
	}
}

func TestTheSeventeenthViewerEvictsTheLeastRecentlyUsed(t *testing.T) {
	b := New("brd", "/r")
	n := b.Create(model.Note, map[string]any{"markdown": "plan"}, frame(0, 0, 200, 100), "", "")
	viewer := func(i int) string { return fmt.Sprintf("vw_viewer%02d", i) }
	for i := range 16 {
		viewerMove(t, b, viewer(i), 1, n.ID, frame(float64(10*(i+1)), 0, 200, 100))
	}
	viewerMove(t, b, viewer(0), 2, n.ID, frame(0, 300, 200, 100))
	viewerMove(t, b, viewer(16), 1, n.ID, frame(0, 600, 200, 100))
	for _, c := range []struct {
		viewer, step, want int
	}{{1, 1, 0}, {2, 1, 1}, {0, 2, 2}, {16, 1, 1}} {
		if got := replayOf(t, b, viewer(c.viewer), c.step, false).step; got != c.want {
			t.Errorf("%s undo of %d replayed step %d, want %d", viewer(c.viewer), c.step, got, c.want)
		}
	}
}

func TestAViewerUndoBelowTheRetainedStepsIsAConflict(t *testing.T) {
	b := New("brd", "/r")
	n := b.Create(model.Note, map[string]any{"markdown": "plan"}, frame(0, 0, 200, 100), "", "")
	for step := 1; step <= 201; step++ {
		viewerMove(t, b, viewerA, step, n.ID, frame(float64(step), 0, 200, 100))
	}
	_, err := b.ReplayViewer(viewerA, 1, false)
	var be *Error
	if !errors.As(err, &be) || be.Code != "conflict" || be.Message != "step 1 is older than the 200 steps this board keeps for viewer vw_viewerAA" {
		t.Fatalf("undo of 1: %v", err)
	}
	if got := replayOf(t, b, viewerA, 2, false).step; got != 2 {
		t.Fatalf("undo of 2 replayed step %d", got)
	}
}
