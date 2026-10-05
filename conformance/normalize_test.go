package conformance

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func normalized(t *testing.T, n *normalizer, doc string) string {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(doc), &v); err != nil {
		t.Fatal(err)
	}
	n.learnIDs(v)
	var out strings.Builder
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	enc.Encode(n.value(v, "", false))
	return strings.TrimSpace(out.String())
}

// Two servers (or two runs of one) that differ only in ids, times, revisions and paths
// normalise to the same record, and the relations between those values survive. The ids come
// from different generators: what makes a value an id is the field it is in, not its length.
func TestNormalizationKeepsRelationsAndDropsIncidentals(t *testing.T) {
	run := func(board, a, b, root string, rev float64) string {
		n := newNormalizer([]pathSubst{{root, "<root>"}})
		n.alias(board, "<board>")
		doc := `{"board":"` + board + `","frames":{"` + b + `":{"x":1}},"objects":[` +
			`{"id":"` + a + `","rev":` + jsonNumber(rev) + `,"createdAt":812918940.5,"props":{"path":"` + root + `/src/a.ts","text":"snake_case"}},` +
			`{"id":"` + b + `","rev":` + jsonNumber(rev) + `,"updatedAt":"2026-10-05T18:50:46Z","props":{"members":["` + a + `"],"from":{"object":"` + a + `"}}}],` +
			`"summary":"created note ` + a + ` (pid 4242) on ` + board + `"}`
		return normalized(t, n, doc)
	}
	swift := run("brd_7f3a9c", "obj_01M46PBNZMT65BK5EM", "obj_01M46PBNZMT65BK5EN", "/tmp/run-1/s", 3)
	other := run("brd_1", "obj_1", "obj_0123456789abcdef0123456789abcdef", "/private/var/x/s", 7)
	if swift != other {
		t.Fatalf("servers differ:\n%s\n%s", swift, other)
	}
	// Keys are walked in order, so `frames` (holding the second object) numbers first.
	for _, want := range []string{`"frames":{"<obj:1>":{"x":1}}`, `"id":"<obj:2>"`, `"members":["<obj:2>"]`, `"from":{"object":"<obj:2>"}`,
		`"rev":"<rev:1>"`, `"<root>/src/a.ts"`, `"text":"snake_case"`, `created note <obj:2> (pid <pid>) on <board>`, `"board":"<board>"`} {
		if !strings.Contains(swift, want) {
			t.Errorf("missing %s in %s", want, swift)
		}
	}
}

// An id is replaced only as a whole word: `obj_1` inside `obj_12` is another id.
func TestKnownIDsReplaceWholeWordsOnly(t *testing.T) {
	n := newNormalizer(nil)
	got := normalized(t, n, `{"ids":["obj_1","obj_12"],"message":"obj_12 overlaps obj_1; obj_123 is unknown"}`)
	want := `{"ids":["<obj:1>","<obj:2>"],"message":"<obj:2> overlaps <obj:1>; obj_123 is unknown"}`
	if got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

// A time keeps its wire type (the API's seconds since 2001 and an ISO string stay apart), and a
// value under a time key that isn't a valid moment stays as it is, so it differs from the token
// a fixture recorded.
func TestTimesKeepTheirWireTypeAndMustBeValid(t *testing.T) {
	n := newNormalizer(nil)
	got := normalized(t, n, `[{"createdAt":812918940.5},{"at":"2026-10-05T18:50:46.123Z"},{"at":{"x":1,"y":2}}]`)
	want := `[{"createdAt":"<time:number>"},{"at":"<time:iso>"},{"at":{"x":1,"y":2}}]`
	if got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
	for _, bad := range []string{
		`""`, `"yesterday"`, `"2026-10-05"`, // not ISO 8601 date-times
		`1791000000`,             // seconds since 1970: 2057 counted from 2001
		`1791000000000`,          // milliseconds
		`120`,                    // an elapsed time, not a moment
		`"2099-01-01T00:00:00Z"`, // in the future
	} {
		got := normalized(t, newNormalizer(nil), `{"updatedAt":`+bad+`}`)
		if strings.Contains(got, "<time") {
			t.Errorf("%s normalised to %s; want it kept", bad, got)
		}
	}
}

// A write that should have moved a revision shows: different values stay different tokens.
func TestDistinctRevisionsStayDistinct(t *testing.T) {
	n := newNormalizer(nil)
	got := normalized(t, n, `[{"rev":1},{"rev":2},{"rev":1},{"revision":1}]`)
	want := `[{"rev":"<rev:1>"},{"rev":"<rev:2>"},{"rev":"<rev:1>"},{"revision":"<board:1>"}]`
	if got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func TestDiffNamesThePathsThatDiffer(t *testing.T) {
	want := Record{Step: "object.get", Response: map[string]any{"ok": true, "result": map[string]any{"object": map[string]any{"frame": map[string]any{"x": 1.0}}}}}
	got := Record{Step: "object.get", Response: map[string]any{"ok": true, "result": map[string]any{"object": map[string]any{"frame": map[string]any{"x": 2.0}}}}}
	diffs := diffRecords(want, got)
	if len(diffs) != 1 || !strings.HasPrefix(diffs[0], "response.result.object.frame.x: got 2, want 1") {
		t.Fatalf("diffs = %v", diffs)
	}
	if d := diffRecords(want, want); len(d) != 0 {
		t.Fatalf("equal records differ: %v", d)
	}
}

// An explicit null and an absent key are different answers: a removal (`props.title: null`
// sent, the key gone from the object) and agent.release's `lifecycle: null` event.
func TestDiffSeparatesAbsentFromNull(t *testing.T) {
	removed := Record{Response: map[string]any{"object": map[string]any{"props": map[string]any{}}}}
	keptNull := Record{Response: map[string]any{"object": map[string]any{"props": map[string]any{"title": nil}}}}
	if d := diffRecords(removed, keptNull); len(d) != 1 || d[0] != "response.object.props.title: got null, want it absent" {
		t.Errorf("a null kept where the key was removed: diffs = %v", d)
	}
	reset := Record{Events: []any{map[string]any{"event": "agent.lifecycle", "data": map[string]any{"lifecycle": nil}}}}
	dropped := Record{Events: []any{map[string]any{"event": "agent.lifecycle", "data": map[string]any{}}}}
	if d := diffRecords(reset, dropped); len(d) != 1 || d[0] != "events.0.data.lifecycle: absent, want null" {
		t.Errorf("a dropped null: diffs = %v", d)
	}
}

func TestUnorderedArraysCompareAsSets(t *testing.T) {
	a := map[string]any{"graph": map[string]any{"arrowsOut": []any{"b", "a"}}}
	b := map[string]any{"graph": map[string]any{"arrowsOut": []any{"a", "b"}}}
	sortUnordered(a, []string{"graph", "arrowsOut"})
	sortUnordered(b, []string{"graph", "arrowsOut"})
	if d := diffRecords(Record{Response: a}, Record{Response: b}); len(d) != 0 {
		t.Fatalf("diffs = %v", d)
	}
}

// A mask leaves out only the matched part of a string: the rest is still compared.
func TestMaskKeepsTheRestOfTheText(t *testing.T) {
	record := func(summary string) Record {
		r := rawRecord{
			step:     Step{Call: "board.history", Mask: map[string]Mask{"response.result.entries.0.summary": {Match: ` at \(-?\d+, -?\d+\)`, As: " at (<view>)", Why: "placement in the user's view"}}},
			conn:     "main",
			response: map[string]any{"result": map[string]any{"entries": []any{map[string]any{"summary": summary}}}},
		}
		return r.normalized(newNormalizer(nil), nil, nil)
	}
	want := record("created browser http://h/other at (50000, 49250) 1000×726")
	if d := diffRecords(want, record("created browser http://h/other at (0, -363) 1000×726")); len(d) != 0 {
		t.Errorf("a placement elsewhere differs: %v", d)
	}
	if d := diffRecords(want, record("created browser http://h/other at (0, -363) 800×600")); len(d) != 1 {
		t.Errorf("a different size passed: %v", d)
	}
}

// Every property the schema types as an id is an id field, so a new one can't slip through
// unnormalised and fail every other server's ids.
func TestIDKeysCoverTheSchema(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "schema", "easl-api.json"))
	if err != nil {
		t.Fatal(err)
	}
	var schema any
	if err := json.Unmarshal(data, &schema); err != nil {
		t.Fatal(err)
	}
	missing := map[string]bool{}
	var walk func(v any, property string)
	walk = func(v any, property string) {
		switch x := v.(type) {
		case map[string]any:
			if x["$ref"] == "#/definitions/Id" && property != "" && !idKeys[property] {
				missing[property] = true
			}
			for k, e := range x {
				if props, ok := e.(map[string]any); ok && k == "properties" {
					for name, p := range props {
						walk(p, name)
					}
					continue
				}
				walk(e, property)
			}
		case []any:
			for _, e := range x {
				walk(e, property)
			}
		}
	}
	walk(schema, "")
	if len(missing) > 0 {
		names := make([]string, 0, len(missing))
		for m := range missing {
			names = append(names, m)
		}
		sort.Strings(names)
		t.Fatalf("schema id properties missing from idKeys: %v", names)
	}
}

func jsonNumber(f float64) string {
	b, _ := json.Marshal(f)
	return string(b)
}
