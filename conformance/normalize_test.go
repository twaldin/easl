package conformance

import (
	"encoding/json"
	"strings"
	"testing"
)

func normalized(t *testing.T, n *normalizer, doc string) string {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(doc), &v); err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	enc.Encode(n.value(v, "", false))
	return strings.TrimSpace(out.String())
}

// Two runs that differ only in ids, times, revisions and paths normalise to the same record,
// and the relations between those values survive.
func TestNormalizationKeepsRelationsAndDropsIncidentals(t *testing.T) {
	run := func(a, b, root string, rev float64) string {
		n := newNormalizer([]pathSubst{{root, "<root>"}})
		n.alias("brd_"+a[:6], "<board>")
		doc := `{"board":"brd_` + a[:6] + `","frames":{"obj_` + b + `":{"x":1}},"objects":[` +
			`{"id":"obj_` + a + `","rev":` + jsonNumber(rev) + `,"createdAt":812918940.5,"props":{"path":"` + root + `/src/a.ts"}},` +
			`{"id":"obj_` + b + `","rev":` + jsonNumber(rev) + `,"updatedAt":"2026-10-05T18:50:46Z"}],` +
			`"summary":"created note obj_` + a + ` (pid 4242)"}`
		return normalized(t, n, doc)
	}
	first := run("01M46PBNZMT65BK5EM", "01M46PBNZMT65BK5EN", "/tmp/run-1/s", 3)
	second := run("01M46Q39E2W6Y66AWN", "01M46Q39E2W6Y66AWP", "/private/var/x/s", 7)
	if first != second {
		t.Fatalf("runs differ:\n%s\n%s", first, second)
	}
	// Keys are walked in order, so `frames` (holding the second object) numbers first.
	for _, want := range []string{`"frames":{"<obj:1>":{"x":1}}`, `"id":"<obj:2>"`, `"rev":"<rev:1>"`, `"<root>/src/a.ts"`, `"<time>"`, `created note <obj:2> (pid <pid>)`, `"board":"<board>"`} {
		if !strings.Contains(first, want) {
			t.Errorf("missing %s in %s", want, first)
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

func TestUnorderedArraysCompareAsSets(t *testing.T) {
	a := map[string]any{"graph": map[string]any{"arrowsOut": []any{"b", "a"}}}
	b := map[string]any{"graph": map[string]any{"arrowsOut": []any{"a", "b"}}}
	sortUnordered(a, []string{"graph", "arrowsOut"})
	sortUnordered(b, []string{"graph", "arrowsOut"})
	if d := diffRecords(Record{Response: a}, Record{Response: b}); len(d) != 0 {
		t.Fatalf("diffs = %v", d)
	}
}

func jsonNumber(f float64) string {
	b, _ := json.Marshal(f)
	return string(b)
}
