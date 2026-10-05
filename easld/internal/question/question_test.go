package question

import (
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

// gone marks a key `with` removes (nil is JSON null).
type gone struct{}

// base is a valid question as `object.create` would store it.
func base() map[string]any {
	return map[string]any{
		"question": "Ship it?",
		"options": []any{
			map[string]any{"id": "a", "label": "Yes"},
			map[string]any{"id": "b", "label": "No", "why": "too early"},
		},
		"asker":  map[string]any{"name": "cos"},
		"status": "open",
	}
}

func with(overrides map[string]any) map[string]any {
	props := base()
	for k, v := range overrides {
		if _, removed := v.(gone); removed {
			delete(props, k)
		} else {
			props[k] = v
		}
	}
	return props
}

func option(id, label string) map[string]any { return map[string]any{"id": id, "label": label} }

func list(items ...any) []any { return items }

func obj(kv ...any) map[string]any {
	m := map[string]any{}
	for i := 0; i < len(kv); i += 2 {
		m[kv[i].(string)] = kv[i+1]
	}
	return m
}

// stored is a question as the board holds it (before an update).
func stored(overrides map[string]any) *model.Object {
	return &model.Object{ID: "obj_q", Type: model.Question, Props: with(overrides)}
}

func TestCreateRulesRunInOrderWithTheirMessages(t *testing.T) {
	cases := []struct {
		name  string
		props map[string]any
		want  string
	}{
		{"no question", with(map[string]any{"question": gone{}}), "a question needs props.question, a non-empty string"},
		{"null question", with(map[string]any{"question": nil}), "a question needs props.question, a non-empty string"},
		{"blank question", with(map[string]any{"question": " \n\t "}), "a question needs props.question, a non-empty string"},
		{"number question", with(map[string]any{"question": 5.0}), "a question needs props.question, a non-empty string"},
		{"no options", with(map[string]any{"options": gone{}}), "a question needs props.options, an array of {id, label, why?}"},
		{"options not an array", with(map[string]any{"options": "a"}), "a question needs props.options, an array of {id, label, why?}"},
		{"option not an object", with(map[string]any{"options": list("a")}), "options[0] must be {id, label, why?}"},
		{"second option not an object", with(map[string]any{"options": list(option("a", "A"), nil)}), "options[1] must be {id, label, why?}"},
		{"unknown option key, the first sorted", with(map[string]any{"options": list(obj("label", "A", "id", "a", "zeta", 1.0, "alpha", 2.0))}), `options[0] has unknown key "alpha" (an option is {id, label, why?})`},
		{"no option id", with(map[string]any{"options": list(obj("label", "A"))}), "options[0] needs an id, a non-empty string"},
		{"empty option id", with(map[string]any{"options": list(option("", "A"))}), "options[0] needs an id, a non-empty string"},
		{"number option id", with(map[string]any{"options": list(obj("id", 1.0, "label", "A"))}), "options[0] needs an id, a non-empty string"},
		{"no option label", with(map[string]any{"options": list(obj("id", "a"))}), "options[0] needs a label, a non-empty string"},
		{"blank option label", with(map[string]any{"options": list(option("a", "  "))}), "options[0] needs a label, a non-empty string"},
		{"number why", with(map[string]any{"options": list(obj("id", "a", "label", "A", "why", 3.0))}), "options[0].why must be a string"},
		{"duplicate option id", with(map[string]any{"options": list(option("a", "A"), option("b", "B"), option("a", "C"))}), `option id "a" is used twice`},
		{"recommended not a string", with(map[string]any{"recommended": 1.0}), "recommended must be an option id (a, b)"},
		{"recommended not an option", with(map[string]any{"recommended": "c"}), `recommended "c" is not an option id (a, b)`},
		{"recommended with no options", with(map[string]any{"options": list(), "recommended": "a"}), `recommended "a" is not an option id (none)`},
		{"context not an array", with(map[string]any{"context": "x"}), "props.context must be an array of {object}, {url}, or {path, lines?}"},
		{"empty context item", with(map[string]any{"context": list(obj())}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context object not an id", with(map[string]any{"context": list(obj("url", "https://x"), obj("object", "x"))}), `context[1] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context two kinds", with(map[string]any{"context": list(obj("object", "obj_1", "url", "u"))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context unknown key", with(map[string]any{"context": list(obj("url", "u", "title", "t"))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context empty url", with(map[string]any{"context": list(obj("url", ""))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context null url", with(map[string]any{"context": list(obj("url", nil))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context lines beside a url", with(map[string]any{"context": list(obj("url", "u", "lines", obj("start", 1.0, "end", 2.0)))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context lines backwards", with(map[string]any{"context": list(obj("path", "a.go", "lines", obj("start", 3.0, "end", 2.0)))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context lines from zero", with(map[string]any{"context": list(obj("path", "a.go", "lines", obj("start", 0.0, "end", 2.0)))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context lines fractional", with(map[string]any{"context": list(obj("path", "a.go", "lines", obj("start", 1.5, "end", 2.0)))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context lines without end", with(map[string]any{"context": list(obj("path", "a.go", "lines", obj("start", 1.0)))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"context lines with an extra key", with(map[string]any{"context": list(obj("path", "a.go", "lines", obj("start", 1.0, "end", 2.0, "x", 1.0)))}), `context[0] must be {object: "obj_…"}, {url: "…"}, or {path: "…", lines?: {start, end}}`},
		{"no asker", with(map[string]any{"asker": gone{}}), "a question needs props.asker, {name, host?}, when no terminal asks it (no caller)"},
		{"null asker", with(map[string]any{"asker": nil}), "a question needs props.asker, {name, host?}, when no terminal asks it (no caller)"},
		{"asker not an object", with(map[string]any{"asker": "cos"}), `asker must be {tile: "obj_…"} or {name, host?}`},
		{"empty asker", with(map[string]any{"asker": obj()}), `asker must be {tile: "obj_…"} or {name, host?}`},
		{"asker tile not an id", with(map[string]any{"asker": obj("tile", "terminal")}), `asker must be {tile: "obj_…"} or {name, host?}`},
		{"asker null tile", with(map[string]any{"asker": obj("tile", nil, "name", "cos")}), `asker must be {tile: "obj_…"} or {name, host?}`},
		{"asker empty name", with(map[string]any{"asker": obj("name", "")}), `asker must be {tile: "obj_…"} or {name, host?}`},
		{"asker host only", with(map[string]any{"asker": obj("host", "mini")}), `asker must be {tile: "obj_…"} or {name, host?}`},
		{"asker number host", with(map[string]any{"asker": obj("name", "cos", "host", 1.0)}), `asker must be {tile: "obj_…"} or {name, host?}`},
		{"asker unknown key", with(map[string]any{"asker": obj("name", "cos", "pid", 1.0)}), `asker must be {tile: "obj_…"} or {name, host?}`},
		{"unknown status", with(map[string]any{"status": "closed"}), "status must be open, answered, cancelled, or expired"},
		{"number status", with(map[string]any{"status": 1.0}), "status must be open, answered, cancelled, or expired"},
		{"created answered", with(map[string]any{"status": "answered", "answer": obj("option", "a")}), "a question is created open, not answered"},
		{"created cancelled", with(map[string]any{"status": "cancelled"}), "a question is created open, not cancelled"},
		{"expiresAt not a time", with(map[string]any{"expiresAt": "tomorrow"}), "expiresAt must be an ISO 8601 date-time, e.g. 2026-10-05T17:00:00Z"},
		{"expiresAt a date", with(map[string]any{"expiresAt": "2026-10-05"}), "expiresAt must be an ISO 8601 date-time, e.g. 2026-10-05T17:00:00Z"},
		{"expiresAt a number", with(map[string]any{"expiresAt": 1.0}), "expiresAt must be an ISO 8601 date-time, e.g. 2026-10-05T17:00:00Z"},
		{"answer on an open question", with(map[string]any{"answer": obj("option", "a")}), "answer goes with status answered"},
		{"archived not a bool", with(map[string]any{"archived": "yes"}), "archived must be true or false"},
		{"archived open", with(map[string]any{"archived": true}), "an open question can't be archived: answer or cancel it first"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got, bad := Problem(c.props, nil); !bad || got != c.want {
				t.Errorf("got %q (bad %v), want %q", got, bad, c.want)
			}
		})
	}
}

func TestAnAskedQuestionTheRulesAccept(t *testing.T) {
	for name, props := range map[string]map[string]any{
		"plain":                 base(),
		"no options":            with(map[string]any{"options": list()}),
		"recommended":           with(map[string]any{"recommended": "b"}),
		"null recommended":      with(map[string]any{"recommended": nil}),
		"null why":              with(map[string]any{"options": list(obj("id", "a", "label", "A", "why", nil))}),
		"tile asker":            with(map[string]any{"asker": obj("tile", "obj_01JABC")}),
		"named asker on a host": with(map[string]any{"asker": obj("name", "cos", "host", "mini", "tile", "obj_1")}),
		"context of every kind": with(map[string]any{"context": list(obj("object", "obj_1"), obj("url", "https://x"), obj("path", "a.go"), obj("path", "a.go", "lines", obj("start", 3.0, "end", 3.0)))}),
		"expires with Z":        with(map[string]any{"expiresAt": "2026-10-05T17:00:00Z"}),
		"expires with fraction": with(map[string]any{"expiresAt": "2026-10-05T17:00:00.250Z"}),
		"expires with offset":   with(map[string]any{"expiresAt": "2026-10-05T19:00:00+02:00"}),
		"null archived":         with(map[string]any{"archived": nil}),
	} {
		if got, bad := Problem(props, nil); bad {
			t.Errorf("%s: %s", name, got)
		}
	}
}

func TestAnUpdateIsJudgedMergedWithWhatIsStored(t *testing.T) {
	answered := map[string]any{"status": "answered", "answer": obj("option", "a", "at", "2026-10-05T17:00:00Z", "by", obj("kind", "user"))}
	cases := []struct {
		name   string
		before map[string]any
		patch  any
		want   string // "" accepts
	}{
		{"answer with an option", nil, obj("status", "answered", "answer", obj("option", "a")), ""},
		{"answer with a note", nil, obj("status", "answered", "answer", obj("note", "later")), ""},
		{"answer with both", nil, obj("status", "answered", "answer", obj("option", "b", "note", "n")), ""},
		{"answered without an answer", nil, obj("status", "answered"), "an answered question needs answer: {option, note?} or {note}"},
		{"answered with an empty answer", nil, obj("status", "answered", "answer", obj()), "an answered question needs answer: {option, note?} or {note}"},
		{"answered with a blank note only", nil, obj("status", "answered", "answer", obj("note", " \n")), "an answered question needs answer: {option, note?} or {note}"},
		{"answer is not an object", nil, obj("status", "answered", "answer", "a"), "an answered question needs answer: {option, note?} or {note}"},
		{"answer option not an option", nil, obj("status", "answered", "answer", obj("option", "z")), `answer.option "z" is not an option id (a, b)`},
		{"answer option not a string", nil, obj("status", "answered", "answer", obj("option", 1.0)), "answer.option must be an option id (a, b)"},
		{"answer note not a string", nil, obj("status", "answered", "answer", obj("option", "a", "note", 1.0)), "answer.note must be a string"},
		{"null answer parts are absent", nil, obj("status", "answered", "answer", obj("option", nil, "note", "n")), ""},
		{"cancelled", nil, obj("status", "cancelled"), ""},
		{"expired", nil, obj("status", "expired"), ""},
		{"cancelled with an answer", nil, obj("status", "cancelled", "answer", obj("option", "a")), "answer goes with status answered"},
		{"unknown status", nil, obj("status", "done"), "status must be open, answered, cancelled, or expired"},
		{"an answered question can be archived", answered, obj("archived", true), ""},
		{"an open question can't be archived", nil, obj("archived", true), "an open question can't be archived: answer or cancel it first"},
		{"an open question takes any change", nil, obj("question", "Ship it now?", "recommended", "a", "expiresAt", "2026-10-05T17:00:00Z"), ""},
		{"an open question can't lose its question", nil, obj("question", nil), "a question needs props.question, a non-empty string"},
		{"an open question can't lose its asker", nil, obj("asker", nil), "a question needs props.asker, {name, host?}, when no terminal asks it (no caller)"},
		{"an open question can't drop an option under the recommended", map[string]any{"recommended": "b"}, obj("options", list(option("a", "A"))), `recommended "b" is not an option id (a)`},
		{"props that aren't an object", nil, "text", "a question needs props.question, a non-empty string"},
		{"props null", nil, nil, "a question needs props.question, a non-empty string"},

		{"an answered question takes archived, key and zoom", answered, obj("archived", true, "key", "ASK-1", "zoom", 2.0), ""},
		{"an answered question can be brought back", with(map[string]any{"status": "answered", "answer": obj("option", "a"), "archived": true}), obj("archived", nil), ""},
		{"an answered question can't change its question", answered, obj("question", "other"), "question obj_q is answered: only archived can change"},
		{"an answered question can't change its answer", answered, obj("answer", obj("option", "b")), "question obj_q is answered: only archived can change"},
		{"an answered question can't reopen", answered, obj("status", "open"), "question obj_q is answered: only archived can change"},
		{"an answered question can't expire", answered, obj("status", "expired"), "question obj_q is answered: only archived can change"},
		{"an answered question takes what it holds", answered, obj("question", "Ship it?", "archived", true), ""},
		{"an answered question takes a null for what it lacks", answered, obj("expiresAt", nil), ""},
		{"an answered question can't lose what it has", answered, obj("answer", nil), "question obj_q is answered: only archived can change"},
		{"a cancelled question", map[string]any{"status": "cancelled"}, obj("recommended", "a"), "question obj_q is cancelled: only archived can change"},
		{"an expired question", map[string]any{"status": "expired"}, obj("expiresAt", "2026-10-05T17:00:00Z"), "question obj_q is expired: only archived can change"},
		{"a closed question can be archived", map[string]any{"status": "expired"}, obj("archived", true), ""},
		{"a closed question, archived with a bad flag", map[string]any{"status": "expired"}, obj("archived", "yes"), "archived must be true or false"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			before := stored(c.before)
			got, bad := Problem(c.patch, before)
			if bad != (c.want != "") || got != c.want {
				t.Errorf("got %q (bad %v), want %q", got, bad, c.want)
			}
		})
	}
}

func TestCreatingFillsStatusAndTheCallingTerminalAsAsker(t *testing.T) {
	given := map[string]any{"question": "Q", "options": list()}
	got := Creating(given, "obj_term")
	if got["status"] != "open" || !reflect.DeepEqual(got["asker"], map[string]any{"tile": "obj_term"}) {
		t.Errorf("filled %v", got)
	}
	if _, touched := given["status"]; touched || len(given) != 2 {
		t.Errorf("Creating changed what it was given: %v", given)
	}
	if got := Creating(map[string]any{"status": nil, "asker": nil}, ""); got["status"] != "open" || got["asker"] != nil {
		t.Errorf("a null status is open, and without a caller a null asker stays: %v", got)
	}
	named := Creating(map[string]any{"asker": map[string]any{"name": "cos"}, "status": "answered"}, "obj_term")
	if !reflect.DeepEqual(named["asker"], map[string]any{"name": "cos"}) || named["status"] != "answered" {
		t.Errorf("what the call gave stays: %v", named)
	}
}

func TestDatesAreRFC3339WithOrWithoutFractionsAndOffsets(t *testing.T) {
	want := time.Date(2026, 10, 5, 17, 0, 0, 0, time.UTC)
	for _, text := range []string{"2026-10-05T17:00:00Z", "2026-10-05T19:00:00+02:00", "2026-10-05T12:00:00-05:00", "2026-10-05T17:00:00.000Z"} {
		if got, ok := Date(text); !ok || !got.Equal(want) {
			t.Errorf("%s: %v %v", text, got, ok)
		}
	}
	if got, ok := Date("2026-10-05T17:00:00.250Z"); !ok || got.Sub(want) != 250*time.Millisecond {
		t.Errorf("fraction: %v %v", got, ok)
	}
	for _, text := range []string{"", "2026-10-05", "2026-10-05 17:00:00Z", "17:00:00", "2026-13-05T17:00:00Z", "2026-10-05T17:00:00", "tomorrow"} {
		if _, ok := Date(text); ok {
			t.Errorf("%q parsed", text)
		}
	}
	zone := time.FixedZone("x", 2*3600)
	if got := Stamp(time.Date(2026, 10, 5, 19, 0, 0, 999_000_000, zone)); got != "2026-10-05T17:00:00Z" {
		t.Errorf("stamp %s", got)
	}
}

func TestSizeIsCountedFromTheProps(t *testing.T) {
	cases := []struct {
		name  string
		props map[string]any
		h     float64
	}{
		{"no options", map[string]any{"options": list()}, 194},
		{"two options", base(), 294},
		{"two options and context", with(map[string]any{"context": list(obj("url", "u"))}), 324},
		{"empty context adds nothing", with(map[string]any{"context": list()}), 294},
		{"no status is open", with(map[string]any{"status": gone{}}), 294},
		{"an unknown status is open", with(map[string]any{"status": "weird"}), 294},
		{"answered", with(map[string]any{"status": "answered", "answer": obj("option", "a")}), 148},
		{"answered with a note", with(map[string]any{"status": "answered", "answer": obj("option", "a", "note", "why")}), 188},
		{"answered with a blank note", with(map[string]any{"status": "answered", "answer": obj("note", "  ")}), 148},
		{"cancelled", with(map[string]any{"status": "cancelled"}), 148},
		{"expired with context and options", with(map[string]any{"status": "expired", "context": list(obj("url", "u"))}), 148},
	}
	for _, c := range cases {
		if w, h := Size(c.props); w != 460 || h != c.h {
			t.Errorf("%s: %v×%v, want 460×%v", c.name, w, h, c.h)
		}
	}
	// A new question without options or a frame is sized like the default size for three.
	if w, h := model.DefaultSize(model.Question); w != 460 || h != OpenBase+3*OptionRow {
		t.Errorf("default size %v×%v", w, h)
	}
}

func TestMentionLinesTellTheWholeQuestion(t *testing.T) {
	open := with(map[string]any{
		"question":    "Which one?\nBe quick",
		"recommended": "b",
		"asker":       obj("name", "cos", "host", "mini", "tile", "obj_term"),
		"expiresAt":   "2026-10-05T17:00:00Z",
		"context":     list(obj("object", "obj_9"), obj("url", "https://x"), obj("path", "a.go", "lines", obj("start", 3.0, "end", 3.0)), obj("path", "b.go", "lines", obj("start", 3.0, "end", 9.0)), obj("path", "c.go")),
	})
	want := []string{
		`    question: Which one?\nBe quick`,
		"    asked by cos@mini (terminal obj_term) · open · expires 2026-10-05T17:00:00Z",
		"    [a] Yes",
		"    [b] No (recommended): too early",
		"    context: obj_9, https://x, a.go:3, b.go:3-9, c.go",
	}
	if got := MentionLines(open); !reflect.DeepEqual(got, want) {
		t.Errorf("open:\n%q\nwant\n%q", got, want)
	}

	answer := func(by any, at any, option, note any) map[string]any {
		a := obj("option", option, "note", note)
		if by != nil {
			a["by"] = by
		}
		if at != nil {
			a["at"] = at
		}
		return a
	}
	closed := func(status string, answerProps any) map[string]any {
		return with(map[string]any{"status": status, "answer": answerProps, "asker": obj("tile", "obj_term"), "expiresAt": "2026-10-05T17:00:00Z", "archived": true})
	}
	for name, c := range map[string]struct {
		props map[string]any
		last  string
	}{
		"by an agent":     {closed("answered", answer(obj("kind", "agent", "tile", "obj_t2"), "2026-10-05T17:01:02Z", "a", "go\nfast")), `    answer: [a] Yes · note: "go\nfast" · by terminal obj_t2 at 2026-10-05T17:01:02Z`},
		"by the user":     {closed("answered", answer(obj("kind", "user"), "2026-10-05T17:01:02Z", "b", nil)), "    answer: [b] No · by the user at 2026-10-05T17:01:02Z"},
		"no by":           {closed("answered", answer(nil, "2026-10-05T17:01:02Z", nil, "just this")), `    answer: note: "just this" · at 2026-10-05T17:01:02Z`},
		"no by, no at":    {closed("answered", answer(nil, nil, "a", nil)), "    answer: [a] Yes"},
		"an unknown pick": {closed("answered", answer(obj("kind", "user"), nil, "zz", " ")), "    answer: [zz] · by the user"},
		"a bad by":        {closed("answered", answer("someone", "2026-10-05T17:01:02Z", "a", nil)), "    answer: [a] Yes · at 2026-10-05T17:01:02Z"},
	} {
		got := MentionLines(c.props)
		if len(got) != 5 || got[1] != "    asked by terminal obj_term · answered · archived" || got[len(got)-1] != c.last {
			t.Errorf("%s:\n%q", name, got)
		}
	}
	if got := MentionLines(closed("cancelled", nil)); len(got) != 4 || got[1] != "    asked by terminal obj_term · cancelled · archived" {
		t.Errorf("cancelled: %q", got)
	}
	if got := MentionLines(map[string]any{}); !reflect.DeepEqual(got, []string{"    question: ", "    asked by someone · open"}) {
		t.Errorf("empty: %q", got)
	}
}

func TestAnIdMayEndInALineTerminatorAsICUsDollarAllows(t *testing.T) {
	for id, want := range map[string]bool{
		"obj_01J": true, "obj_01J\n": true, "obj_01J\r\n": true, "obj_01J\u2028": true,
		"obj_01J\n\n": false, "obj_": false, "_abc": false, "Obj_abc": false, "obj_a b": false, "obj_é": false, "": false,
	} {
		if got := isID(id); got != want {
			t.Errorf("isID(%q) = %v", id, got)
		}
	}
	if isID(5.0) || isID(nil) {
		t.Error("only a string is an id")
	}
}

func TestReadKeepsWhatIsReadableAndStatusDefaultsToOpen(t *testing.T) {
	spec := Read(map[string]any{
		"question": "Q",
		"options":  list(option("a", "A"), "junk", obj("id", "x"), obj("id", "b", "label", "B", "why", "w")),
		"asker":    obj("name", "cos"),
		"status":   "bogus",
		"answer":   obj("option", "a", "by", obj("kind", "agent")),
	})
	if len(spec.Options) != 2 || spec.Options[1].ID != "b" || *spec.Options[1].Why != "w" || spec.Options[0].Why != nil {
		t.Errorf("options %+v", spec.Options)
	}
	if spec.Status != Open || spec.Asker == nil || *spec.Asker.Name != "cos" || spec.Answer == nil || spec.Answer.By != nil {
		t.Errorf("spec %+v", spec)
	}
	if got := spec.Option(spec.Answer.Option); got == nil || got.Label != "A" {
		t.Errorf("answered option %v", got)
	}
}
