package router

import (
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestBoardGetOmitsEmptyAttentionAndSortsMarkers(t *testing.T) {
	f := newFixture(t)
	if _, present := f.result("board.get", map[string]any{})["attention"]; present {
		t.Fatal("empty attention was emitted")
	}
	note := f.board.Create(model.Note, map[string]any{"markdown": "n"}, &model.Frame{W: 10, H: 10}, "", "")
	other := f.board.Create(model.Note, map[string]any{"markdown": "o"}, &model.Frame{X: 40, W: 10, H: 10}, "", "")
	if _, _, err := f.board.RaiseAttention(other.ID, nil, ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.board.RaiseAttention(note.ID, nil, ""); err != nil {
		t.Fatal(err)
	}
	got := f.result("board.get", map[string]any{})["attention"].([]any)
	if len(got) != 2 {
		t.Fatalf("attention %v", got)
	}
	first := got[0].(map[string]any)
	second := got[1].(map[string]any)
	if first["id"].(string) > second["id"].(string) || first["raisedAt"] == "" {
		t.Fatalf("unsorted or unstamped %v", got)
	}
}

func TestViewSeenStaleMarkerAndRevisionKeepNewerState(t *testing.T) {
	f := newFixture(t)
	term := f.board.Create(model.Terminal, map[string]any{}, &model.Frame{W: 10, H: 10}, "", "")
	note := f.board.Create(model.Note, map[string]any{"markdown": "n"}, &model.Frame{Y: 40, W: 10, H: 10}, "", "")
	first, _, err := f.board.RaiseAttention(note.ID, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := f.board.RaiseAttention(note.ID, new("later"), "")
	if err != nil {
		t.Fatal(err)
	}
	stale, err := f.router.viewSeen(map[string]any{"id": note.ID, "marker": map[string]any{"id": note.ID, "raisedAt": first.Stamp}})
	if err != nil {
		t.Fatal(err)
	}
	if stale.(map[string]any)["cleared"] != false || f.board.AttentionMarkers(nil)[0]["raisedAt"] != second.Stamp {
		t.Fatalf("stale clear %v", stale)
	}
	f.result("agent.report", map[string]any{"tile": term.ID, "kind": "omp", "state": "working"})
	working := f.result("object.get", map[string]any{"id": term.ID})["object"].(map[string]any)
	f.result("agent.report", map[string]any{"tile": term.ID, "kind": "omp", "state": "idle"})
	seen := f.result("view.seen", map[string]any{"id": term.ID, "rev": working["rev"]})
	if seen["seen"] != false {
		t.Fatal("stale working rev marked the finished turn seen")
	}
	done := f.result("object.get", map[string]any{"id": term.ID})["object"].(map[string]any)
	if done["props"].(map[string]any)["lifecycle"].(map[string]any)["state"] != "done" {
		t.Fatalf("stale acknowledgment changed the finished turn: %v", done)
	}
	seen = f.result("view.seen", map[string]any{"id": term.ID, "rev": done["rev"]})
	after := f.result("object.get", map[string]any{"id": term.ID})["object"].(map[string]any)
	lifecycle := after["props"].(map[string]any)["lifecycle"].(map[string]any)
	if seen["seen"] != true || lifecycle["state"] != "idle" || lifecycle["seen"] != true {
		t.Fatalf("current acknowledgment did not mark the finished turn seen: %v %v", seen, after)
	}
}

func TestComposerPromptRefusesMentionsAndStagedWithoutComposer(t *testing.T) {
	if err := checkComposer(map[string]any{"composer": true, "mentions": []any{map[string]any{"object": "obj_a"}}}); err == nil {
		t.Fatal("mentions with composer were accepted")
	}
	if err := checkComposer(map[string]any{"staged": []any{}}); err == nil {
		t.Fatal("staged without composer was accepted")
	}
	if err := checkComposer(map[string]any{"viewer": "vw_viewer01"}); err == nil {
		t.Fatal("viewer without composer was accepted")
	}
	if err := checkComposer(map[string]any{"composer": true, "answer": true, "staged": []any{map[string]any{"id": "men_a"}}}); err == nil {
		t.Fatal("staged with an answer was accepted")
	}
}

func TestStagedMentionsKeepOrderAndRejectAMissingObject(t *testing.T) {
	f := newFixture(t)
	note := f.board.Create(model.Note, map[string]any{"markdown": "n"}, &model.Frame{W: 10, H: 10}, "", "")
	raw := []any{
		map[string]any{"id": "men_b", "label": "b", "edited": false, "stagedAt": 7.5e8, "target": map[string]any{"kind": "object", "object": note.ID}},
		map[string]any{"id": "men_a", "label": "a", "edited": false, "stagedAt": 7.5e8, "target": map[string]any{"kind": "object", "object": note.ID}},
	}
	got, err := stagedMentions(raw, f.board)
	if err != nil || len(got) != 2 || got[0].ID != "men_b" || got[1].ID != "men_a" {
		t.Fatalf("%v %v", got, err)
	}
	if _, err := stagedMentions([]any{map[string]any{"id": "men_x", "label": "x", "stagedAt": 1.0, "target": map[string]any{"kind": "object", "object": "obj_missing"}}}, f.board); err == nil {
		t.Fatal("a missing target was accepted")
	}
}
