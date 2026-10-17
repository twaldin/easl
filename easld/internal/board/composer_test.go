package board

import (
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

func frameAt(x, y, w, h float64) *model.Frame {
	return &model.Frame{X: x, Y: y, W: w, H: h}
}

func composerBoard(t *testing.T) (*Board, model.Object, model.Object) {
	t.Helper()
	b := New("brd", "/r")
	term := b.Create(model.Terminal, map[string]any{"name": "alpha"}, frameAt(0, 0, 100, 100), "", "")
	if err := b.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "idle"}); err != nil {
		t.Fatal(err)
	}
	note := b.Create(model.Note, map[string]any{"markdown": "n"}, frameAt(0, 200, 100, 100), "", "")
	return b, term, note
}

func staged(id, object, label string) model.Mention {
	return model.Mention{ID: id, Target: map[string]any{"kind": "object", "object": object}, Label: label, StagedAt: time.Unix(1_700_000_000, 0)}
}

func idsOf(event model.Event) []string {
	data, _ := event.Data.(map[string]any)
	raw, _ := data["ids"].([]any)
	out := make([]string, len(raw))
	for i, id := range raw {
		out[i], _ = id.(string)
	}
	return out
}

func TestComposerQueueNumbersOriginsAndLeavesTheOtherTerminal(t *testing.T) {
	b, alpha, note := composerBoard(t)
	beta := b.Create(model.Terminal, map[string]any{"name": "beta"}, frameAt(200, 0, 100, 100), "", "")
	if err := b.ReportLifecycle(Report{Tile: beta.ID, Kind: "omp", State: "idle"}); err != nil {
		t.Fatal(err)
	}
	first := staged("men_one", note.ID, "n")
	second := staged("men_two", note.ID, "n2")
	var submitted []string
	b.OnEvent = func(e model.Event) {
		if e.Name == EventComposerSubmitted {
			submitted = idsOf(e)
		}
	}
	b.QueueComposerPrompt("[1] one [2] two", alpha.ID, []model.Mention{first, second}, false, "vw_viewer01", time.Now())
	b.QueueComposerPrompt("[1] one [2] two", beta.ID, []model.Mention{first, second}, false, "vw_viewer02", time.Now())
	got := b.composerPrompts[alpha.ID][0].Origins
	if len(got) != 2 || got[0] != "men_one" || got[1] != "men_two" {
		t.Fatalf("origins %v", got)
	}
	if b.composerPrompts[alpha.ID][0].Mentions[0].ID == "men_one" {
		t.Fatal("copies must not keep the origin id")
	}
	resolved, _ := b.Drain(false, alpha.ID, "[1] one [2] two", true)
	if len(resolved) != 2 || !strings.HasPrefix(resolved[0].Summary, "[1]") || !strings.HasPrefix(resolved[1].Summary, "[2]") {
		t.Fatalf("numbered %#v", resolved)
	}
	if strings.Join(submitted, ",") != "men_one,men_two" {
		t.Fatalf("submitted %v", submitted)
	}
	if len(b.composerPrompts[beta.ID]) != 1 {
		t.Fatal("the other terminal's queue was stripped")
	}
}

func TestUnrelatedAndPromptlessDrainsLeaveTheQueue(t *testing.T) {
	b, alpha, note := composerBoard(t)
	b.QueueComposerPrompt("fix the parser", alpha.ID, []model.Mention{staged("men_one", note.ID, "n")}, false, "vw_viewer01", time.Now())
	if _, context := b.Drain(true, alpha.ID, "ship the widget", false); context != "" || len(b.composerPrompts[alpha.ID]) != 1 {
		t.Fatalf("unrelated drain took the queue: %s", context)
	}
	if _, context := b.Drain(true, alpha.ID, "", false); context != "" || len(b.composerPrompts[alpha.ID]) != 1 {
		t.Fatalf("a drain without a prompt saw the queue: %s", context)
	}
	resolved, _ := b.Drain(true, alpha.ID, "Please fix the parser", false)
	if len(resolved) != 1 || !strings.HasPrefix(resolved[0].Summary, "[1]") {
		t.Fatalf("matching drain %#v", resolved)
	}
}

func TestUnicodeFoldAndShortEquality(t *testing.T) {
	b, alpha, note := composerBoard(t)
	b.QueueComposerPrompt("Straße", alpha.ID, []model.Mention{staged("men_one", note.ID, "n")}, false, "vw_viewer01", time.Now())
	resolved, context := b.Drain(true, alpha.ID, "STRASSE", false)
	if len(resolved) != 1 || !strings.Contains(context, note.ID) || !strings.Contains(context, "[1] note") {
		t.Fatalf("case-folded submission %v: %s", resolved, context)
	}
	b.CommitComposerPrompts([]string{b.composerPrompts[alpha.ID][0].Mentions[0].ID})
	b.QueueComposerPrompt("Ab", alpha.ID, []model.Mention{staged("men_two", note.ID, "n")}, false, "vw_viewer01", time.Now())
	if _, context := b.Drain(true, alpha.ID, "abacus", false); context != "" || len(b.composerPrompts[alpha.ID]) != 1 {
		t.Fatal("a short prompt matched a longer drain")
	}
	if resolved, _ := b.Drain(true, alpha.ID, "AB", false); len(resolved) != 1 {
		t.Fatal("short equality did not claim")
	}
}

func TestComposerFoldKeepsMarksNumbersAndShortGraphemeEquality(t *testing.T) {
	for _, tc := range []struct {
		name, prompt, unrelated, submitted string
	}{
		{"combining-short", "e\u0301x", "éxtra", "Éx"},
		{"numeric-short", "①²", "prefix①²suffix", "①²"},
		{"combining-contained", "a\u0301bc", "abc", "prefix ÁBC suffix"},
		{"accent-is-content", "café", "cafe", "CAFE\u0301"},
		{"substring-grapheme-boundary", "abcक", "abcकि", "prefix abcक suffix"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b, terminal, note := composerBoard(t)
			b.QueueComposerPrompt(tc.prompt, terminal.ID, []model.Mention{staged("men_one", note.ID, "n")}, false, "vw_viewer01", time.Now())
			if _, context := b.Drain(true, terminal.ID, tc.unrelated, false); context != "" {
				t.Fatalf("unrelated submission claimed context: %s", context)
			}
			resolved, context := b.Drain(false, terminal.ID, tc.submitted, false)
			if len(resolved) != 1 || !strings.Contains(context, note.ID) {
				t.Fatalf("matching submission lost its note: %v %s", resolved, context)
			}
		})
	}
}

func TestPeekHoldsUntilCommit(t *testing.T) {
	b, alpha, note := composerBoard(t)
	b.QueueComposerPrompt("fix it", alpha.ID, []model.Mention{staged("men_one", note.ID, "n")}, false, "vw_viewer01", time.Now())
	if resolved, _ := b.Drain(true, alpha.ID, "fix it", false); len(resolved) != 1 {
		t.Fatal("peek missed the prompt")
	}
	if resolved, _ := b.Drain(true, alpha.ID, "fix it", false); len(resolved) != 1 || len(b.composerPrompts[alpha.ID]) != 1 {
		t.Fatal("a second peek took the prompt")
	}
	b.CommitComposerPrompts([]string{b.composerPrompts[alpha.ID][0].Mentions[0].ID})
	if len(b.composerPrompts[alpha.ID]) != 0 {
		t.Fatal("commit left the prompt")
	}
}

func TestReleaseAndExpiryReturnOriginIDs(t *testing.T) {
	b, alpha, note := composerBoard(t)
	var returned []string
	b.OnEvent = func(e model.Event) {
		if e.Name == EventComposerReturned {
			returned = append(returned, idsOf(e)...)
		}
	}
	b.QueueComposerPrompt("hold", alpha.ID, []model.Mention{staged("men_one", note.ID, "n")}, false, "vw_viewer01", time.Now())
	if err := b.ReleaseAgent(alpha.ID); err != nil {
		t.Fatal(err)
	}
	if strings.Join(returned, ",") != "men_one" {
		t.Fatalf("release returned %v", returned)
	}
	if err := b.ReportLifecycle(Report{Tile: alpha.ID, Kind: "omp", State: "idle"}); err != nil {
		t.Fatal(err)
	}
	b.QueueComposerPrompt("later", alpha.ID, []model.Mention{staged("men_two", note.ID, "n")}, false, "vw_viewer01", time.Now().Add(-composerLifetime-time.Second))
	b.ExpireComposerPrompts(time.Now())
	if strings.Join(returned, ",") != "men_one,men_two" {
		t.Fatalf("expiry returned %v", returned)
	}
}

func TestFailedDeleteNeitherLosesNorEmitsTheQueue(t *testing.T) {
	b, alpha, note := composerBoard(t)
	b.QueueComposerPrompt("keep", alpha.ID, []model.Mention{staged("men_one", note.ID, "n")}, false, "vw_viewer01", time.Now())
	events := 0
	b.OnEvent = func(e model.Event) {
		if e.Name == EventComposerReturned || e.Name == EventComposerSubmitted {
			events++
		}
	}
	err := b.Atomically(func() error {
		if err := b.Delete(alpha.ID, ""); err != nil {
			return err
		}
		return stopError{}
	})
	if err != (stopError{}) {
		t.Fatal(err)
	}
	if events != 0 || len(b.composerPrompts[alpha.ID]) != 1 || len(b.ComposerReceipts("vw_viewer01")) != 0 {
		t.Fatalf("events %d queue %d receipts %d", events, len(b.composerPrompts[alpha.ID]), len(b.ComposerReceipts("vw_viewer01")))
	}
	_ = note
}

func TestPartialCommitThenReleaseReturnsTheRemainder(t *testing.T) {
	b, alpha, note := composerBoard(t)
	other := b.Create(model.Note, map[string]any{"markdown": "o"}, frameAt(0, 400, 100, 100), "", "")
	b.QueueComposerPrompt("both", alpha.ID, []model.Mention{staged("men_one", note.ID, "n"), staged("men_two", other.ID, "o")}, false, "vw_viewer01", time.Now())
	b.CommitComposerPrompts([]string{b.composerPrompts[alpha.ID][0].Mentions[0].ID})
	var returned []string
	b.OnEvent = func(e model.Event) {
		if e.Name == EventComposerReturned {
			returned = idsOf(e)
		}
	}
	if err := b.ReleaseAgent(alpha.ID); err != nil {
		t.Fatal(err)
	}
	if strings.Join(returned, ",") != "men_two" {
		t.Fatalf("remainder %v", returned)
	}
}

func TestTargetDeletionReturnsThatOrigin(t *testing.T) {
	b, alpha, note := composerBoard(t)
	b.QueueComposerPrompt("look", alpha.ID, []model.Mention{staged("men_one", note.ID, "n")}, false, "vw_viewer01", time.Now())
	var returned []string
	b.OnEvent = func(e model.Event) {
		if e.Name == EventComposerReturned {
			returned = idsOf(e)
		}
	}
	if err := b.Delete(note.ID, ""); err != nil {
		t.Fatal(err)
	}
	if strings.Join(returned, ",") != "men_one" {
		t.Fatalf("deleted target returned %v", returned)
	}
}

func TestWithdrawEmitsNothing(t *testing.T) {
	b, alpha, note := composerBoard(t)
	id := b.QueueComposerPrompt("nope", alpha.ID, []model.Mention{staged("men_one", note.ID, "n")}, false, "vw_viewer01", time.Now())
	events := 0
	b.OnEvent = func(e model.Event) {
		if e.Name == EventComposerReturned || e.Name == EventComposerSubmitted {
			events++
		}
	}
	b.WithdrawComposerPrompt(id)
	if events != 0 || len(b.composerPrompts[alpha.ID]) != 0 {
		t.Fatal("withdraw emitted or left the prompt")
	}
}

func TestAnswerClaimSubmitsAnEmptyIDList(t *testing.T) {
	b := New("brd", "/r")
	term := b.Create(model.Terminal, map[string]any{}, frameAt(0, 0, 100, 100), "", "")
	if err := b.ReportLifecycle(Report{Tile: term.ID, Kind: "codex", State: "blocked"}); err != nil {
		t.Fatal(err)
	}
	var ids []any
	b.OnEvent = func(e model.Event) {
		if e.Name == EventComposerSubmitted {
			ids, _ = e.Data.(map[string]any)["ids"].([]any)
		}
	}
	b.QueueComposerPrompt("yes", term.ID, nil, true, "vw_viewer01", time.Now())
	if _, context := b.Drain(true, term.ID, "yes", false); context != "" {
		t.Fatalf("answer drain %s", context)
	}
	if ids == nil || len(ids) != 0 || len(b.composerPrompts[term.ID]) != 0 {
		t.Fatalf("answer submitted %v queue %d", ids, len(b.composerPrompts[term.ID]))
	}
}

func TestStaleSeenKeepsTheNewerMarker(t *testing.T) {
	b, alpha, note := composerBoard(t)
	first, _, err := b.RaiseAttention(note.ID, nil, alpha.ID)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(time.Millisecond)
	second, _, err := b.RaiseAttention(note.ID, new("new"), alpha.ID)
	if err != nil {
		t.Fatal(err)
	}
	cleared, _ := b.Seen(note.ID, nil, map[string]any{"id": note.ID, "raisedAt": first.Stamp})
	if cleared || b.attention[note.ID].Stamp != second.Stamp {
		t.Fatal("stale ack cleared the newer marker")
	}
	cleared, _ = b.Seen(note.ID, nil, AttentionMarkerJSON(second))
	if !cleared || len(b.attention) != 0 {
		t.Fatal("matching ack did not clear")
	}
	rev := b.objects[alpha.ID].Rev
	if _, seen := b.Seen(alpha.ID, new(rev-1), nil); seen {
		t.Fatal("a stale revision was marked seen")
	}
	if _, seen := b.Seen(alpha.ID, new(rev), nil); !seen {
		t.Fatal("the shown revision was not marked seen")
	}
}

func TestAttentionMarkersOmitNoneAndSort(t *testing.T) {
	b, alpha, note := composerBoard(t)
	if len(b.AttentionMarkers(nil)) != 0 {
		t.Fatal("empty markers were emitted")
	}
	if _, _, err := b.RaiseAttention(note.ID, nil, alpha.ID); err != nil {
		t.Fatal(err)
	}
	other := b.Create(model.Note, map[string]any{"markdown": "o"}, frameAt(0, 400, 10, 10), "", "")
	if _, _, err := b.RaiseAttention(other.ID, nil, alpha.ID); err != nil {
		t.Fatal(err)
	}
	markers := b.AttentionMarkers(nil)
	if len(markers) != 2 || markers[0]["id"].(string) > markers[1]["id"].(string) || markers[0]["raisedAt"] == "" {
		t.Fatalf("markers %v", markers)
	}
}

type stopError struct{}

func (stopError) Error() string { return "stop" }
