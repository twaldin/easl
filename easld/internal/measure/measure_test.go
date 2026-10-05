package measure

import (
	"errors"
	"image"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

// A git that hangs is stopped even when the caller gave no timeout (easld runs requests under
// one lock), and a process it started that keeps its output open doesn't hold the call either.
func TestHungGitIsStopped(t *testing.T) {
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte("#!/bin/sh\nsleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	saved := gitTimeout
	gitTimeout = 200 * time.Millisecond
	t.Cleanup(func() { gitTimeout = saved })
	started := time.Now()
	_, err := RunGit([]string{"remote"}, t.TempDir(), nil, 0, 0)
	var failure *GitError
	if !errors.As(err, &failure) || failure.Kind != "timedOut" {
		t.Fatalf("got %v", err)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("returned after %v", elapsed)
	}
}

func write(t *testing.T, root, path string, lines ...string) {
	t.Helper()
	file := filepath.Join(root, path)
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func git(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return strings.TrimSpace(string(out))
}

func pngFile(t *testing.T, path string, w, h int) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, image.NewNRGBA(image.Rect(0, 0, w, h))); err != nil {
		t.Fatal(err)
	}
}

func size(t *testing.T, typ model.ObjectType, props map[string]any, width *float64, root string) (float64, float64, error) {
	t.Helper()
	return Size(typ, props, width, root)
}

const appTS = "export function greet(name: string): string {\n  return `hello ${name}`;\n}\n\nexport function add(a: number, b: number): number {\n  return a + b;\n}\n\nexport const answer = 42;\n"

// The values the Swift app answered in conformance/fixtures/code-tiles.json.
func TestCodeTilesMeasureAsTheAppDid(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src/app.ts"), []byte(appTS), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		props map[string]any
		width *float64
		w, h  float64
	}{
		{map[string]any{"path": "src/app.ts"}, nil, 441, 204},
		{map[string]any{"path": "src/app.ts", "range": map[string]any{"start": 1.0, "end": 3.0}}, nil, 396, 108},
		{map[string]any{"path": "src/app.ts"}, new(200.0), 280, 236},
		{map[string]any{"path": "src/app.ts", "range": map[string]any{"start": 5.0, "end": 10.0}}, nil, 441, 140},
	}
	for _, c := range cases {
		w, h, err := size(t, model.Code, c.props, c.width, root)
		if err != nil || w != c.w || h != c.h {
			t.Errorf("measure %v width %v = %v×%v (%v), want %v×%v", c.props, c.width, w, h, err, c.w, c.h)
		}
	}
	_, _, err := size(t, model.Code, map[string]any{"path": "missing.ts"}, nil, root)
	var failure *Failure
	if !errors.As(err, &failure) || failure.Code != "not_found" || failure.Message != "no file missing.ts" {
		t.Errorf("missing file: %v", err)
	}
	_, _, err = size(t, model.Code, map[string]any{"path": "src/app.ts", "range": map[string]any{"start": 40.0, "end": 50.0}}, nil, root)
	if !errors.As(err, &failure) || failure.Code != "unavailable" || failure.Message != "lines 40-50 are past the end of the file (9 lines)" {
		t.Errorf("range past the end: %v", err)
	}
	// A zoomed tile lays out at width / zoom and measures its body zoom times that.
	w, h, _ := size(t, model.Code, map[string]any{"path": "src/app.ts", "zoom": 2.0}, nil, root)
	if w != 882 || h != 26+178*2 {
		t.Errorf("zoomed: %v×%v", w, h)
	}
	// A caption that would widen the tile needs the app's font metrics.
	if _, _, err := size(t, model.Code, map[string]any{"path": "src/app.ts", "caption": "the answer"}, nil, root); !IsNeedsApp(err) {
		t.Errorf("caption: %v", err)
	}
	// One that can't (the rows already take the whole width) doesn't.
	if w, _, err := size(t, model.Code, map[string]any{"path": "src/app.ts", "caption": "x"}, new(300.0), root); err != nil || w != 300 {
		t.Errorf("caption at full width: %v %v", w, err)
	}
}

func TestImagesFitTheirPictureCappedAtTheirWidth(t *testing.T) {
	root := t.TempDir()
	pngFile(t, filepath.Join(root, "chart.png"), 1200, 675)
	pngFile(t, filepath.Join(root, "img.png"), 30, 20)
	cases := []struct {
		props map[string]any
		width *float64
		w, h  float64
	}{
		{map[string]any{"path": "img.png"}, nil, 30, 46}, // conformance/fixtures/measure-notes.json
		{map[string]any{"path": "chart.png"}, nil, 960, 26 + 540},
		{map[string]any{"path": "chart.png", "caption": "Figure 1"}, nil, 960, 26 + 540 + 24},
		{map[string]any{"path": "chart.png"}, new(400.0), 400, 26 + 225},
		{map[string]any{"path": "chart.png"}, new(2000.0), 1200, 26 + 675},
		{map[string]any{"path": filepath.Join(root, "chart.png"), "zoom": 2.0}, new(400.0), 400, 26 + 225},
	}
	for _, c := range cases {
		w, h, err := size(t, model.Image, c.props, c.width, root)
		if err != nil || w != c.w || h != c.h {
			t.Errorf("measure %v width %v = %v×%v (%v), want %v×%v", c.props, c.width, w, h, err, c.w, c.h)
		}
	}
	var failure *Failure
	if _, _, err := size(t, model.Image, map[string]any{"path": "missing.png"}, nil, root); !errors.As(err, &failure) || failure.Code != "not_found" ||
		failure.Message != "no readable image at "+filepath.Join(root, "missing.png") {
		t.Errorf("missing image: %v", err)
	}
	if _, _, err := size(t, model.Image, map[string]any{}, nil, root); !errors.As(err, &failure) || failure.Message != "an image needs props.path" {
		t.Errorf("no path: %v", err)
	}
}

func TestQuarterTurnedJPEGsSwapTheirSides(t *testing.T) {
	root := t.TempDir()
	// A JPEG header: SOI, an APP1 Exif with orientation 6, an SOF0 of 40×10.
	exif := []byte("Exif\x00\x00MM\x00*\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00\x00\x00\x00\x00")
	data := []byte{0xFF, 0xD8, 0xFF, 0xE1, 0, byte(len(exif) + 2)}
	data = append(data, exif...)
	data = append(data, 0xFF, 0xC0, 0, 11, 8, 0, 10, 0, 40, 1, 1, 0x11, 0)
	if err := os.WriteFile(filepath.Join(root, "turned.jpg"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	w, h, ok, err := ImageNaturalSize(filepath.Join(root, "turned.jpg"))
	if !ok || err != nil || w != 10 || h != 40 {
		t.Errorf("rotated jpeg: %v×%v %v %v", w, h, ok, err)
	}
}

func TestTypesWithoutAnIntrinsicSizeSaySo(t *testing.T) {
	var failure *Failure
	for _, typ := range []model.ObjectType{model.Browser, model.Terminal, model.Arrow, model.Group} {
		if _, _, err := Size(typ, map[string]any{}, nil, t.TempDir()); !errors.As(err, &failure) || failure.Code != "unsupported" ||
			failure.Message != string(typ)+" objects have no intrinsic size" {
			t.Errorf("%s: %v", typ, err)
		}
	}
	if _, _, err := Size(model.Shape, map[string]any{"kind": "ink"}, nil, ""); !errors.As(err, &failure) || failure.Message != "ink has no intrinsic size" {
		t.Errorf("ink: %v", err)
	}
	if _, _, err := Size(model.Shape, map[string]any{"kind": "blob"}, nil, ""); !errors.As(err, &failure) || failure.Message != "shape props need a kind" {
		t.Errorf("bad kind: %v", err)
	}
	if _, _, err := Size(model.Diagram, map[string]any{}, nil, ""); !errors.As(err, &failure) || failure.Code != "unavailable" {
		t.Errorf("diagram without graph: %v", err)
	}
}

func TestADiagramMeasuresItsGraphAtFullSize(t *testing.T) {
	node := func(id string, level float64, excerpts int) map[string]any {
		var lines []any
		for i := range excerpts {
			lines = append(lines, map[string]any{"line": float64(i + 1), "text": "x"})
		}
		return map[string]any{"id": id, "name": id, "kind": "function", "path": "a.ts", "line": 1.0,
			"lines": map[string]any{"start": 1.0, "end": 2.0}, "excerpt": lines, "level": level}
	}
	graph := map[string]any{
		"aim":        map[string]any{"kind": "calls", "symbol": "f", "direction": "incoming"},
		"root":       "f",
		"nodes":      []any{node("f", 0, 1), node("a", -1, 0), node("b", -1, 2)},
		"edges":      []any{map[string]any{"from": "a", "to": "f", "lines": []any{3.0}}},
		"computedAt": "2026-01-01T00:00:00Z",
	}
	w, h, err := Size(model.Diagram, map[string]any{"graph": graph}, nil, "")
	// Two columns; the callers' column (a node of 50 points and one of 86, 14 apart) is the taller.
	if err != nil || w != 2*36+2*300+76 || h != 26+28+2*36+50+14+86 {
		t.Errorf("diagram: %v×%v %v", w, h, err)
	}
	broken := map[string]any{"aim": graph["aim"], "nodes": []any{map[string]any{"id": "f"}}, "edges": []any{}, "computedAt": "x"}
	if _, ok := DecodeDiagramGraph(broken); ok {
		t.Error("a graph missing node fields doesn't decode")
	}
}

// CodeWrapTests.swift
func TestLongLinesBreakAtTheColumnWithAnIndentedContinuation(t *testing.T) {
	check := func(line string, columns int, breaks []int, indent int) {
		t.Helper()
		b, i := Wrap(UTF16(line), columns)
		if !reflect.DeepEqual(b, breaks) || i != indent {
			t.Errorf("wrap %q at %d = %v indent %d, want %v indent %d", line, columns, b, i, breaks, indent)
		}
	}
	check("short", 10, nil, 0)
	check("0123456789", 10, nil, 0)
	check("abcdefghij", 4, []int{4, 6, 8}, 2)
	check("    let x = 1234567890", 16, []int{16}, 6)
	if _, i := Wrap(UTF16(strings.Repeat(" ", 30)+"x"), 16); i != 8 {
		t.Errorf("indent capped at half: %d", i)
	}
	tabbed := "\t" + strings.Repeat("a", 12)
	if Columns(tabbed) != 16 {
		t.Errorf("tab columns %d", Columns(tabbed))
	}
	check(tabbed, 10, []int{7, 12}, 5)
	check("abcdef\tgh", 7, []int{6}, 2)
	if Columns("漢字漢字漢字") != 12 || Columns("a😀😀") != 5 {
		t.Error("wide characters and emoji take 2 columns")
	}
	check("漢字漢字漢字", 5, []int{2, 3, 4, 5}, 2)
	check("a😀😀", 2, []int{1, 3}, 1)
}

func TestCodeRowsMapLinesToTheirWrappedRows(t *testing.T) {
	text := "one\n" + strings.Repeat("n", 18) + "\nthree\n"
	width := func(columns int) float64 {
		return float64(int(GutterWidth(3) + float64(columns)*CharAdvance + TrailingPadding + 0.999999))
	}
	rows := CodeRowsForFile(text, width(10))
	if rows.Count() != 4 || rows.IndexOfLine(2) != 1 || rows.IndexOfLine(3) != 3 {
		t.Errorf("rows %d, line 2 at %d, line 3 at %d", rows.Count(), rows.IndexOfLine(2), rows.IndexOfLine(3))
	}
	if s, e := rows.RowsOfLine(2); s != 1 || e != 3 {
		t.Errorf("line 2 rows %d..<%d", s, e)
	}
	if s, e := rows.RowsOfLine(99); s != 3 || e != 4 {
		t.Errorf("past the end clamps to the last line: %d..<%d", s, e)
	}
	if CodeRowsForFile(text, width(18)).Count() != 3 {
		t.Error("18 columns show the line whole")
	}
	if r := CodeRowsForLineCount(5); r.Count() != 5 || r.IndexOfLine(3) != 2 {
		t.Error("unwrapped rows are one per line")
	}
}

// NoteFenceTests (NoteTests.swift)
func TestFenceInfoStrings(t *testing.T) {
	f := ParseFenceInfo("ts file=src/app.ts#L10-40")
	if f.Language != "ts" || *f.Path != "src/app.ts" || *f.Lines != (model.LineRange{Start: 10, End: 40}) || f.Mode() != FenceExcerpt {
		t.Errorf("excerpt: %+v", f)
	}
	for info, want := range map[string]*model.LineRange{
		"file=a.ts#L7": {Start: 7, End: 7}, "file=a.ts#L7-L9": {Start: 7, End: 9}, "file=a.ts#7-9": {Start: 7, End: 9},
		"file=a.ts#L9-7": nil, "file=a.ts#L0": nil,
	} {
		f := ParseFenceInfo(info)
		if !reflect.DeepEqual(f.Lines, want) || *f.Path != "a.ts" {
			t.Errorf("%s: %+v %v", info, f.Lines, *f.Path)
		}
	}
	scoped := ParseFenceInfo("swift file=Sources/Board.swift symbol=Board.update")
	if *scoped.Path != "Sources/Board.swift" || *scoped.Symbol != "Board.update" || scoped.Mode() != FenceExcerpt {
		t.Error("scoped symbol")
	}
	if w := ParseFenceInfo("ts symbol=restoreSnapshot"); w.Path != nil || w.Mode() != FenceExcerpt {
		t.Error("workspace symbol")
	}
	p := ParseFenceInfo("ts propose file=src/app.ts@1a2b3c4#L10-40")
	if *p.Commit != "1a2b3c4" || *p.Path != "src/app.ts" || p.Mode() != FencePropose {
		t.Errorf("pinned proposal %+v", p)
	}
	if s := ParseFenceInfo("file=node_modules/@types/node/fs.d.ts#L3"); *s.Path != "node_modules/@types/node/fs.d.ts" || s.Commit != nil {
		t.Error("@ inside a path")
	}
	for info, want := range map[string]string{
		`file=a.ts#L1 anchor="s.split(/\d+/)"`:                        `s.split(/\d+/)`,
		`file=a.ts#L1 anchor="a \\ b"`:                                `a \ b`,
		`ts file=a.ts#L3-5 anchor="let label = \"hi there\"" propose`: `let label = "hi there"`,
		`file=a.ts#L3 anchor='func  go()'`:                            `func  go()`,
	} {
		if a := ParseFenceInfo(info).Anchor; a == nil || *a != want {
			t.Errorf("%s: anchor %v", info, a)
		}
	}
	if ParseFenceInfo("ts").Mode() != FenceFree || ParseFenceInfo("").Mode() != FenceFree || ParseFenceInfo("ts propose").Mode() != FenceFree {
		t.Error("free fences")
	}
}

// NoteAnchorTests (NoteTests.swift)
var anchorSource = []string{"import x", "", "func load() {", "    read()", "}", "", "func save() {", "    write()", "}"}

func fence(path string, start, end int) Fence {
	return Fence{Path: &path, Lines: &model.LineRange{Start: start, End: end}}
}

func rng(start, end int) *model.LineRange { return &model.LineRange{Start: start, End: end} }

func TestAnchorsFollowTheirCode(t *testing.T) {
	expect := func(name string, got Resolution, want *model.LineRange, status string) {
		t.Helper()
		if !reflect.DeepEqual(got.Range, want) || (status != "" && got.Status.Kind != status) {
			t.Errorf("%s: %v %+v, want %v %s", name, got.Range, got.Status, want, status)
		}
	}
	f := fence("a.swift", 7, 9)
	expect("unmoved", ResolveAnchor(f, anchorSource, nil, nil), rng(7, 9), "exact")
	moved := append([]string{"// header", "// more"}, anchorSource...)
	second := ResolveAnchor(f, moved, anchorSource[6:9], nil)
	expect("captured", second, rng(9, 11), "relocated")
	if second.Status.From != (model.LineRange{Start: 7, End: 9}) {
		t.Errorf("relocated from %v", second.Status.From)
	}
	anchored := fence("a.swift", 3, 5)
	anchored.Anchor = new("func save() {")
	expect("anchor attribute", ResolveAnchor(anchored, anchorSource, nil, nil), rng(7, 9), "relocated")

	proposal := fence("a.swift", 7, 9)
	proposal.Propose = true
	shifted := append([]string{"// a", "// b", "// c"}, anchorSource...)
	expect("proposal body", ResolveAnchor(proposal, shifted, nil, []string{"func save() {", "    write()", "    flush()", "}"}), rng(10, 12), "")
	expect("unmoved proposal", ResolveAnchor(proposal, anchorSource, nil, []string{"func save() {", "    write()", "    flush()", "}"}), rng(7, 9), "exact")
	expect("inserted proposal", ResolveAnchor(proposal, shifted, nil, []string{"func save() {", "    validate()", "    write()", "}"}), rng(10, 12), "")
	expect("unmatched body", ResolveAnchor(proposal, shifted, nil, []string{"brand new"}), rng(7, 9), "")

	captured := []string{"func a() {", "    two()", "}"}
	twoA := fence("a.swift", 2, 4)
	expect("captured block wins", ResolveAnchor(twoA, []string{"x", "func a() {", "    other()", "}", "func a() {", "    two()", "}"}, captured, nil), rng(5, 7), "relocated")
	expect("twin tie", ResolveAnchor(twoA, []string{"x", "func a() {", "    two()", "}", "func a() {", "    two()", "}"}, captured, nil), rng(2, 4), "exact")
	expect("neighbours", ResolveAnchor(twoA, []string{"x", "}", "func a() {", "    one()", "}", "func a() {", "    two()", "}"}, captured, nil), rng(6, 8), "")
	expect("deleted", ResolveAnchor(f, anchorSource[:6], anchorSource[6:9], nil), nil, "stale")
	past := ResolveAnchor(fence("a.swift", 40, 50), anchorSource, nil, nil)
	if past.Range != nil || past.Status.Reason != "lines 40-50 are past the end of the file (9 lines)" {
		t.Errorf("past the end: %+v", past)
	}

	parse := []string{"def parse_args(self, args):", "    state = ParsingState(args)", "    self._process_args(state)", "    return state.opts"}
	pf := fence("p.py", 3, 6)
	logged := []string{"import x", "# TEMP", "", parse[0], parse[1], "    print('TEMP', state)  # TEMP", "    print('TEMP')  # TEMP", parse[2], parse[3], "", "def other():", "    pass"}
	expect("grown", ResolveAnchor(pf, logged, parse, nil), rng(4, 9), "relocated")
	expect("removed inside", ResolveAnchor(pf, []string{"import x", "", parse[0], parse[1], parse[3], "", "def other():"}, parse, nil), rng(3, 5), "")
	expect("edited last", ResolveAnchor(pf, []string{"import x", "", parse[0], parse[1], parse[2], "    return state.opts  # checked", "", "def other():"}, parse, nil), rng(3, 6), "")

	star := []string{"    if spos is not None:", "        rv = list(rv)", "        # reverse everything after the star", "        rv[spos + 1 :] = reversed(rv[spos + 2 :])"}
	sf := fence("parser.py", 2, 5)
	fixed := append(append([]string{"def f(rv, spos):"}, star[:3]...), "        # the star keeps its slot;", "        # only what follows it is reversed", "        rv[spos + 1 :] = reversed(rv[spos + 1 :])", "    return rv", "", "def g():")
	expect("replaced last line", ResolveAnchor(sf, fixed, star, nil), rng(2, 7), "relocated")
	deleted := append(append([]string{"def f(rv, spos):"}, star[:3]...), "    return rv", "", "        rv[spos + 1 :] = []")
	expect("deleted last line", ResolveAnchor(sf, deleted, star, nil), rng(2, 4), "")

	stop := []string{"def stop(self):", "    os.dup2(self.saved, self.fd)", "    self.tmp.seek(0)", "    return self.tmp.read()"}
	tf := fence("t.py", 1, 4)
	tf.Anchor = new("def stop(self):")
	file := append(append([]string{"class X:", "    pass", "", "def finish(self):"}, stop[1:]...), "")
	expect("changed first line", ResolveAnchor(tf, file, stop, nil), rng(4, 7), "")
	expect("anchor alone is lost", ResolveAnchor(tf, file, nil, nil), nil, "")

	env := []string{"rv = self.resolve_envvar_value(ctx)", "", "if rv is not None and self.nargs != 1:", "    return self.type.split_envvar_value(rv)", "", "return rv"}
	twin := []string{"rv = self.resolve_envvar_value(ctx)", "", "# Absent environment variable", "if rv is None:", "    return None", ""}
	ef := fence("core.py", 2, 7)
	loggedEnv := append(append(append([]string{"x", env[0], "print('TEMP rv', rv)", "print('TEMP nargs')"}, env[1:]...), "", "class Option:"), twin...)
	expect("twin first line", ResolveAnchor(ef, loggedEnv, env, nil), rng(2, 9), "")
	lost := ResolveAnchor(ef, append([]string{"x", "", "class Option:"}, twin...), env, nil)
	if lost.Range != nil || lost.Status.Reason != "lines 2-7 no longer hold the code they showed" {
		t.Errorf("lost twin: %+v", lost)
	}
}

func TestSymbolsResolveToTheirBody(t *testing.T) {
	expect := func(symbol string, source []string, want *model.LineRange) {
		t.Helper()
		if got := SymbolRange(symbol, source); !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %v, want %v", symbol, got, want)
		}
	}
	swift := []string{"struct Board {", "    var name = \"{\"", "    public func update(_ id: String) throws {", "        if id.isEmpty { return }", "    }", "}", "func update() {}"}
	expect("Board", swift, rng(1, 6))
	expect("Board.update", swift, rng(3, 5))
	expect("update", swift, rng(3, 5))
	expect("missing", swift, nil)
	ts := []string{"const x = restoreSnapshot(1);", "export async function restoreSnapshot(id: string) {", "  const s = await load(id);", "  return s;", "}",
		"export const load = async (id: string) => {", "  return id;", "};"}
	expect("restoreSnapshot", ts, rng(2, 5))
	expect("load", ts, rng(6, 8))
	python := []string{"class Store:", "    def get(self, key):", "        value = self.data[key]", "", "        return value", "", "    def put(self, key):", "        pass"}
	expect("Store.get", python, rng(2, 5))
	expect("Store", python, rng(1, 8))
	testing := []string{"class CliRunner:", "    def make_env(", "        self, overrides: cabc.Mapping[str, str | None] | None = None", "    ) -> cabc.Mapping[str, str | None]:",
		`        """Returns the environment overrides for invoking a script."""`, "        rv = dict(self.env)", "        if overrides:", "            rv.update(overrides)", "        return rv", "",
		"    @contextlib.contextmanager", "    def isolation(", "        self,", "        input: str | bytes | t.IO[t.Any] | None = None,",
		"        env: cabc.Mapping[str, str | None] | None = None,", "        color: bool = False,", "    ) -> cabc.Generator[tuple[io.BytesIO, io.BytesIO, io.BytesIO]]:",
		"        bytes_input = make_input_stream(input, self.charset)", "        yield (bytes_input, bytes_input, bytes_input)", "",
		"    def invoke(self, cli, args=None, extra={}, **kw):", "        return self.run(cli, args, extra)"}
	expect("CliRunner.make_env", testing, rng(2, 9))
	expect("isolation", testing, rng(12, 19))
	expect("CliRunner.invoke", testing, rng(21, 22))

	core := []string{"class Parameter(ABC):", `    r"""A parameter to a command comes in two versions: they are either`, "    :class:`Option`\\s or :class:`Argument`\\s.", `    """`, ""}
	for i := range 120 {
		core = append(core, "    def helper_"+itoa(i)+"(self, ctx: Context) -> None:", "        value = ctx.lookup("+itoa(i)+")", "        return None", "")
	}
	method := len(core)
	core = append(core, "    def resolve_envvar_value(self, ctx: Context) -> str | None:", `        """Returns the value found in the environment variable(s) attached to this`,
		"        parameter (i.e. the", "        environment variable is present but has an empty string).", `        """`, "        if not self.envvar:", "            return None",
		"        return os.environ.get(self.envvar)", "", "    def value_from_envvar(self, ctx: Context) -> t.Any:", "        return None", "", "",
		"class Option(Parameter):", "    def resolve_envvar_value(self, ctx: Context) -> str | None:", "        return None")
	expect("Parameter.resolve_envvar_value", core, rng(method+1, method+8))
	expect("Option.resolve_envvar_value", core, rng(len(core)-1, len(core)))
	if r := SymbolRange("Parameter", core); r == nil || r.End != 400 {
		t.Errorf("a class is capped at 400 lines: %v", r)
	}

	sym := fence("a.swift", 3, 5)
	sym.Symbol = new("save")
	if r := ResolveAnchor(sym, anchorSource, nil, nil).Range; !reflect.DeepEqual(r, rng(7, 9)) {
		t.Errorf("symbol wins: %v", r)
	}
	sym.Symbol = new("gone")
	if r := ResolveAnchor(sym, anchorSource, nil, nil).Range; !reflect.DeepEqual(r, rng(3, 5)) {
		t.Errorf("falls back to the range: %v", r)
	}
	only := Fence{Path: new("a.swift"), Symbol: new("gone")}
	if s := ResolveAnchor(only, anchorSource, nil, nil).Status; s.Reason != "symbol gone not found" {
		t.Errorf("symbol alone: %+v", s)
	}
}

func itoa(i int) string { return strconv.Itoa(i) }

// NoteDiffTests (NoteTests.swift)
func TestProposalDiffs(t *testing.T) {
	diff := DiffLines([]string{"func load() {", "    read()", "    parse()", "}"}, []string{"func load() async {", "    read()", "    try validate()", "    parse()", "}"})
	want := []DiffLine{{0, -1, "func load() {"}, {-1, 0, "func load() async {"}, {1, 1, "    read()"}, {-1, 2, "    try validate()"}, {2, 3, "    parse()"}, {3, 4, "}"}}
	if !reflect.DeepEqual(diff, want) {
		t.Errorf("diff %v", diff)
	}
	run := DiffLines([]string{"a", "b", "c", "d"}, []string{"a", "x", "y", "d"})
	if !reflect.DeepEqual(run, []DiffLine{{0, 0, "a"}, {1, -1, "b"}, {2, -1, "c"}, {-1, 1, "x"}, {-1, 2, "y"}, {3, 3, "d"}}) {
		t.Errorf("removals first: %v", run)
	}
	if KeptCount([]string{"keep", "a", "b", "c", "end"}, []string{"keep", "x", "b", "y", "end"}) != 3 {
		t.Error("kept count")
	}
	old := []string{"a", "b", "c", "a", "b", "b", "a"}
	new := []string{"c", "b", "a", "b", "a", "c"}
	edits := 0
	var replayOld, replayNew []string
	for _, l := range DiffLines(old, new) {
		if !l.Same() {
			edits++
		}
		if l.Old >= 0 {
			replayOld = append(replayOld, l.Text)
		}
		if l.New >= 0 {
			replayNew = append(replayNew, l.Text)
		}
	}
	if edits != 5 || !reflect.DeepEqual(replayOld, old) || !reflect.DeepEqual(replayNew, new) {
		t.Errorf("Myers' example: %d edits", edits)
	}
	big := make([]string, 20000)
	other := make([]string, 20000)
	for i := range big {
		big[i], other[i] = "old "+itoa(i%1000), "new "+itoa(i%1000)
	}
	if len(DiffLines(big, other)) != 40000 {
		t.Error("whole-file rewrite")
	}
	if !reflect.DeepEqual(DiffLines(nil, []string{"a"}), []DiffLine{{-1, 0, "a"}}) || !reflect.DeepEqual(DiffLines([]string{"a"}, []string{"a"}), []DiffLine{{0, 0, "a"}}) {
		t.Error("empty sides")
	}
}

// NoteSourceTests (NoteTests.swift)
func TestExcerptsReadFilesAndGit(t *testing.T) {
	root := t.TempDir()
	write(t, root, "src/a.ts", "one", "two", "three", "four")
	f := ParseFenceInfo("ts file=src/a.ts#L3-4")
	first := ExcerptFor(f, root, nil, nil)
	if !reflect.DeepEqual(first.Lines, []string{"three", "four"}) || first.Status.Kind != "exact" {
		t.Errorf("first %+v", first)
	}
	write(t, root, "src/a.ts", "zero", "one", "two", "three", "four")
	if moved := ExcerptFor(f, root, first.Lines, nil); !reflect.DeepEqual(moved.Range, rng(4, 5)) {
		t.Errorf("moved %+v", moved)
	}
	write(t, root, "src/a.ts", "zero", "one", "two")
	if lost := ExcerptFor(f, root, first.Lines, nil); lost.Status.Kind != "stale" || !reflect.DeepEqual(lost.Lines, []string{"three", "four"}) {
		t.Errorf("lost %+v", lost)
	}
	if missing := ExcerptFor(ParseFenceInfo("file=nope.ts#L1"), root, nil, nil); missing.Status.Reason != "no file nope.ts" || !missing.Missing {
		t.Errorf("missing %+v", missing)
	}

	write(t, root, "src/a.ts", "one", "two", "three", "four", "five")
	appended := ExcerptFor(ParseFenceInfo("ts file=src/a.ts#L2-3 propose"), root, nil, []string{"two", "three", "inserted"})
	if !reflect.DeepEqual(appended.Diff, []DiffLine{{0, 0, "two"}, {1, 1, "three"}, {-1, 2, "inserted"}}) {
		t.Errorf("proposal diff %v", appended.Diff)
	}

	example := []string{"def test_sync():", "    runner = CliRunner()", "    result = runner.invoke(cli)", "    assert 'Debug mode is on' in result.output", "    assert result.exit_code == 0", "```"}
	write(t, root, "src/doc.md", append(append([]string{"Intro", "```python"}, example...), "", "More")...)
	docFence := ParseFenceInfo("python file=src/doc.md#L3-7 propose")
	body := []string{example[0], example[1], example[2], example[4]}
	before := ExcerptFor(docFence, root, nil, body)
	if before.Applied {
		t.Error("not applied yet")
	}
	write(t, root, "src/doc.md", append(append([]string{"Intro", "```python"}, body...), "```", "", "More")...)
	after := ExcerptFor(docFence, root, before.Lines, body)
	if !after.Applied || after.State() != "applied" || after.HasDiff || !reflect.DeepEqual(after.Range, rng(3, 6)) {
		t.Errorf("applied %+v", after)
	}

	write(t, root, "src/b.ts", "", "function f(x) {", "  one(x)", "}")
	rewritten := ExcerptFor(ParseFenceInfo(`ts file=src/b.ts#L1-3 anchor="function f() {" propose`), root, []string{"function f() {", "  one()", "}"}, []string{"function f(x) {", "  one(x)", "}"})
	if !rewritten.Applied || !reflect.DeepEqual(rewritten.Range, rng(2, 4)) || rewritten.StatusJSON()["state"] != "applied" {
		t.Errorf("rewritten %+v", rewritten)
	}

	git(t, root, "init", "-q")
	write(t, root, "src/p.ts", "old 1", "old 2", "old 3")
	git(t, root, "add", ".")
	git(t, root, "commit", "-q", "-m", "one")
	sha := git(t, root, "rev-parse", "--short", "HEAD")
	write(t, root, "src/p.ts", "new 1", "new 2")
	git(t, root, "commit", "-q", "-am", "two")
	pinned := ExcerptFor(ParseFenceInfo("ts file=src/p.ts@"+sha+"#L2-3"), root, nil, nil)
	if !reflect.DeepEqual(pinned.Lines, []string{"old 2", "old 3"}) || pinned.Status.Kind != "exact" {
		t.Errorf("pinned %+v", pinned)
	}
	if bogus := ExcerptFor(ParseFenceInfo("ts file=src/p.ts@0000000#L1"), root, nil, nil); bogus.Status.Reason != "unknown commit 0000000" {
		t.Errorf("bogus %+v", bogus)
	}
	if option := ExcerptFor(ParseFenceInfo("ts file=src/p.ts#L1 commit=--format=%s"), root, nil, nil); option.Status.Kind != "stale" || len(option.Lines) != 0 {
		t.Errorf("option-like revision %+v", option)
	}
	write(t, root, "src/use.ts", "import { restoreSnapshot } from './snap'", "restoreSnapshot(1)")
	write(t, root, "src/snap.ts", "// snapshots", "export function restoreSnapshot(id: number) {", "  return id", "}")
	git(t, root, "add", ".")
	if found := ExcerptFor(ParseFenceInfo("ts symbol=restoreSnapshot"), root, nil, nil); found.Path != "src/snap.ts" || !reflect.DeepEqual(found.Range, rng(2, 4)) {
		t.Errorf("workspace symbol %+v", found)
	}
	if missing := ExcerptFor(ParseFenceInfo("ts symbol=nothingHere"), root, nil, nil); missing.Status.Kind != "stale" {
		t.Errorf("missing symbol %+v", missing)
	}
}

// PinnedMentionTests.codeTileRangesReanchorAsBookkeepingAndReportTheirState
func TestCodeTileRangesReportTheirStateAndReanchor(t *testing.T) {
	root := t.TempDir()
	write(t, root, "src/a.py", "import os", "", "def a():", "    return 1", "", "def b():", "    return 2")
	props := map[string]any{"path": "src/a.py", "range": model.LineRange{Start: 6, End: 7}.JSON(), "anchor": "def b():", "caption": "b"}
	if s, ok := CodeRangeStatus(props, root); !ok || !model.Equal(s, map[string]any{"state": "live", "range": model.LineRange{Start: 6, End: 7}.JSON()}) {
		t.Errorf("live %v", s)
	}
	if _, _, changed := Reanchor(props, root); changed {
		t.Error("nothing moved")
	}
	write(t, root, "src/a.py", "import os", "import sys", "", "", "def a():", "    return 1", "", "def b():", "    return 2")
	moved, _ := CodeRangeStatus(props, root)
	if moved["state"] != "relocated" || !model.Equal(moved["range"], model.LineRange{Start: 8, End: 9}.JSON()) || !model.Equal(moved["written"], model.LineRange{Start: 6, End: 7}.JSON()) {
		t.Errorf("relocated %v", moved)
	}
	r, anchor, changed := Reanchor(props, root)
	if !changed || r != (model.LineRange{Start: 8, End: 9}) || anchor == nil || *anchor != "def b():" {
		t.Errorf("reanchor %v %v %v", r, anchor, changed)
	}
	write(t, root, "src/a.py", "import os")
	if gone, _ := CodeRangeStatus(props, root); gone["state"] != "stale" || gone["range"] != nil {
		t.Errorf("gone %v", gone)
	}
	if _, ok := CodeRangeStatus(map[string]any{"path": "src/a.py", "range": model.LineRange{Start: 1, End: 1}.JSON(), "followOf": "obj_t"}, root); ok {
		t.Error("follow tiles don't anchor")
	}
}

func TestSwiftDecodingErrorTexts(t *testing.T) {
	k, _ := DecodeKeyed(map[string]any{"lines": map[string]any{"start": 1.5, "end": 2.0}, "x": "s", "n": nil}, nil)
	if _, _, err := k.LineRange("lines"); err == nil || err.Error() != `DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not valid JSON.. Underlying error: Error Domain=NSCocoaErrorDomain Code=3840 "Number 1.5 is not representable in Swift." UserInfo={NSDebugDescription=Number 1.5 is not representable in Swift.}` {
		t.Errorf("fraction: %v", err)
	}
	if _, err := k.Int("x"); err == nil || err.Error() != "DecodingError.typeMismatch: expected value of type Int. Path: x. Debug description: Expected to decode Int but found a string instead." {
		t.Errorf("mismatch: %v", err)
	}
	if _, err := k.String("n"); err == nil || err.Error() != "DecodingError.valueNotFound: Expected value of type String but found null instead. Path: n. Debug description: Cannot get value of type String -- found null value instead" {
		t.Errorf("null: %v", err)
	}
}
