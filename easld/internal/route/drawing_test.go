package route

import (
	"math"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

// Ported from Tests/CanvasCoreTests/DrawingTests.swift (ArrowRoutingTests) and the routing and
// line-bound arrow tests of LayoutTests.swift (LayoutBoardTests), plus arrow frames recorded from
// the Swift app (conformance/fixtures/arrows.json, batch.json).

func TestSideBySideObjectsConnectFacingEdgesThroughTheirOverlap(t *testing.T) {
	a, b := Rect{0, 0, 200, 100}, Rect{400, 20, 200, 100}
	start, end := RouteEnds(RectEnd(a), RectEnd(b), ArrowGap, 0)
	// Vertical extents overlap on 20…100, so the arrow runs flat through y = 60.
	if start != (Point{a.MaxX() + ArrowGap, 60}) || end != (Point{b.MinX() - ArrowGap, 60}) {
		t.Errorf("route %v → %v", start, end)
	}
}

func TestMovingABoundObjectReroutesToTheNewNearestEdges(t *testing.T) {
	a := Rect{0, 0, 200, 100}
	before, _ := RouteEnds(RectEnd(a), RectEnd(Rect{400, 0, 200, 100}), ArrowGap, 0)
	moved := Rect{50, 300, 200, 100}
	start, end := RouteEnds(RectEnd(a), RectEnd(moved), ArrowGap, 0)
	if before.X != a.MaxX()+ArrowGap {
		t.Errorf("right edge while b is to the right: %v", before)
	}
	// Now stacked with horizontal overlap 50…200: bottom edge of a to top edge of b.
	if start != (Point{125, a.MaxY() + ArrowGap}) || end != (Point{125, moved.MinY() - ArrowGap}) {
		t.Errorf("stacked: %v → %v", start, end)
	}
}

func TestDiagonalObjectsAimCenterToCenterAndStayOutsideBothOutlines(t *testing.T) {
	a, b := Rect{0, 0, 100, 100}, Rect{300, 250, 100, 100}
	start, end := RouteEnds(RectEnd(a), RectEnd(b), ArrowGap, 0)
	for _, p := range []Point{start, end} {
		if a.Contains(p) || b.Contains(p) {
			t.Errorf("%v inside an outline", p)
		}
	}
	// Each tip sits `gap` beyond its outline.
	if math.Abs(DistanceToSegment(start, Point{100, 0}, Point{100, 100})-ArrowGap) >= 0.5 &&
		math.Abs(DistanceToSegment(start, Point{0, 100}, Point{100, 100})-ArrowGap) >= 0.5 {
		t.Errorf("start %v isn't gap off a", start)
	}
	if !(start.X > a.MidX() && start.Y > a.MidY()) || !(end.X < b.MidX() && end.Y < b.MidY()) {
		t.Errorf("leaves from the corners facing each other: %v → %v", start, end)
	}
}

func TestEllipseOutlinesAttachOnTheCurveNotTheBoundingBox(t *testing.T) {
	start, end := RouteEnds(EllipseEnd(Rect{0, 0, 100, 100}), PointEnd(Point{300, 300}), ArrowGap, 0)
	if math.Abs(math.Hypot(start.X-50, start.Y-50)-(50+ArrowGap)) >= 0.01 {
		t.Errorf("start %v not on the curve plus the gap", start)
	}
	if end != (Point{300, 300}) {
		t.Errorf("free ends stay exactly where they were put: %v", end)
	}
}

func TestAvoidRoutesAroundATileTheStraightLineCrosses(t *testing.T) {
	from, to := Rect{0, 0, 100, 100}, Rect{600, 0, 100, 100}
	wall := Rect{250, -100, 200, 300}
	straight := Path(RectEnd(from), RectEnd(to), Straight, 0, nil, ArrowGap)
	if !PathCrosses(straight, wall) {
		t.Fatal("the straight line should cross the wall")
	}
	avoid := Path(RectEnd(from), RectEnd(to), Avoid, 0, []Rect{wall}, ArrowGap)
	if PathCrosses(avoid, wall.InsetBy(-AvoidMargin+1, -AvoidMargin+1)) {
		t.Errorf("keeps its margin: %v", avoid)
	}
	if PathCrosses(avoid, from) || PathCrosses(avoid, to) {
		t.Errorf("through its own ends: %v", avoid)
	}
	for i := 1; i < len(avoid); i++ {
		if avoid[i].X != avoid[i-1].X && avoid[i].Y != avoid[i-1].Y {
			t.Errorf("axis-aligned segments: %v", avoid)
		}
	}
	end := avoid[len(avoid)-1]
	if !to.InsetBy(-ArrowGap-1, -ArrowGap-1).Contains(end) || to.Contains(end) {
		t.Errorf("ends just off its target: %v", end)
	}
}

func TestOrthogonalJogsBetweenOffsetBoxes(t *testing.T) {
	path := Path(RectEnd(Rect{0, 0, 100, 100}), RectEnd(Rect{400, 300, 100, 100}), Orthogonal, 0, nil, ArrowGap)
	if len(path) != 4 {
		t.Fatalf("path %v", path)
	}
	for i := 1; i < len(path); i++ {
		if path[i].X != path[i-1].X && path[i].Y != path[i-1].Y {
			t.Errorf("axis-aligned: %v", path)
		}
	}
	if path[0].X != 100+ArrowGap || path[3].X != 400-ArrowGap {
		t.Errorf("ends %v", path)
	}
}

func TestParallelArrowsInBothDirectionsDrawApart(t *testing.T) {
	offsets := ParallelOffsets([]ParallelArrow{{"obj_1", "obj_a", "obj_b"}, {"obj_2", "obj_b", "obj_a"}, {"obj_3", "obj_a", "obj_c"}})
	if _, ok := offsets["obj_3"]; ok {
		t.Error("a lone arrow has no offset")
	}
	a := RectEnd(Rect{0, 0, 200, 100})
	b := RectEnd(Rect{500, 40, 200, 100})
	for _, style := range []RouteStyle{Straight, Orthogonal} {
		forward := Path(a, b, style, offsets["obj_1"], nil, ArrowGap)
		back := Path(b, a, style, offsets["obj_2"], nil, ArrowGap)
		// Reversed, the return arrow's route must not coincide with the forward one anywhere.
		separation := math.Inf(1)
		for _, p := range forward {
			separation = math.Min(separation, DistanceToPath(p, back))
		}
		if separation < ParallelSpacing-0.5 {
			t.Errorf("%s: %v vs %v", style, forward, back)
		}
	}
	// Diagonal pairs separate too.
	c := RectEnd(Rect{600, 600, 100, 100})
	forward := Path(a, c, Straight, 10, nil, ArrowGap)
	back := Path(c, a, Straight, 10, nil, ArrowGap)
	if DistanceToPath(forward[0], back) <= 15 {
		t.Errorf("diagonal: %v vs %v", forward, back)
	}
}

func TestALabelSitsBesideItsRouteClearOfBoxes(t *testing.T) {
	path := []Point{{0, 100}, {400, 100}}
	size := Size{80, 20}
	free := LabelAlong(path, size, nil, nil).Rect
	if PathCrosses(path, free) || !(free.MaxY() <= 100-LabelClearance+0.5 || free.MinY() >= 100+LabelClearance-0.5) {
		t.Errorf("beside the line: %v", free)
	}
	if free.MinX() < 0 || free.MaxX() > 400 {
		t.Errorf("along it, not past its ends: %v", free)
	}
	box := Rect{0, 50, 400, 45}
	moved := LabelAlong(path, size, []Rect{box}, nil).Rect
	if moved.Intersects(box) || PathCrosses(path, moved) {
		t.Errorf("the other side when a box covers one: %v", moved)
	}
}

func shape(id string, frame model.Frame, props map[string]any) model.Object {
	return model.Object{ID: id, Type: model.Shape, Frame: frame, Props: props}
}

func arrowObject(id string, props map[string]any) model.Object {
	return model.Object{ID: id, Type: model.Arrow, Frame: model.Frame{}, Props: props}
}

func bound(id string) map[string]any { return map[string]any{"object": id} }

// Arrow frames as the Swift app reported them (conformance/fixtures/arrows.json, batch.json):
// an arrow's frame is the bounds of its route as the drawing layer draws it, through document
// coordinates (the diagonal's ulps show it).
func TestReportedArrowFramesMatchTheApp(t *testing.T) {
	rect := map[string]any{"kind": "rect"}
	objects := map[string]model.Object{
		"obj_1": shape("obj_1", model.Frame{X: 0, Y: 0, W: 160, H: 100}, rect),
		"obj_2": shape("obj_2", model.Frame{X: 400, Y: 0, W: 160, H: 100}, rect),
		"obj_3": shape("obj_3", model.Frame{X: 400, Y: 300, W: 160, H: 100}, rect),
		"obj_4": arrowObject("obj_4", map[string]any{"from": bound("obj_1"), "to": bound("obj_2"), "relation": "calls"}),
		"obj_5": arrowObject("obj_5", map[string]any{"from": bound("obj_1"), "to": bound("obj_3"), "label": "down", "route": "orthogonal"}),
		"obj_6": arrowObject("obj_6", map[string]any{"from": map[string]any{"point": []any{-200.0, -200.0}}, "to": bound("obj_1")}),
		"obj_7": arrowObject("obj_7", map[string]any{"from": map[string]any{"point": []any{0.0, 600.0}}, "to": map[string]any{"point": []any{300.0, 700.0}}, "color": "red"}),
		"obj_8": arrowObject("obj_8", map[string]any{"from": bound("obj_missing"), "to": bound("obj_1")}),
	}
	var settled *Result
	frames := func() map[string]model.Frame {
		settled = Geometry{Objects: objects, Settled: settled}.DrawnRouting(nil)
		out := map[string]model.Frame{}
		for id := range settled.Paths {
			path, _ := settled.DrawnPath(id)
			out[id] = Bounds(path)
		}
		return out
	}
	got := frames()
	for id, want := range map[string]model.Frame{
		"obj_4": {X: 166, Y: 50, W: 228, H: 0},
		"obj_5": {X: 166, Y: 50, W: 228, H: 300},
		"obj_6": {X: -200, Y: -200, W: 219.52437403023941, H: 196.0039053841465},
		"obj_7": {X: 0, Y: 600, W: 300, H: 100},
	} {
		if got[id] != want {
			t.Errorf("%s: %+v, the app reported %+v", id, got[id], want)
		}
	}
	if _, ok := got["obj_8"]; ok {
		t.Error("an arrow whose end is gone has no route")
	}
	// The target moves: the route follows.
	moved := objects["obj_2"]
	moved.Frame = model.Frame{X: 600, Y: 100, W: 160, H: 100}
	objects["obj_2"] = moved
	if f := frames()["obj_4"]; f != (model.Frame{X: 166, Y: 100, W: 428, H: 0}) {
		t.Errorf("moved: %+v", f)
	}
	// obj_3 deleted: obj_5's end detached to where it attached.
	delete(objects, "obj_3")
	objects["obj_5"] = arrowObject("obj_5", map[string]any{"from": bound("obj_1"), "to": map[string]any{"point": []any{394.0, 350.0}}, "label": "down", "route": "orthogonal"})
	if f := frames()["obj_5"]; f != (model.Frame{X: 80, Y: 106, W: 314, H: 244}) {
		t.Errorf("detached: %+v", f)
	}

	// In a batch the frames are reported after its last op (the notes then at x 100 and 400).
	notes := map[string]model.Object{
		"obj_2": {ID: "obj_2", Type: model.Note, Frame: model.Frame{X: 100, Y: 200, W: 200, H: 100}},
		"obj_3": {ID: "obj_3", Type: model.Note, Frame: model.Frame{X: 400, Y: 200, W: 200, H: 100}},
		"obj_4": arrowObject("obj_4", map[string]any{"from": bound("obj_2"), "to": bound("obj_3"), "label": "next"}),
	}
	drawn := Geometry{Objects: notes}.DrawnRouting(nil)
	if path, _ := drawn.DrawnPath("obj_4"); Bounds(path) != (model.Frame{X: 306, Y: 250, W: 88, H: 0}) {
		t.Errorf("batch arrow: %+v", Bounds(path))
	}
	// The board's own routing (layout.check, arrows the app hasn't drawn) works in canvas
	// coordinates: the diagonal ends a few ulps apart.
	if path := Routes(objects, nil, nil)["obj_6"]; Bounds(path).W != 219.5243740302445 {
		t.Errorf("canvas routing: %+v", Bounds(path))
	}
}

// rows is a code tile's visual rows for tests: `lines` lines, some wrapping onto extra rows.
type rows struct {
	lines int
	extra map[int]int
}

func (r rows) clampLine(line int) int { return min(max(1, line), max(1, r.lines)) }

func (r rows) RowsOfLine(line int) (int, int) {
	line = r.clampLine(line)
	start := line - 1
	for l, n := range r.extra {
		if l < line {
			start += n
		}
	}
	return start, start + 1 + r.extra[line]
}

func (r rows) IndexOfLine(line int) int { s, _ := r.RowsOfLine(line); return s }

func (r rows) Count() int {
	n := r.lines
	for _, e := range r.extra {
		n += e
	}
	return n
}

func codeRange(start, end int) map[string]any {
	return map[string]any{"path": "src.txt", "range": map[string]any{"start": float64(start), "end": float64(end)}}
}

func TestLineAnchorsFollowTheRangeScrollRuleAndClampToTheRows(t *testing.T) {
	rng := codeRange(10, 19)
	rowsTop := TileTitleHeight + codeHeaderHeight
	middle := func(row int, scroll float64) float64 {
		return rowsTop + codeVerticalPadding + float64(row)*codeRowHeight - scroll + codeRowHeight/2
	}
	check := func(name string, got, want float64) {
		t.Helper()
		if got != want {
			t.Errorf("%s: %v, want %v", name, got, want)
		}
	}
	// Fit to its range: no context rows, line 10 is the first row.
	fit := model.Frame{X: 0, Y: 100, W: 400, H: rowsTop + 2*codeVerticalPadding + 10*codeRowHeight}
	check("fit line 10", CodeLineY(10, fit, rng, nil), 100+middle(0, 0))
	check("fit line 12", CodeLineY(12, fit, rng, nil), 100+middle(2, 0))
	// Room for 30 rows: three rows of context above the range.
	tall := model.Frame{X: 0, Y: 0, W: 400, H: rowsTop + 2*codeVerticalPadding + 30*codeRowHeight}
	check("tall line 10", CodeLineY(10, tall, rng, nil), middle(3, 0))
	// Lines scrolled out of view pin to the top of the rows or the bottom of the tile.
	check("above", CodeLineY(1, tall, rng, nil), rowsTop)
	check("below", CodeLineY(99, tall, rng, nil), tall.H)
	// Near the end of the file the scroll stops at the last row, which shifts the range down.
	end := codeRange(95, 100)
	check("end, length known", CodeLineY(95, tall, end, rows{lines: 100}), middle(30-6, 0))
	check("end, length unknown", CodeLineY(95, tall, end, nil), middle(3, 0))
	// A caption strip moves the rows down.
	captioned := codeRange(10, 19)
	captioned["caption"] = "why"
	check("captioned", CodeLineY(10, fit, captioned, nil), 100+middle(0, 0)+codeCaptionHeight)
	// At 2× in a frame whose body is twice the size, the tile shows the same rows, twice as far
	// below its 1× title bar.
	zoomed := codeRange(10, 19)
	zoomed["zoom"] = 2.0
	doubled := model.Frame{X: 0, Y: 50, W: 800, H: TileTitleHeight + (tall.H-TileTitleHeight)*2}
	check("zoomed", CodeLineY(10, doubled, zoomed, nil), 50+TileTitleHeight+2*(middle(3, 0)-TileTitleHeight))
	check("zoomed below", CodeLineY(99, doubled, zoomed, nil), 50+doubled.H)
}

func TestLineAnchorsBelowAWrappedLineLandOnTheirVisualRow(t *testing.T) {
	// 20 lines; line 12 wraps onto 3 rows (CodeRows(file:width:) of a 120-column line at 400 pt).
	wrapped := rows{lines: 20, extra: map[int]int{12: 2}}
	rng := codeRange(10, 19)
	rowsTop := TileTitleHeight + codeHeaderHeight
	middle := func(row int) float64 {
		return rowsTop + codeVerticalPadding + float64(row)*codeRowHeight + codeRowHeight/2
	}
	// Fit to its range, 10 lines in 12 rows: line 10 is the first row, line 13 the sixth.
	fit := model.Frame{X: 0, Y: 100, W: 400, H: rowsTop + 2*codeVerticalPadding + 12*codeRowHeight}
	for _, c := range []struct{ line, row int }{{10, 0}, {12, 2}, {13, 5}, {19, 11}} {
		if got := CodeLineY(c.line, fit, rng, wrapped); got != 100+middle(c.row) {
			t.Errorf("line %d at %v, want row %d", c.line, got, c.row)
		}
	}
	// Arrows route to the wrapped row when the board is given the tile's rows.
	objects := map[string]model.Object{
		"obj_code": {ID: "obj_code", Type: model.Code, Frame: fit, Props: rng},
		"obj_note": {ID: "obj_note", Type: model.Note, Frame: model.Frame{X: 600, Y: 100, W: 200, H: 100}},
		"obj_arrow": arrowObject("obj_arrow", map[string]any{"from": bound("obj_note"),
			"to": map[string]any{"object": "obj_code", "lines": map[string]any{"start": 13.0, "end": 13.0}}}),
	}
	path := Geometry{Objects: objects}.Routes(map[string]CodeRows{"obj_code": wrapped}, nil)["obj_arrow"]
	if last := path[len(path)-1]; last != (Point{400 + ArrowGap, 100 + middle(5)}) {
		t.Errorf("ends at %v", last)
	}
}

func codeTile(id string, x, y float64, start, end int) model.Object {
	h := TileTitleHeight + codeHeaderHeight + 2*codeVerticalPadding + float64(end-start+1)*codeRowHeight
	return model.Object{ID: id, Type: model.Code, Frame: model.Frame{X: x, Y: y, W: 400, H: h}, Props: codeRange(start, end)}
}

func lineArrow(id string, from model.Object, fromLine int, to model.Object, toLine int, route RouteStyle) model.Object {
	end := func(o model.Object, line int) map[string]any {
		return map[string]any{"object": o.ID, "lines": map[string]any{"start": float64(line), "end": float64(line)}}
	}
	return arrowObject(id, map[string]any{"from": end(from, fromLine), "to": end(to, toLine), "route": string(route)})
}

func TestLineBoundArrowsLandOnTheirLinesForEveryRoute(t *testing.T) {
	a := codeTile("obj_a", 0, 0, 10, 19)
	b := codeTile("obj_b", 600, 100, 40, 49)
	wall := model.Object{ID: "obj_wall", Type: model.Note, Frame: model.Frame{X: 450, Y: -50, W: 100, H: 500}}
	y := func(o model.Object, line int) float64 { return CodeLineY(line, o.Frame, o.Props, nil) }
	for _, style := range []RouteStyle{Straight, Orthogonal, Avoid} {
		forward := lineArrow("obj_x1", a, 12, b, 45, style)
		back := lineArrow("obj_x2", b, 41, a, 18, style)
		routes := Routes(map[string]model.Object{a.ID: a, b.ID: b, wall.ID: wall, forward.ID: forward, back.ID: back}, nil, nil)
		there, home := routes[forward.ID], routes[back.ID]
		if there[0] != (Point{400 + ArrowGap, y(a, 12)}) || there[len(there)-1] != (Point{600 - ArrowGap, y(b, 45)}) {
			t.Errorf("%s: %v", style, there)
		}
		if home[0] != (Point{600 - ArrowGap, y(b, 41)}) || home[len(home)-1] != (Point{400 + ArrowGap, y(a, 18)}) {
			t.Errorf("%s: %v", style, home)
		}
		if style != Straight {
			for i := 1; i < len(there); i++ {
				if there[i].X != there[i-1].X && there[i].Y != there[i-1].Y {
					t.Errorf("%s not axis-aligned: %v", style, there)
				}
			}
		}
	}
	if y(a, 12) == y(a, 18) || y(b, 45) == y(b, 41) {
		t.Error("distinct lines, distinct rows")
	}
}

func TestStackedLineBoundTilesLoopAroundTheirRightEdges(t *testing.T) {
	a := codeTile("obj_a", 0, 0, 10, 19)
	c := codeTile("obj_c", 0, 400, 10, 19)
	loop := lineArrow("obj_loop", a, 12, c, 15, Orthogonal)
	path := Routes(map[string]model.Object{a.ID: a, c.ID: c, loop.ID: loop}, nil, nil)[loop.ID]
	if path[0] != (Point{400 + ArrowGap, CodeLineY(12, a.Frame, a.Props, nil)}) || path[len(path)-1] != (Point{400 + ArrowGap, CodeLineY(15, c.Frame, c.Props, nil)}) {
		t.Errorf("ends %v", path)
	}
	for _, p := range path {
		if p.X < 400 {
			t.Errorf("never through either tile: %v", path)
		}
	}
	if PathCrosses(path, RectOf(a.Frame)) || PathCrosses(path, RectOf(c.Frame)) {
		t.Errorf("crosses a tile: %v", path)
	}
}

func TestUnfilledRectsAndEllipsesAreAnnotationsNotOverlaps(t *testing.T) {
	note := func(id string, x float64) model.Object {
		return model.Object{ID: id, Type: model.Note, Frame: model.Frame{X: x, Y: 0, W: 300, H: 200}}
	}
	objects := map[string]model.Object{"obj_a": note("obj_a", 0), "obj_b": note("obj_b", 400)}
	if o := Overlaps(objects, nil); len(o) != 0 {
		t.Errorf("apart: %v", o)
	}
	// Drawn across both notes (not around either), the way users mark a column or a pair.
	objects["obj_box"] = shape("obj_box", model.Frame{X: 200, Y: 100, W: 300, H: 200}, map[string]any{"kind": "rect"})
	objects["obj_ring"] = shape("obj_ring", model.Frame{X: 250, Y: -50, W: 100, H: 400}, map[string]any{"kind": "ellipse"})
	objects["obj_filled"] = shape("obj_filled", model.Frame{X: 250, Y: 150, W: 100, H: 100}, map[string]any{"kind": "rect", "fill": "semi"})
	if o := Overlaps(objects, nil); len(o) != 1 || o[0][0] != "obj_a" || o[0][1] != "obj_filled" {
		t.Errorf("only the filled rect covers anything: %v", o)
	}
	if o := Overlaps(objects, []string{"obj_box", "obj_ring", "obj_b"}); len(o) != 0 {
		t.Errorf("scoped: %v", o)
	}
}

func TestAnArrowCaptionIsItsLabelElseItsRelationAndAnEmptyLabelHidesIt(t *testing.T) {
	caption := func(props map[string]any) string {
		props["from"], props["to"] = bound("obj_a"), bound("obj_b")
		spec, _ := ParseArrow(props)
		return spec.Caption()
	}
	for _, c := range []struct {
		props map[string]any
		want  string
	}{
		{map[string]any{"relation": "calls"}, "calls"},
		{map[string]any{"relation": "calls", "label": "retries"}, "retries"},
		{map[string]any{"relation": "calls", "label": ""}, ""},
		{map[string]any{}, ""},
	} {
		if got := caption(c.props); got != c.want {
			t.Errorf("%v: %q, want %q", c.props, got, c.want)
		}
	}
}
