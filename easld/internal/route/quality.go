package route

import (
	"math"
	"sort"
)

// OverlapTolerance: lines nearer than this read as one (a stroke is 2 points wide and wanders
// up to 2).
const OverlapTolerance = 3.0

// ArrowOverlap is two arrows drawn on top of each other for Length points, first at At.
type ArrowOverlap struct {
	Arrows [2]string
	Length float64
	At     Point
}

// ArrowIntersection is two arrows whose lines cross Count times, first at At.
type ArrowIntersection struct {
	Arrows [2]string
	Count  int
	At     Point
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// ArrowOverlaps is ConnectorRouter.overlaps: pairs of arrows (ids sorted) that share length,
// sorted by ids; runs shorter than 2 points (a touch at a corner) don't count.
func ArrowOverlaps(paths map[string][]Point) []ArrowOverlap {
	ids := sortedKeys(paths)
	segments := make([][]axisSegment, len(ids))
	for i, id := range ids {
		segments[i] = axisSegments(paths[id])
	}
	var result []ArrowOverlap
	for a := range ids {
		for b := a + 1; b < len(ids); b++ {
			length := 0.0
			var at *Point
			for _, s := range segments[a] {
				for _, t := range segments[b] {
					if s.vertical != t.vertical || !(math.Abs(s.coord-t.coord) < OverlapTolerance) {
						continue
					}
					low, high := swiftMax(s.low, t.low), swiftMin(s.high, t.high)
					if !(high-low >= 2) {
						continue
					}
					length += high - low
					if at == nil {
						p := Point{(low + high) / 2, s.coord}
						if s.vertical {
							p = Point{s.coord, (low + high) / 2}
						}
						at = &p
					}
				}
			}
			if at != nil {
				result = append(result, ArrowOverlap{Arrows: [2]string{ids[a], ids[b]}, Length: length, At: *at})
			}
		}
	}
	return result
}

// ArrowIntersections is ConnectorRouter.intersections: pairs of arrows (ids sorted) whose lines
// cross, sorted by ids.
func ArrowIntersections(paths map[string][]Point) []ArrowIntersection {
	ids := sortedKeys(paths)
	var result []ArrowIntersection
	for a := range ids {
		p := paths[ids[a]]
		for b := a + 1; b < len(ids); b++ {
			q := paths[ids[b]]
			count := 0
			var at *Point
			for i := range len(p) - 1 {
				for j := range len(q) - 1 {
					if !properlyIntersect(p[i], p[i+1], q[j], q[j+1]) {
						continue
					}
					count++
					if at == nil {
						x := intersection(p[i], p[i+1], q[j], q[j+1])
						at = &x
					}
				}
			}
			if at != nil {
				result = append(result, ArrowIntersection{Arrows: [2]string{ids[a], ids[b]}, Count: count, At: *at})
			}
		}
	}
	return result
}

type axisSegment struct {
	vertical         bool
	coord, low, high float64
}

func axisSegments(path []Point) []axisSegment {
	var out []axisSegment
	for i := range len(path) - 1 {
		a, b := path[i], path[i+1]
		if math.Abs(a.X-b.X) < 0.01 && math.Abs(a.Y-b.Y) > 0.01 {
			out = append(out, axisSegment{true, a.X, swiftMin(a.Y, b.Y), swiftMax(a.Y, b.Y)})
		} else if math.Abs(a.Y-b.Y) < 0.01 && math.Abs(a.X-b.X) > 0.01 {
			out = append(out, axisSegment{false, a.Y, swiftMin(a.X, b.X), swiftMax(a.X, b.X)})
		}
	}
	return out
}

func intersection(a, b, c, d Point) Point {
	r := Point{b.X - a.X, b.Y - a.Y}
	s := Point{d.X - c.X, d.Y - c.Y}
	denominator := float64(r.X*s.Y) - float64(r.Y*s.X)
	if !(math.Abs(denominator) > 1e-9) {
		return a
	}
	t := (float64((c.X-a.X)*s.Y) - float64((c.Y-a.Y)*s.X)) / denominator
	return Point{a.X + float64(t*r.X), a.Y + float64(t*r.Y)}
}
