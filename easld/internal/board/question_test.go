package board

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

var answeredAt = time.Date(2026, 10, 5, 17, 0, 2, 500_000_000, time.UTC)

func askProps(extra map[string]any) map[string]any {
	props := map[string]any{
		"question": "Ship it?",
		"options": []any{
			map[string]any{"id": "a", "label": "Yes"},
			map[string]any{"id": "b", "label": "No"},
		},
	}
	for k, v := range extra {
		props[k] = v
	}
	return props
}

func iso(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

// ask creates a question as object.create does: the caller's terminal asks unless props name an asker.
func ask(t *testing.T, b *Board, props map[string]any, f *model.Frame, caller string) model.Object {
	t.Helper()
	stored, err := b.QuestionToCreate(props, caller)
	if err != nil {
		t.Fatal(err)
	}
	return b.Create(model.Question, stored, f, "", caller)
}

// write updates a question as object.update does.
func write(t *testing.T, b *Board, id string, patch map[string]any, f *model.Frame, caller string) model.Object {
	t.Helper()
	o, err := writeErr(b, id, patch, f, caller)
	if err != nil {
		t.Fatal(err)
	}
	return o
}

func writeErr(b *Board, id string, patch map[string]any, f *model.Frame, caller string) (model.Object, error) {
	props, frame, err := b.QuestionUpdate(id, patch, true, f, caller, answeredAt)
	if err != nil {
		return model.Object{}, err
	}
	return b.Update(id, nil, frame, nil, props, caller, "")
}

func statusOf(b *Board, id string) any { return b.Objects()[id].Props["status"] }

func TestANewQuestionIsSizedByItsPropsAndAskedByItsCaller(t *testing.T) {
	b := New("brd", "/r")
	terminal := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	q := ask(t, b, askProps(nil), nil, terminal.ID)
	if q.Frame.W != 460 || q.Frame.H != 294 {
		t.Errorf("two options: %v", q.Frame)
	}
	if q.Props["status"] != "open" || !jsonEq(q.Props["asker"], map[string]any{"tile": terminal.ID}) {
		t.Errorf("props %v", q.Props)
	}
	withContext := ask(t, b, askProps(map[string]any{"asker": map[string]any{"name": "cos"}, "context": []any{map[string]any{"url": "https://x"}}}), nil, "")
	if withContext.Frame.W != 460 || withContext.Frame.H != 324 {
		t.Errorf("with context: %v", withContext.Frame)
	}
	framed := ask(t, b, askProps(map[string]any{"asker": map[string]any{"name": "cos"}}), frame(5000, 0, 300, 100), "")
	if framed.Frame != *frame(5000, 0, 300, 100) {
		t.Errorf("a given frame stays: %v", framed.Frame)
	}
	if got := Describe(q); got != `question "Ship it?"` {
		t.Errorf("describe %q", got)
	}
}

func jsonEq(a, b any) bool { return model.Equal(a, b) }

func TestClosingAQuestionShrinksItToTheClosedTileUnlessTheCallGivesAFrame(t *testing.T) {
	b := New("brd", "/r")
	asker := map[string]any{"name": "cos"}
	open := func(extra map[string]any) model.Object {
		extra["asker"] = asker
		return ask(t, b, askProps(extra), nil, "")
	}

	answered := write(t, b, open(map[string]any{}).ID, map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}, nil, "")
	if answered.Frame.H != 148 || answered.Frame.W != 460 {
		t.Errorf("answered: %v", answered.Frame)
	}
	cancelled := write(t, b, open(map[string]any{}).ID, map[string]any{"status": "cancelled"}, nil, "")
	if cancelled.Frame.H != 148 {
		t.Errorf("cancelled: %v", cancelled.Frame)
	}
	expired := write(t, b, open(map[string]any{}).ID, map[string]any{"status": "expired"}, nil, "")
	if expired.Frame.H != 148 {
		t.Errorf("expired: %v", expired.Frame)
	}

	// A note makes the closed tile 40 taller; where and how wide it was stays.
	q := open(map[string]any{})
	noted := write(t, b, q.ID, map[string]any{"status": "answered", "answer": map[string]any{"note": "go ahead"}}, nil, "")
	if noted.Frame != (model.Frame{X: q.Frame.X, Y: q.Frame.Y, W: 460, H: 188}) {
		t.Errorf("noted: %v (was %v)", noted.Frame, q.Frame)
	}

	// The call's frame wins.
	kept := write(t, b, open(map[string]any{}).ID, map[string]any{"status": "cancelled"}, frame(0, 9000, 460, 300), "")
	if kept.Frame.H != 300 {
		t.Errorf("a given frame: %v", kept.Frame)
	}

	// Already no taller than the closed tile: no frame written.
	small := ask(t, b, askProps(map[string]any{"asker": asker, "options": []any{}}), frame(0, 8000, 460, 100), "")
	if closed := write(t, b, small.ID, map[string]any{"status": "cancelled"}, nil, ""); closed.Frame != small.Frame {
		t.Errorf("small: %v", closed.Frame)
	}

	// At zoom 2 the body doubles under a 1× title bar: 26 + 122 × 2.
	zoomed := ask(t, b, askProps(map[string]any{"asker": asker, "zoom": 2.0}), nil, "")
	if closed := write(t, b, zoomed.ID, map[string]any{"status": "cancelled"}, nil, ""); closed.Frame.H != 270 {
		t.Errorf("zoomed: %v", closed.Frame)
	}
	// A zoomed note makes the closed tile taller than the open one was: it stays.
	both := ask(t, b, askProps(map[string]any{"asker": asker, "zoom": 2.0}), nil, "")
	if closed := write(t, b, both.ID, map[string]any{"status": "answered", "answer": map[string]any{"note": "n"}}, nil, ""); closed.Frame.H != 294 {
		t.Errorf("zoomed with a note: %v", closed.Frame)
	}

	// Changes that leave the question open leave the frame.
	still := open(map[string]any{})
	if o := write(t, b, still.ID, map[string]any{"recommended": "a"}, nil, ""); o.Frame != still.Frame {
		t.Errorf("open: %v", o.Frame)
	}
}

func TestAnAnswerIsStampedWithWhenAndByWhomWhateverTheCallSays(t *testing.T) {
	b := New("brd", "/r")
	terminal := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	patch := func() map[string]any {
		return map[string]any{"status": "answered", "answer": map[string]any{
			"option": "b", "at": "1999-01-01T00:00:00Z", "by": map[string]any{"kind": "agent", "tile": "obj_other"},
		}}
	}
	byUser := write(t, b, ask(t, b, askProps(map[string]any{"asker": map[string]any{"name": "cos"}}), nil, "").ID, patch(), nil, "")
	if !jsonEq(byUser.Props["answer"], map[string]any{"option": "b", "at": "2026-10-05T17:00:02Z", "by": map[string]any{"kind": "user"}}) {
		t.Errorf("by the user: %v", byUser.Props["answer"])
	}
	byAgent := write(t, b, ask(t, b, askProps(map[string]any{"asker": map[string]any{"name": "cos"}}), nil, "").ID, patch(), nil, terminal.ID)
	if !jsonEq(byAgent.Props["answer"], map[string]any{"option": "b", "at": "2026-10-05T17:00:02Z", "by": map[string]any{"kind": "agent", "tile": terminal.ID}}) {
		t.Errorf("by a terminal: %v", byAgent.Props["answer"])
	}
	if byAgent.UpdatedBy == nil || byAgent.UpdatedBy.Tile != terminal.ID {
		t.Errorf("updatedBy %v", byAgent.UpdatedBy)
	}
}

func TestAQuestionMovesOpenToAnsweredCancelledOrExpiredAndNoFurther(t *testing.T) {
	b := New("brd", "/r")
	asker := map[string]any{"name": "cos"}
	for status, patch := range map[string]map[string]any{
		"answered":  {"status": "answered", "answer": map[string]any{"option": "a"}},
		"cancelled": {"status": "cancelled"},
		"expired":   {"status": "expired"},
	} {
		q := ask(t, b, askProps(map[string]any{"asker": asker}), nil, "")
		if o := write(t, b, q.ID, patch, nil, ""); o.Props["status"] != status || o.Rev != 2 {
			t.Fatalf("%s: %v rev %d", status, o.Props, o.Rev)
		}
		for name, change := range map[string]map[string]any{
			"reopen":      {"status": "open"},
			"another end": {"status": "cancelled"},
			"the text":    {"question": "other?"},
			"an option":   {"recommended": "b"},
			"expiry":      {"expiresAt": "2026-10-05T17:00:00Z"},
		} {
			beforeRev := b.Objects()[q.ID].Rev
			_, err := writeErr(b, q.ID, change, nil, "")
			if status == "cancelled" && name == "another end" {
				if err != nil {
					t.Errorf("%s then %s: %v", status, name, err)
				}
				continue
			}
			if err == nil || b.Objects()[q.ID].Rev != beforeRev || b.Objects()[q.ID].Props["status"] != status {
				t.Errorf("%s then %s: %v", status, name, err)
			}
		}
		// Archived, key and zoom still go; archive is not a status.
		archived := write(t, b, q.ID, map[string]any{"archived": true, "key": "K-" + status, "zoom": 1.5}, nil, "")
		if archived.Props["status"] != status || archived.Props["archived"] != true {
			t.Errorf("%s archived: %v", status, archived.Props)
		}
		if back := write(t, b, q.ID, map[string]any{"archived": nil}, nil, ""); back.Props["archived"] != nil || back.Props["status"] != status {
			t.Errorf("%s brought back: %v", status, back.Props)
		}
	}

	// An open question can't be archived, and the frame of a failed write stays.
	q := ask(t, b, askProps(map[string]any{"asker": asker}), nil, "")
	if _, err := writeErr(b, q.ID, map[string]any{"archived": true}, nil, ""); err == nil || err.Error() != "an open question can't be archived: answer or cancel it first" {
		t.Errorf("archive open: %v", err)
	}
	if b.Objects()[q.ID].Rev != 1 {
		t.Error("a refused write changed the question")
	}
	// Only a question is judged: the same props on a note are just props.
	note := b.Create(model.Note, map[string]any{"markdown": "x"}, frame(0, 9000, 100, 100), "", "")
	props, f, err := b.QuestionUpdate(note.ID, map[string]any{"status": "bogus"}, true, nil, "", answeredAt)
	if err != nil || f != nil || props["status"] != "bogus" {
		t.Errorf("note: %v %v %v", props, f, err)
	}
	if _, _, err := b.QuestionUpdate("obj_missing", map[string]any{}, true, nil, "", answeredAt); err == nil || err.Error() != "object obj_missing" {
		t.Errorf("missing: %v", err)
	}
	// Without props there is nothing to judge or stamp.
	if props, f, err := b.QuestionUpdate(q.ID, nil, false, frame(1, 2, 3, 4), "", answeredAt); err != nil || props != nil || *f != *frame(1, 2, 3, 4) {
		t.Errorf("no props: %v %v %v", props, f, err)
	}
}

func TestAnAnsweredQuestionIsHandedToItsAskingTerminalWithItsOwnHeader(t *testing.T) {
	b := New("brd", "/r")
	terminal := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	other := b.Create(model.Terminal, map[string]any{}, frame(2000, 0, 1000, 620), "", "")
	note := b.Create(model.Note, map[string]any{"markdown": "# Plan"}, frame(0, 900, 300, 200), "", "")

	q := ask(t, b, askProps(map[string]any{"recommended": "a", "context": []any{map[string]any{"path": "a.go", "lines": map[string]any{"start": 1.0, "end": 4.0}}}}), nil, terminal.ID)
	// Not yet: nothing waits for the terminal.
	if _, context := b.Drain(true, terminal.ID, false); context != "" {
		t.Fatalf("before the answer: %q", context)
	}
	// A script's mention queued first, so the question's block comes second.
	if _, err := b.HandOff([]map[string]any{{"kind": "object", "object": note.ID}}, terminal.ID, "", "", false, ""); err != nil {
		t.Fatal(err)
	}
	write(t, b, q.ID, map[string]any{"status": "answered", "answer": map[string]any{"option": "a", "note": "go\nnow"}}, nil, "")

	resolved, context := b.Drain(true, terminal.ID, false)
	if len(resolved) != 2 {
		t.Fatalf("mentions %d: %s", len(resolved), context)
	}
	header := "Your question " + q.ID + " was answered (easl ask):"
	for _, want := range []string{
		"Attached by a script to its prompt to you (agent.prompt):",
		header + "\n[2] question " + q.ID + ` "Ship it?"`,
		"\n    question: Ship it?\n    asked by terminal " + terminal.ID + " · answered\n    [a] Yes (recommended)\n    [b] No\n    context: a.go:1-4\n",
		`    answer: [a] Yes · note: "go\nnow" · by the user at 2026-10-05T17:00:02Z`,
	} {
		if !strings.Contains(context, want) {
			t.Errorf("context lacks %q:\n%s", want, context)
		}
	}
	if strings.Count(context, "<canvas-mentions") != 2 || strings.Contains(context, "Attached by terminal") {
		t.Errorf("one block per (sender, header):\n%s", context)
	}
	if blocks := strings.SplitN(context, "<canvas-mentions", 3); strings.Contains(blocks[2], "Attached by") || strings.Contains(blocks[1], "Your question") {
		t.Errorf("blocks mixed:\n%s", context)
	}
	if _, other := b.Drain(true, other.ID, false); other != "" {
		t.Errorf("another terminal got it: %q", other)
	}

	// Delivered with a drained prompt, once; a later write of the answered question hands nothing off.
	b.Drain(false, terminal.ID, false)
	write(t, b, q.ID, map[string]any{"archived": true}, nil, "")
	if _, context := b.Drain(true, terminal.ID, false); context != "" {
		t.Errorf("after delivery: %q", context)
	}
}

func TestOnlyAnAnswerToATerminalOnThisBoardIsHandedOff(t *testing.T) {
	b := New("brd", "/r")
	terminal := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	note := b.Create(model.Note, map[string]any{"markdown": "x"}, frame(0, 900, 300, 200), "", "")
	answer := map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}

	named := ask(t, b, askProps(map[string]any{"asker": map[string]any{"name": "cos", "tile": "obj_elsewhere"}}), nil, "")
	write(t, b, named.ID, answer, nil, "")
	notATerminal := ask(t, b, askProps(map[string]any{"asker": map[string]any{"tile": note.ID}}), nil, "")
	write(t, b, notATerminal.ID, answer, nil, "")
	cancelled := ask(t, b, askProps(nil), nil, terminal.ID)
	write(t, b, cancelled.ID, map[string]any{"status": "cancelled"}, nil, "")
	expired := ask(t, b, askProps(nil), nil, terminal.ID)
	write(t, b, expired.ID, map[string]any{"status": "expired"}, nil, "")
	if _, context := b.Drain(true, terminal.ID, false); context != "" {
		t.Errorf("handed off:\n%s", context)
	}

	// The question may also be answered by another terminal: the asker still gets it.
	asked := ask(t, b, askProps(nil), nil, terminal.ID)
	write(t, b, asked.ID, answer, nil, note.ID)
	if _, context := b.Drain(true, terminal.ID, false); !strings.Contains(context, "answer: [a] Yes · by terminal "+note.ID+" at ") {
		t.Errorf("answered by a terminal:\n%s", context)
	}
}

func TestExpiringQuestionsClosesTheDueOpenOnesAsTheSystem(t *testing.T) {
	b := New("brd", "/r")
	asker := map[string]any{"name": "cos"}
	now := time.Now()
	past := iso(now.Add(-time.Hour))
	due := ask(t, b, askProps(map[string]any{"asker": asker, "expiresAt": past, "question": "due"}), nil, "")
	zoomed := ask(t, b, askProps(map[string]any{"asker": asker, "expiresAt": iso(now.Add(-time.Second)), "zoom": 2.0}), nil, "")
	later := ask(t, b, askProps(map[string]any{"asker": asker, "expiresAt": iso(now.Add(time.Hour))}), nil, "")
	never := ask(t, b, askProps(map[string]any{"asker": asker}), nil, "")
	answered := ask(t, b, askProps(map[string]any{"asker": asker, "expiresAt": past}), nil, "")
	write(t, b, answered.ID, map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}, nil, "")
	note := b.Create(model.Note, map[string]any{"markdown": "x", "expiresAt": past}, frame(0, 9000, 100, 100), "", "")

	events := recorder(b)
	got := b.ExpireQuestions(now)
	want := []string{due.ID, zoomed.ID}
	if want[0] > want[1] {
		want[0], want[1] = want[1], want[0]
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("expired %v, want %v", got, want)
	}
	if o := b.Objects()[due.ID]; o.Props["status"] != "expired" || o.Frame.H != 148 || o.Frame.W != 460 || o.Frame.X != due.Frame.X || o.Rev != 2 || o.UpdatedBy == nil || o.UpdatedBy.Kind != "user" {
		t.Errorf("due: %+v", o)
	}
	if o := b.Objects()[zoomed.ID]; o.Frame.H != 270 {
		t.Errorf("zoomed: %v", o.Frame)
	}
	for _, id := range []string{later.ID, never.ID, note.ID} {
		if o := b.Objects()[id]; o.Rev != 1 || o.Props["status"] == "expired" {
			t.Errorf("%s changed: %+v", id, o)
		}
	}
	if o := b.Objects()[answered.ID]; o.Props["status"] != "answered" {
		t.Errorf("answered: %v", o.Props)
	}
	if strings.Join(names(*events), ",") != "object.updated,object.updated" {
		t.Errorf("events %v", names(*events))
	}
	entries := b.Activity.Entries()
	last := entries[len(entries)-1]
	if last.Actor != SystemActor || last.Kind != KindUpdated || !strings.HasPrefix(last.Summary, `question "`) || !strings.Contains(last.Summary, "status") {
		t.Errorf("activity %+v", last)
	}
	if again := b.ExpireQuestions(now); len(again) != 0 {
		t.Errorf("expired twice: %v", again)
	}
	// An `expiresAt` that isn't a time never expires.
	odd := b.Create(model.Question, map[string]any{"question": "q", "options": []any{}, "asker": asker, "expiresAt": "soon"}, frame(0, 9500, 460, 194), "", "")
	if got := b.ExpireQuestions(now.Add(100 * 365 * 24 * time.Hour)); len(got) != 1 || got[0] == odd.ID || statusOf(b, odd.ID) != nil {
		t.Errorf("an unreadable expiresAt: %v", got)
	}
}

// timed is a board under a lock, as the registry's, whose events arrive on a channel.
type timed struct {
	*Board
	mu     *sync.Mutex
	events chan model.Event
}

func newTimed() *timed {
	t := &timed{Board: New("brd", "/r"), mu: &sync.Mutex{}, events: make(chan model.Event, 64)}
	t.Lock = t.mu
	t.OnEvent = func(e model.Event) { t.events <- e }
	return t
}

// expired waits for the object.updated event announcing id expired.
func (b *timed) expired(t *testing.T, id string, within time.Duration) {
	t.Helper()
	deadline := time.After(within)
	for {
		select {
		case e := <-b.events:
			data, _ := e.Data.(map[string]any)
			props, _ := data["props"].(map[string]any)
			if e.Name == EventObjectUpdated && data["id"] == id && props["status"] == "expired" {
				return
			}
		case <-deadline:
			t.Fatalf("%s not expired within %v", id, within)
		}
	}
}

// quiet reports whether no event announcing id expired arrives within d.
func (b *timed) quiet(id string, d time.Duration) bool {
	deadline := time.After(d)
	for {
		select {
		case e := <-b.events:
			data, _ := e.Data.(map[string]any)
			props, _ := data["props"].(map[string]any)
			if e.Name == EventObjectUpdated && data["id"] == id && props["status"] == "expired" {
				return false
			}
		case <-deadline:
			return true
		}
	}
}

func (b *timed) status(id string) any {
	b.mu.Lock()
	defer b.mu.Unlock()
	return statusOf(b.Board, id)
}

func expiring(at time.Time) map[string]any {
	return askProps(map[string]any{"asker": map[string]any{"name": "cos"}, "expiresAt": iso(at)})
}

func TestAPastDueQuestionExpiresOnTheNextTurnNotInsideItsWrite(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	q := ask(t, b.Board, expiring(time.Now().Add(-time.Hour)), nil, "")
	// Still inside the call that wrote it: open, announced created.
	if statusOf(b.Board, q.ID) != "open" || len(b.events) != 1 {
		t.Errorf("inside the write: %v, %d events", statusOf(b.Board, q.ID), len(b.events))
	}
	b.mu.Unlock()

	b.expired(t, q.ID, 2*time.Second)
	b.mu.Lock()
	defer b.mu.Unlock()
	if o := b.Objects()[q.ID]; o.Props["status"] != "expired" || o.Frame.H != 148 {
		t.Errorf("after: %+v", o)
	}
}

func TestAFutureQuestionExpiresWhenItsTimeComes(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	q := ask(t, b.Board, expiring(time.Now().Add(400*time.Millisecond)), nil, "")
	b.mu.Unlock()
	if !b.quiet(q.ID, 150*time.Millisecond) || b.status(q.ID) != "open" {
		t.Fatal("expired early")
	}
	b.expired(t, q.ID, 3*time.Second)
}

func TestTheTimerFollowsTheEarliestOpenQuestionAndEveryWrite(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	hour := ask(t, b.Board, expiring(time.Now().Add(time.Hour)), nil, "")
	soon := ask(t, b.Board, expiring(time.Now().Add(200*time.Millisecond)), nil, "")
	b.mu.Unlock()
	b.expired(t, soon.ID, 3*time.Second)
	if b.status(hour.ID) != "open" {
		t.Fatal("the later one expired with it")
	}

	// Writing the later one's expiresAt earlier reschedules for it.
	b.mu.Lock()
	write(t, b.Board, hour.ID, map[string]any{"expiresAt": iso(time.Now().Add(150 * time.Millisecond))}, nil, "")
	b.mu.Unlock()
	b.expired(t, hour.ID, 3*time.Second)

	// Writing it later keeps the question open past the first time.
	b.mu.Lock()
	moved := ask(t, b.Board, expiring(time.Now().Add(150*time.Millisecond)), nil, "")
	write(t, b.Board, moved.ID, map[string]any{"expiresAt": iso(time.Now().Add(time.Hour))}, nil, "")
	b.mu.Unlock()
	if !b.quiet(moved.ID, 500*time.Millisecond) || b.status(moved.ID) != "open" {
		t.Error("the replaced time still fired")
	}

	// Answering takes a question out of the schedule.
	b.mu.Lock()
	answered := ask(t, b.Board, expiring(time.Now().Add(150*time.Millisecond)), nil, "")
	write(t, b.Board, answered.ID, map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}, nil, "")
	b.mu.Unlock()
	if !b.quiet(answered.ID, 500*time.Millisecond) || b.status(answered.ID) != "answered" {
		t.Error("an answered question expired")
	}
}

func TestEveryPathThatStoresAQuestionReschedulesIncludingRevertedBatches(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	q := ask(t, b.Board, expiring(time.Now().Add(300*time.Millisecond)), nil, "")
	// A batch moves the expiry out and then fails: the revert stores the question as it was.
	err := b.Atomically(func() error {
		write(t, b.Board, q.ID, map[string]any{"expiresAt": iso(time.Now().Add(time.Hour))}, nil, "")
		return InvalidParams("boom")
	})
	b.mu.Unlock()
	if err == nil {
		t.Fatal("batch succeeded")
	}
	b.expired(t, q.ID, 3*time.Second)
}

func TestAClosedBoardsTimerStops(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	q := ask(t, b.Board, expiring(time.Now().Add(150*time.Millisecond)), nil, "")
	b.StopQuestionExpiry()
	b.mu.Unlock()
	if !b.quiet(q.ID, 500*time.Millisecond) || b.status(q.ID) != "open" {
		t.Error("expired after it was stopped")
	}
}

func TestABoardWithoutALockSetsNoTimer(t *testing.T) {
	b := New("brd", "/r")
	q := ask(t, b, expiring(time.Now().Add(-time.Hour)), nil, "")
	time.Sleep(50 * time.Millisecond)
	if statusOf(b, q.ID) != "open" {
		t.Fatal("expired by itself")
	}
	if got := b.ExpireQuestions(time.Now()); len(got) != 1 || statusOf(b, q.ID) != "expired" {
		t.Errorf("expired %v", got)
	}
}

func TestQuestionsPastDueWhenABoardOpensExpireThen(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	reg := NewRegistry(filepath.Join(dir, "boards"), time.Hour, "")
	reg.Mu.Lock()
	first, err := reg.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	q := ask(t, first, expiring(time.Now().Add(300*time.Millisecond)), nil, "")
	id := first.ID()
	closeErr := reg.Close(id, nil)
	reg.Mu.Unlock()
	if closeErr != nil {
		t.Fatal(closeErr)
	}

	// The closed board's timer is stopped: it stays open though its time passes.
	time.Sleep(450 * time.Millisecond)
	reg.Mu.Lock()
	if statusOf(first, q.ID) != "open" {
		t.Error("a closed board expired a question")
	}
	reopened, err := reg.Open(root)
	reg.Mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		reg.Mu.Lock()
		status := statusOf(reopened, q.ID)
		reg.Mu.Unlock()
		if status == "expired" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("not expired when the board opened")
}

func closedQuestion(t *testing.T, b *Board, extra map[string]any, updated time.Time) model.Object {
	t.Helper()
	props := askProps(map[string]any{"asker": map[string]any{"name": "cos"}})
	for k, v := range extra {
		props[k] = v
	}
	o := ask(t, b, props, frame(0, 0, 460, 294), "")
	closed := write(t, b, o.ID, map[string]any{"status": "answered", "answer": map[string]any{"option": "a", "note": "go"}}, nil, "")
	stored := b.objects[closed.ID]
	stored.UpdatedAt = updated
	b.objects[closed.ID] = stored
	return stored
}

func TestArchiveQuestionsHonorsEligibilityBoundaries(t *testing.T) {
	b := New("brd", "/r")
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	open := ask(t, b, askProps(map[string]any{"asker": map[string]any{"name": "cos"}, "archiveAfter": 0.0}), nil, "")
	back := b.objects[open.ID]
	back.UpdatedAt = now.Add(-time.Hour)
	b.objects[open.ID] = back
	kept := closedQuestion(t, b, map[string]any{"keep": true, "archiveAfter": 0.0}, now.Add(-time.Hour))
	already := closedQuestion(t, b, nil, now.Add(-time.Hour))
	write(t, b, already.ID, map[string]any{"archived": true}, nil, "")
	already = b.objects[already.ID]
	already.UpdatedAt = now.Add(-time.Hour)
	b.objects[already.ID] = already
	due := closedQuestion(t, b, nil, now.Add(-10*time.Second))
	notYet := closedQuestion(t, b, nil, now.Add(-10*time.Second+time.Nanosecond))
	zero := closedQuestion(t, b, map[string]any{"archiveAfter": 0.0}, now)
	zeroLater := closedQuestion(t, b, map[string]any{"archiveAfter": 0.0}, now.Add(time.Millisecond))
	halfMinute := closedQuestion(t, b, map[string]any{"archiveAfter": 30.0}, now.Add(-30*time.Second))
	halfMinuteEarly := closedQuestion(t, b, map[string]any{"archiveAfter": 30.0}, now.Add(-30*time.Second+time.Nanosecond))
	garbage := closedQuestion(t, b, nil, now.Add(-10*time.Second))
	tooBig := closedQuestion(t, b, nil, now.Add(-9*time.Second))
	for id, delay := range map[string]any{garbage.ID: "soon", tooBig.ID: 90000.0} {
		stored := b.objects[id]
		stored.Props["archiveAfter"] = delay
		b.objects[id] = stored
	}
	note := b.Create(model.Note, map[string]any{"markdown": "x"}, frame(0, 9000, 100, 100), "", "")

	got := b.ArchiveQuestions(now)
	want := map[string]bool{due.ID: true, zero.ID: true, halfMinute.ID: true, garbage.ID: true}
	if len(got) != len(want) {
		t.Fatalf("archived %v", got)
	}
	for _, id := range got {
		if !want[id] {
			t.Errorf("archived %s", id)
		}
		o := b.Objects()[id]
		if o.Props["archived"] != true || o.Props["status"] != "answered" || o.Props["answer"] == nil || o.Frame != due.Frame && id == due.ID {
			t.Errorf("%s %+v", id, o)
		}
	}
	for _, id := range []string{open.ID, kept.ID, already.ID, notYet.ID, zeroLater.ID, halfMinuteEarly.ID, tooBig.ID, note.ID} {
		if b.Objects()[id].Props["archived"] == true && id != already.ID {
			t.Errorf("%s was archived", id)
		}
	}
	if again := b.ArchiveQuestions(now); len(again) != 0 {
		t.Errorf("archived twice: %v", again)
	}
}

func TestChangingRetentionAfterClosureRestartsTheGrace(t *testing.T) {
	b := New("brd", "/r")
	q := closedQuestion(t, b, nil, time.Now().Add(-time.Hour))
	frame, answer := q.Frame, q.Props["answer"]
	kept := write(t, b, q.ID, map[string]any{"keep": true, "archiveAfter": 30.0}, nil, "")
	if kept.Props["keep"] != true || kept.Props["archiveAfter"] != 30.0 || kept.Props["status"] != "answered" || kept.Frame != frame {
		t.Fatalf("retention write %v", kept.Props)
	}
	if got := b.ArchiveQuestions(time.Now()); len(got) != 0 {
		t.Fatalf("keep did not exempt: %v", got)
	}
	explicit := write(t, b, q.ID, map[string]any{"archived": true}, nil, "")
	if explicit.Props["archived"] != true || explicit.Props["keep"] != true {
		t.Fatalf("explicit archive %v", explicit.Props)
	}
	back := write(t, b, q.ID, map[string]any{"archived": nil, "keep": nil}, nil, "")
	if back.Props["archived"] != nil || back.Props["keep"] != nil || back.Props["archiveAfter"] != 30.0 || back.Frame != frame || !jsonEq(back.Props["answer"], answer) {
		t.Fatalf("brought back %v", back.Props)
	}
	if got := b.ArchiveQuestions(time.Now().Add(29 * time.Second)); len(got) != 0 {
		t.Fatalf("clearing keep restarted from the old close: %v", got)
	}
	if got := b.ArchiveQuestions(back.UpdatedAt.Add(30 * time.Second)); len(got) != 1 || got[0] != q.ID {
		t.Fatalf("new deadline: %v", got)
	}
	rev := b.Objects()[q.ID].Rev
	if _, err := writeErr(b, q.ID, map[string]any{"question": "other?"}, nil, ""); err == nil || b.Objects()[q.ID].Rev != rev {
		t.Fatalf("closed text change: %v", err)
	}
}

func TestSystemArchiveIsPersistedWithoutAnUndoStep(t *testing.T) {
	b := New("brd", "/r")
	events := recorder(b)
	saves := 0
	b.OnChange = func() { saves++ }
	q := closedQuestion(t, b, nil, time.Now().Add(-time.Minute))
	frame, answer, status := q.Frame, q.Props["answer"], q.Props["status"]
	*events = nil
	saves = 0
	if got := b.ArchiveQuestions(time.Now()); len(got) != 1 || got[0] != q.ID {
		t.Fatalf("archived %v", got)
	}
	after := b.Objects()[q.ID]
	if after.Props["archived"] != true || after.Props["status"] != status || !jsonEq(after.Props["answer"], answer) || after.Frame != frame {
		t.Fatalf("archive changed the question: %+v", after)
	}
	if after.UpdatedBy == nil || after.UpdatedBy.Kind != "user" || saves == 0 {
		t.Fatalf("updatedBy %v saves %d", after.UpdatedBy, saves)
	}
	if strings.Join(names(*events), ",") != "object.updated" {
		t.Fatalf("events %v", names(*events))
	}
	entries := b.Activity.Entries()
	last := entries[len(entries)-1]
	if last.Actor != SystemActor || last.Kind != KindUpdated {
		t.Fatalf("activity %+v", last)
	}

	second := closedQuestion(t, b, nil, time.Now().Add(-time.Minute))
	var noteID string
	err := b.Atomically(func() error {
		note := b.Create(model.Note, map[string]any{"markdown": "x"}, &frame, "", "")
		noteID = note.ID
		if got := b.ArchiveQuestions(time.Now()); len(got) != 1 || got[0] != second.ID {
			t.Fatalf("archived inside the step: %v", got)
		}
		return InvalidParams("boom")
	})
	if err == nil || b.objects[noteID].ID != "" || b.objects[second.ID].Props["archived"] != true || b.objects[q.ID].Props["archived"] != true {
		t.Fatalf("revert undid the archive: %v note %q", err, b.objects[noteID].ID)
	}
}

func (b *timed) waitArchived(t *testing.T, id string, within time.Duration) []model.Event {
	t.Helper()
	var got []model.Event
	deadline := time.After(within)
	for {
		select {
		case e := <-b.events:
			got = append(got, e)
			data, _ := e.Data.(map[string]any)
			props, _ := data["props"].(map[string]any)
			if e.Name == EventObjectUpdated && data["id"] == id && props["archived"] == true {
				return got
			}
		case <-deadline:
			t.Fatalf("%s not archived within %v", id, within)
		}
	}
}

func (b *timed) quietArchived(id string, d time.Duration) bool {
	deadline := time.After(d)
	for {
		select {
		case e := <-b.events:
			data, _ := e.Data.(map[string]any)
			props, _ := data["props"].(map[string]any)
			if e.Name == EventObjectUpdated && data["id"] == id && props["archived"] == true {
				return false
			}
		case <-deadline:
			return true
		}
	}
}

func TestAClosedQuestionArchivesWhenItsDelayElapses(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	q := ask(t, b.Board, askProps(map[string]any{"asker": map[string]any{"name": "cos"}, "archiveAfter": 0.25}), nil, "")
	closed := write(t, b.Board, q.ID, map[string]any{"status": "cancelled"}, nil, "")
	b.mu.Unlock()
	if !b.quietArchived(q.ID, 80*time.Millisecond) {
		t.Fatal("archived early")
	}
	b.waitArchived(t, q.ID, 3*time.Second)
	b.mu.Lock()
	defer b.mu.Unlock()
	o := b.Objects()[q.ID]
	if o.Props["status"] != "cancelled" || o.Props["archived"] != true || o.Frame != closed.Frame {
		t.Fatalf("after: %+v", o)
	}
}

func TestExpiryThenArchiveUsesOneTimer(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	later := ask(t, b.Board, expiring(time.Now().Add(time.Hour)), nil, "")
	q := ask(t, b.Board, askProps(map[string]any{
		"asker": map[string]any{"name": "cos"}, "expiresAt": iso(time.Now().Add(200 * time.Millisecond)), "archiveAfter": 0.0,
	}), nil, "")
	if b.questionExpiry == nil {
		t.Fatal("no timer")
	}
	b.mu.Unlock()
	events := b.waitArchived(t, q.ID, 3*time.Second)
	var sawExpired bool
	for _, e := range events {
		data, _ := e.Data.(map[string]any)
		props, _ := data["props"].(map[string]any)
		if e.Name != EventObjectUpdated || data["id"] != q.ID {
			continue
		}
		if props["status"] == "expired" && props["archived"] != true {
			sawExpired = true
		}
		if props["archived"] == true && !sawExpired {
			t.Fatal("archived before it expired")
		}
	}
	if !sawExpired {
		t.Fatal("no expiry before the archive")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	defer b.StopQuestionExpiry()
	o := b.Objects()[q.ID]
	if o.Props["status"] != "expired" || o.Props["archived"] != true || o.Frame.H != 148 {
		t.Fatalf("after: %+v", o)
	}
	if statusOf(b.Board, later.ID) != "open" {
		t.Fatal("the later question was closed with it")
	}
}

func TestAKeptQuestionDoesNotScheduleArchive(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	q := ask(t, b.Board, askProps(map[string]any{"asker": map[string]any{"name": "cos"}, "keep": true, "archiveAfter": 0.0}), nil, "")
	write(t, b.Board, q.ID, map[string]any{"status": "cancelled"}, nil, "")
	if b.questionExpiry != nil {
		t.Fatal("a kept question scheduled a timer")
	}
	b.mu.Unlock()
	if !b.quietArchived(q.ID, 300*time.Millisecond) || b.status(q.ID) != "cancelled" {
		t.Fatal("a kept question archived")
	}
}

func TestStoppingTheTimerStopsArchiveToo(t *testing.T) {
	b := newTimed()
	b.mu.Lock()
	q := ask(t, b.Board, askProps(map[string]any{"asker": map[string]any{"name": "cos"}, "archiveAfter": 0.15}), nil, "")
	write(t, b.Board, q.ID, map[string]any{"status": "cancelled"}, nil, "")
	b.StopQuestionExpiry()
	b.mu.Unlock()
	if !b.quietArchived(q.ID, 400*time.Millisecond) || b.status(q.ID) != "cancelled" {
		t.Fatal("archived after the timer was stopped")
	}
}

func TestLoadArchivesOnlyDueClosedQuestionsWithoutChurn(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	reg := NewRegistry(filepath.Join(dir, "boards"), time.Hour, "")
	id := store.PathID(root)
	t.Cleanup(func() {
		reg.Mu.Lock()
		defer reg.Mu.Unlock()
		_ = reg.Close(id, nil)
	})
	format := store.Format
	old := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	recent := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Second)
	asker := map[string]any{"name": "cos"}
	answer := map[string]any{"option": "a", "note": "go"}
	q := func(oid string, at time.Time, extra map[string]any) model.Object {
		props := map[string]any{
			"question": "Ship it?",
			"options":  []any{map[string]any{"id": "a", "label": "Yes"}},
			"asker":    asker,
			"status":   "answered",
			"answer":   answer,
		}
		for k, v := range extra {
			props[k] = v
		}
		return model.Object{
			ID: oid, Type: model.Question, Rev: 7,
			CreatedAt: old, UpdatedAt: at, CreatedBy: model.Actor{Kind: "user"},
			Frame: model.Frame{X: 10, Y: 20, W: 460, H: 188}, Props: props,
		}
	}
	objects := []model.Object{
		q("obj_due", old, nil),
		q("obj_kept", old, map[string]any{"keep": true}),
		q("obj_recent", recent, map[string]any{"archiveAfter": 86400.0}),
		q("obj_open", old, map[string]any{"status": "open"}),
		q("obj_garbage", old, map[string]any{"archiveAfter": "soon"}),
		q("obj_long", recent, map[string]any{"archiveAfter": 90000.0}),
		q("obj_zero", recent, map[string]any{"archiveAfter": 0.0}),
	}
	delete(objects[3].Props, "answer")
	snap := &store.Snapshot{Format: &format, ID: id, Root: root, Revision: 19, Objects: objects}
	if err := reg.Store.Write(snap); err != nil {
		t.Fatal(err)
	}
	opened := false
	reg.Opened = func(b *Board, _ string) {
		opened = true
		if b.objects["obj_due"].Props["archived"] != true || b.objects["obj_recent"].Props["archived"] == true {
			t.Error("opened callback saw the wrong archive flags")
		}
	}
	reg.Mu.Lock()
	b, err := reg.Open(root)
	reg.Mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if !opened || b.Revision() != 19 {
		t.Fatalf("open = %v, revision = %d", opened, b.Revision())
	}
	wantArchived := map[string]bool{"obj_due": true, "obj_garbage": true, "obj_zero": true}
	for _, original := range objects {
		got := b.objects[original.ID]
		if got.Rev != 7 || !got.UpdatedAt.Equal(original.UpdatedAt) || got.Frame != original.Frame {
			t.Errorf("%s churned: rev %d updated %v frame %v", original.ID, got.Rev, got.UpdatedAt, got.Frame)
		}
		if (got.Props["archived"] == true) != wantArchived[original.ID] {
			t.Errorf("%s archived=%v", original.ID, got.Props["archived"])
		}
		if original.ID != "obj_open" && got.Props["answer"] == nil {
			t.Errorf("%s lost its answer", original.ID)
		}
	}
	entries := b.Activity.Entries()
	if len(entries) != 1 || entries[0].Kind != KindRestart || entries[0].Rev != 19 {
		t.Fatalf("normalization recorded activity: %+v", entries)
	}
	disk, err := reg.Store.Read(id)
	if err != nil || disk == nil || disk.Revision != 19 {
		t.Fatalf("disk: %v rev %v", err, disk)
	}
	if scrubDueQuestions(disk, time.Now()) {
		t.Fatal("a second scrub changed normalized questions")
	}
	reg.Mu.Lock()
	if err := reg.Close(id, nil); err != nil {
		reg.Mu.Unlock()
		t.Fatal(err)
	}
	again, err := reg.Open(root)
	reg.Mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if again.Revision() != 19 || again.objects["obj_due"].Rev != 7 || again.objects["obj_due"].Props["archived"] != true || again.objects["obj_recent"].Props["archived"] == true {
		t.Fatalf("reopen churned revision %d due %+v recent %+v", again.Revision(), again.objects["obj_due"], again.objects["obj_recent"])
	}
}

func TestAHostsDefaultDelayArchivesOnlyQuestionsThatNameNoDelayOfTheirOwn(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "thirty")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	reg := NewRegistry(filepath.Join(dir, "thirty-boards"), time.Hour, "")
	reg.DefaultQuestionArchiveAfter = 30
	boardID := store.PathID(root)
	format := store.Format
	storedAt := time.Now().UTC().Add(time.Hour)
	asker := map[string]any{"name": "cos"}
	snap := &store.Snapshot{Format: &format, ID: boardID, Root: root, Revision: 4, Objects: []model.Object{{
		ID: "obj_stored", Type: model.Question, Rev: 2,
		CreatedAt: storedAt, UpdatedAt: storedAt, CreatedBy: model.Actor{Kind: "user"},
		Frame: model.Frame{X: 10, Y: 20, W: 460, H: 188},
		Props: map[string]any{
			"question": "Ship it?",
			"options":  []any{map[string]any{"id": "a", "label": "Yes"}},
			"asker":    asker,
			"status":   "answered",
			"answer":   map[string]any{"option": "a", "note": "go"},
		},
	}}}
	if err := reg.Store.Write(snap); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		reg.Mu.Lock()
		defer reg.Mu.Unlock()
		_ = reg.Close(boardID, nil)
	})
	reg.Mu.Lock()
	b, err := reg.Open(root)
	if err != nil {
		reg.Mu.Unlock()
		t.Fatal(err)
	}
	b.StopQuestionExpiry()
	b.Lock = nil
	reg.Mu.Unlock()
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	stored := b.objects["obj_stored"]
	stored.UpdatedAt = now
	b.objects["obj_stored"] = stored
	if _, err := b.QuestionToCreate(askProps(map[string]any{"asker": asker, "archiveAfter": -1.0}), ""); err == nil {
		t.Fatal("invalid explicit delay was replaced by the host default")
	}
	own := closedQuestion(t, b, map[string]any{"archiveAfter": 5.0}, now)
	historical := closedQuestion(t, b, map[string]any{"archiveAfter": 10.0}, now)
	kept := closedQuestion(t, b, map[string]any{"keep": true}, now)
	cleared := closedQuestion(t, b, map[string]any{"archiveAfter": nil}, now)
	unnamed := closedQuestion(t, b, nil, now)

	if got := b.ArchiveQuestions(now.Add(5*time.Second - time.Nanosecond)); len(got) != 0 {
		t.Fatalf("before the explicit delay: %v", got)
	}
	if got := b.ArchiveQuestions(now.Add(5 * time.Second)); len(got) != 1 || got[0] != own.ID {
		t.Fatalf("explicit delay: %v", got)
	}
	if got := b.ArchiveQuestions(now.Add(10*time.Second - time.Nanosecond)); len(got) != 0 {
		t.Fatalf("before 10s: %v", got)
	}
	got := b.ArchiveQuestions(now.Add(10 * time.Second))
	want := map[string]bool{stored.ID: true, historical.ID: true}
	if len(got) != len(want) {
		t.Fatalf("stored implicit 10 and explicit 10: %v", got)
	}
	for _, id := range got {
		if !want[id] {
			t.Fatalf("stored implicit 10 and explicit 10: %v", got)
		}
	}
	if got := b.ArchiveQuestions(now.Add(30*time.Second - time.Nanosecond)); len(got) != 0 {
		t.Fatalf("before the host default: %v", got)
	}
	got = b.ArchiveQuestions(now.Add(30 * time.Second))
	want = map[string]bool{cleared.ID: true, unnamed.ID: true}
	if len(got) != len(want) {
		t.Fatalf("omitted and null: %v", got)
	}
	for _, id := range got {
		if !want[id] {
			t.Fatalf("omitted and null: %v", got)
		}
	}
	if got := b.ArchiveQuestions(now.Add(24 * time.Hour)); len(got) != 0 || b.Objects()[kept.ID].Props["archived"] == true {
		t.Fatalf("keep archived: %v", got)
	}
}
