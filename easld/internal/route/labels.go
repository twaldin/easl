package route

import (
	"math"
	"sort"
)

type labelCandidate struct {
	rect   Rect
	leader []Point
	// onLine: centred on its own route (the chip interrupts the line).
	onLine bool
	// bundled: beside a stretch of its route other arrows run alongside, or led from one.
	bundled bool
	// tethered: beside a bundled stretch of its own line, led to a stretch where it runs alone.
	tethered bool
}

// placeLabels decides where each caption goes: beside its arrow's segments (the ones no other
// arrow runs along first, longest first) from their middles outward; then on the line itself;
// then leaderReaches away with a leader. A spot keeps off tiles, title bands, other arrows' lines
// and labels. Labels with the fewest clear spots go first; one left without takes a spot a single
// other label is in the way of when that one can move, else the spot with the fewest collisions.
func placeLabels(connectors []Connector, routes [][]Point, obstacles, titles, groups []Rect) map[string]Label {
	var labelled []int
	for i, c := range connectors {
		if c.Label != nil && len(routes[i]) >= 2 {
			labelled = append(labelled, i)
		}
	}
	if len(labelled) == 0 {
		return map[string]Label{}
	}
	segs := newLabelSegments(routes, obstacles, titles, groups)
	candidates := map[int][]labelCandidate{}
	clearCount := map[int]int{}
	for _, index := range labelled {
		all := labelCandidates(routes[index], index, *connectors[index].Label, segs)
		// Acceptable spots, best first: clear beside or on the route, then beside it with another
		// line close by, then a clear leader.
		type scored struct {
			score, order int
			spot         labelCandidate
		}
		var open []scored
		for order, spot := range all {
			if score := segs.collisions(spot, index, nil, underCost); score < underCost {
				open = append(open, scored{score, order, spot})
			}
		}
		sort.SliceStable(open, func(a, b int) bool {
			if open[a].score != open[b].score {
				return open[a].score < open[b].score
			}
			return open[a].order < open[b].order
		})
		if len(open) == 0 {
			candidates[index] = all
		} else {
			spots := make([]labelCandidate, len(open))
			for k, s := range open {
				spots[k] = s.spot
			}
			candidates[index] = spots
		}
		clearCount[index] = len(open)
	}
	// clash: two placed labels in each other's way: chips closer than 2 points, or a leader
	// through the other chip.
	clash := func(a, b labelCandidate) bool {
		if a.rect.InsetBy(-2, -2).Intersects(b.rect.InsetBy(0.5, 0.5)) {
			return true
		}
		if len(a.leader) == 2 && segmentIntersects(a.leader[0], a.leader[1], b.rect) {
			return true
		}
		if len(b.leader) == 2 && segmentIntersects(b.leader[0], b.leader[1], a.rect) {
			return true
		}
		return false
	}
	order := append([]int(nil), labelled...)
	sort.SliceStable(order, func(a, b int) bool {
		ca, cb := clearCount[order[a]], clearCount[order[b]]
		if ca != cb {
			return ca < cb
		}
		return connectors[order[a]].ID < connectors[order[b]].ID
	})
	chosen := map[int]labelCandidate{}
	var stuck []int
	for _, index := range order {
		if clearCount[index] > 0 {
			placed := false
			for _, spot := range candidates[index] {
				free := true
				for _, other := range chosen {
					if clash(spot, other) {
						free = false
						break
					}
				}
				if free {
					chosen[index] = spot
					placed = true
					break
				}
			}
			if placed {
				continue
			}
		}
		stuck = append(stuck, index)
		placed := make([]Rect, 0, len(chosen))
		for _, c := range chosen {
			placed = append(placed, c.rect)
		}
		fewest := math.MaxInt
		for _, candidate := range candidates[index] {
			if count := segs.collisions(candidate, index, placed, fewest); count < fewest {
				fewest = count
				chosen[index] = candidate
			}
		}
	}
	// A label left without a clear spot takes one that a single other label is in the way of,
	// when that label has another clear spot.
	for _, index := range stuck {
		if !(clearCount[index] > 0) {
			continue
		}
	search:
		for _, spot := range candidates[index] {
			var blocking []int
			for key, value := range chosen {
				if key != index && clash(spot, value) {
					blocking = append(blocking, key)
				}
			}
			if len(blocking) != 1 || !(clearCount[blocking[0]] > 0) {
				continue
			}
			other := blocking[0]
			for _, mv := range candidates[other] {
				if clash(mv, spot) {
					continue
				}
				hit := false
				for key, value := range chosen {
					if key != index && key != other && clash(mv, value) {
						hit = true
						break
					}
				}
				if hit {
					continue
				}
				chosen[other] = mv
				chosen[index] = spot
				break search
			}
		}
	}
	result := map[string]Label{}
	for index, spot := range chosen {
		result[connectors[index].ID] = Label{Rect: spot.rect, Leader: spot.leader}
	}
	return result
}

// labelSegments: every route's segments, tiles, title bands, and group frames (whose borders a
// tether keeps off), for label collision tests.
type labelSegments struct {
	owners                    []int
	starts, ends              []Point
	bounds                    []Rect
	routes                    [][]Point
	obstacles, titles, groups []Rect
}

func newLabelSegments(routes [][]Point, obstacles, titles, groups []Rect) *labelSegments {
	s := &labelSegments{routes: routes, obstacles: obstacles, titles: titles, groups: groups}
	for owner, route := range routes {
		for i := range len(route) - 1 {
			a, b := route[i], route[i+1]
			s.owners = append(s.owners, owner)
			s.starts = append(s.starts, a)
			s.ends = append(s.ends, b)
			s.bounds = append(s.bounds, Rect{swiftMin(a.X, b.X), swiftMin(a.Y, b.Y), math.Abs(a.X - b.X), math.Abs(a.Y - b.Y)})
		}
	}
	return s
}

// othersNear: whether another arrow's line comes within `reach` of `rect`.
func (s *labelSegments) othersNear(rect Rect, owner int, reach float64) bool {
	area := rect.InsetBy(-reach, -reach)
	for k, o := range s.owners {
		if o == owner || !s.bounds[k].InsetBy(-0.5, -0.5).Intersects(area) {
			continue
		}
		if segmentIntersects(s.starts[k], s.ends[k], area) {
			return true
		}
	}
	return false
}

// othersCrossing: how many other arrows' segments cross segment a–b.
func (s *labelSegments) othersCrossing(a, b Point, owner int) int {
	box := Rect{swiftMin(a.X, b.X), swiftMin(a.Y, b.Y), math.Abs(a.X - b.X), math.Abs(a.Y - b.Y)}.InsetBy(-0.5, -0.5)
	count := 0
	for k, o := range s.owners {
		if o != owner && s.bounds[k].Intersects(box) && properlyIntersect(a, b, s.starts[k], s.ends[k]) {
			count++
		}
	}
	return count
}

// othersUnder: how many other arrows' segments run under `rect`.
func (s *labelSegments) othersUnder(rect Rect, owner int) int {
	count := 0
	for k, o := range s.owners {
		if o != owner && s.bounds[k].InsetBy(-0.5, -0.5).Intersects(rect) && segmentIntersects(s.starts[k], s.ends[k], rect) {
			count++
		}
	}
	return count
}

// collisions: how bad a label at `candidate` would be, 0 when clear, counted up to `limit`: a
// tile, title band, placed label, or its own route under it (unless on it) counts coverCost;
// another arrow's line under it underCost; a leader leaderCost; another arrow nearer than its own
// (beside the route) 1; each line its leader crosses 3, and each tile or label coverCost.
func (s *labelSegments) collisions(candidate labelCandidate, owner int, labels []Rect, limit int) int {
	rect := candidate.rect
	inner := rect.InsetBy(0.5, 0.5)
	count := 0
	for _, o := range s.obstacles {
		if o.Intersects(inner) {
			count += coverCost
			if count >= limit {
				return count
			}
		}
	}
	for _, t := range s.titles {
		if t.Intersects(inner) {
			count += coverCost
			if count >= limit {
				return count
			}
		}
	}
	for _, l := range labels {
		if l.InsetBy(-2, -2).Intersects(inner) {
			count += coverCost
			if count >= limit {
				return count
			}
		}
	}
	under := s.othersUnder(inner, owner)
	count += underCost * under
	if count >= limit {
		return count
	}
	if leader := candidate.leader; len(leader) == 2 {
		count += leaderCost
		if !candidate.tethered && hypot(leader[1].X-leader[0].X, leader[1].Y-leader[0].Y) > shortLeader+LabelClearance {
			count++
		}
		if under == 0 && s.othersNear(rect, owner, 3) {
			count++
		}
		count += 3 * s.othersCrossing(leader[0], leader[1], owner)
		for _, o := range s.obstacles {
			if segmentIntersects(leader[0], leader[1], o.InsetBy(0.5, 0.5)) {
				count += coverCost
			}
		}
		for _, l := range labels {
			if segmentIntersects(leader[0], leader[1], l) {
				count += coverCost
			}
		}
	} else if under == 0 && !candidate.onLine && s.othersNear(rect, owner, LabelClearance-1) {
		count++
	}
	// A leader from a bundle costs what a spot beside it does.
	if candidate.bundled {
		if candidate.leader == nil {
			count += bundleCost
		} else {
			count += bundleCost - leaderCost
		}
	}
	if count < limit && !candidate.onLine && distanceFromPath(s.routes[owner], rect) < LabelClearance-1 {
		count += coverCost
	}
	return count
}

type stretch struct{ lo, hi float64 }

func labelCandidates(route []Point, owner int, size Size, segs *labelSegments) []labelCandidate {
	spacing := ParallelSpacing * 1.5
	// Each segment's length that no other arrow runs alongside (within 1.5 track spacings).
	type ranked struct {
		index            int
		distinct, length float64
	}
	var ranks []ranked
	// The stretches of each segment other arrows run alongside (bundled), and those no other line
	// runs closer to than half a track spacing (where a leader's foot names this line alone).
	bundles := map[int][]stretch{}
	alone := map[int][]stretch{}
	for index := range len(route) - 1 {
		a, b := route[index], route[index+1]
		horizontal := math.Abs(a.Y-b.Y) < 0.5
		vertical := math.Abs(a.X-b.X) < 0.5
		length := hypot(b.X-a.X, b.Y-a.Y)
		if !(length > 0.5) {
			continue
		}
		low, high := swiftMin(a.Y, b.Y), swiftMax(a.Y, b.Y)
		if horizontal {
			low, high = swiftMin(a.X, b.X), swiftMax(a.X, b.X)
		}
		var covered, close []stretch
		if horizontal || vertical {
			for k, o := range segs.owners {
				if o == owner {
					continue
				}
				p, q := segs.starts[k], segs.ends[k]
				var parallel bool
				var gap, pl, ph float64
				if horizontal {
					parallel, gap = math.Abs(p.Y-q.Y) < 0.5, math.Abs(p.Y-a.Y)
					pl, ph = swiftMin(p.X, q.X), swiftMax(p.X, q.X)
				} else {
					parallel, gap = math.Abs(p.X-q.X) < 0.5, math.Abs(p.X-a.X)
					pl, ph = swiftMin(p.Y, q.Y), swiftMax(p.Y, q.Y)
				}
				if !parallel || !(gap < spacing) {
					continue
				}
				l, h := swiftMax(low, pl), swiftMin(high, ph)
				if !(h > l) {
					continue
				}
				covered = append(covered, stretch{l, h})
				if gap < ParallelSpacing/2 {
					close = append(close, stretch{l, h})
				}
			}
		}
		union := 0.0
		reach := math.Inf(-1)
		sortedCovered := append([]stretch(nil), covered...)
		sort.SliceStable(sortedCovered, func(x, y int) bool { return sortedCovered[x].lo < sortedCovered[y].lo })
		for _, st := range sortedCovered {
			start := swiftMax(st.lo, reach)
			if st.hi > start {
				union += st.hi - start
			}
			reach = swiftMax(reach, st.hi)
		}
		ranks = append(ranks, ranked{index, length - union, length})
		bundles[index] = covered
		if !(horizontal || vertical) {
			continue
		}
		var free []stretch
		open := low
		sort.SliceStable(close, func(x, y int) bool { return close[x].lo < close[y].lo })
		for _, st := range close {
			if st.lo > open {
				free = append(free, stretch{open, st.lo})
			}
			open = swiftMax(open, st.hi)
		}
		if high > open {
			free = append(free, stretch{open, high})
		}
		var kept []stretch
		for _, st := range free {
			if st.hi-st.lo >= 8 {
				kept = append(kept, st)
			}
		}
		alone[index] = kept
	}
	// Descending by (distinct, length, -index).
	sort.SliceStable(ranks, func(x, y int) bool {
		a, b := ranks[x], ranks[y]
		if a.distinct != b.distinct {
			return a.distinct > b.distinct
		}
		if a.length != b.length {
			return a.length > b.length
		}
		return -a.index > -b.index
	})
	// fractions: spots along a segment of `length`, from its middle outward, about every 12 pt.
	fractions := func(length float64) []float64 {
		steps := max(2, min(24, int(length/12)))
		out := make([]float64, steps+1)
		for k := range out {
			out[k] = float64(k) / float64(steps)
		}
		sort.SliceStable(out, func(x, y int) bool {
			dx, dy := math.Abs(out[x]-0.5), math.Abs(out[y]-0.5)
			if dx != dy {
				return dx < dy
			}
			return out[x] < out[y]
		})
		return out
	}
	w, h := size.W, size.H
	clearance := LabelClearance
	first, last := route[0], route[len(route)-1]
	var result []labelCandidate
	// bundled: whether a chip beside segment `index` spanning low…high along it (a leader: its
	// foot) sits by a bundled stretch.
	bundled := func(index int, low, high float64) bool {
		for _, st := range bundles[index] {
			if swiftMin(st.hi, high)-swiftMax(st.lo, low) > 0 {
				return true
			}
		}
		return false
	}
	aloneKeys := make([]int, 0, len(alone))
	for k := range alone {
		aloneKeys = append(aloneKeys, k)
	}
	sort.Ints(aloneKeys)
	// tether: the shortest leader from `chip` straight to a stretch where the route runs alone,
	// within the chip's extent, longer than the chip's clearance and no longer than the longest
	// leader.
	tether := func(chip Rect) []Point {
		var best []Point
		shortest := leaderReaches[len(leaderReaches)-1] + clearance
		for _, index := range aloneKeys {
			stretches := alone[index]
			a, b := route[index], route[index+1]
			horizontal := math.Abs(a.Y-b.Y) < 0.5
			var across, s0, s1, near, far float64
			if horizontal {
				across, s0, s1 = a.Y, chip.MinX()+4, chip.MaxX()-4
				near, far = chip.MinY(), chip.MaxY()
			} else {
				across, s0, s1 = a.X, chip.MinY()+4, chip.MaxY()-4
				near, far = chip.MinX(), chip.MaxX()
			}
			if !(across < near || across > far) {
				continue
			}
			edge := far
			if across < near {
				edge = near
			}
			length := math.Abs(edge - across)
			if !(length > clearance+1 && length < shortest) {
				continue
			}
			for _, st := range stretches {
				from, to := swiftMax(st.lo, s0), swiftMin(st.hi, s1)
				if !(to >= from) {
					continue
				}
				// Off group borders it would run along: the spot in the stretch farthest from them
				// (up to borderClearance), nearest its middle.
				low, high := swiftMin(across, edge), swiftMax(across, edge)
				var borders []float64
				for _, f := range segs.groups {
					start, end := f.MinX(), f.MaxX()
					if horizontal {
						start, end = f.MinY(), f.MaxY()
					}
					if !(start < high && end > low) {
						continue
					}
					if horizontal {
						borders = append(borders, f.MinX(), f.MaxX())
					} else {
						borders = append(borders, f.MinY(), f.MaxY())
					}
				}
				middle := (from + to) / 2
				spots := []float64{middle, from, to}
				for _, bd := range borders {
					for _, v := range []float64{bd - borderClearance, bd + borderClearance} {
						if v >= from && v <= to {
							spots = append(spots, v)
						}
					}
				}
				room := func(t float64) float64 {
					if len(borders) == 0 {
						return borderClearance
					}
					least := math.Abs(borders[0] - t)
					for _, bd := range borders[1:] {
						if d := math.Abs(bd - t); d < least {
							least = d
						}
					}
					return swiftMin(borderClearance, least)
				}
				// max by (room, -|t - middle|): the first of equals.
				t := spots[0]
				for _, v := range spots[1:] {
					rt, rv := room(t), room(v)
					if rt < rv || (rt == rv && -math.Abs(t-middle) < -math.Abs(v-middle)) {
						t = v
					}
				}
				if horizontal {
					best = []Point{{t, across}, {t, edge}}
				} else {
					best = []Point{{across, t}, {edge, t}}
				}
				shortest = length
				break
			}
		}
		return best
	}
	// Beside the route, on it (-1), then leaders.
	reaches := []float64{clearance, -1}
	for _, r := range leaderReaches {
		reaches = append(reaches, r+clearance)
	}
	for _, reach := range reaches {
		onLine := reach < 0
		leader := reach > clearance
		for _, seg := range ranks {
			a, b := route[seg.index], route[seg.index+1]
			horizontal := math.Abs(a.Y-b.Y) < 0.5
			vertical := math.Abs(a.X-b.X) < 0.5
			for _, fraction := range fractions(seg.length) {
				switch {
				case horizontal:
					low, high := swiftMin(a.X, b.X), swiftMax(a.X, b.X)
					x := low + float64((high-low)*fraction)
					if high-low >= w {
						x = swiftMin(swiftMax(x, low+w/2), high-w/2)
					}
					if onLine {
						result = append(result, labelCandidate{rect: Rect{x - w/2, a.Y - h/2, w, h}, onLine: true})
						continue
					}
					// Centred on the spot, or (a segment shorter than the chip) hanging off either
					// end of it.
					shifts := []float64{0}
					if !(high-low >= w) {
						shifts = []float64{0, w/2 - 10, 10 - w/2}
					}
					for _, shift := range shifts {
						above := Rect{x - w/2 + shift, a.Y - reach - h, w, h}
						below := Rect{x - w/2 + shift, a.Y + reach, w, h}
						ca := labelCandidate{rect: above}
						cb := labelCandidate{rect: below}
						if leader {
							ca.leader = []Point{{x, a.Y}, {x, above.MaxY()}}
							cb.leader = []Point{{x, a.Y}, {x, below.MinY()}}
							ca.bundled = bundled(seg.index, x-0.5, x+0.5)
							cb.bundled = ca.bundled
						} else {
							ca.bundled = bundled(seg.index, above.MinX(), above.MaxX())
							cb.bundled = bundled(seg.index, below.MinX(), below.MaxX())
						}
						result = append(result, ca, cb)
					}
				case vertical:
					low, high := swiftMin(a.Y, b.Y), swiftMax(a.Y, b.Y)
					y := low + float64((high-low)*fraction)
					if high-low >= h {
						y = swiftMin(swiftMax(y, low+h/2), high-h/2)
					}
					if onLine {
						result = append(result, labelCandidate{rect: Rect{a.X - w/2, y - h/2, w, h}, onLine: true})
						continue
					}
					right := Rect{a.X + reach, y - h/2, w, h}
					left := Rect{a.X - reach - w, y - h/2, w, h}
					var spanBundled bool
					if leader {
						spanBundled = bundled(seg.index, y-0.5, y+0.5)
					} else {
						spanBundled = bundled(seg.index, y-h/2, y+h/2)
					}
					cr := labelCandidate{rect: right, bundled: spanBundled}
					cl := labelCandidate{rect: left, bundled: spanBundled}
					if leader {
						cr.leader = []Point{{a.X, y}, {right.MinX(), y}}
						cl.leader = []Point{{a.X, y}, {left.MaxX(), y}}
					}
					result = append(result, cr, cl)
				default:
					length := hypot(b.X-a.X, b.Y-a.Y)
					point := Point{a.X + float64((b.X-a.X)*fraction), a.Y + float64((b.Y-a.Y)*fraction)}
					if onLine {
						result = append(result, labelCandidate{rect: Rect{point.X - w/2, point.Y - h/2, w, h}, onLine: true})
						continue
					}
					normal := Point{(a.Y - b.Y) / length, (b.X - a.X) / length}
					if normal.Y > 0 {
						normal = Point{-normal.X, -normal.Y}
					}
					for _, sign := range []float64{1, -1} {
						n := Point{normal.X * sign, normal.Y * sign}
						lift := float64(math.Abs(n.X)*w)/2 + float64(math.Abs(n.Y)*h)/2 + reach
						center := Point{point.X + float64(n.X*lift), point.Y + float64(n.Y*lift)}
						rect := Rect{center.X - w/2, center.Y - h/2, w, h}
						edge := Point{center.X - float64(n.X*(lift-reach)), center.Y - float64(n.Y*(lift-reach))}
						c := labelCandidate{rect: rect}
						if leader {
							c.leader = []Point{point, edge}
						}
						result = append(result, c)
					}
				}
			}
		}
	}
	// A chip on the line never hides the arrowhead or the tail; one beside a bundle is tried
	// first led to where its line runs alone.
	var out []labelCandidate
	for _, spot := range result {
		if spot.onLine {
			if spot.rect.InsetBy(-12, -12).Contains(last) || spot.rect.InsetBy(-6, -6).Contains(first) {
				continue
			}
			out = append(out, spot)
			continue
		}
		if spot.bundled && spot.leader == nil {
			if leader := tether(spot.rect); leader != nil {
				out = append(out, labelCandidate{rect: spot.rect, leader: leader, tethered: true})
			}
		}
		out = append(out, spot)
	}
	return out
}

// properlyIntersect: whether segments a–b and c–d cross at a point inside both (touching ends
// or running along each other doesn't count).
func properlyIntersect(a, b, c, d Point) bool {
	cross := func(o, p, q Point) float64 {
		return float64((p.X-o.X)*(q.Y-o.Y)) - float64((p.Y-o.Y)*(q.X-o.X))
	}
	d1, d2, d3, d4 := cross(c, d, a), cross(c, d, b), cross(a, b, c), cross(a, b, d)
	scale := float64(swiftMax(1, float64(hypot(b.X-a.X, b.Y-a.Y)*hypot(d.X-c.X, d.Y-c.Y))) * 1e-6)
	return ((d1 > scale && d2 < -scale) || (d1 < -scale && d2 > scale)) && ((d3 > scale && d4 < -scale) || (d3 < -scale && d4 > scale))
}
