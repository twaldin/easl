package router

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
)

func questionProps(extra map[string]any) map[string]any {
	props := map[string]any{
		"question": "Ship it?",
		"options": []any{
			map[string]any{"id": "a", "label": "Yes"},
			map[string]any{"id": "b", "label": "No"},
		},
		"asker": map[string]any{"name": "cos"},
	}
	for k, v := range extra {
		props[k] = v
	}
	return props
}

func (f *fixture) ask(extra map[string]any) map[string]any {
	f.t.Helper()
	return f.result("object.create", map[string]any{"type": "question", "props": questionProps(extra)})["object"].(map[string]any)
}

func (f *fixture) object(id string) map[string]any {
	f.t.Helper()
	return f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
}

func propsOf(o map[string]any) map[string]any { return o["props"].(map[string]any) }

func sizeOf(o map[string]any) [2]float64 {
	frame := o["frame"].(map[string]any)
	return [2]float64{frame["w"].(float64), frame["h"].(float64)}
}

func (f *fixture) refused(method string, params map[string]any) string {
	f.t.Helper()
	code, message := errorOf(f.call(method, params))
	if code != "invalid_params" {
		f.t.Fatalf("%s: code %q (%s)", method, code, message)
	}
	return message
}

func (f *fixture) terminal() string {
	return f.board.Create(model.Terminal, map[string]any{}, &model.Frame{W: 1000, H: 620}, "", "").ID
}

func TestAQuestionIsCreatedOpenAskedByItsCallerAndSizedByItsProps(t *testing.T) {
	f := newFixture(t)
	terminal := f.terminal()
	created := f.result("object.create", map[string]any{"type": "question", "caller": terminal, "props": map[string]any{
		"question": "Ship it?", "options": []any{map[string]any{"id": "a", "label": "Yes"}, map[string]any{"id": "b", "label": "No"}},
	}})
	o := created["object"].(map[string]any)
	if props := propsOf(o); props["status"] != "open" || props["asker"].(map[string]any)["tile"] != terminal || o["type"] != "question" {
		t.Errorf("props %v", props)
	}
	if got := sizeOf(o); got != [2]float64{460, 294} {
		t.Errorf("size %v", got)
	}
	if created["warnings"] != nil {
		t.Errorf("warnings %v", created["warnings"])
	}
	sized := f.ask(map[string]any{"context": []any{map[string]any{"url": "https://x"}}})
	if got := sizeOf(sized); got != [2]float64{460, 324} {
		t.Errorf("with context %v", got)
	}
	framed := f.result("object.create", map[string]any{"type": "question", "props": questionProps(nil), "frame": map[string]any{"x": 5000.0, "y": 0.0, "w": 500.0, "h": 400.0}})["object"].(map[string]any)
	if got := sizeOf(framed); got != [2]float64{500, 400} {
		t.Errorf("framed %v", got)
	}
	odd := f.result("object.create", map[string]any{"type": "question", "props": questionProps(map[string]any{"volume": 11.0})})
	if w, _ := odd["warnings"].([]any); len(w) != 1 || !strings.Contains(w[0].(string), `unknown prop "volume" for question`) || !strings.Contains(w[0].(string), "question props: answer, archived, asker, context, expiresAt, key, options, question, recommended, status, zoom") {
		t.Errorf("warnings %v", odd["warnings"])
	}
}

func TestAQuestionCreateIsRefusedWithTheRulesMessage(t *testing.T) {
	f := newFixture(t)
	for want, props := range map[string]map[string]any{
		"a question needs props.asker, {name, host?}, when no terminal asks it (no caller)": {"question": "q", "options": []any{}},
		"a question needs props.options, an array of {id, label, why?}":                     {"question": "q", "asker": map[string]any{"name": "cos"}},
		`option id "a" is used twice`:                                                       questionProps(map[string]any{"options": []any{map[string]any{"id": "a", "label": "A"}, map[string]any{"id": "a", "label": "B"}}}),
		"a question is created open, not answered":                                          questionProps(map[string]any{"status": "answered", "answer": map[string]any{"note": "n"}}),
	} {
		before := len(f.board.Objects())
		if got := f.refused("object.create", map[string]any{"type": "question", "props": props}); got != want {
			t.Errorf("got %q, want %q", got, want)
		}
		if len(f.board.Objects()) != before {
			t.Errorf("%s: an object was made", want)
		}
	}
	// A key conflict is the key's, checked before the question's rules.
	f.ask(map[string]any{"key": "ASK-1"})
	if code, _ := errorOf(f.call("object.create", map[string]any{"type": "question", "props": map[string]any{"key": "ASK-1", "question": ""}})); code != "conflict" {
		t.Errorf("key conflict came as %s", code)
	}
}

func TestUpdatingAQuestionAnswersItStampedAndShrunk(t *testing.T) {
	f := newFixture(t)
	terminal := f.terminal()
	q := f.ask(nil)
	id := q["id"].(string)

	answered := f.result("object.update", map[string]any{"id": id, "caller": terminal, "props": map[string]any{
		"status": "answered", "answer": map[string]any{"option": "b", "note": "later", "at": "1999-01-01T00:00:00Z"},
	}})["object"].(map[string]any)
	answer := propsOf(answered)["answer"].(map[string]any)
	at, _ := time.Parse(time.RFC3339, answer["at"].(string))
	if answer["option"] != "b" || !strings.HasSuffix(answer["at"].(string), "Z") || time.Since(at) > time.Minute || time.Since(at) < -time.Minute || answer["by"].(map[string]any)["tile"] != terminal || answer["by"].(map[string]any)["kind"] != "agent" {
		t.Errorf("answer %v", answer)
	}
	if got := sizeOf(answered); got != [2]float64{460, 188} {
		t.Errorf("closed size %v (a note makes it 40 taller)", got)
	}

	if got := f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"question": "again?"}}); got != "question "+id+" is answered: only archived can change" {
		t.Errorf("edit: %s", got)
	}
	if got := f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"status": "open"}}); got != "question "+id+" is answered: only archived can change" {
		t.Errorf("reopen: %s", got)
	}
	archived := f.result("object.update", map[string]any{"id": id, "props": map[string]any{"archived": true}})["object"].(map[string]any)
	if props := propsOf(archived); props["archived"] != true || props["status"] != "answered" {
		t.Errorf("archived %v", props)
	}

	// By the user without a caller; and the call's frame wins over the shrink.
	user := f.ask(nil)
	closed := f.result("object.update", map[string]any{"id": user["id"], "frame": map[string]any{"h": 350.0}, "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}})["object"].(map[string]any)
	if by := propsOf(closed)["answer"].(map[string]any)["by"]; !model.Equal(by, map[string]any{"kind": "user"}) || sizeOf(closed)[1] != 350 {
		t.Errorf("by %v frame %v", by, closed["frame"])
	}

	// Judged before the rev: a refused write is the rules', a valid one at a stale rev the conflict.
	another := f.ask(nil)
	if got := f.refused("object.update", map[string]any{"id": another["id"], "rev": 99.0, "props": map[string]any{"archived": true}}); got != "an open question can't be archived: answer or cancel it first" {
		t.Errorf("refused at a stale rev: %s", got)
	}
	if code, _ := errorOf(f.call("object.update", map[string]any{"id": another["id"], "rev": 99.0, "props": map[string]any{"recommended": "a"}})); code != "conflict" {
		t.Errorf("valid at a stale rev came as %s", code)
	}
	// Props that aren't an object are a question without props.question.
	for _, bad := range []any{nil, "text", 3.0} {
		if got := f.refused("object.update", map[string]any{"id": another["id"], "props": bad}); got != "a question needs props.question, a non-empty string" {
			t.Errorf("props %v: %s", bad, got)
		}
	}
	// Other objects are not judged.
	note := f.result("object.create", note(0, map[string]any{"markdown": "x"}))
	f.result("object.update", map[string]any{"id": idOf(note), "props": map[string]any{"status": "bogus"}})
}

func TestQuestionRulesApplyToUpsertAndBatchToo(t *testing.T) {
	f := newFixture(t)
	created := f.result("object.upsert", map[string]any{"key": "ASK-1", "type": "question", "props": questionProps(nil)})
	id := idOf(created)
	if created["created"] != true || propsOf(created["object"].(map[string]any))["status"] != "open" {
		t.Fatalf("upsert create %v", created)
	}
	if got := f.refused("object.upsert", map[string]any{"key": "ASK-2", "type": "question", "props": map[string]any{"question": "q", "options": []any{}}}); !strings.HasPrefix(got, "a question needs props.asker") {
		t.Errorf("upsert create: %s", got)
	}
	answered := f.result("object.upsert", map[string]any{"key": "ASK-1", "type": "question", "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}})
	if answered["created"] != false || idOf(answered) != id || propsOf(answered["object"].(map[string]any))["answer"].(map[string]any)["at"] == nil {
		t.Errorf("upsert update %v", answered)
	}
	if got := f.refused("object.upsert", map[string]any{"key": "ASK-1", "type": "question", "props": map[string]any{"question": "changed"}}); got != "question "+id+" is answered: only archived can change" {
		t.Errorf("upsert of a closed question: %s", got)
	}

	// A batch applies them in order and as a whole.
	result := f.result("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": map[string]any{"type": "question", "props": questionProps(nil)}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "$0", "props": map[string]any{"status": "cancelled"}}},
	}})
	second := result["results"].([]any)[1].(map[string]any)["object"].(map[string]any)
	if propsOf(second)["status"] != "cancelled" || sizeOf(second)[1] != 148 {
		t.Errorf("batch: %v", second)
	}
	before := len(f.board.Objects())
	got := f.refused("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": map[string]any{"type": "question", "props": questionProps(nil)}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "props": map[string]any{"question": "changed"}}},
	}})
	if got != "op 1 (object.update): question "+id+" is answered: only archived can change" || len(f.board.Objects()) != before {
		t.Errorf("failed batch: %s (%d objects, was %d)", got, len(f.board.Objects()), before)
	}
	got = f.refused("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": map[string]any{"type": "question", "props": map[string]any{"question": "q", "asker": map[string]any{"name": "cos"}}}},
	}})
	if got != "op 0 (object.create): a question needs props.options, an array of {id, label, why?}" {
		t.Errorf("batch create: %s", got)
	}
}

func TestFindByTypeAndStatusListsOldestFirst(t *testing.T) {
	f := newFixture(t)
	first := f.ask(map[string]any{"question": "first"})
	second := f.ask(map[string]any{"question": "second"})
	third := f.ask(map[string]any{"question": "third"})
	f.result("object.create", note(0, map[string]any{"markdown": "x", "status": "open"}))
	f.result("object.update", map[string]any{"id": second["id"], "props": map[string]any{"status": "cancelled"}})

	listed := func(params map[string]any) []string {
		var out []string
		for _, o := range f.result("object.find", params)["objects"].([]any) {
			out = append(out, o.(map[string]any)["id"].(string))
		}
		return out
	}
	ids := func(objects ...map[string]any) string {
		var out []string
		for _, o := range objects {
			out = append(out, o["id"].(string))
		}
		return strings.Join(out, ",")
	}
	if got := strings.Join(listed(map[string]any{"type": "question"}), ","); got != ids(first, second, third) {
		t.Errorf("all questions: %s", got)
	}
	if got := strings.Join(listed(map[string]any{"type": "question", "status": "open"}), ","); got != ids(first, third) {
		t.Errorf("open: %s", got)
	}
	if got := strings.Join(listed(map[string]any{"type": "question", "status": "cancelled"}), ","); got != ids(second) {
		t.Errorf("cancelled: %s", got)
	}
	if got := listed(map[string]any{"type": "question", "status": "answered"}); len(got) != 0 {
		t.Errorf("answered: %v", got)
	}
	if got := listed(map[string]any{"type": "note", "status": "open"}); len(got) != 1 {
		t.Errorf("a note's props.status counts too: %v", got)
	}
	if empty := f.result("object.find", map[string]any{"type": "terminal"})["objects"].([]any); len(empty) != 0 {
		t.Errorf("no terminals on the board: %v", empty)
	}

	const oneOf = "object.find takes one of key, keyPrefix, or type"
	for name, params := range map[string]map[string]any{
		"nothing":         {},
		"key and type":    {"key": "K", "type": "question"},
		"prefix and type": {"keyPrefix": "K", "type": "question"},
		"key and prefix":  {"key": "K", "keyPrefix": "K"},
		"status alone":    {"status": "open"},
	} {
		if got := f.refused("object.find", params); got != oneOf {
			t.Errorf("%s: %s", name, got)
		}
	}
	if got := f.refused("object.find", map[string]any{"type": "gizmo"}); got != "unknown object type" {
		t.Errorf("unknown type: %s", got)
	}
	// status with a key or prefix is the status-only-with-type message.
	if got := f.refused("object.find", map[string]any{"key": "K", "status": "open"}); got != "object.find takes status only with type (e.g. type question, status open)" {
		t.Errorf("status with key: %s", got)
	}
}

func TestMeasuringAQuestionCountsItsRowsAtItsZoomAndWidth(t *testing.T) {
	f := newFixture(t)
	measure := func(extra map[string]any, width any) [2]float64 {
		params := map[string]any{"type": "question", "props": questionProps(extra)}
		if width != nil {
			params["width"] = width
		}
		r := f.result("object.measure", params)
		return [2]float64{r["w"].(float64), r["h"].(float64)}
	}
	for name, c := range map[string]struct {
		extra map[string]any
		width any
		want  [2]float64
	}{
		"open":              {nil, nil, [2]float64{460, 294}},
		"width":             {nil, 300.0, [2]float64{300, 294}},
		"zoomed":            {map[string]any{"zoom": 2.0}, nil, [2]float64{920, 562}},
		"zoomed with width": {map[string]any{"zoom": 2.0}, 300.0, [2]float64{300, 562}},
		"closed":            {map[string]any{"status": "cancelled"}, nil, [2]float64{460, 148}},
	} {
		if got := measure(c.extra, c.width); got != c.want {
			t.Errorf("%s: %v, want %v", name, got, c.want)
		}
	}
	// size: fit is the same count, at the given origin.
	fit := f.result("object.create", map[string]any{"type": "question", "size": "fit", "props": questionProps(nil), "frame": map[string]any{"x": 4000.0, "y": 100.0, "w": 520.0}})["object"].(map[string]any)
	if got := sizeOf(fit); got != [2]float64{520, 294} {
		t.Errorf("fit %v", got)
	}
	// A question refit after an update takes the new rows.
	refit := f.result("object.update", map[string]any{"id": fit["id"], "size": "fit", "props": map[string]any{"options": []any{map[string]any{"id": "a", "label": "Yes"}}}})["object"].(map[string]any)
	if got := sizeOf(refit); got != [2]float64{520, 244} {
		t.Errorf("refit %v", got)
	}
}

func TestAnAnswerReachesTheAskingTerminalOnItsNextDrain(t *testing.T) {
	f := newFixture(t)
	terminal := f.terminal()
	q := f.result("object.create", map[string]any{"type": "question", "caller": terminal, "props": map[string]any{
		"question": "Ship it?", "recommended": "a", "options": []any{map[string]any{"id": "a", "label": "Yes"}},
	}})["object"].(map[string]any)
	drain := func(peek bool) map[string]any {
		return f.result("tray.drain", map[string]any{"caller": terminal, "peek": peek})
	}
	if got := drain(true); len(got["mentions"].([]any)) != 0 {
		t.Fatalf("early: %v", got)
	}
	f.result("object.update", map[string]any{"id": q["id"], "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}})
	got := drain(false)
	context := got["context"].(string)
	if len(got["mentions"].([]any)) != 1 || !strings.Contains(context, "Your question "+q["id"].(string)+" was answered (easl ask):\n[1] question "+q["id"].(string)+` "Ship it?"`) ||
		!strings.Contains(context, "    [a] Yes (recommended)\n    answer: [a] Yes · by the user at ") {
		t.Errorf("drain: %v", got)
	}
	if again := drain(false); len(again["mentions"].([]any)) != 0 {
		t.Errorf("delivered twice: %v", again)
	}
}

func TestAFailedBatchLeavesTheAnswersHandOffAsItWas(t *testing.T) {
	f := newFixture(t)
	terminal := f.terminal()
	q := f.result("object.create", map[string]any{"type": "question", "caller": terminal, "props": map[string]any{
		"question": "Ship it?", "options": []any{map[string]any{"id": "a", "label": "Yes"}},
	}})["object"].(map[string]any)
	id := q["id"].(string)
	pending := func() map[string]any {
		return f.result("tray.drain", map[string]any{"caller": terminal, "peek": true})
	}
	// The answer applies, then the stale rev fails the batch and reverts it.
	code, message := errorOf(f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "rev": q["rev"], "props": map[string]any{"archived": true}}},
	}}))
	if code != "conflict" || propsOf(f.object(id))["status"] != "open" {
		t.Fatalf("batch: %s %s, status %v", code, message, propsOf(f.object(id))["status"])
	}
	if got := pending(); len(got["mentions"].([]any)) != 0 {
		t.Errorf("the reverted answer was handed off: %v", got)
	}

	// Answered for real, then a batch that deletes the question fails: the answer still waits.
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}})
	code, _ = errorOf(f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.delete", "params": map[string]any{"id": id}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": "obj_missing", "props": map[string]any{}}},
	}}))
	got := pending()
	if code != "not_found" || len(got["mentions"].([]any)) != 1 || !strings.Contains(got["context"].(string), "Your question "+id+" was answered (easl ask):") {
		t.Errorf("after the failed delete (%s): %v", code, got)
	}
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func TestAWorktreeAgentsContextPathsMeanItsOwnCheckout(t *testing.T) {
	dir := t.TempDir()
	repo := filepath.Join(dir, "repo")
	if err := os.MkdirAll(filepath.Join(repo, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "src", "a.ts"), []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "init", "-q", "-b", "main")
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-q", "-m", "init")
	worktree := filepath.Join(dir, "fees")
	git(t, repo, "worktree", "add", "-q", "-b", "feature", worktree)
	reg := board.NewRegistry(filepath.Join(dir, "boards"), time.Hour, "")
	reg.Mu.Lock()
	b, err := reg.Open(repo)
	reg.Mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{t: t, router: New(reg), board: b, conn: &conn{}}
	agent := b.Create(model.Terminal, map[string]any{"cwd": filepath.Join(worktree, "src")}, &model.Frame{W: 1000, H: 620}, "", "").ID
	home := b.Create(model.Terminal, map[string]any{"cwd": repo}, &model.Frame{X: 2000, W: 1000, H: 620}, "", "").ID
	ask := func(context []any, caller string) map[string]any {
		return f.result("object.create", map[string]any{"type": "question", "board": b.ID(), "caller": caller, "props": map[string]any{
			"question": "Review this change?", "options": []any{map[string]any{"id": "a", "label": "Yes"}}, "context": context,
		}})["object"].(map[string]any)
	}
	lines := func(start, end float64) map[string]any { return map[string]any{"start": start, "end": end} }

	asked := ask([]any{map[string]any{"path": "src/a.ts", "lines": lines(3, 5)}, map[string]any{"path": "/etc/hosts"}, map[string]any{"url": "https://example.com"}}, agent)
	want := []any{map[string]any{"path": filepath.Join(worktree, "src", "a.ts"), "lines": lines(3, 5)}, map[string]any{"path": "/etc/hosts"}, map[string]any{"url": "https://example.com"}}
	if got := propsOf(asked)["context"]; !model.Equal(got, want) {
		t.Errorf("create: %v, want %v", got, want)
	}
	inWorktree := filepath.Join(worktree, "src", "b.ts")
	updated := f.result("object.update", map[string]any{"id": asked["id"], "caller": agent, "props": map[string]any{"context": []any{map[string]any{"path": "src/b.ts", "lines": lines(2, 2)}}}})
	if got := propsOf(updated["object"].(map[string]any))["context"]; !model.Equal(got, []any{map[string]any{"path": inWorktree, "lines": lines(2, 2)}}) {
		t.Errorf("update: %v", got)
	}
	// From the board's own checkout a relative path stays board-relative.
	if got := propsOf(ask([]any{map[string]any{"path": "src/a.ts"}}, home))["context"]; !model.Equal(got, []any{map[string]any{"path": "src/a.ts"}}) {
		t.Errorf("from the board's checkout: %v", got)
	}

	f.result("object.update", map[string]any{"id": asked["id"], "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}})
	context := f.result("tray.drain", map[string]any{"caller": agent, "peek": true})["context"].(string)
	if !strings.Contains(context, "    context: "+inWorktree+":2\n") {
		t.Errorf("the mention names the worktree's file:\n%s", context)
	}
}

func (f *fixture) waitEvent(name, id string, within time.Duration) (map[string]any, bool) {
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		for _, m := range f.conn.messages() {
			data, _ := m["data"].(map[string]any)
			if m["event"] == name && data["id"] == id && data["props"].(map[string]any)["status"] == "expired" {
				return m, true
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil, false
}

func TestAPastDueQuestionIsExpiredAndAnnouncedAfterItsWrite(t *testing.T) {
	f := newFixture(t)
	f.call("events.subscribe", map[string]any{"events": []any{"object.created", "object.updated"}})
	past := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	q := f.ask(map[string]any{"expiresAt": past})
	id := q["id"].(string)
	// The reply to the write still says open.
	if propsOf(q)["status"] != "open" || sizeOf(q)[1] != 294 {
		t.Fatalf("reply %v", q)
	}
	event, ok := f.waitEvent("object.updated", id, 3*time.Second)
	if !ok {
		t.Fatal("no object.updated announcing the expiry")
	}
	if event["board"] != f.board.ID() || sizeOf(event["data"].(map[string]any))[1] != 148 {
		t.Errorf("event %v", event)
	}
	o := f.object(id)
	if propsOf(o)["status"] != "expired" || o["rev"] != 2.0 || !model.Equal(o["updatedBy"], map[string]any{"kind": "user"}) {
		t.Errorf("after: %v", o)
	}
	found := f.result("object.find", map[string]any{"type": "question", "status": "expired"})["objects"].([]any)
	if len(found) != 1 || len(f.result("object.find", map[string]any{"type": "question", "status": "open"})["objects"].([]any)) != 0 {
		t.Errorf("find: %v", found)
	}
	// Written as the app: the activity log credits the system, and the question is closed for good.
	page := f.result("board.history", map[string]any{"kinds": []any{"updated"}})["entries"].([]any)
	if last := page[len(page)-1].(map[string]any); last["actor"] != "system" || !strings.HasPrefix(last["summary"].(string), `question "Ship it?": `) {
		t.Errorf("history %v", last)
	}
	if got := f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"status": "open"}}); got != "question "+id+" is expired: only archived can change" {
		t.Errorf("reopen: %s", got)
	}
}
