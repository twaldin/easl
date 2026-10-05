package route

import (
	"math"
	"sort"
)

// grid is the orthogonal grid searches run on: what blocks each node and edge, what running each
// edge costs extra (group borders, title bands; float32 as in Swift), and which arrows use it.
type grid struct {
	xs, ys []float64
	nx, ny int
	// Obstacles whose inside covers the node / the edge to the right / the edge down.
	node, right, down []uint16
	// Extra cost per point of length of the edge to the right / down.
	rightFactor, downFactor []float32
	// Tiles' margins the edge to the right / down runs along: 2 is a one-track gap.
	rightHugs, downHugs []uint8
	// Arrows routed on the edge to the right / down.
	usedRight, usedDown []uint16
	best                []float64
	parent              []int32
	stamp               []uint32
	generation          uint32
}

const gridEpsilon = 0.001

func newGrid(xs, ys []float64, blocks []Rect, regions []Region) *grid {
	g := &grid{xs: gridLines(xs), ys: gridLines(ys)}
	g.nx, g.ny = len(g.xs), len(g.ys)
	if g.nx == 0 || g.ny == 0 || g.nx*g.ny > 1_000_000 {
		return nil
	}
	count := g.nx * g.ny
	g.node = make([]uint16, count)
	g.right = make([]uint16, count)
	g.down = make([]uint16, count)
	g.rightFactor = make([]float32, count)
	g.downFactor = make([]float32, count)
	g.rightHugs = make([]uint8, count)
	g.downHugs = make([]uint8, count)
	g.usedRight = make([]uint16, count)
	g.usedDown = make([]uint16, count)
	g.best = make([]float64, count*4)
	g.parent = make([]int32, count*4)
	g.stamp = make([]uint32, count*4)
	for i := range g.best {
		g.best[i] = math.Inf(1)
		g.parent[i] = -1
	}
	for _, r := range blocks {
		g.cover(r)
	}
	for _, r := range regions {
		g.soften(r)
	}
	return g
}

// gridLines: sorted, with values within 0.01 of each other merged.
func gridLines(values []float64) []float64 {
	finite := make([]float64, 0, len(values))
	for _, v := range values {
		if !math.IsInf(v, 0) && !math.IsNaN(v) {
			finite = append(finite, v)
		}
	}
	sort.Float64s(finite)
	var result []float64
	for _, v := range finite {
		if len(result) == 0 || v-result[len(result)-1] > 0.01 {
			result = append(result, v)
		}
	}
	return result
}

// lower: first index whose value is ≥ value - ε.
func (g *grid) lower(values []float64, value float64) int {
	low, high := 0, len(values)
	for low < high {
		mid := (low + high) / 2
		if values[mid] < value-gridEpsilon {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}

// upper: first index whose value is > value + ε.
func (g *grid) upper(values []float64, value float64) int {
	low, high := 0, len(values)
	for low < high {
		mid := (low + high) / 2
		if values[mid] <= value+gridEpsilon {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}

func (g *grid) index(p Point) (int, bool) {
	i := g.lower(g.xs, p.X-0.01)
	j := g.lower(g.ys, p.Y-0.01)
	if i >= g.nx || j >= g.ny || !(math.Abs(g.xs[i]-p.X) <= 0.01) || !(math.Abs(g.ys[j]-p.Y) <= 0.01) {
		return 0, false
	}
	return j*g.nx + i, true
}

func gridInside(r Rect, x, y float64) bool {
	return x > r.MinX()+gridEpsilon && x < r.MaxX()-gridEpsilon && y > r.MinY()+gridEpsilon && y < r.MaxY()-gridEpsilon
}

func spansRight(r Rect, x0, x1, y float64) bool {
	return y > r.MinY()+gridEpsilon && y < r.MaxY()-gridEpsilon && x0 >= r.MinX()-gridEpsilon && x1 <= r.MaxX()+gridEpsilon
}

func spansDown(r Rect, y0, y1, x float64) bool {
	return x > r.MinX()+gridEpsilon && x < r.MaxX()-gridEpsilon && y0 >= r.MinY()-gridEpsilon && y1 <= r.MaxY()+gridEpsilon
}

// cover blocks what lies inside `rect`; running along its edges (a tile's margin) costs hugCost
// extra.
func (g *grid) cover(rect Rect) {
	i0 := g.lower(g.xs, rect.MinX())
	i1 := g.upper(g.xs, rect.MaxX()) - 1
	j0 := g.lower(g.ys, rect.MinY())
	j1 := g.upper(g.ys, rect.MaxY()) - 1
	if i0 > i1 || j0 > j1 {
		return
	}
	hug := float32(hugCost)
	for j := j0; j <= j1; j++ {
		edgeY := math.Abs(g.ys[j]-rect.MinY()) < gridEpsilon || math.Abs(g.ys[j]-rect.MaxY()) < gridEpsilon
		for i := i0; i <= i1; i++ {
			n := j*g.nx + i
			if gridInside(rect, g.xs[i], g.ys[j]) {
				g.node[n]++
			}
			if i < i1 {
				if spansRight(rect, g.xs[i], g.xs[i+1], g.ys[j]) {
					g.right[n]++
				} else if edgeY {
					g.rightFactor[n] += hug
					g.rightHugs[n]++
				}
			}
			if j < j1 {
				edgeX := math.Abs(g.xs[i]-rect.MinX()) < gridEpsilon || math.Abs(g.xs[i]-rect.MaxX()) < gridEpsilon
				if spansDown(rect, g.ys[j], g.ys[j+1], g.xs[i]) {
					g.down[n]++
				} else if edgeX {
					g.downFactor[n] += hug
					g.downHugs[n]++
				}
			}
		}
	}
}

// soften: running along a group's border, or across its title band, costs extra.
func (g *grid) soften(region Region) {
	frame := region.Frame
	title := region.Title()
	border := float32(borderCost)
	titled := float32(titleCost)
	i0 := g.lower(g.xs, frame.MinX()-borderBand)
	i1 := g.upper(g.xs, frame.MaxX()+borderBand) - 1
	j0 := g.lower(g.ys, frame.MinY()-borderBand)
	j1 := g.upper(g.ys, frame.MaxY()+borderBand) - 1
	if i0 > i1 || j0 > j1 {
		return
	}
	for j := j0; j <= j1; j++ {
		y := g.ys[j]
		for i := i0; i <= i1; i++ {
			x := g.xs[i]
			n := j*g.nx + i
			if i+1 < g.nx && g.xs[i+1] > frame.MinX() && x < frame.MaxX() {
				if math.Abs(y-frame.MinY()) < borderBand || math.Abs(y-frame.MaxY()) < borderBand || math.Abs(y-title.MaxY()) < borderBand {
					g.rightFactor[n] += border
				}
				if y > title.MinY() && y < title.MaxY() {
					g.rightFactor[n] += titled
				}
			}
			if j+1 < g.ny && g.ys[j+1] > frame.MinY() && y < frame.MaxY() {
				if math.Abs(x-frame.MinX()) < borderBand || math.Abs(x-frame.MaxX()) < borderBand {
					g.downFactor[n] += border
				}
			}
		}
	}
}

type gridQuery struct {
	starts, goals []port
	// window is (i0, i1, j0, j1), inclusive.
	window        [4]int
	exempt, extra []Rect
	congestion    bool
}

type found struct {
	nodes       []int
	start, goal port
	cost        float64
}

func (g *grid) nodeBlocked(n int, q *gridQuery) bool {
	count := int(g.node[n])
	if len(q.exempt) == 0 && len(q.extra) == 0 {
		return count > 0
	}
	x, y := g.xs[n%g.nx], g.ys[n/g.nx]
	if count > 0 {
		exempt := 0
		for _, r := range q.exempt {
			if gridInside(r, x, y) {
				exempt++
			}
		}
		if count > exempt {
			return true
		}
	}
	for _, r := range q.extra {
		if gridInside(r, x, y) {
			return true
		}
	}
	return false
}

func (g *grid) edgeBlocked(n int, horizontal bool, q *gridQuery) bool {
	var count int
	if horizontal {
		count = int(g.right[n])
	} else {
		count = int(g.down[n])
	}
	if len(q.exempt) == 0 && len(q.extra) == 0 {
		return count > 0
	}
	i, j := n%g.nx, n/g.nx
	spans := func(r Rect) bool {
		if horizontal {
			return spansRight(r, g.xs[i], g.xs[i+1], g.ys[j])
		}
		return spansDown(r, g.ys[j], g.ys[j+1], g.xs[i])
	}
	if count > 0 {
		exempt := 0
		for _, r := range q.exempt {
			if spans(r) {
				exempt++
			}
		}
		if count > exempt {
			return true
		}
	}
	for _, r := range q.extra {
		if spans(r) {
			return true
		}
	}
	return false
}

// use adds (delta 1) or removes (-1) a route's use of its grid edges.
func (g *grid) use(nodes []int, delta int) {
	for k := range len(nodes) - 1 {
		a, b := nodes[k], nodes[k+1]
		if a == b {
			continue
		}
		n := min(a, b)
		if a-b == 1 || b-a == 1 {
			g.usedRight[n] = uint16(max(0, int(g.usedRight[n])+delta))
		} else {
			g.usedDown[n] = uint16(max(0, int(g.usedDown[n])+delta))
		}
	}
}

// nodesAlong: the grid nodes along an axis-aligned polyline whose corners lie on grid lines, in
// order; false when one doesn't.
func (g *grid) nodesAlong(points []Point) ([]int, bool) {
	var result []int
	for k := range len(points) - 1 {
		from, ok1 := g.index(points[k])
		to, ok2 := g.index(points[k+1])
		if !ok1 || !ok2 {
			return nil, false
		}
		i0, j0, i1, j1 := from%g.nx, from/g.nx, to%g.nx, to/g.nx
		switch {
		case j0 == j1:
			step := 1
			if i1 < i0 {
				step = -1
			}
			for i := i0; i != i1; i += step {
				result = append(result, j0*g.nx+i)
			}
		case i0 == i1:
			step := 1
			if j1 < j0 {
				step = -1
			}
			for j := j0; j != j1; j += step {
				result = append(result, j*g.nx+i0)
			}
		default:
			return nil, false
		}
	}
	if len(points) > 0 {
		if n, ok := g.index(points[len(points)-1]); ok {
			result = append(result, n)
		}
	}
	return result, true
}

func (g *grid) points(f *found) []Point {
	pts := make([]Point, 0, len(f.nodes)+2)
	pts = append(pts, f.start.point)
	for _, n := range f.nodes {
		pts = append(pts, Point{g.xs[n%g.nx], g.ys[n/g.nx]})
	}
	pts = append(pts, f.goal.point)
	return simplified(pts)
}

// search: the cheapest route from a start port's stub to a goal port's stub (A* over (node,
// heading) states, reversing never allowed), within the query's window.
func (g *grid) search(q gridQuery) *found {
	g.generation++
	if g.generation == 0 {
		clear(g.stamp)
		g.generation = 1
	}
	gen := g.generation
	goalAt := map[int][]int{}
	var goalStubs []Point
	for k, goal := range q.goals {
		n, ok := g.index(goal.stub)
		if !ok || g.nodeBlocked(n, &q) {
			continue
		}
		goalAt[n] = append(goalAt[n], k)
		goalStubs = append(goalStubs, goal.stub)
	}
	if len(goalAt) == 0 {
		return nil
	}
	estimate := func(n int) float64 {
		x, y := g.xs[n%g.nx], g.ys[n/g.nx]
		least := math.Inf(1)
		for _, s := range goalStubs {
			least = swiftMin(least, math.Abs(s.X-x)+math.Abs(s.Y-y))
		}
		return least
	}
	var heap minHeap
	startAt := map[int]int{}
	for k, start := range q.starts {
		n, ok := g.index(start.stub)
		if !ok || g.nodeBlocked(n, &q) {
			continue
		}
		state := n*4 + start.heading
		cost := start.cost + math.Abs(start.point.X-start.stub.X) + math.Abs(start.point.Y-start.stub.Y)
		if g.stamp[state] == gen && g.best[state] <= cost {
			continue
		}
		g.stamp[state] = gen
		g.best[state] = cost
		g.parent[state] = -1
		startAt[state] = k
		heap.push(state, cost+estimate(n))
	}
	i0, i1, j0, j1 := q.window[0], q.window[1], q.window[2], q.window[3]
	finishState, finishGoal, finishCost, finished := 0, 0, 0.0, false
	for {
		state, ok := heap.pop()
		if !ok {
			break
		}
		cost := g.best[state]
		if finished && cost >= finishCost {
			break
		}
		n := state / 4
		heading := state % 4
		if goals, ok := goalAt[n]; ok {
			for _, k := range goals {
				goal := q.goals[k]
				turn := bendCost
				if heading == (goal.heading+2)%4 {
					turn = 0
				}
				total := cost + turn + goal.cost + math.Abs(goal.point.X-goal.stub.X) + math.Abs(goal.point.Y-goal.stub.Y)
				if !finished || total < finishCost {
					finishState, finishGoal, finishCost, finished = state, k, total, true
				}
			}
		}
		i, j := n%g.nx, n/g.nx
		for direction := range 4 {
			if direction == (heading+2)%4 {
				continue
			}
			ni, nj := i, j
			switch direction {
			case 0:
				ni++
			case 1:
				nj++
			case 2:
				ni--
			case 3:
				nj--
			}
			if ni < i0 || ni > i1 || nj < j0 || nj > j1 {
				continue
			}
			next := nj*g.nx + ni
			horizontal := direction%2 == 0
			edge := min(n, next)
			if g.edgeBlocked(edge, horizontal, &q) || g.nodeBlocked(next, &q) {
				continue
			}
			length := math.Abs(g.xs[ni]-g.xs[i]) + math.Abs(g.ys[nj]-g.ys[j])
			factor := g.downFactor[edge]
			if horizontal {
				factor = g.rightFactor[edge]
			}
			step := float64(length * (1 + float64(factor)))
			if direction != heading {
				step += bendCost
			}
			if q.congestion {
				used := g.usedDown[edge]
				hugs := g.downHugs[edge]
				if horizontal {
					used, hugs = g.usedRight[edge], g.rightHugs[edge]
				}
				step += float64(float64(length*shareCost) * float64(used))
				if used > 0 && hugs >= 2 {
					step += float64(float64(length*narrowShareCost) * float64(used))
				}
				if horizontal {
					if nj > 0 && g.usedDown[next] > 0 && g.usedDown[next-g.nx] > 0 {
						step += float64(crossCost * float64(min(g.usedDown[next], g.usedDown[next-g.nx])))
					}
				} else if ni > 0 && g.usedRight[next] > 0 && g.usedRight[next-1] > 0 {
					step += float64(crossCost * float64(min(g.usedRight[next], g.usedRight[next-1])))
				}
			}
			nextCost := cost + step
			nextState := next*4 + direction
			if g.stamp[nextState] == gen && g.best[nextState] <= nextCost {
				continue
			}
			g.stamp[nextState] = gen
			g.best[nextState] = nextCost
			g.parent[nextState] = int32(state)
			heap.push(nextState, nextCost+estimate(next))
		}
	}
	if !finished {
		return nil
	}
	states := []int{finishState}
	for g.parent[states[len(states)-1]] >= 0 {
		states = append(states, int(g.parent[states[len(states)-1]]))
	}
	start, ok := startAt[states[len(states)-1]]
	if !ok {
		return nil
	}
	nodes := make([]int, len(states))
	for k, s := range states {
		nodes[len(states)-1-k] = s / 4
	}
	return &found{nodes: nodes, start: q.starts[start], goal: q.goals[finishGoal], cost: finishCost}
}
