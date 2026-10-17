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
	"github.com/twaldin/easl/easld/internal/store"
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
	if w, _ := odd["warnings"].([]any); len(w) != 1 || !strings.Contains(w[0].(string), `unknown prop "volume" for question`) || !strings.Contains(w[0].(string), "question props: answer, archiveAfter, archived, asker, context, expiresAt, keep, key, options, question, recommended, status, zoom") {
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

	beforeEdit := f.object(id)
	f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"question": "again?"}})
	f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"status": "open"}})
	if !model.Equal(f.object(id), beforeEdit) {
		t.Errorf("refused updates changed the question")
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
	beforeUpsert := f.object(id)
	f.refused("object.upsert", map[string]any{"key": "ASK-1", "type": "question", "props": map[string]any{"question": "changed"}})
	if !model.Equal(f.object(id), beforeUpsert) {
		t.Errorf("upsert changed a closed question")
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
	beforeN := len(f.board.Objects())
	beforeQ := f.object(id)
	code, _ := errorOf(f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": map[string]any{"type": "question", "props": questionProps(nil)}},
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "props": map[string]any{"question": "changed"}}},
	}}))
	if code != "invalid_params" || len(f.board.Objects()) != beforeN || !model.Equal(f.object(id), beforeQ) {
		t.Errorf("failed batch changed the board (%d objects, was %d)", len(f.board.Objects()), beforeN)
	}
	got := f.refused("object.batch", map[string]any{"ops": []any{
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
	beforeReopen := f.object(id)
	f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"status": "open"}})
	if !model.Equal(f.object(id), beforeReopen) {
		t.Errorf("reopen changed the question")
	}
}

func (f *fixture) waitProps(id string, within time.Duration, match func(map[string]any) bool) (map[string]any, bool) {
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		for _, m := range f.conn.messages() {
			data, _ := m["data"].(map[string]any)
			if m["event"] != "object.updated" || data["id"] != id {
				continue
			}
			props, _ := data["props"].(map[string]any)
			if match(props) {
				return m, true
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil, false
}

func TestAClosedQuestionCanChangeRetention(t *testing.T) {
	f := newFixture(t)
	q := f.ask(nil)
	id := q["id"].(string)
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a"}}})
	kept := f.result("object.update", map[string]any{"id": id, "props": map[string]any{"keep": true, "archiveAfter": 30.0}})["object"].(map[string]any)
	props := propsOf(kept)
	if props["keep"] != true || props["archiveAfter"] != 30.0 || props["status"] != "answered" || props["answer"] == nil {
		t.Fatalf("retention %v", props)
	}
	cleared := f.result("object.update", map[string]any{"id": id, "props": map[string]any{"keep": nil, "archiveAfter": nil}})["object"].(map[string]any)
	if props := propsOf(cleared); props["keep"] != nil || props["archiveAfter"] != nil || props["status"] != "answered" {
		t.Fatalf("cleared %v", props)
	}
	f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"keep": "yes"}})
	f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"archiveAfter": -1.0}})
	f.refused("object.update", map[string]any{"id": id, "props": map[string]any{"archiveAfter": 86400.1}})
	if props := propsOf(f.object(id)); props["status"] != "answered" || props["keep"] != nil {
		t.Fatalf("bad retention changed %v", props)
	}
}

func TestAnAnsweredQuestionIsArchivedAndAnnounced(t *testing.T) {
	f := newFixture(t)
	f.call("events.subscribe", map[string]any{"events": []any{"object.updated"}})
	q := f.ask(map[string]any{"archiveAfter": 0.2})
	id := q["id"].(string)
	answered := f.result("object.update", map[string]any{"id": id, "props": map[string]any{"status": "answered", "answer": map[string]any{"option": "a", "note": "go"}}})["object"].(map[string]any)
	if propsOf(answered)["archived"] == true {
		t.Fatal("archived inside the answer")
	}
	event, ok := f.waitProps(id, 3*time.Second, func(props map[string]any) bool { return props["archived"] == true })
	if !ok {
		t.Fatal("no object.updated announcing the archive")
	}
	data := event["data"].(map[string]any)
	props := propsOf(data)
	if event["board"] != f.board.ID() || props["status"] != "answered" || props["answer"] == nil || !model.Equal(data["frame"], answered["frame"]) {
		t.Fatalf("event %v", event)
	}
	o := f.object(id)
	if propsOf(o)["archived"] != true || o["rev"] == answered["rev"] || !model.Equal(o["updatedBy"], map[string]any{"kind": "user"}) || !model.Equal(o["frame"], answered["frame"]) {
		t.Fatalf("after %v", o)
	}
	page := f.result("board.history", map[string]any{"kinds": []any{"updated"}})["entries"].([]any)
	if last := page[len(page)-1].(map[string]any); last["actor"] != "system" {
		t.Fatalf("history %v", last)
	}
}

func TestExpiryIsAnnouncedBeforeArchive(t *testing.T) {
	f := newFixture(t)
	f.call("events.subscribe", map[string]any{"events": []any{"object.updated"}})
	past := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	q := f.ask(map[string]any{"expiresAt": past, "archiveAfter": 0.0})
	id := q["id"].(string)
	if _, ok := f.waitProps(id, 3*time.Second, func(props map[string]any) bool {
		return props["archived"] == true && props["status"] == "expired"
	}); !ok {
		t.Fatal("expiry did not archive")
	}
	var sawExpired bool
	for _, m := range f.conn.messages() {
		data, _ := m["data"].(map[string]any)
		if m["event"] != "object.updated" || data["id"] != id {
			continue
		}
		props := propsOf(data)
		if props["status"] == "expired" && props["archived"] != true {
			sawExpired = true
		}
		if props["archived"] == true && !sawExpired {
			t.Fatal("archived before it expired")
		}
	}
	if !sawExpired {
		t.Fatal("no expiry event before the archive")
	}
	o := f.object(id)
	if propsOf(o)["status"] != "expired" || propsOf(o)["archived"] != true || sizeOf(o)[1] != 148 {
		t.Fatalf("after %v", o)
	}
}

func TestOpeningABoardArchivesDueQuestionsWithoutARevisionChange(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	reg := board.NewRegistry(filepath.Join(dir, "boards"), time.Hour, "")
	f := &fixture{t: t, router: New(reg), conn: &conn{}}
	id := store.PathID(root)
	format := store.Format
	old := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	recent := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Second)
	question := func(oid string, at time.Time, extra map[string]any) model.Object {
		props := map[string]any{
			"question": "Ship it?",
			"options":  []any{map[string]any{"id": "a", "label": "Yes"}},
			"asker":    map[string]any{"name": "cos"},
			"status":   "answered",
			"answer":   map[string]any{"option": "a"},
		}
		for k, v := range extra {
			props[k] = v
		}
		return model.Object{
			ID: oid, Type: model.Question, Rev: 4,
			CreatedAt: old, UpdatedAt: at, CreatedBy: model.Actor{Kind: "user"},
			Frame: model.Frame{W: 460, H: 148}, Props: props,
		}
	}
	snap := &store.Snapshot{Format: &format, ID: id, Root: root, Revision: 11, Objects: []model.Object{
		question("obj_due", old, nil),
		question("obj_recent", recent, map[string]any{"keep": true}),
	}}
	if err := reg.Store.Write(snap); err != nil {
		t.Fatal(err)
	}
	f.result("board.open", map[string]any{"root": root})
	due := f.object("obj_due")
	recentObj := f.object("obj_recent")
	if propsOf(due)["archived"] != true || due["rev"] != 4.0 || propsOf(due)["status"] != "answered" || propsOf(due)["answer"] == nil {
		t.Fatalf("due %v", due)
	}
	if propsOf(recentObj)["archived"] == true || recentObj["rev"] != 4.0 || propsOf(recentObj)["keep"] != true {
		t.Fatalf("recent %v", recentObj)
	}
	boardObj := f.result("board.get", map[string]any{})
	if boardObj["revision"] != 11.0 {
		t.Fatalf("revision %v", boardObj["revision"])
	}
	f.result("board.close", map[string]any{"board": id})
	f.result("board.open", map[string]any{"root": root})
	again := f.object("obj_due")
	if again["rev"] != 4.0 || propsOf(again)["archived"] != true {
		t.Fatalf("reopen %v", again)
	}
}
