package route

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

// Ported from Tests/CanvasCoreTests/RoutingTests.swift: a board's `avoid` arrows routed
// together: ports, tracks, labels, flow, stability, and what layout.check reports about arrows.

type board struct {
	serial int
}

func (b *board) next(prefix string) string {
	b.serial++
	return fmt.Sprintf("obj_%s%03d", prefix, b.serial)
}

func (b *board) tile(x, y float64, size ...float64) model.Object {
	w, h := 200.0, 100.0
	if len(size) == 2 {
		w, h = size[0], size[1]
	}
	return model.Object{ID: b.next("t"), Type: model.Note, Frame: model.Frame{X: x, Y: y, W: w, H: h}, Z: float64(b.serial), Props: map[string]any{"markdown": "x"}}
}

func (b *board) arrow(from, to model.Object, label string, route string) model.Object {
	props := map[string]any{"from": map[string]any{"object": from.ID}, "to": map[string]any{"object": to.ID}, "route": route}
	if label != "" {
		props["label"] = label
	}
	return model.Object{ID: b.next("a"), Type: model.Arrow, Frame: model.Frame{W: 1, H: 1}, Z: float64(b.serial), Props: props}
}

func (b *board) line(from, to Point) model.Object {
	return model.Object{ID: b.next("a"), Type: model.Arrow, Frame: model.Frame{W: 1, H: 1}, Z: float64(b.serial), Props: map[string]any{
		"from": map[string]any{"point": []any{from.X, from.Y}}, "to": map[string]any{"point": []any{to.X, to.Y}}}}
}

func (b *board) group(members []model.Object, flow string) model.Object {
	ids := make([]any, len(members))
	rects := make([]Rect, len(members))
	for i, m := range members {
		ids[i], rects[i] = m.ID, RectOf(m.Frame)
	}
	props := map[string]any{"members": ids, "title": "Lane"}
	if flow != "" {
		props["flow"] = flow
	}
	spec, _ := ParseGroup(props)
	frame, _ := spec.FrameAround(rects)
	return model.Object{ID: b.next("g"), Type: model.Group, Frame: frame.Frame(), Props: props}
}

// geometry is the board with label chips sized as the drawing layer sizes them, routed on from
// `settled`.
func geometry(t *testing.T, objects []model.Object, settled *Result) Geometry {
	t.Helper()
	byID := map[string]model.Object{}
	labels := map[string]Size{}
	for _, o := range objects {
		byID[o.ID] = o
		if o.Type != model.Arrow {
			continue
		}
		spec, ok := ParseArrow(o.Props)
		if !ok || spec.Caption() == "" {
			continue
		}
		size, ok := measuredLabels[spec.Caption()]
		if !ok {
			t.Fatalf("no measured chip for caption %q", spec.Caption())
		}
		labels[o.ID] = size
	}
	return Geometry{Objects: byID, LabelSizes: labels, Settled: settled}
}

type fan struct {
	sources []model.Object
	target  model.Object
	arrows  []model.Object
}

// fanIn: eight sources in a column, one target to their right.
func (b *board) fanIn(labels bool) fan {
	var f fan
	for i := range 8 {
		f.sources = append(f.sources, b.tile(0, float64(i)*150))
	}
	f.target = b.tile(700, 500)
	for i, s := range f.sources {
		label := ""
		if labels {
			label = fmt.Sprintf("input %d", i+1)
		}
		f.arrows = append(f.arrows, b.arrow(s, f.target, label, "avoid"))
	}
	return f
}

func (f fan) objects() []model.Object {
	return slices.Concat(f.sources, []model.Object{f.target}, f.arrows)
}

// narrowestTrack: the smallest distance between parallel, overlapping segments of different
// arrows.
func narrowestTrack(paths map[string][]Point) float64 {
	type seg struct {
		id   string
		a, b Point
	}
	var segs []seg
	for id, p := range paths {
		for i := range len(p) - 1 {
			segs = append(segs, seg{id, p[i], p[i+1]})
		}
	}
	narrowest := math.Inf(1)
	for i, s := range segs {
		for _, u := range segs[i+1:] {
			if s.id == u.id {
				continue
			}
			sv, uv := s.a.X == s.b.X, u.a.X == u.b.X
			if sv != uv {
				continue
			}
			lo := func(x seg, v bool) (float64, float64) {
				if v {
					return math.Min(x.a.Y, x.b.Y), math.Max(x.a.Y, x.b.Y)
				}
				return math.Min(x.a.X, x.b.X), math.Max(x.a.X, x.b.X)
			}
			sl, sh := lo(s, sv)
			ul, uh := lo(u, uv)
			if !(math.Min(sh, uh)-math.Max(sl, ul) > 1) {
				continue
			}
			if sv {
				narrowest = math.Min(narrowest, math.Abs(s.a.X-u.a.X))
			} else {
				narrowest = math.Min(narrowest, math.Abs(s.a.Y-u.a.Y))
			}
		}
	}
	return narrowest
}

func atlas(t *testing.T) []model.Object {
	t.Helper()
	data, err := os.ReadFile("../../../Tests/Fixtures/atlas-board.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Objects []struct {
			ID    string         `json:"id"`
			Type  string         `json:"type"`
			Frame model.Frame    `json:"frame"`
			Z     float64        `json:"z"`
			Props map[string]any `json:"props"`
		} `json:"objects"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	var out []model.Object
	for _, o := range fixture.Objects {
		typ, ok := model.ParseObjectType(o.Type)
		if !ok {
			t.Fatalf("type %s", o.Type)
		}
		out = append(out, model.Object{ID: o.ID, Type: typ, Frame: o.Frame, Z: o.Z, Props: o.Props})
	}
	return out
}

func TestArrowsSharingASideGetDistinctPortsInTheOrderOfTheirSources(t *testing.T) {
	var b board
	f := b.fanIn(false)
	paths := geometry(t, f.objects(), nil).Routes(nil, nil)
	side := RectOf(f.target.Frame).MinX() - ArrowGap
	var ys []float64
	for _, a := range f.arrows {
		end := paths[a.ID][len(paths[a.ID])-1]
		if math.Abs(end.X-side) >= 0.5 {
			t.Errorf("%s enters %v, not the side facing it", a.ID, end)
		}
		ys = append(ys, end.Y)
	}
	if !slices.IsSorted(ys) {
		t.Errorf("ports run in the order of the sources, so the arrows don't cross at the side: %v", ys)
	}
	for i := 1; i < len(ys); i++ {
		if ys[i]-ys[i-1] < 8 {
			t.Errorf("distinct ports: %v", ys)
		}
	}
}

func TestCollinearRunsSpreadIntoSeparateTracksWithoutCrossing(t *testing.T) {
	var b board
	f := b.fanIn(false)
	paths := geometry(t, f.objects(), nil).Routes(nil, nil)
	if o := ArrowOverlaps(paths); len(o) != 0 {
		t.Errorf("overlaps: %v", o)
	}
	if n := narrowestTrack(paths); n < 8 {
		t.Errorf("narrowest track %v", n)
	}
	if x := ArrowIntersections(paths); len(x) != 0 {
		t.Errorf("a fan-in needs no crossing: %v", x)
	}
	// Fanning out is the mirror image.
	source := b.tile(0, 500)
	var targets, arrows []model.Object
	for i := range 8 {
		targets = append(targets, b.tile(700, float64(i)*150))
	}
	for _, target := range targets {
		arrows = append(arrows, b.arrow(source, target, "", "avoid"))
	}
	out := geometry(t, slices.Concat([]model.Object{source}, targets, arrows), nil).Routes(nil, nil)
	if len(ArrowOverlaps(out)) != 0 || len(ArrowIntersections(out)) != 0 {
		t.Errorf("fan-out: %v %v", ArrowOverlaps(out), ArrowIntersections(out))
	}
}

func TestLabelsKeepOffTilesTitlesArrowsAndEachOther(t *testing.T) {
	var b board
	f := b.fanIn(true)
	lane := b.group(f.sources, "")
	objects := slices.Concat(f.sources, []model.Object{f.target, lane}, f.arrows)
	routing := geometry(t, objects, nil).Routing(nil)
	labels := routing.Labels
	if len(labels) != len(f.arrows) {
		t.Fatalf("%d labels for %d arrows", len(labels), len(f.arrows))
	}
	var tiles []Rect
	for _, o := range objects {
		if BlocksRoutes(o) {
			tiles = append(tiles, RectOf(o.Frame))
		}
	}
	title := Region{ID: lane.ID, Frame: RectOf(lane.Frame)}.Title()
	for id, label := range labels {
		inner := label.Rect.InsetBy(0.5, 0.5)
		for _, tile := range tiles {
			if tile.Intersects(inner) {
				t.Errorf("%s on a tile", id)
			}
		}
		if title.Intersects(inner) {
			t.Errorf("%s on the title", id)
		}
		for other, l := range labels {
			if other != id && l.Rect.Intersects(inner) {
				t.Errorf("%s on another label", id)
			}
		}
		for other, p := range routing.Paths {
			if other != id && PathCrosses(p, inner) {
				t.Errorf("%s on another arrow", id)
			}
		}
		path := routing.Paths[id]
		gap := math.Inf(1)
		for i := range len(path) - 1 {
			a, c := path[i], path[i+1]
			r := label.Rect
			box := Rect{math.Min(a.X, c.X), math.Min(a.Y, c.Y), math.Abs(a.X - c.X), math.Abs(a.Y - c.Y)}
			gap = math.Min(gap, math.Hypot(math.Max(0, math.Max(box.MinX()-r.MaxX(), r.MinX()-box.MaxX())), math.Max(0, math.Max(box.MinY()-r.MaxY(), r.MinY()-box.MaxY()))))
		}
		if label.Leader != nil || gap > 8 {
			t.Errorf("%s right by its own line: leader %v gap %v", id, label.Leader, gap)
		}
	}
	if check := geometry(t, objects, nil).LayoutCheck(nil, nil); len(check.LabelOverlaps) != 0 {
		t.Errorf("label overlaps: %+v", check.LabelOverlaps)
	}
}

func TestMovingAnUnrelatedTileLeavesARouteAlone(t *testing.T) {
	var b board
	a, c, wall := b.tile(0, 0), b.tile(600, 200), b.tile(300, -100, 100, 400)
	near := b.arrow(a, c, "near", "avoid")
	d, e := b.tile(3000, 0), b.tile(3600, 300)
	far := b.arrow(d, e, "far", "avoid")
	before := geometry(t, []model.Object{a, c, wall, near, d, e, far}, nil).Routing(nil)
	moved := e
	moved.Frame = model.Frame{X: 3640, Y: 360, W: 200, H: 100}
	after := geometry(t, []model.Object{a, c, wall, near, d, moved, far}, nil).Routing(nil)
	if !pathEqual(after.Paths[near.ID], before.Paths[near.ID]) || !after.Labels[near.ID].equal(before.Labels[near.ID]) {
		t.Errorf("near moved: %v → %v", before.Paths[near.ID], after.Paths[near.ID])
	}
	if pathEqual(after.Paths[far.ID], before.Paths[far.ID]) {
		t.Errorf("the moved tile's own arrow follows it")
	}
}

func TestFlowPicksTheSidesArrowsLeaveAndEnterWithoutUTurns(t *testing.T) {
	var b board
	a, c := b.tile(0, 0), b.tile(400, 300)
	link := b.arrow(a, c, "", "avoid")
	path := func(flow string) []Point {
		return geometry(t, []model.Object{a, c, b.group([]model.Object{a, c}, flow), link}, nil).Routes(nil, nil)[link.ID]
	}
	down := path("down")
	if math.Abs(down[0].Y-(RectOf(a.Frame).MaxY()+ArrowGap)) >= 0.5 || math.Abs(down[len(down)-1].Y-(RectOf(c.Frame).MinY()-ArrowGap)) >= 0.5 {
		t.Errorf("leaves the downstream (bottom) side and enters the upstream (top) side: %v", down)
	}
	right := path("right")
	if math.Abs(right[0].X-(RectOf(a.Frame).MaxX()+ArrowGap)) >= 0.5 || math.Abs(right[len(right)-1].X-(RectOf(c.Frame).MinX()-ArrowGap)) >= 0.5 {
		t.Errorf("leaves the right side and enters the left: %v", right)
	}
	// Side by side, a downward flow still goes straight across rather than looping.
	beside := b.tile(400, 0)
	across := b.arrow(a, beside, "", "avoid")
	straight := geometry(t, []model.Object{a, beside, b.group([]model.Object{a, beside}, "down"), across}, nil).Routes(nil, nil)[across.ID]
	for i := 1; i < len(straight); i++ {
		if straight[i].X < straight[i-1].X-0.5 {
			t.Errorf("monotone: %v", straight)
		}
	}
}

func TestALineBoundEndKeepsItsRowWhileOthersSpread(t *testing.T) {
	code := Rect{0, 0, 300, 400}
	targets := []Rect{{700, 0, 200, 100}, {700, 300, 200, 100}}
	router := Router{Connectors: []Connector{
		{ID: "row", From: RowEnd(code, 130), To: RectEnd(targets[0]), FromObject: "code", ToObject: "t0"},
		{ID: "whole", From: RectEnd(code), To: RectEnd(targets[1]), FromObject: "code", ToObject: "t1"},
	}, Obstacles: []Obstacle{{"code", code}, {"t0", targets[0]}, {"t1", targets[1]}}}
	paths := router.Route(nil).Paths
	if paths["row"][0].Y != 130 || !(paths["row"][0].X > code.MaxX()) {
		t.Errorf("row end: %v", paths["row"])
	}
	if paths["whole"][0] == paths["row"][0] {
		t.Errorf("whole shares the row's port: %v", paths["whole"])
	}
}

func TestRoutingIsDeterministic(t *testing.T) {
	objects := atlas(t)
	first := geometry(t, objects, nil).Routing(nil)
	for range 3 {
		reversed := slices.Clone(objects)
		slices.Reverse(reversed)
		again := geometry(t, reversed, nil).Routing(nil)
		if !sameRouting(first, again) {
			t.Fatal("the same board routed differently")
		}
	}
}

func sameRouting(a, b *Result) bool {
	if len(a.Paths) != len(b.Paths) || len(a.Labels) != len(b.Labels) {
		return false
	}
	for id, p := range a.Paths {
		if !pathEqual(p, b.Paths[id]) {
			return false
		}
	}
	for id, l := range a.Labels {
		if other, ok := b.Labels[id]; !ok || !l.equal(other) {
			return false
		}
	}
	return true
}

func TestTheAtlasBoardRoutesWithoutSharedRunsArrowsThroughTilesOrCoveredLabels(t *testing.T) {
	check := geometry(t, atlas(t), nil).LayoutCheck(nil, nil)
	if len(check.ArrowOverlaps) != 0 {
		t.Errorf("arrow overlaps: %+v", check.ArrowOverlaps)
	}
	if len(check.Crossings) != 0 {
		t.Errorf("crossings: %+v", check.Crossings)
	}
	if len(check.LabelOverlaps) != 0 {
		t.Errorf("no label on a tile, title, label, or line: %+v", check.LabelOverlaps)
	}
}

// atlasDrop: the Atlas board with its lowest Ingress note moved by dx, dy: that note's frame,
// and the board as the drop commits it (the note moved, its group re-fitted around it).
func atlasDrop(t *testing.T, dx, dy float64) (objects []model.Object, note string, held Rect, committed []model.Object) {
	objects = atlas(t)
	var ingress model.Object
	for _, o := range objects {
		if o.Type == model.Group && o.Props["title"] == "Ingress" {
			ingress = o
		}
	}
	spec, _ := ParseGroup(ingress.Props)
	var lowest *model.Object
	for i, o := range objects {
		if slices.Contains(spec.Members, o.ID) && (lowest == nil || o.Frame.Y > lowest.Frame.Y) {
			lowest = &objects[i]
		}
	}
	held = RectOf(lowest.Frame).Offset(dx, dy)
	note = lowest.ID
	var members []Rect
	for _, o := range objects {
		if o.ID == note {
			o.Frame = held.Frame()
		}
		if slices.Contains(spec.Members, o.ID) {
			members = append(members, RectOf(o.Frame))
		}
		committed = append(committed, o)
	}
	fitted, _ := spec.FrameAround(members)
	for i := range committed {
		if committed[i].ID == ingress.ID {
			committed[i].Frame = fitted.Frame()
		}
	}
	return objects, note, held, committed
}

func regionFrames(regions []Region) ([]string, []Rect) {
	var ids []string
	var frames []Rect
	for _, r := range regions {
		ids = append(ids, r.ID)
		frames = append(frames, r.Frame)
	}
	return ids, frames
}

func TestAHeldTileRoutesWithTheGroupFramesItsDropCommits(t *testing.T) {
	objects, note, held, committed := atlasDrop(t, 40, 120)
	wantIDs, want := regionFrames(geometry(t, committed, nil).Regions())
	// Mid-drag the model still has the note and its group where they were.
	gotIDs, got := regionFrames(geometry(t, objects, nil).RegionsShown(map[string]Rect{note: held}))
	if !slices.Equal(gotIDs, wantIDs) || !slices.Equal(got, want) {
		t.Errorf("the held note's group as the drop fits it, the others as they are: %v vs %v", got, want)
	}
	_, stale := regionFrames(geometry(t, objects, nil).Regions())
	if slices.Equal(stale, want) {
		t.Error("the model's own frames are stale until the drop")
	}
	var frame Rect
	for _, o := range objects {
		if o.ID == note {
			frame = RectOf(o.Frame)
		}
	}
	_, still := regionFrames(geometry(t, objects, nil).RegionsShown(map[string]Rect{note: frame}))
	if !slices.Equal(still, stale) {
		t.Error("nothing shown away from its frame: the board's regions")
	}
}

func TestAHeldTileRefitsNestedGroupsOutward(t *testing.T) {
	var b board
	a, c, d, e, f := b.tile(0, 0), b.tile(0, 200), b.tile(400, 0), b.tile(1200, 0), b.tile(1200, 200)
	inner := b.group([]model.Object{a, c}, "")
	outer := b.group([]model.Object{d}, "")
	nested := outer
	nested.Props = map[string]any{"members": []any{inner.ID, d.ID}, "title": "Lane"}
	innerSpec, _ := ParseGroup(inner.Props)
	nestedSpec, _ := ParseGroup(nested.Props)
	innerRect, _ := innerSpec.FrameAround([]Rect{RectOf(a.Frame), RectOf(c.Frame)})
	nestedRect, _ := nestedSpec.FrameAround([]Rect{innerRect, RectOf(d.Frame)})
	nested.Frame = nestedRect.Frame()
	apart := b.group([]model.Object{e, f}, "")
	held := RectOf(c.Frame).Offset(-150, 300)
	regions := geometry(t, []model.Object{a, c, d, e, f, inner, nested, apart}, nil).RegionsShown(map[string]Rect{c.ID: held})
	frameOf := func(id string) Rect {
		for _, r := range regions {
			if r.ID == id {
				return r.Frame
			}
		}
		return NullRect
	}
	innerHeld, _ := innerSpec.FrameAround([]Rect{RectOf(a.Frame), held})
	nestedHeld, _ := nestedSpec.FrameAround([]Rect{innerHeld, RectOf(d.Frame)})
	if frameOf(inner.ID) != innerHeld {
		t.Errorf("inner %v want %v", frameOf(inner.ID), innerHeld)
	}
	if frameOf(nested.ID) != nestedHeld {
		t.Errorf("outer %v want %v", frameOf(nested.ID), nestedHeld)
	}
	if frameOf(apart.ID) != RectOf(apart.Frame) {
		t.Error("a group without the held tile stays put")
	}
}

func TestADropSettlesOnceAndSettlingAgainChangesNothing(t *testing.T) {
	objects, _, _, committed := atlasDrop(t, 40, 120)
	before := geometry(t, objects, nil).Routing(nil)
	// The settle while the note is held (routed with the regions the drop commits) …
	held := geometry(t, committed, before).Routing(nil)
	if sameRouting(held, before) {
		t.Error("the held note's arrows follow it")
	}
	// … is what the drop settles to: settling the same board again changes nothing.
	if dropped := geometry(t, committed, held).Routing(nil); !sameRouting(dropped, held) {
		t.Error("settling again changed the routing")
	}
}

func TestALabelInABundleNamesItsOwnLine(t *testing.T) {
	objects := atlas(t)
	routing := geometry(t, objects, nil).Routing(nil)
	spacing := ParallelSpacing
	// The fan-in from Ingress into Dispatch: six lines share one trunk 8 pt apart.
	for _, caption := range []string{"text trigger", "matching routines", "timer occurrence", "continuation triggers"} {
		var arrow model.Object
		for _, o := range objects {
			if o.Props["label"] == caption {
				arrow = o
			}
		}
		label, own := routing.Labels[arrow.ID], routing.Paths[arrow.ID]
		var others [][]Point
		for id, p := range routing.Paths {
			if id != arrow.ID {
				others = append(others, p)
			}
		}
		near := false
		for _, p := range others {
			if PathCrosses(p, label.Rect.InsetBy(-1.5*spacing, -1.5*spacing)) {
				near = true
			}
		}
		if !near {
			continue
		}
		// Beside the bundle, the chip is led to a stretch of its own line no other line runs by.
		if len(label.Leader) == 0 {
			t.Errorf("%s sits by other lines with nothing tying it to its own", caption)
			continue
		}
		foot := label.Leader[0]
		if DistanceToPath(foot, own) >= 0.5 {
			t.Errorf("%s's leader starts off its own line", caption)
		}
		for _, p := range others {
			if DistanceToPath(foot, p) < spacing/2 {
				t.Errorf("%s's leader starts where another line runs by", caption)
			}
		}
	}
}

func TestLayoutCheckReportsArrowsOnTopOfOrCrossingEachOther(t *testing.T) {
	var b board
	under := b.line(Point{0, 100}, Point{400, 100})
	over := b.line(Point{200, 100}, Point{600, 100})
	across := b.line(Point{100, 0}, Point{100, 300})
	check := geometry(t, []model.Object{under, over, across}, nil).LayoutCheck(nil, nil)
	pair := func(arrows [2]string, a, c string) bool {
		return (arrows[0] == a && arrows[1] == c) || (arrows[0] == c && arrows[1] == a)
	}
	found := false
	for _, o := range check.ArrowOverlaps {
		if pair(o.Arrows, under.ID, over.ID) {
			found = math.Abs(o.Length-200) < 1
		}
	}
	if !found {
		t.Errorf("overlap of 200: %+v", check.ArrowOverlaps)
	}
	crossed, wrong := false, false
	for _, x := range check.ArrowIntersections {
		if pair(x.Arrows, under.ID, across.ID) && x.Count == 1 {
			crossed = true
		}
		if pair(x.Arrows, over.ID, across.ID) {
			wrong = true
		}
	}
	if !crossed || wrong {
		t.Errorf("intersections: %+v", check.ArrowIntersections)
	}
	scoped := geometry(t, []model.Object{under, over, across}, nil).LayoutCheck(map[string]bool{over.ID: true}, nil)
	if len(scoped.ArrowIntersections) != 0 {
		t.Errorf("scoped to what's involved: %+v", scoped.ArrowIntersections)
	}
}

func TestLayoutCheckHintsAtColoringManyLabelledArrowsThatShareOneColor(t *testing.T) {
	var b board
	f := b.fanIn(true)
	colored := func(arrow model.Object, color string) model.Object {
		c := arrow.Clone()
		c.Props["color"] = color
		return c
	}
	var grey []model.Object
	for _, a := range f.arrows {
		grey = append(grey, colored(a, "grey"))
	}
	tiles := append(append([]model.Object(nil), f.sources...), f.target)
	hints := geometry(t, slices.Concat(tiles, grey), nil).LayoutCheck(nil, nil).Hints
	if len(hints) != 1 || !strings.Contains(hints[0], "8 labelled arrows are all grey") {
		t.Errorf("hints %v", hints)
	}
	if h := geometry(t, slices.Concat(tiles, grey[:6]), nil).LayoutCheck(nil, nil).Hints; len(h) != 0 {
		t.Errorf("six are few enough to tell apart: %v", h)
	}
	mixed := slices.Concat(tiles, grey[:len(grey)-1], []model.Object{colored(grey[len(grey)-1], "blue")})
	if h := geometry(t, mixed, nil).LayoutCheck(nil, nil).Hints; len(h) != 0 {
		t.Errorf("already colored by flow: %v", h)
	}
	if h := geometry(t, slices.Concat(tiles, f.arrows), nil).LayoutCheck(nil, nil).Hints; len(h) != 1 {
		t.Errorf("the default ink counts as one color: %v", h)
	}
}
