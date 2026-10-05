package route

import (
	"fmt"
	"sort"
	"strings"

	"github.com/twaldin/easl/easld/internal/model"
)

// SameColorLimit: labelled arrows past which one shared color gets a hint to color them by lane
// or flow.
const SameColorLimit = 6

// Report is BoardGeometry.LayoutReport: what layout.check finds about placement and arrows.
type Report struct {
	// Overlaps: pairs (sorted ids) whose frames overlap by accident.
	Overlaps [][]string
	// Crossings: arrows whose route runs through objects other than their own ends.
	Crossings []Crossing
	// LabelOverlaps: arrows whose label lies on a tile, text, or filled shape, a group's title,
	// another arrow's label, or another arrow's line.
	LabelOverlaps []LabelOverlap
	// ArrowOverlaps: pairs of arrows drawn on top of each other along some length.
	ArrowOverlaps []ArrowOverlap
	// ArrowIntersections: pairs of arrows whose lines cross.
	ArrowIntersections []ArrowIntersection
	// Hints: advice that isn't a fault.
	Hints []string
}

// Crossing is an arrow and the objects its route runs through.
type Crossing struct {
	Arrow   string
	Crosses []string
}

// LabelOverlap is an arrow's label lying on something.
type LabelOverlap struct {
	Arrow string
	// Label is the caption as drawn (`label`, else `relation`).
	Label string
	// Frame is where the label chip is drawn.
	Frame model.Frame
	// Overlaps: objects under the label; an arrow id means that arrow's label, a group id its
	// title.
	Overlaps []string
	// Lines: other arrows whose line runs under the label.
	Lines []string
}

// LayoutCheck is BoardGeometry.layoutCheck(scope:rows:): overlaps, arrow crossings, label
// overlaps, and arrows overlapping or crossing each other, involving `scope` (every object when
// nil): an arrow crossing or a label lying on a scoped object is reported whether or not the
// arrow is in scope. Routes and labels are computed as drawn (Routing); an arrow never crosses
// its own ends or what contains them.
func (g Geometry) LayoutCheck(scope map[string]bool, rows map[string]CodeRows) Report {
	involved := func(arrow string, others ...string) bool {
		if scope == nil || scope[arrow] {
			return true
		}
		for _, o := range others {
			if scope[o] {
				return true
			}
		}
		return false
	}
	report := Report{Overlaps: overlaps(g.Objects, scope), Crossings: []Crossing{}, LabelOverlaps: []LabelOverlap{}, Hints: []string{}}
	routing := g.Routing(rows)
	routes := routing.Paths
	blockers := sortedObjects(g.Objects, BlocksRoutes)
	for _, arrowID := range sortedKeys(routes) {
		path := routes[arrowID]
		o, ok := g.Objects[arrowID]
		if !ok {
			continue
		}
		spec, ok := ParseArrow(o.Props)
		if !ok {
			continue
		}
		var endRects []Rect
		endIDs := map[string]bool{}
		for _, b := range []Binding{spec.From, spec.To} {
			if !b.IsPoint() {
				endIDs[b.Object] = true
				if end, ok := g.Objects[b.Object]; ok {
					endRects = append(endRects, RectOf(end.Frame))
				}
			} else {
				endRects = append(endRects, Rect{X: b.Point.X, Y: b.Point.Y})
			}
		}
		var crossed []string
		for _, blocker := range blockers {
			rect := RectOf(blocker.Frame)
			if endIDs[blocker.ID] {
				continue
			}
			holdsEnd := false
			for _, e := range endRects {
				// A zero-size end rect is a point (CGRect.contains(point)), else the rect.
				if e.W == 0 && e.H == 0 {
					holdsEnd = rect.Contains(Point{e.X, e.Y})
				} else {
					holdsEnd = rect.ContainsRect(e)
				}
				if holdsEnd {
					break
				}
			}
			if !holdsEnd && PathCrosses(path, rect) {
				crossed = append(crossed, blocker.ID)
			}
		}
		if len(crossed) > 0 && involved(arrowID, crossed...) {
			report.Crossings = append(report.Crossings, Crossing{Arrow: arrowID, Crosses: crossed})
		}
	}
	regions := g.Regions()
	labels := map[string]Rect{}
	for id, l := range routing.Labels {
		labels[id] = l.Rect
	}
	for _, arrowID := range sortedKeys(labels) {
		inner := labels[arrowID].InsetBy(0.5, 0.5)
		under := []string{}
		for _, b := range blockers {
			if RectOf(b.Frame).Intersects(inner) {
				under = append(under, b.ID)
			}
		}
		for _, r := range regions {
			if r.Title().Intersects(inner) {
				under = append(under, r.ID)
			}
		}
		var others []string
		for id, rect := range labels {
			if id != arrowID && rect.Intersects(inner) {
				others = append(others, id)
			}
		}
		sort.Strings(others)
		under = append(under, others...)
		lines := []string{}
		for id, route := range routes {
			if id == arrowID {
				continue
			}
			for i := range len(route) - 1 {
				if segmentIntersects(route[i], route[i+1], inner) {
					lines = append(lines, id)
					break
				}
			}
		}
		sort.Strings(lines)
		if len(under) == 0 && len(lines) == 0 {
			continue
		}
		if !involved(arrowID, append(append([]string(nil), under...), lines...)...) {
			continue
		}
		o, ok := g.Objects[arrowID]
		if !ok {
			continue
		}
		spec, ok := ParseArrow(o.Props)
		if !ok {
			continue
		}
		report.LabelOverlaps = append(report.LabelOverlaps, LabelOverlap{Arrow: arrowID, Label: spec.Caption(), Frame: labels[arrowID].Frame(), Overlaps: under, Lines: lines})
	}
	report.ArrowOverlaps = []ArrowOverlap{}
	for _, o := range ArrowOverlaps(routes) {
		if involved(o.Arrows[0], o.Arrows[1]) {
			report.ArrowOverlaps = append(report.ArrowOverlaps, o)
		}
	}
	report.ArrowIntersections = []ArrowIntersection{}
	for _, x := range ArrowIntersections(routes) {
		if involved(x.Arrows[0], x.Arrows[1]) {
			report.ArrowIntersections = append(report.ArrowIntersections, x)
		}
	}
	// Arrows drawn with a caption (`label`, else `relation`), as DrawingStyle.arrowLabel.
	labelled := 0
	colors := map[string]bool{}
	for _, o := range g.Objects {
		if o.Type != model.Arrow {
			continue
		}
		spec, ok := ParseArrow(o.Props)
		if !ok || spec.Caption() == "" {
			continue
		}
		var ends []string
		for _, b := range []Binding{spec.From, spec.To} {
			if !b.IsPoint() {
				ends = append(ends, b.Object)
			}
		}
		if !involved(o.ID, ends...) {
			continue
		}
		labelled++
		color := "black"
		if spec.Color != nil {
			color = strings.ToLower(*spec.Color)
		}
		colors[color] = true
	}
	if labelled > SameColorLimit && len(colors) == 1 {
		for color := range colors {
			report.Hints = append(report.Hints, fmt.Sprintf("%d labelled arrows are all %s: color them by lane or flow (props.color, e.g. blue for the request path, green for replies) so each label reads with its own line", labelled, color))
		}
	}
	return report
}
