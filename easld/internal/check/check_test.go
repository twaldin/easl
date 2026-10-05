package check

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/route"
)

// Ported from the layout.check tests of Tests/CanvasCoreTests/LayoutTests.swift (LayoutApiTests)
// and the Swift-recorded conformance/fixtures/layout-check.json.

// Caption chips as DrawingStyle.arrowLabel measures them (AppKit, Shantell Sans 15 pt).
var measuredLabels = map[string]route.Size{
	"through":                        {W: 65, H: 20},
	"this.forward() → bridgeFetch()": {W: 222, H: 20},
	"BridgeConfig.load()":            {W: 145, H: 20},
	"start() writes":                 {W: 104, H: 20},
	"read back (:656)":               {W: 125, H: 20},
	"calls":                          {W: 40, H: 20},
}

type board struct {
	t       *testing.T
	root    string
	objects map[string]model.Object
	n       int
}

func newBoard(t *testing.T) *board {
	root := t.TempDir()
	// 100 lines; line 12 is a tab plus 60 x's (64 columns), line 50 is the longest in the file.
	lines := make([]string, 100)
	for i := range lines {
		lines[i] = "line " + itoa(i+1)
	}
	lines[11] = "\t" + strings.Repeat("x", 60)
	lines[49] = strings.Repeat("y", 120)
	if err := os.WriteFile(filepath.Join(root, "src.txt"), []byte(strings.Join(lines, "\n")), 0o644); err != nil {
		t.Fatal(err)
	}
	return &board{t: t, root: root, objects: map[string]model.Object{}}
}

func itoa(i int) string {
	b, _ := json.Marshal(i)
	return string(b)
}

func (b *board) create(typ model.ObjectType, props map[string]any, frame model.Frame) model.Object {
	b.n++
	id := "obj_" + string(rune('a'+b.n/26)) + string(rune('a'+b.n%26))
	if typ == model.Group {
		spec, _ := route.ParseGroup(props)
		var rects []route.Rect
		for _, m := range spec.Members {
			rects = append(rects, route.RectOf(b.objects[m].Frame))
		}
		r, _ := spec.FrameAround(rects)
		frame = r.Frame()
	}
	o := model.Object{ID: id, Type: typ, Frame: frame, Z: float64(b.n), Props: props}
	b.objects[id] = o
	return o
}

func (b *board) env() Env {
	sizes := map[string]route.Size{}
	for id, o := range b.objects {
		if spec, ok := route.ParseArrow(o.Props); ok && o.Type == model.Arrow && spec.Caption() != "" {
			size, ok := measuredLabels[spec.Caption()]
			if !ok {
				b.t.Fatalf("no measured chip for %q", spec.Caption())
			}
			sizes[id] = size
		}
	}
	return Env{Root: b.root, LabelSizes: sizes}
}

func (b *board) check(ids []string, rect *model.Frame) map[string]any {
	// Through JSON, as the API delivers it.
	data, err := json.Marshal(Check(b.objects, b.env(), ids, rect))
	if err != nil {
		b.t.Fatal(err)
	}
	var out map[string]any
	json.Unmarshal(data, &out)
	return out
}

func obj(id string) map[string]any { return map[string]any{"object": id} }

func code(start, end int) map[string]any {
	return map[string]any{"path": "src.txt", "range": map[string]any{"start": float64(start), "end": float64(end)}}
}

func solid(b *board, x, y, w, h float64) model.Object {
	return b.create(model.Shape, map[string]any{"kind": "rect", "fill": "solid"}, model.Frame{X: x, Y: y, W: w, H: h})
}

// The whole layout.check results the app returned (conformance/fixtures/layout-check.json).
func TestTheAppsLayoutCheckResults(t *testing.T) {
	b := newBoard(t)
	s1 := solid(b, 0, 0, 200, 200)
	s2 := solid(b, 150, 150, 200, 200)
	s3 := solid(b, 600, 0, 100, 100)
	s4 := solid(b, 600, 400, 100, 100)
	s5 := solid(b, 620, 200, 60, 60)
	note := b.create(model.Note, map[string]any{"markdown": "note"}, model.Frame{X: 1200, Y: 0, W: 280, H: 120})
	through := b.create(model.Arrow, map[string]any{"from": obj(s3.ID), "to": obj(s4.ID), "label": "through"}, model.Frame{})
	across := b.create(model.Arrow, map[string]any{"from": map[string]any{"point": []any{500.0, 250.0}}, "to": map[string]any{"point": []any{800.0, 250.0}}}, model.Frame{})
	empty := map[string]any{"arrowCrossings": []any{}, "arrowIntersections": []any{}, "arrowOverlaps": []any{}, "labelOverlaps": []any{},
		"overflow": []any{}, "overlaps": []any{}, "scrolls": []any{}, "truncated": []any{}}
	with := func(changes map[string]any) map[string]any {
		out := map[string]any{}
		for k, v := range empty {
			out[k] = v
		}
		for k, v := range changes {
			out[k] = v
		}
		return out
	}
	for _, c := range []struct {
		name string
		ids  []string
		rect *model.Frame
		want map[string]any
	}{
		{"board", nil, nil, with(map[string]any{
			"arrowCrossings":     []any{map[string]any{"arrow": through.ID, "crosses": []any{s5.ID}}, map[string]any{"arrow": across.ID, "crosses": []any{s5.ID}}},
			"arrowIntersections": []any{map[string]any{"arrows": []any{through.ID, across.ID}, "at": map[string]any{"x": 650.0, "y": 250.0}, "count": 1.0}},
			"overlaps":           []any{[]any{s1.ID, s2.ID}},
		})},
		{"ids", []string{s1.ID}, nil, with(map[string]any{"overlaps": []any{[]any{s1.ID, s2.ID}}})},
		{"a lone note", []string{note.ID}, nil, empty},
		{"rect", nil, &model.Frame{X: 1100, Y: -100, W: 500, H: 500}, empty},
	} {
		if got := b.check(c.ids, c.rect); !reflect.DeepEqual(got, c.want) {
			gj, _ := json.Marshal(got)
			wj, _ := json.Marshal(c.want)
			t.Errorf("%s:\n got %s\nwant %s", c.name, gj, wj)
		}
	}
}

func ids(v any) [][]string {
	var out [][]string
	for _, pair := range v.([]any) {
		var p []string
		for _, id := range pair.([]any) {
			p = append(p, id.(string))
		}
		out = append(out, p)
	}
	return out
}

func TestCheckReportsOverlapsCrossingsAndOverflow(t *testing.T) {
	b := newBoard(t)
	note := func(text string, x, y, w, h float64) model.Object {
		return b.create(model.Note, map[string]any{"markdown": text}, model.Frame{X: x, Y: y, W: w, H: h})
	}
	a := note("a", 0, 0, 200, 200)
	nb := note("b", 400, 0, 200, 200)
	c := note("c", 800, 0, 200, 200)
	stray := note("stray", 150, 150, 200, 100)
	region := b.create(model.Shape, map[string]any{"kind": "rect"}, model.Frame{X: -50, Y: -100, W: 1100, H: 450})
	group := b.create(model.Group, map[string]any{"members": []any{nb.ID, c.ID}}, model.Frame{})
	through := b.create(model.Arrow, map[string]any{"from": obj(a.ID), "to": obj(c.ID)}, model.Frame{})
	around := b.create(model.Arrow, map[string]any{"from": obj(a.ID), "to": obj(c.ID), "route": "avoid"}, model.Frame{})
	tiny := b.create(model.Code, code(1, 30), model.Frame{X: 0, Y: 600, W: 300, H: 100})

	report := b.check(nil, nil)
	overlaps := ids(report["overlaps"])
	has := func(x, y string) bool {
		for _, p := range overlaps {
			if (p[0] == x && p[1] == y) || (p[0] == y && p[1] == x) {
				return true
			}
		}
		return false
	}
	if !has(a.ID, stray.ID) {
		t.Errorf("a and stray overlap: %v", overlaps)
	}
	for _, p := range overlaps {
		if p[0] == region.ID || p[1] == region.ID {
			t.Errorf("a drawn region around things isn't an overlap: %v", overlaps)
		}
	}
	if has(nb.ID, group.ID) || has(a.ID, group.ID) {
		t.Errorf("nor is a group around its members: %v", overlaps)
	}
	crossings := report["arrowCrossings"].([]any)
	found := false
	for _, c := range crossings {
		m := c.(map[string]any)
		if m["arrow"] == through.ID && reflect.DeepEqual(m["crosses"], []any{nb.ID}) {
			found = true
		}
		if m["arrow"] == around.ID {
			t.Errorf("an avoid route goes around b: %v", crossings)
		}
	}
	if !found {
		t.Errorf("the straight arrow crosses b: %v", crossings)
	}
	// Code wraps at its tile's width: at 300 pt (32 columns) line 12's 64 columns take 3 rows,
	// which the tile scrolls through; that's `scrolls`, not content cut off.
	_, h := measure.Content(32, 64, measure.GutterWidth(1), measure.ChromeHeight(false, false)-measure.TitleHeight)
	want := map[string]any{"id": tiny.ID, "y": h + measure.TitleHeight - 100}
	if scrolls := report["scrolls"].([]any); len(scrolls) != 1 || !reflect.DeepEqual(scrolls[0], want) {
		t.Errorf("scrolls %v, want %v", scrolls, want)
	}
	for _, o := range report["overflow"].([]any) {
		if o.(map[string]any)["id"] == tiny.ID {
			t.Error("a code tile's rows past its frame are scrolls, not overflow")
		}
	}
	scoped := b.check([]string{c.ID}, nil)
	if len(scoped["overlaps"].([]any)) != 0 || len(scoped["arrowCrossings"].([]any)) != 0 {
		t.Errorf("scoped to c: %v", scoped)
	}
}

func TestLabelsOnTilesAreReportedAndLabelsKeepOffEachOther(t *testing.T) {
	b := newBoard(t)
	note := func(text string, x, y, w, h float64) model.Object {
		return b.create(model.Note, map[string]any{"markdown": text}, model.Frame{X: x, Y: y, W: w, H: h})
	}
	// Two notes 30 pt apart, walled in above and below: nowhere near the route is clear.
	a := note("a", 0, 0, 200, 100)
	c := note("b", 230, 0, 200, 100)
	above := note("above", -300, -700, 1030, 695)
	below := note("below", -300, 105, 1030, 695)
	point := func(x, y float64) map[string]any { return map[string]any{"point": []any{x, y}} }
	squeezed := b.create(model.Arrow, map[string]any{"from": obj(a.ID), "to": obj(c.ID), "label": "this.forward() → bridgeFetch()"}, model.Frame{})
	one := b.create(model.Arrow, map[string]any{"from": point(1000, 0), "to": point(1400, 0), "label": "BridgeConfig.load()"}, model.Frame{})
	two := b.create(model.Arrow, map[string]any{"from": point(1000, 8), "to": point(1400, 8), "label": "start() writes"}, model.Frame{})
	entries := b.check(nil, nil)["labelOverlaps"].([]any)
	under := func(arrow model.Object) []string {
		for _, e := range entries {
			m := e.(map[string]any)
			if m["arrow"] == arrow.ID {
				var out []string
				for _, id := range m["overlaps"].([]any) {
					out = append(out, id.(string))
				}
				return out
			}
		}
		return nil
	}
	got := under(squeezed)
	if len(got) == 0 {
		t.Errorf("no room anywhere near the route: reported with what it lies on: %v", entries)
	}
	for _, id := range got {
		if id != a.ID && id != c.ID && id != above.ID && id != below.ID {
			t.Errorf("squeezed lies on %s", id)
		}
	}
	if len(under(one)) != 0 || len(under(two)) != 0 {
		t.Errorf("arrows 8 pt apart label their outer sides, not on each other: %v", entries)
	}
}

// A tile put down over an arrow's label: checking just that tile reports the label (its text
// and where it is drawn) and the route.
func TestCheckingATileReportsArrowLabelsLyingOnIt(t *testing.T) {
	b := newBoard(t)
	arrow := b.create(model.Arrow, map[string]any{"from": map[string]any{"point": []any{0.0, 0.0}}, "to": map[string]any{"point": []any{400.0, 0.0}}, "label": "read back (:656)"}, model.Frame{})
	report := b.create(model.HTML, map[string]any{"html": "<p>report</p>"}, model.Frame{X: 60, Y: -150, W: 300, H: 300})
	checked := b.check([]string{report.ID}, nil)
	entries := checked["labelOverlaps"].([]any)
	if len(entries) != 1 {
		t.Fatalf("label overlaps %v", entries)
	}
	entry := entries[0].(map[string]any)
	if entry["arrow"] != arrow.ID || entry["label"] != "read back (:656)" || !reflect.DeepEqual(entry["overlaps"], []any{report.ID}) {
		t.Errorf("entry %v", entry)
	}
	f := model.FrameFromJSON(entry["frame"])
	if !(f.W > 0 && f.H > 0 && f.Intersects(report.Frame) && f.X >= 0 && f.MaxX() <= 400) {
		t.Errorf("the chip, beside the route: %+v", f)
	}
	if want := []any{map[string]any{"arrow": arrow.ID, "crosses": []any{report.ID}}}; !reflect.DeepEqual(checked["arrowCrossings"], want) {
		t.Errorf("crossings %v", checked["arrowCrossings"])
	}
	moved := report
	moved.Frame = model.Frame{X: 60, Y: 200, W: 300, H: 300}
	b.objects[report.ID] = moved
	clear := b.check([]string{report.ID}, nil)
	if len(clear["labelOverlaps"].([]any)) != 0 || len(clear["arrowCrossings"].([]any)) != 0 {
		t.Errorf("moved off: %v", clear)
	}
}

func TestCheckWithSharedFilesAtSeveralWidthsMatchesPerTileRows(t *testing.T) {
	b := newBoard(t)
	// src.txt line 50 is 120 columns: it wraps at 300 pt and 420 pt into different row counts.
	narrow := b.create(model.Code, code(45, 60), model.Frame{X: 0, Y: 0, W: 300, H: 300})
	wider := b.create(model.Code, code(45, 60), model.Frame{X: 0, Y: 400, W: 420, H: 300})
	missing := b.create(model.Code, map[string]any{"path": "gone.txt"}, model.Frame{X: 0, Y: 800, W: 300, H: 200})
	target := b.create(model.Note, map[string]any{"markdown": "t"}, model.Frame{X: 900, Y: 0, W: 200, H: 900})
	wall := b.create(model.Note, map[string]any{"markdown": "wall"}, model.Frame{X: 600, Y: -100, W: 60, H: 1100})
	for _, c := range []struct {
		tile model.Object
		line int
	}{{narrow, 55}, {wider, 52}, {missing, 3}} {
		lines := map[string]any{"start": float64(c.line), "end": float64(c.line)}
		b.create(model.Arrow, map[string]any{"from": map[string]any{"object": c.tile.ID, "lines": lines}, "to": obj(target.ID), "route": "straight", "label": "calls"}, model.Frame{})
	}
	data, _ := os.ReadFile(filepath.Join(b.root, "src.txt"))
	rows := map[string]route.CodeRows{narrow.ID: measure.CodeRowsForFile(string(data), 300), wider.ID: measure.CodeRowsForFile(string(data), 420)}
	if rows[narrow.ID].IndexOfLine(55) == rows[wider.ID].IndexOfLine(55) {
		t.Fatal("the widths wrap line 50 differently")
	}
	expected := route.Geometry{Objects: b.objects, LabelSizes: b.env().LabelSizes}.LayoutCheck(nil, rows)
	if len(expected.Crossings) != 3 {
		t.Fatalf("crossings %+v", expected.Crossings)
	}
	for _, c := range expected.Crossings {
		if len(c.Crosses) != 1 || c.Crosses[0] != wall.ID {
			t.Errorf("crossing %+v", c)
		}
	}
	want := ResultJSON(expected, nil, nil, nil)
	report := b.check(nil, nil)
	for _, key := range []string{"arrowCrossings", "labelOverlaps", "overlaps"} {
		w, _ := json.Marshal(want[key])
		g, _ := json.Marshal(report[key])
		if string(w) != string(g) {
			t.Errorf("%s: %s, want %s", key, g, w)
		}
	}
}
