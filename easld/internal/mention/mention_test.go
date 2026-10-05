package mention

import (
	"fmt"
	"image"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
)

type testBoard struct {
	id, root string
	objects  map[string]model.Object
	z        float64
	tray     []model.Mention
}

func newBoard(t *testing.T) *testBoard {
	return &testBoard{id: "brd_test", root: t.TempDir(), objects: map[string]model.Object{}}
}

func (b *testBoard) ID() string                       { return b.id }
func (b *testBoard) Root() string                     { return b.root }
func (b *testBoard) Objects() map[string]model.Object { return b.objects }

func (b *testBoard) create(typ model.ObjectType, props map[string]any, frame model.Frame) model.Object {
	b.z++
	o := model.Object{ID: fmt.Sprintf("obj_%d", len(b.objects)+1), Type: typ, Frame: frame, Z: b.z, Rev: 1, CreatedBy: model.Actor{Kind: "user"}, Props: props}
	b.objects[o.ID] = o
	return o
}

// update merges props as object.update does, marking staged mentions edited (Board.update).
func (b *testBoard) update(id string, props map[string]any, frame *model.Frame) {
	before := b.objects[id]
	after := before.Clone()
	after.Props = model.Merge(after.Props, props).(map[string]any)
	if frame != nil {
		after.Frame = *frame
	}
	after.Rev++
	b.objects[id] = after
	for i, m := range b.tray {
		for _, object := range model.MentionObjects(m.Target) {
			if object == id && !m.Edited && IsEdited(m.Target, before, after) {
				b.tray[i].Edited = true
			}
		}
	}
}

func (b *testBoard) stage(t *testing.T, target map[string]any) model.Mention {
	t.Helper()
	canonical, err := ValidateTarget(target)
	if err != nil {
		t.Fatalf("stage %v: %v", target, err)
	}
	m := model.Mention{ID: fmt.Sprintf("men_%d", len(b.tray)+1), Target: canonical, Label: Label(canonical, b)}
	b.tray = append(b.tray, m)
	return m
}

func (b *testBoard) drain() string {
	var resolved []Resolved
	var targets []map[string]any
	for i, m := range b.tray {
		resolved = append(resolved, Resolve(m, i+1, b, ""))
		targets = append(targets, m.Target)
	}
	b.tray = nil
	return Render(resolved, b, targets, "", "")
}

func writeFile(t *testing.T, root, path, text string) {
	t.Helper()
	file := filepath.Join(root, path)
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func contains(t *testing.T, context, want string) {
	t.Helper()
	if !strings.Contains(context, want) {
		t.Errorf("context lacks %q:\n%s", want, context)
	}
}

func lacks(t *testing.T, context, unwanted string) {
	t.Helper()
	if strings.Contains(context, unwanted) {
		t.Errorf("context has %q:\n%s", unwanted, context)
	}
}

func frame(x, y, w, h float64) model.Frame { return model.Frame{X: x, Y: y, W: w, H: h} }

func lines(start, end int) map[string]any {
	return map[string]any{"start": float64(start), "end": float64(end)}
}

const appTS = "export function greet(name: string): string {\n  return `hello ${name}`;\n}\n\nexport function add(a: number, b: number): number {\n  return a + b;\n}\n\nexport const answer = 42;\n"

// conformance/fixtures/tray.json, as the Swift app answered it.
func TestTheTrayFixture(t *testing.T) {
	b := newBoard(t)
	writeFile(t, b.root, "src/app.ts", appTS)
	note := b.create(model.Note, map[string]any{"markdown": "# Plan\n\nShip the parser.\n\n- write tests\n- fix bugs"}, frame(0, 0, 300, 200))
	shape := b.create(model.Shape, map[string]any{"kind": "rect", "text": "box"}, frame(400, 0, 160, 100))
	code := b.create(model.Code, map[string]any{"path": "src/app.ts", "range": lines(5, 7)}, frame(0, 400, 640, 300))
	labels := []string{
		b.stage(t, map[string]any{"kind": "object", "object": shape.ID}).Label,
		b.stage(t, map[string]any{"kind": "code", "lines": lines(5, 7), "object": code.ID, "path": "src/app.ts", "symbol": "add"}).Label,
		b.stage(t, map[string]any{"kind": "group", "name": "these two", "objects": []any{note.ID, shape.ID}}).Label,
		b.stage(t, map[string]any{"block": "paragraph", "headings": []any{"Plan"}, "kind": "note", "lines": lines(3, 3), "object": note.ID, "text": "Ship the parser."}).Label,
	}
	if want := []string{"shape box", "src/app.ts:5-7 add", "these two", "note Plan › Ship the parser."}; !reflect.DeepEqual(labels, want) {
		t.Errorf("labels %q", labels)
	}
	b.update(shape.ID, map[string]any{"color": "red"}, nil)
	moved := frame(5, 0, 300, 200)
	b.update(note.ID, nil, &moved)
	var edited []bool
	for _, m := range b.tray {
		edited = append(edited, m.Edited)
	}
	if !reflect.DeepEqual(edited, []bool{true, false, true, false}) {
		t.Errorf("edited %v", edited)
	}
	b.tray = append(b.tray[:2], b.tray[3])
	resolved := Resolve(b.tray[0], 1, b, "")
	if resolved.Ref != "canvas:men_1@rev2" || resolved.Summary != "[1] shape "+shape.ID+" \"box\" (drawn by user) (edited)" {
		t.Errorf("resolved %+v", resolved)
	}
	want := "<canvas-mentions board=\"brd_test\" root=\"" + b.root + "\">\n" +
		"[1] shape " + shape.ID + " \"box\" (drawn by user) (edited)\n" +
		"[2] code src/app.ts:5-7 (symbol add) · tile " + code.ID + "\n" +
		"    2      return `hello ${name}`;\n    3    }\n    4    \n  > 5    export function add(a: number, b: number): number {\n  > 6      return a + b;\n  > 7    }\n    8    \n    9    export const answer = 42;\n" +
		"[3] note " + note.ID + " \"Plan\" · paragraph, markdown line 3 · in Plan\n    Ship the parser.\n" +
		"Read more with the easl SDK or CLI: easl get <id> --as graph; look with easl render <id>\n</canvas-mentions>"
	if got := b.drain(); got != want {
		t.Errorf("context:\n%s\nwant:\n%s", got, want)
	}
	if b.drain() != "" {
		t.Error("an empty tray drains to no context")
	}
}

// Swift 6.3's String(describing: DecodingError), recorded with a compiled probe.
func TestBadTargetsFailAsSwiftsDecoderDoes(t *testing.T) {
	cases := map[string]any{
		`DecodingError.keyNotFound: Key 'kind' not found in keyed decoding container. Debug description: No value associated with key CodingKeys(stringValue: "kind", intValue: nil) ("kind").`:                                                                                                       map[string]any{},
		`DecodingError.dataCorrupted: Data was corrupted. Path: kind. Debug description: unknown mention kind sparkle`:                                                                                                                                                                                map[string]any{"kind": "sparkle", "object": "o"},
		`DecodingError.typeMismatch: expected value of type String. Path: kind. Debug description: Expected to decode String but found number instead.`:                                                                                                                                               map[string]any{"kind": 5.0},
		`DecodingError.valueNotFound: Expected value of type String but found null instead. Path: object. Debug description: Cannot get value of type String -- found null value instead`:                                                                                                             map[string]any{"kind": "object", "object": nil},
		`DecodingError.keyNotFound: Key 'end' not found in keyed decoding container. Path: lines. Debug description: No value associated with key CodingKeys(stringValue: "end", intValue: nil) ("end").`:                                                                                             map[string]any{"kind": "code", "object": "o", "path": "p", "lines": map[string]any{"start": 1.0}},
		`DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not valid JSON.. Underlying error: Error Domain=NSCocoaErrorDomain Code=3840 "Number 1e+30 is not representable in Swift." UserInfo={NSDebugDescription=Number 1e+30 is not representable in Swift.}`: map[string]any{"kind": "image", "object": "o", "path": "p", "x": 1e30, "y": 2.0},
		`DecodingError.dataCorrupted: Data was corrupted. Path: part. Debug description: Cannot initialize TerminalPart from invalid String value bogus`:                                                                                                                                              map[string]any{"kind": "terminal", "object": "o", "text": "t", "part": "bogus"},
		`DecodingError.typeMismatch: expected value of type String. Path: objects[1]. Debug description: Expected to decode String but found number instead.`:                                                                                                                                         map[string]any{"kind": "group", "objects": []any{"a", 5.0}},
		`DecodingError.valueNotFound: Expected value of type Array<Any> but found null instead. Path: objects. Debug description: Cannot get unkeyed decoding container -- found null value instead`:                                                                                                  map[string]any{"kind": "group", "objects": nil},
		`DecodingError.dataCorrupted: Data was corrupted. Path: entry.kind. Debug description: Cannot initialize Kind from invalid String value bogus`:                                                                                                                                                map[string]any{"kind": "console", "object": "o", "url": "u", "entry": map[string]any{"seq": 1.0, "time": "t", "kind": "bogus", "level": "l", "text": "x"}},
		`DecodingError.typeMismatch: expected value of type Int. Path: command.exit. Debug description: Expected to decode Int but found a string instead.`:                                                                                                                                           map[string]any{"kind": "terminal", "object": "o", "text": "t", "command": map[string]any{"exit": "x"}},
		`DecodingError.typeMismatch: expected value of type Dictionary<String, Any>. Debug description: Expected to decode Dictionary<String, Any> but found an array instead.`:                                                                                                                       []any{},
		`DecodingError.keyNotFound: Key 'h' not found in keyed decoding container. Path: point. Debug description: No value associated with key CodingKeys(stringValue: "h", intValue: nil) ("h").`:                                                                                                   map[string]any{"kind": "dom", "object": "o", "url": "u", "selector": "s", "point": map[string]any{"x": 1.0, "y": 2.0, "w": 3.0}},
	}
	for want, target := range cases {
		if _, err := ValidateTarget(target); err == nil || err.Error() != want {
			t.Errorf("%v:\n got %v\nwant %s", target, err, want)
		}
	}
	// Re-encoded as MentionTarget.encode writes it: unknown keys dropped, the default part left out.
	got, err := ValidateTarget(map[string]any{"kind": "terminal", "object": "o", "text": "t", "part": "selection", "command": nil, "extra": 1.0})
	if err != nil || !model.Equal(got, map[string]any{"kind": "terminal", "object": "o", "text": "t"}) {
		t.Errorf("canonical %v %v", got, err)
	}
	if _, err := DecodeLineRanges([]any{lines(1, 2), map[string]any{"start": 1.0, "end": "x"}}); err == nil ||
		err.Error() != "DecodingError.typeMismatch: expected value of type Int. Path: [1].end. Debug description: Expected to decode Int but found a string instead." {
		t.Errorf("line ranges: %v", err)
	}
}

// BoardTests.codeMentionContextIncludesTheRealExcerpt
func TestCodeMentionContextIncludesTheRealExcerpt(t *testing.T) {
	b := newBoard(t)
	writeFile(t, b.root, "restore.ts", "line one\nexport function restoreSnapshot() {\n  return 1\n}\n")
	code := b.create(model.Code, map[string]any{"path": "restore.ts"}, frame(0, 0, 640, 446))
	b.stage(t, map[string]any{"kind": "code", "object": code.ID, "path": "restore.ts", "lines": lines(2, 3), "symbol": "restoreSnapshot"})
	context := b.drain()
	contains(t, context, "restore.ts:2-3 (symbol restoreSnapshot)")
	contains(t, context, "  > 2    export function restoreSnapshot() {")
	contains(t, context, "  > 3      return 1")
	contains(t, context, "    1    line one")

	var rows []string
	for i := 1; i <= 40; i++ {
		rows = append(rows, fmt.Sprintf("row %d", i))
	}
	writeFile(t, b.root, "long.txt", strings.Join(rows, "\n"))
	tile := b.create(model.Code, map[string]any{"path": "long.txt"}, frame(0, 0, 640, 446))
	b.stage(t, map[string]any{"kind": "code", "object": tile.ID, "path": "long.txt", "lines": lines(5, 30)})
	capped := b.drain()
	contains(t, capped, "  > 16   row 16")
	lacks(t, capped, "row 17")
	lacks(t, capped, "row 4\n")
	contains(t, capped, "    …")

	b.stage(t, map[string]any{"kind": "code", "object": tile.ID, "path": "gone.txt", "lines": lines(1, 1)})
	contains(t, b.drain(), "    (file unreadable: "+b.root+"/gone.txt)")
}

// BoardTests.domChipsLeadWithTextTagAndTileAndEndWithTheSelector
func TestDomLabels(t *testing.T) {
	b := newBoard(t)
	page := b.create(model.Browser, map[string]any{"url": "http://localhost:3000/blog", "title": "Blog"}, frame(0, 0, 1000, 726))
	label := func(selector string, text any) string {
		target := map[string]any{"kind": "dom", "object": page.ID, "url": "http://localhost:3000/blog", "selector": selector}
		if text != nil {
			target["text"] = text
		}
		return b.stage(t, target).Label
	}
	for got, want := range map[string]string{
		label("body > main > div:nth-of-type(2) > strong", "navigation"): "\"navigation\" · strong · Blog · body > main > div:nth-of-type(2) > strong",
		label("#discussion_r1 > div > p:nth-of-type(1)", nil):            "p · Blog · #discussion_r1 > div > p:nth-of-type(1)",
		label("#submit", "Sign in"):                                      "\"Sign in\" · Blog · #submit",
		label("a[aria-label=\"a > b\"]", "Next"):                         "\"Next\" · a · Blog · a[aria-label=\"a > b\"]",
	} {
		if got != want {
			t.Errorf("%q, want %q", got, want)
		}
	}
	b.tray = nil
	b.stage(t, map[string]any{"kind": "dom", "object": page.ID, "url": "http://x/", "selector": "canvas", "point": map[string]any{"x": 3.0, "y": 4.0, "w": 640.0, "h": 480.0}})
	contains(t, b.drain(), "[1] dom http://x/ · canvas · pixel (3, 4) of 640×480, from its top-left · browser tile "+page.ID)
}

// BoardTests.drawnShapeMentionDescribesWhatItEnclosesAndWhatItIsDrawnOn and
// drawingMentionsCarryTheWholeNoteWhatTheyAreOnAndThePageUnderThem.
func TestDrawnShapesDescribeWhatTheyEncloseAndLieOn(t *testing.T) {
	b := newBoard(t)
	inner := b.create(model.Note, map[string]any{"markdown": "inside"}, frame(20, 20, 50, 50))
	box := b.create(model.Shape, map[string]any{"kind": "rect", "text": "auth path?"}, frame(0, 0, 200, 200))
	b.stage(t, map[string]any{"kind": "object", "object": box.ID})
	context := b.drain()
	contains(t, context, "drawn by user")
	contains(t, context, "encloses "+inner.ID)
	lacks(t, context, "· over")

	page := b.create(model.Browser, map[string]any{"url": "http://localhost/"}, frame(1000, 0, 600, 400))
	upper := b.create(model.Browser, map[string]any{"url": "http://localhost/b"}, frame(1000, 0, 600, 400))
	circle := b.create(model.Shape, map[string]any{"kind": "ellipse"}, frame(1240, 226, 125, 120))
	straddling := b.create(model.Shape, map[string]any{"kind": "rect"}, frame(1500, 300, 200, 50))
	b.stage(t, map[string]any{"kind": "object", "object": circle.ID})
	b.stage(t, map[string]any{"kind": "object", "object": straddling.ID})
	over := b.drain()
	contains(t, over, circle.ID+" \"ellipse\" (drawn by user) · over browser "+upper.ID+" at (240, 200) 125×120")
	lacks(t, over, page.ID)
	lacks(t, over, straddling.ID+" \"rect\" (drawn by user) · over")

	zoomed := b.create(model.Browser, map[string]any{"url": "http://localhost/c", "zoom": 2.0}, frame(3000, 0, 1200, 800))
	mark := b.create(model.Shape, map[string]any{"kind": "ellipse"}, frame(3480, 426, 250, 240))
	b.stage(t, map[string]any{"kind": "object", "object": mark.ID})
	contains(t, b.drain(), mark.ID+" \"ellipse\" (drawn by user) · over browser "+zoomed.ID+" at (240, 200) 125×120")

	gui := b.create(model.Browser, map[string]any{"url": "http://localhost/gui"}, frame(0, 1000, 400, 900))
	text := b.create(model.Shape, map[string]any{"kind": "text", "text": "dots dangle at line ends: keep link + dot together, one per line on phone?\nand the footer"}, frame(-100, 1300, 300, 60))
	b.stage(t, map[string]any{"kind": "object", "object": text.ID})
	notes := b.drain()
	contains(t, notes, "\"dots dangle at line ends: keep link + dot together, one per line on phone?\\nand the footer\" (drawn by user)")
	contains(t, notes, "· partly over browser "+gui.ID+" at (0, 274) 200×60")

	arrow := b.create(model.Arrow, map[string]any{"from": map[string]any{"object": inner.ID}, "to": map[string]any{"point": []any{10.0, 10.0}}, "relation": "calls"}, frame(0, 0, 0, 0))
	b.stage(t, map[string]any{"kind": "object", "object": box.ID})
	b.stage(t, map[string]any{"kind": "object", "object": arrow.ID})
	arrows := b.drain()
	contains(t, arrows, "· inner arrow "+inner.ID+" → (10, 10) (calls)")
	contains(t, arrows, "[2] arrow "+arrow.ID+" \"calls\" · "+inner.ID+" → (10, 10) (calls)")
}

// BoardTests.changesMentionIsEditedOnlyByActionsOnItsOwnLines and
// undoingAnotherFilesReviewLeavesTheMentionButUndoingItsOwnEditsIt.
func TestChangesMentionsAreEditedOnlyByActionsOnTheirLines(t *testing.T) {
	tile := model.Object{ID: "obj_1", Type: model.Changes, Props: map[string]any{}}
	target, _ := ValidateTarget(map[string]any{"kind": "code", "object": "obj_1", "path": "a.txt", "lines": lines(10, 12), "diff": "added line · unstaged hunk"})
	entry := func(path, header, scope string) any {
		e := map[string]any{"action": "stage", "path": path, "scope": scope}
		if header != "" {
			e["header"] = header
		}
		return e
	}
	var reviewed []any
	review := func(next any) bool {
		before := tile
		reviewed = append(reviewed, next)
		tile = tile.Clone()
		tile.Props["reviewed"] = model.Clone(reviewed)
		return IsEdited(target, before, tile)
	}
	if review(entry("b.txt", "", "file")) || review(entry("b.txt", "@@ -8,6 +8,8 @@", "hunk")) || review(entry("a.txt", "@@ -30,3 +30,4 @@", "hunk")) {
		t.Error("other files and other hunks leave the lines as they were")
	}
	viewed := tile.Clone()
	viewed.Props["viewed"] = map[string]any{"a.txt": "f1"}
	viewed.Frame = frame(0, 0, 900, 700)
	if IsEdited(target, tile, viewed) {
		t.Error("Viewed and moves aren't edits")
	}
	if !review(entry("a.txt", "@@ -8,4 +8,6 @@", "hunk")) {
		t.Error("a Stage of the hunk holding the lines is")
	}
	based := tile.Clone()
	based.Props["base"] = "merge-base"
	if !IsEdited(target, tile, based) {
		t.Error("another base is")
	}

	other := model.Object{ID: "obj_1", Type: model.Changes, Props: map[string]any{"reviewed": []any{map[string]any{"action": "stage", "path": "b.txt", "scope": "file"}}}}
	undone := model.Object{ID: "obj_1", Type: model.Changes, Props: map[string]any{"reviewed": []any{}}}
	short, _ := ValidateTarget(map[string]any{"kind": "code", "object": "obj_1", "path": "a.txt", "lines": lines(3, 3)})
	if IsEdited(short, other, undone) {
		t.Error("undoing another file's review leaves the mention")
	}
	own := model.Object{ID: "obj_1", Type: model.Changes, Props: map[string]any{"reviewed": []any{map[string]any{"action": "revert", "path": "a.txt", "scope": "file"}}}}
	if !IsEdited(short, own, undone) {
		t.Error("undoing its own review edits it")
	}
	code := model.Object{ID: "obj_2", Type: model.Code, Props: map[string]any{"path": "a.txt"}}
	reaimed := code.Clone()
	reaimed.Props["path"] = "b.txt"
	if IsEdited(short, code, reaimed) {
		t.Error("re-aiming the code tile a mention came from changes nothing")
	}
	note := model.Object{ID: "obj_3", Type: model.Note, Props: map[string]any{"markdown": "v1"}}
	whole, _ := ValidateTarget(map[string]any{"kind": "object", "object": "obj_3"})
	zoomed := note.Clone()
	zoomed.Props["zoom"] = 2.0
	if IsEdited(whole, note, zoomed) {
		t.Error("zoom is bookkeeping")
	}
	rewritten := note.Clone()
	rewritten.Props["markdown"] = "v2"
	if !IsEdited(whole, note, rewritten) {
		t.Error("new markdown is an edit")
	}
}

const audit = `# Audit log: shop-api

Intro paragraph that
wraps onto two lines.

## Leads

1. Session secret fallback
2. Unescaped og:image
3. JSON-LD not escaped
4. Rate limit keyed on IP
   - behind a proxy: all one key
   - see server/index.ts:117
5. CSP allows unsafe-inline

#### Rate limits

> Quoted finding
> continues

| Lead | Severity |
| --- | --- |
| rlKey | Low |
| seo | Med |

` + "```ts\nconst x = 1\n```" + `

## Fixed

Nothing yet.`

func item(t *testing.T, line int, markdown string) NoteItem {
	t.Helper()
	i, ok := NoteItemAt(line, markdown)
	if !ok {
		t.Fatalf("no block at line %d", line)
	}
	return i
}

func lr(start, end int) model.LineRange { return model.LineRange{Start: start, End: end} }

// NoteItemTests (NoteTests.swift)
func TestNoteBlocks(t *testing.T) {
	expect := func(name string, got, want any) {
		t.Helper()
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %#v, want %#v", name, got, want)
		}
	}
	p := item(t, 4, audit)
	expect("paragraph", []any{p.Kind, p.Lines, p.Headings, p.Text}, []any{"paragraph", lr(3, 4), []string{"Audit log: shop-api"}, "Intro paragraph that\nwraps onto two lines."})

	lead := item(t, 11, audit)
	expect("item", []any{lead.Kind, lead.Lines, lead.Headings, lead.Text, lead.Summary()},
		[]any{"item", lr(11, 13), []string{"Audit log: shop-api", "Leads"}, "4. Rate limit keyed on IP\n   - behind a proxy: all one key\n   - see server/index.ts:117", "4. Rate limit keyed on IP"})
	nested := item(t, 12, audit)
	expect("nested", []any{nested.Lines, nested.Text, nested.Summary()}, []any{lr(12, 12), "- behind a proxy: all one key", "behind a proxy: all one key"})

	leads := item(t, 6, audit)
	expect("heading", []any{leads.Kind, leads.Lines, leads.Headings, leads.Summary(), strings.HasPrefix(leads.Text, "## Leads\n\n1. Session secret fallback")},
		[]any{"heading", lr(6, 28), []string{"Audit log: shop-api"}, "Leads", true})
	section := item(t, 16, audit)
	expect("deeper heading", []any{section.Lines, section.Headings}, []any{lr(16, 28), []string{"Audit log: shop-api", "Leads"}})
	expect("path", item(t, 19, audit).Headings, []string{"Audit log: shop-api", "Leads", "Rate limits"})
	expect("later section", item(t, 32, audit).Headings, []string{"Audit log: shop-api", "Fixed"})

	quote := item(t, 19, audit)
	expect("quote", []any{quote.Kind, quote.Lines}, []any{"quote", lr(18, 19)})
	row := item(t, 23, audit)
	expect("row", []any{row.Kind, row.Text, row.Summary()}, []any{"row", "| rlKey | Low |", "rlKey · Low"})
	expect("delimiter", item(t, 22, audit).Lines, lr(21, 21))
	fence := item(t, 27, audit)
	expect("fence", []any{fence.Kind, fence.Lines, fence.Summary()}, []any{"code", lr(26, 28), "const x = 1"})

	for _, c := range []struct {
		line     int
		markdown string
	}{{2, audit}, {99, audit}, {2, "a\n\n---\n\nb"}, {3, "a\n\n---\n\nb"}} {
		if _, ok := NoteItemAt(c.line, c.markdown); ok {
			t.Errorf("line %d of %q is no block", c.line, c.markdown)
		}
	}

	var big []string
	for i := 1; i <= 60; i++ {
		big = append(big, fmt.Sprintf("- item %d", i))
	}
	long := item(t, 1, "# Big\n\n"+strings.Join(big, "\n"))
	expect("long section", []any{long.Lines, len(measure.NoteLines(long.Text)), long.OmittedLines()}, []any{lr(1, 62), 40, 22})
	wide := item(t, 1, strings.Repeat("word ", 1000))
	expect("wide", []any{measure.CharCount(wide.Text), strings.HasSuffix(wide.Text, "…")}, []any{2000, true})
}

func TestNoteBlocksAreRefoundAfterEdits(t *testing.T) {
	lead := item(t, 11, audit)
	found, unchanged, ok := FindNoteItem(lead.Text, lead.Lines.Start, "Preface\n\n"+audit)
	if !ok || !unchanged || found.Lines != lr(13, 15) {
		t.Errorf("moved: %+v %v %v", found, unchanged, ok)
	}
	grown := strings.Replace(audit, "   - see server/index.ts:117", "   - see server/index.ts:117\n   - fixed in 1a2b3c4", 1)
	if changed, unchanged, ok := FindNoteItem(lead.Text, lead.Lines.Start, grown); !ok || unchanged || !strings.HasSuffix(changed.Text, "- fixed in 1a2b3c4") {
		t.Errorf("grown: %+v", changed)
	}
	reworded := strings.Replace(audit, "4. Rate limit keyed on IP", "4. Rate limit keyed on the client IP", 1)
	if _, _, ok := FindNoteItem(lead.Text, lead.Lines.Start, reworded); ok {
		t.Error("reworded: gone")
	}
	twice := audit + "\n\n4. Rate limit keyed on IP\n   - behind a proxy: all one key\n   - see server/index.ts:117\n"
	if found, _, _ := FindNoteItem(lead.Text, lead.Lines.Start, twice); found.Lines.Start != 11 {
		t.Errorf("twice: nearest %v", found.Lines)
	}
}

func noteTarget(note model.Object, i NoteItem) map[string]any {
	headings := []any{}
	for _, h := range i.Headings {
		headings = append(headings, h)
	}
	return map[string]any{"kind": "note", "object": note.ID, "block": i.Kind, "headings": headings, "lines": i.Lines.JSON(), "text": i.Text}
}

// NoteMentionTests (NoteTests.swift)
func TestNoteMentionsInTheContext(t *testing.T) {
	b := newBoard(t)
	note := b.create(model.Note, map[string]any{"markdown": audit}, frame(0, 0, 280, 266))
	stageLead := func() {
		b.stage(t, noteTarget(note, item(t, 11, audit)))
	}
	stageLead()
	context := b.drain()
	contains(t, context, "[1] note "+note.ID+" \"Audit log: shop-api\" · list item, markdown lines 11-13 · in Audit log: shop-api › Leads\n")
	contains(t, context, "\n    4. Rate limit keyed on IP\n       - behind a proxy: all one key\n       - see server/index.ts:117\n")
	lacks(t, context, "CSP allows")

	stageLead()
	b.update(note.ID, map[string]any{"markdown": "Preface\n\n" + audit}, nil)
	moved := b.drain()
	contains(t, moved, "list item, markdown lines 13-15 · in Audit log: shop-api › Leads (edited)")
	lacks(t, moved, "changed since")

	b.update(note.ID, map[string]any{"markdown": audit}, nil)
	stageLead()
	b.update(note.ID, map[string]any{"markdown": strings.Replace(audit, "   - see server/index.ts:117", "   - fixed", 1)}, nil)
	contains(t, b.drain(), "(changed since it was mentioned; as it reads now:)\n    4. Rate limit keyed on IP\n       - behind a proxy: all one key\n       - fixed")

	b.update(note.ID, map[string]any{"markdown": audit}, nil)
	stageLead()
	b.update(note.ID, map[string]any{"markdown": "# Audit log: shop-api\n\nAll fixed."}, nil)
	contains(t, b.drain(), "(no longer in the note; as it read when mentioned:)\n    4. Rate limit keyed on IP")

	var hundred []string
	for i := 1; i <= 100; i++ {
		hundred = append(hundred, fmt.Sprintf("line %d", i))
	}
	short := b.create(model.Note, map[string]any{"markdown": audit}, frame(0, 0, 280, 266))
	big := b.create(model.Note, map[string]any{"markdown": strings.Join(hundred, "\n")}, frame(0, 0, 280, 266))
	b.stage(t, map[string]any{"kind": "object", "object": short.ID})
	b.stage(t, map[string]any{"kind": "object", "object": big.ID})
	whole := b.drain()
	contains(t, whole, "    Nothing yet.")
	contains(t, whole, "    line 80\n    … 20 more lines (easl get "+big.ID+")")
	lacks(t, whole, "line 81")

	markdown := "# a\\_b\n\n| key | value |\n|---|---|\n| max\\_depth | a \\| b |\n\nUse \\_\\_init\\_\\_ or `x\\_y`."
	escaped := b.create(model.Note, map[string]any{"markdown": markdown}, frame(0, 0, 280, 266))
	if l := b.stage(t, noteTarget(escaped, item(t, 5, markdown))).Label; l != "note a_b › max_depth · a | b" {
		t.Errorf("row label %q", l)
	}
	if l := b.stage(t, noteTarget(escaped, item(t, 7, markdown))).Label; l != "note a_b › Use __init__ or `x\\_y`." {
		t.Errorf("paragraph label %q", l)
	}
}

func TestPlainTextOfALine(t *testing.T) {
	for line, want := range map[string]string{
		"# Plan":                            "Plan",
		"## A *b* **c** `d`":                "A b c `d`",
		"- [ ] write tests":                 "write tests",
		"1. [link](http://x) &amp; ~~old~~": "link & old",
		"> quoted":                          "quoted",
		"---":                               "---",
		"```ts":                             "```ts",
		"<div>":                             "<div>",
		"plain <b>bold</b> text":            "plain <b>bold</b> text",
		"see <http://a.b/c>":                "see http://a.b/c",
	} {
		if got := PlainTextOfLine(line); got != want {
			t.Errorf("%q → %q, want %q", line, got, want)
		}
	}
}

// TerminalMentionTests (without the app's terminal hooks: no block index, no screen).
func TestTerminalMentionsCarryTheirText(t *testing.T) {
	b := newBoard(t)
	shell := b.create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620))
	var output []string
	for i := 1; i <= 60; i++ {
		output = append(output, fmt.Sprintf("ok %d", i))
	}
	m := b.stage(t, map[string]any{"kind": "terminal", "object": shell.ID, "text": strings.Join(output, "\n"), "part": "command",
		"command": map[string]any{"command": "go test ./...", "exit": 1.0, "durationMs": 42000.0}})
	if m.Label != "$ go test ./... · exit 1 · 42 s" {
		t.Errorf("label %q", m.Label)
	}
	b.stage(t, map[string]any{"kind": "object", "object": shell.ID})
	context := b.drain()
	contains(t, context, "[1] command `go test ./...` · exit 1 · 42 s · output of terminal tile "+shell.ID+" \"terminal\"\n")
	contains(t, context, "    ok 10\n    … 20 lines omitted …\n    ok 31")
	contains(t, context, "[2] terminal "+shell.ID+" \"terminal\"")
	contains(t, context, "easl agent.read --target <id>")
	lacks(t, context, "easl get <id> --as graph")

	rows := b.stage(t, map[string]any{"kind": "terminal", "object": shell.ID, "text": "  $ make\n> error: boom\n  done", "part": "rows"})
	if rows.Label != "terminal \"error: boom\"" {
		t.Errorf("rows label %q", rows.Label)
	}
	contains(t, Resolve(rows, 1, b, shell.ID).Summary, "[1] terminal tile "+shell.ID+" (your terminal) · screen rows around the click (> marks it)\n      $ make\n    > error: boom\n      done")
}

func TestPageLogEntries(t *testing.T) {
	b := newBoard(t)
	page := b.create(model.Browser, map[string]any{"url": "http://localhost:3000/", "title": "Shop"}, frame(0, 0, 1000, 726))
	m := b.stage(t, map[string]any{"kind": "console", "object": page.ID, "url": "http://localhost:3000/", "entry": map[string]any{
		"seq": 3.0, "time": "2026-01-02T03:04:05Z", "kind": "exception", "level": "error", "text": "TypeError: x is undefined",
		"source": "http://localhost:3000/static/app.js?v=3:12:5", "stack": "at f (app.js:1:2)\nat canvas-page-log.js:3:4\n  at g (app.js:5:6)"}})
	if m.Label != "error \"TypeError: x is undefined\" · app.js:12" {
		t.Errorf("label %q", m.Label)
	}
	want := "[1] page error · browser tile " + page.ID + " \"Shop\" · page http://localhost:3000/\n    TypeError: x is undefined\n    source: http://localhost:3000/static/app.js?v=3:12:5\n    stack:\n      at f (app.js:1:2)\n      at g (app.js:5:6)"
	if got := Resolve(m, 1, b, "").Summary; got != want {
		t.Errorf("summary:\n%s\nwant:\n%s", got, want)
	}
}

// GroupMentionTests.aGroupMentionListsEachMemberAndTheArrowsAmongThem
func TestAGroupMentionListsEachMemberAndTheArrowsAmongThem(t *testing.T) {
	b := newBoard(t)
	var rows []string
	for i := 1; i <= 20; i++ {
		rows = append(rows, fmt.Sprintf("line %d", i))
	}
	writeFile(t, b.root, "Sources/Webhook.swift", strings.Join(rows, "\n"))
	note := b.create(model.Note, map[string]any{"markdown": "# Webhooks\n\nVerifies the signature.\nThen queues it.\n"}, frame(0, 0, 300, 200))
	code := b.create(model.Code, map[string]any{"path": "Sources/Webhook.swift", "range": lines(3, 5)}, frame(0, 300, 300, 200))
	terminal := b.create(model.Terminal, map[string]any{"cwd": "/", "name": "ingest worker"}, frame(0, 600, 300, 200))
	page := b.create(model.Browser, map[string]any{"url": "http://localhost:3000/hooks", "title": "Hooks dashboard"}, frame(0, 900, 300, 200))
	outside := b.create(model.Note, map[string]any{"markdown": "Delivery"}, frame(1000, 0, 300, 200))
	bind := func(id string) map[string]any { return map[string]any{"object": id} }
	verifies := b.create(model.Arrow, map[string]any{"from": bind(note.ID), "to": bind(code.ID), "relation": "calls", "label": "verifies with"}, frame(0, 0, 0, 0))
	runs := b.create(model.Arrow, map[string]any{"from": bind(code.ID), "to": bind(terminal.ID)}, frame(0, 0, 0, 0))
	b.create(model.Arrow, map[string]any{"from": bind(terminal.ID), "to": bind(outside.ID)}, frame(0, 0, 0, 0))
	region := b.create(model.Group, map[string]any{"members": []any{note.ID, code.ID, terminal.ID, page.ID}, "title": "Ingress"}, frame(0, 0, 400, 1200))
	members, ok := groupTarget(region.ID, b)
	if !ok {
		t.Fatal("group target")
	}
	var objects []any
	for _, m := range members {
		objects = append(objects, m)
	}
	b.stage(t, map[string]any{"kind": "group", "objects": objects, "name": "Ingress"})
	contains(t, b.drain(), strings.Join([]string{
		"[1] group \"Ingress\" of 4 objects · group " + region.ID,
		"    - note " + note.ID + " \"Webhooks\"",
		"      Verifies the signature.",
		"      Then queues it.",
		"    - code " + code.ID + " \"Sources/Webhook.swift\" · lines 3-5",
		"        2    line 2",
		"      > 3    line 3",
		"      > 4    line 4",
		"      > 5    line 5",
		"        6    line 6",
		"    - terminal " + terminal.ID + " \"ingest worker\" · arrow → " + outside.ID,
		"    - browser " + page.ID + " \"Hooks dashboard\" · http://localhost:3000/hooks",
		"    arrows among them:",
		"      " + note.ID + " \"Webhooks\" → " + code.ID + " \"Sources/Webhook.swift\" · \"verifies with\" (calls) · arrow " + verifies.ID,
		"      " + code.ID + " \"Sources/Webhook.swift\" → " + terminal.ID + " \"ingest worker\" · arrow " + runs.ID,
	}, "\n"))
}

// GroupMentionTests.aBigGroupListsEveryMemberAndSaysWhatTextItLeftOut
func TestABigGroupSaysWhatTextItLeftOut(t *testing.T) {
	b := newBoard(t)
	var ids []any
	for index := range 30 {
		var text []string
		for line := range 10 {
			text = append(text, fmt.Sprintf("note %d line %d", index, line))
		}
		ids = append(ids, b.create(model.Note, map[string]any{"markdown": strings.Join(text, "\n")}, frame(0, 0, 280, 266)).ID)
	}
	b.create(model.Group, map[string]any{"members": ids, "title": "Atlas"}, frame(0, 0, 400, 400))
	b.stage(t, map[string]any{"kind": "group", "objects": ids, "name": "Atlas"})
	var block []string
	in := false
	for _, line := range strings.Split(b.drain(), "\n") {
		if strings.HasPrefix(line, "[1] group") {
			in = true
		}
		if strings.HasPrefix(line, "Read more") {
			break
		}
		if in {
			block = append(block, line)
		}
	}
	if !contains2(block, "      note 0 line 1") || len(block) > 122 || !strings.HasPrefix(block[len(block)-1], "    (left out to keep this short: the text of ") {
		t.Errorf("big group: %d lines, last %q", len(block), block[len(block)-1])
	}
}

func contains2(lines []string, want string) bool {
	for _, l := range lines {
		if l == want {
			return true
		}
	}
	return false
}

// ImageTests.aMentionedImagePointNamesThePixelAndTheImageSize
func TestAMentionedImagePointNamesThePixelAndTheImageSize(t *testing.T) {
	b := newBoard(t)
	if err := os.MkdirAll(filepath.Join(b.root, "out"), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(filepath.Join(b.root, "out/chart.png"))
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, image.NewNRGBA(image.Rect(0, 0, 1200, 675))); err != nil {
		t.Fatal(err)
	}
	f.Close()
	tile := b.create(model.Image, map[string]any{"path": "out/chart.png"}, frame(0, 0, 960, 566))
	m := b.stage(t, map[string]any{"kind": "image", "object": tile.ID, "path": "out/chart.png", "x": 600.0, "y": 337.0})
	if m.Label != "out/chart.png at (600, 337)" {
		t.Errorf("label %q", m.Label)
	}
	contains(t, b.drain(), "[1] image out/chart.png · pixel (600, 337) of 1200×675, from its top-left · tile "+tile.ID)
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

// PinnedMentionTests.pinnedExcerptRowsMentionTheirCommit, and worktree paths in labels
// (WorktreeTests.filesOutsideTheRootAreNamedByTheirWorktreeAndRepoPath).
func TestPinnedAndOtherWorktreeMentions(t *testing.T) {
	b := newBoard(t)
	git(t, b.root, "init", "-q")
	writeFile(t, b.root, "a.ts", "then 1\nthen 2\n")
	git(t, b.root, "add", ".")
	git(t, b.root, "commit", "-q", "-m", "one")
	sha := git(t, b.root, "rev-parse", "HEAD")
	writeFile(t, b.root, "a.ts", "now 1\nnow 2\n")
	note := b.create(model.Note, map[string]any{"markdown": "```ts file=a.ts@" + sha + "#L2\n```"}, frame(0, 0, 280, 266))
	b.stage(t, map[string]any{"kind": "code", "object": note.ID, "path": "a.ts", "lines": lines(2, 2), "commit": sha})
	context := b.drain()
	contains(t, context, "at "+sha[:7])
	contains(t, context, "then 2")
	lacks(t, context, "now 2")

	worktree := filepath.Join(t.TempDir(), "fees")
	git(t, b.root, "worktree", "add", "-q", worktree)
	file := filepath.Join(worktree, "a.ts")
	tile := b.create(model.Code, map[string]any{"path": file}, frame(0, 0, 640, 446))
	if l := b.stage(t, map[string]any{"kind": "code", "object": tile.ID, "path": file, "lines": lines(2, 2), "symbol": "fee"}).Label; l != "fees/a.ts:2 fee" {
		t.Errorf("label %q", l)
	}
	if l := b.stage(t, map[string]any{"kind": "object", "object": tile.ID}).Label; l != "code fees/a.ts" {
		t.Errorf("object label %q", l)
	}
	contains(t, b.drain(), "code "+file+":2-2")
}

// NoteMarkdownTests and AnchorStatusApiTests.noteFencesReportTheirState
func TestNoteFencesAnchorAndReportTheirState(t *testing.T) {
	for _, line := range []string{`let label = "hi" & 'there'`, `const re = /\d+\s*"x"/`, `say("a \\ b")`, "plain line"} {
		anchored, ok := anchoring("# t\n\n```ts file=a.ts#L3-5\n```\n", []int{3}, line)
		if fences := AnchoredFences(anchored); !ok || len(fences) != 1 || fences[0].Fence.Anchor == nil || *fences[0].Fence.Anchor != line {
			t.Errorf("anchor %q round trip: %q", line, anchored)
		}
	}
	markdown := "- item\n\n  ```ts file=a.ts#L1-2\n  ```\n\n> ```ts file=a.ts#L1-2 propose\n> x\n> ```\n"
	fences := AnchoredFences(markdown)
	if len(fences) != 2 || !reflect.DeepEqual(fences[0].Lines, []int{3}) || !reflect.DeepEqual(fences[1].Lines, []int{6}) {
		t.Fatalf("fences in containers: %+v", fences)
	}
	text := markdown
	for _, f := range fences {
		text, _ = anchoring(text, f.Lines, "func go() {")
	}
	again := AnchoredFences(text)
	if *again[0].Fence.Anchor != "func go() {" || *again[1].Fence.Anchor != "func go() {" || !reflect.DeepEqual(again[1].Body, []string{"x"}) {
		t.Errorf("anchored in containers: %q", text)
	}
	if _, ok := anchoring("```ts file=a.ts#L1\n```", []int{1}, "let s = `x`"); ok {
		t.Error("a backtick fence can't hold a backtick")
	}
	if tilde, ok := anchoring("~~~ts file=a.ts#L1\n~~~", []int{1}, "let s = `x`"); !ok || *AnchoredFences(tilde)[0].Fence.Anchor != "let s = `x`" {
		t.Errorf("tilde %q", tilde)
	}

	root := t.TempDir()
	writeFile(t, root, "src/a.py", "import os\n\ndef a():\n    return 1\n\ndef b():\n    return 2\n")
	note := "```python file=src/a.py#L3-4 anchor=\"def a():\"\n```\n\n```python file=src/a.py#L1-2 anchor=\"def b():\"\n```\n\n```python file=src/a.py symbol=gone\n```\n\n```python file=src/a.py#L6-7 propose\ndef b():\n    return 2\n```\n\n```python file=src/nope.py#L1\n```"
	status := NoteFences(note, measure.LinkReading{Root: root})
	var states []any
	var opened []any
	for _, s := range status {
		states = append(states, s.(map[string]any)["state"])
		opened = append(opened, s.(map[string]any)["markdownLines"])
	}
	if !reflect.DeepEqual(states, []any{"live", "relocated", "stale", "applied", "missing"}) ||
		!reflect.DeepEqual(opened, []any{[]any{1.0}, []any{4.0}, []any{7.0}, []any{10.0}, []any{15.0}}) {
		t.Errorf("states %v lines %v", states, opened)
	}
	at := func(i int) map[string]any { return status[i].(map[string]any) }
	if !model.Equal(at(1)["range"], lr(6, 7).JSON()) || !model.Equal(at(1)["written"], lr(1, 2).JSON()) || at(2)["reason"] != "symbol gone not found" ||
		at(3)["propose"] != true || at(4)["reason"] != "no file src/nope.py" || at(4)["path"] != "src/nope.py" {
		t.Errorf("status %v", status)
	}
	if got := AnchoringRanges("```python file=src/a.py#L3-4\n```\n", measure.LinkReading{Root: root}); got != "```python file=src/a.py#L3-4 anchor=\"def a():\"\n```\n" {
		t.Errorf("anchoring ranges %q", got)
	}
}
