package route

import (
	"math"
	"sort"
)

// span is a closed range.
type span struct{ lo, hi float64 }

func (s span) contains(v float64) bool { return v >= s.lo && v <= s.hi }
func (s span) overlaps(o span) bool    { return s.lo <= o.hi && o.lo <= s.hi }

type turn struct{ at, way float64 }

type segment struct {
	route, index     int
	coord, low, high float64
	movable          bool
	// free: free space either side, up to the nearest tile.
	free span
	// hard: where it may move (its coordinate alone when fixed); soft: where it may move keeping
	// off borders and title bands.
	hard, soft span
	// turns: each end's position along the segment and which way (±1) the next segment turns.
	turns []turn
}

// nudge spreads collinear, overlapping segments of different arrows into parallel tracks: the
// vertical ones (`vertical`) along x, else the horizontal ones along y. Segments that overlap
// along their extent and see each other across free space (within three track spacings) share a
// channel; a channel's segments are ordered so their turns cross each other least, then placed as
// near where they were as that order allows, ParallelSpacing apart where the channel is wide
// enough, else as far apart as it is. Only interior segments of `movable` routes move; tracks
// keep trackClearance from tiles and, where there is room, borderClearance from group borders and
// title bands.
func nudge(routes [][]Point, movable []bool, obstacles []Rect, soft []softLine, vertical bool) {
	c := func(p Point) float64 {
		if vertical {
			return p.X
		}
		return p.Y
	}
	e := func(p Point) float64 {
		if vertical {
			return p.Y
		}
		return p.X
	}
	spanOf := func(r Rect) (c0, c1, e0, e1 float64) {
		if vertical {
			return r.MinX(), r.MaxX(), r.MinY(), r.MaxY()
		}
		return r.MinY(), r.MaxY(), r.MinX(), r.MaxX()
	}
	var segments []segment
	for r, points := range routes {
		if len(points) < 2 {
			continue
		}
		last := len(points) - 2
		for i := 0; i <= last; i++ {
			a, b := points[i], points[i+1]
			if !(math.Abs(c(a)-c(b)) < 0.01) || !(math.Abs(e(a)-e(b)) > 0.5) {
				continue
			}
			coord := c(a)
			low, high := swiftMin(e(a), e(b)), swiftMax(e(a), e(b))
			var turns []turn
			if i > 0 {
				turns = append(turns, turn{e(a), pick(c(points[i-1]) < coord, -1, 1)})
			}
			if i < last {
				turns = append(turns, turn{e(b), pick(c(points[i+2]) < coord, -1, 1)})
			}
			freeLow, freeHigh := math.Inf(-1), math.Inf(1)
			for _, rect := range obstacles {
				c0, c1, e0, e1 := spanOf(rect)
				if !(e0 < high+1 && e1 > low-1) {
					continue
				}
				if c1 <= coord {
					freeLow = swiftMax(freeLow, c1+trackClearance)
				} else if c0 >= coord {
					freeHigh = swiftMin(freeHigh, c0-trackClearance)
				}
			}
			freeLow = swiftMin(freeLow, coord)
			freeHigh = swiftMax(freeHigh, coord)
			seg := segment{route: r, index: i, coord: coord, low: low, high: high, movable: movable[r] && i > 0 && i < last,
				free: span{freeLow, freeHigh}, hard: span{coord, coord}, soft: span{coord, coord}, turns: turns}
			if seg.movable {
				lowBound, highBound := freeLow, freeHigh
				// Keep the first and last segments long enough, and pointing the same way.
				if i == 1 {
					port := c(points[0])
					if coord > port {
						lowBound = swiftMax(lowBound, port+minStub)
					} else {
						highBound = swiftMin(highBound, port-minStub)
					}
				}
				if i == last-1 {
					port := c(points[last+1])
					if port > coord {
						highBound = swiftMin(highBound, port-minStub)
					} else {
						lowBound = swiftMax(lowBound, port+minStub)
					}
				}
				lowBound = swiftMin(lowBound, coord)
				highBound = swiftMax(highBound, coord)
				// Borders and title bands split the free range into pieces; the segment keeps to
				// its own piece (the larger neighbour when it runs on or right by one),
				// borderClearance in from its ends.
				var cuts []span
				for _, line := range soft {
					if line.vertical != vertical {
						continue
					}
					c0, c1, e0, e1 := spanOf(line.rect)
					if !(e0 < high && e1 > low && c1 > lowBound-borderClearance && c0 < highBound+borderClearance) {
						continue
					}
					cuts = append(cuts, span{c0, c1})
				}
				sort.SliceStable(cuts, func(x, y int) bool { return cuts[x].lo < cuts[y].lo })
				var gaps []span
				previous := math.Inf(-1)
				for _, cut := range cuts {
					if cut.lo > previous {
						gaps = append(gaps, span{previous, cut.lo})
					}
					previous = swiftMax(previous, cut.hi)
				}
				gaps = append(gaps, span{previous, math.Inf(1)})
				type piece struct{ gap, usable span }
				var pieces []piece
				for _, gap := range gaps {
					usableLow := swiftMax(lowBound, gap.lo+borderClearance)
					usableHigh := swiftMin(highBound, gap.hi-borderClearance)
					if usableLow <= usableHigh {
						pieces = append(pieces, piece{gap, span{usableLow, usableHigh}})
					}
				}
				width := func(p piece) float64 { return p.usable.hi - p.usable.lo }
				distance := func(p piece) float64 { return swiftMax(p.usable.lo-coord, coord-p.usable.hi, 0) }
				seg.hard = span{lowBound, highBound}
				seg.soft = seg.hard
				// near.max(by: width), else pieces.min(by: distance): the first of equals.
				var chosen *piece
				for k := range pieces {
					p := pieces[k]
					if !(p.gap.lo-borderClearance < coord && coord < p.gap.hi+borderClearance) {
						continue
					}
					if chosen == nil || width(*chosen) < width(p) {
						chosen = &pieces[k]
					}
				}
				if chosen == nil {
					for k := range pieces {
						if chosen == nil || distance(pieces[k]) < distance(*chosen) {
							chosen = &pieces[k]
						}
					}
				}
				if chosen != nil {
					seg.soft = chosen.usable
				}
			}
			segments = append(segments, seg)
		}
	}
	if len(segments) == 0 {
		return
	}

	// Channels.
	spacing := ParallelSpacing
	parent := make([]int, len(segments))
	for i := range parent {
		parent[i] = i
	}
	root := func(a int) int {
		for parent[a] != a {
			parent[a] = parent[parent[a]]
			a = parent[a]
		}
		return a
	}
	byCoord := make([]int, len(segments))
	for i := range byCoord {
		byCoord[i] = i
	}
	sort.SliceStable(byCoord, func(x, y int) bool {
		a, b := byCoord[x], byCoord[y]
		if segments[a].coord != segments[b].coord {
			return segments[a].coord < segments[b].coord
		}
		return a < b
	})
	for position, a := range byCoord {
		sa := segments[a]
		for _, b := range byCoord[position+1:] {
			sb := segments[b]
			if !(sb.coord-sa.coord < 3*spacing) {
				break
			}
			if !(sa.movable || sb.movable || sb.coord-sa.coord < spacing-0.5) {
				continue
			}
			// Moving segments on either side of a border or title band are separate channels.
			if sa.movable && sb.movable && !sa.soft.overlaps(sb.soft) {
				continue
			}
			if sa.route == sb.route && !(abs(sa.index-sb.index) > 1) {
				continue
			}
			if !(swiftMin(sa.high, sb.high)-swiftMax(sa.low, sb.low) > -1 && sa.free.contains(sb.coord) && sb.free.contains(sa.coord)) {
				continue
			}
			parent[root(a)] = root(b)
		}
	}
	channels := map[int][]int{}
	for index := range segments {
		k := root(index)
		channels[k] = append(channels[k], index)
	}

	// crossings of the two segments' turns with each other when `a` lies before `b`.
	crossings := func(a, b segment) int {
		count := 0
		for _, t := range b.turns {
			if t.way < 0 && t.at > a.low+0.5 && t.at < a.high-0.5 {
				count++
			}
		}
		for _, t := range a.turns {
			if t.way > 0 && t.at > b.low+0.5 && t.at < b.high-0.5 {
				count++
			}
		}
		return count
	}
	feasible := func(order []int, bounds func(int) span, gap float64) bool {
		x := math.Inf(-1)
		for _, m := range order {
			x = swiftMax(bounds(m).lo, x+gap)
			if x > bounds(m).hi+0.001 {
				return false
			}
		}
		return true
	}

	type move struct {
		segment int
		coord   float64
	}
	var moved []move
	keys := make([]int, 0, len(channels))
	for k := range channels {
		keys = append(keys, k)
	}
	sort.Ints(keys)
	for _, key := range keys {
		members := channels[key]
		if len(members) == 1 {
			s := segments[members[0]]
			if s.movable && !s.soft.contains(s.coord) {
				moved = append(moved, move{members[0], swiftMin(swiftMax(s.coord, s.soft.lo), s.soft.hi)})
			}
			continue
		}
		anyMovable := false
		for _, m := range members {
			if segments[m].movable {
				anyMovable = true
			}
		}
		if !anyMovable {
			continue
		}
		// Each overlapping pair prefers the order in which their turns cross less; take an order
		// honouring those preferences (by position where none holds), breaking a cycle at the
		// segment fewest prefer to come after.
		less := func(a, b int) bool { // (coord, route, index)
			sa, sb := segments[a], segments[b]
			if sa.coord != sb.coord {
				return sa.coord < sb.coord
			}
			if sa.route != sb.route {
				return sa.route < sb.route
			}
			return sa.index < sb.index
		}
		after := map[int][]int{}
		waiting := map[int]int{}
		for position, a := range members {
			for _, b := range members[position+1:] {
				sa, sb := segments[a], segments[b]
				if !(swiftMin(sa.high, sb.high)-swiftMax(sa.low, sb.low) > -1) {
					continue
				}
				ab, ba := crossings(sa, sb), crossings(sb, sa)
				if ab == ba {
					continue
				}
				first, second := b, a
				if ab < ba {
					first, second = a, b
				}
				after[first] = append(after[first], second)
				waiting[second]++
			}
		}
		remaining := map[int]bool{}
		for _, m := range members {
			remaining[m] = true
		}
		var preferred []int
		for len(remaining) > 0 {
			next := -1
			for m := range remaining {
				if waiting[m] == 0 && (next < 0 || less(m, next)) {
					next = m
				}
			}
			if next < 0 {
				for m := range remaining {
					if next < 0 || waiting[m] < waiting[next] || (waiting[m] == waiting[next] && less(m, next)) {
						next = m
					}
				}
			}
			delete(remaining, next)
			preferred = append(preferred, next)
			for _, later := range after[next] {
				if remaining[later] {
					waiting[later]--
				}
			}
		}
		byPosition := append([]int(nil), members...)
		sort.SliceStable(byPosition, func(x, y int) bool { return less(byPosition[x], byPosition[y]) })
		type plan struct {
			order []int
			gap   float64
			soft  bool
		}
		var chosen *plan
	search:
		for _, attempt := range []struct {
			soft bool
			gaps []float64
		}{{true, []float64{spacing, 16, 13, 10, 8, 6}}, {false, []float64{spacing, 16, 13, 10, 8, 6, 4, 2}}} {
			bounds := func(m int) span {
				if attempt.soft {
					return segments[m].soft
				}
				return segments[m].hard
			}
			for _, order := range [][]int{preferred, byPosition} {
				for _, gap := range attempt.gaps {
					if feasible(order, bounds, gap) {
						chosen = &plan{order, gap, attempt.soft}
						break search
					}
				}
			}
		}
		if chosen == nil {
			continue
		}
		bounds := func(m int) span {
			if chosen.soft {
				return segments[m].soft
			}
			return segments[m].hard
		}
		order := chosen.order
		k := len(order)
		// Nearest to where they were, in order and `gap` apart (pool adjacent violators on
		// positions less their rank's share of the gaps), then within reach of the bounds.
		type pool struct {
			sum   float64
			count int
		}
		var pools []pool
		for rank, m := range order {
			pools = append(pools, pool{segments[m].coord - float64(float64(rank)*chosen.gap), 1})
			for len(pools) > 1 && pools[len(pools)-2].sum/float64(pools[len(pools)-2].count) > pools[len(pools)-1].sum/float64(pools[len(pools)-1].count) {
				top := pools[len(pools)-1]
				pools = pools[:len(pools)-1]
				pools[len(pools)-1].sum += top.sum
				pools[len(pools)-1].count += top.count
			}
		}
		var desired []float64
		for _, p := range pools {
			for range p.count {
				desired = append(desired, p.sum/float64(p.count))
			}
		}
		earliest := make([]float64, k)
		latest := make([]float64, k)
		x := math.Inf(-1)
		for rank, m := range order {
			x = swiftMax(bounds(m).lo, x+chosen.gap)
			earliest[rank] = x
		}
		x = math.Inf(1)
		for rank := k - 1; rank >= 0; rank-- {
			x = swiftMin(bounds(order[rank]).hi, x-chosen.gap)
			latest[rank] = x
		}
		for rank, m := range order {
			position := swiftMin(swiftMax(desired[rank]+float64(float64(rank)*chosen.gap), earliest[rank]), swiftMax(earliest[rank], latest[rank]))
			if segments[m].movable && math.Abs(position-segments[m].coord) > 0.001 {
				moved = append(moved, move{m, position})
			}
		}
	}
	for _, mv := range moved {
		s := segments[mv.segment]
		for _, p := range []int{s.index, s.index + 1} {
			if vertical {
				routes[s.route][p].X = mv.coord
			} else {
				routes[s.route][p].Y = mv.coord
			}
		}
	}
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
