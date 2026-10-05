package route

import (
	"math"
	"sort"
)

// planned is one arrow's route out of the planner.
type planned struct {
	points []Point
	// sketch is the first route (pass 1), which ordered its ports; nil for a fallback.
	sketch []Point
	// nudges: found by the search (interior segments may nudge), not a fallback.
	nudges bool
}

// planner runs passes 1–3: sides, ports, and routes of the arrows routed here.
type planner struct {
	router Router
}

const plannerMargin = AvoidMargin

type prepared struct {
	index    int
	from, to ArrowEnd
	flow     Flow
	// exempt: inflated obstacles this arrow may pass through (holding one of its ends).
	exempt []Rect
	// extra: inflated end boxes that aren't obstacles (a group, an unfilled shape).
	extra []Rect
}

func (p planner) prepare(index int, flow Flow) prepared {
	c := p.router.Connectors[index]
	ends := map[string]bool{}
	for _, id := range []string{c.FromObject, c.ToObject} {
		if id != "" {
			ends[id] = true
		}
	}
	var boxes []Rect
	for _, e := range []ArrowEnd{c.From, c.To} {
		if b, ok := e.box(); ok {
			boxes = append(boxes, b)
		}
	}
	centers := []Point{{c.From.Aim().MidX(), c.From.Aim().MidY()}, {c.To.Aim().MidX(), c.To.Aim().MidY()}}
	var exempt []Rect
	for _, o := range p.router.Obstacles {
		if ends[o.ID] {
			continue
		}
		rect := o.Rect
		hit := false
		for _, ctr := range centers {
			if rect.Contains(ctr) {
				hit = true
			}
		}
		for _, b := range boxes {
			if b.ContainsRect(rect) {
				hit = true
			}
		}
		if hit {
			exempt = append(exempt, rect.InsetBy(-plannerMargin, -plannerMargin))
		}
	}
	obstacleIDs := map[string]bool{}
	for _, o := range p.router.Obstacles {
		obstacleIDs[o.ID] = true
	}
	var extra []Rect
	for _, end := range []struct {
		object string
		end    ArrowEnd
	}{{c.FromObject, c.From}, {c.ToObject, c.To}} {
		b, ok := end.end.box()
		if !ok || (end.object != "" && obstacleIDs[end.object]) {
			continue
		}
		extra = append(extra, b.InsetBy(-plannerMargin, -plannerMargin))
	}
	return prepared{index: index, from: c.From, to: c.To, flow: flow, exempt: exempt, extra: extra}
}

// baseLines: grid lines every search shares: inflated obstacle edges, channel midlines, lines
// just outside groups, and the edges of non-obstacle end boxes.
func (p planner) baseLines(items []prepared) (xs, ys []float64, blocks []Rect) {
	rects := make([]Rect, len(p.router.Obstacles))
	for i, o := range p.router.Obstacles {
		rects[i] = o.Rect
	}
	for _, r := range rects {
		b := r.InsetBy(-plannerMargin, -plannerMargin)
		blocks = append(blocks, b)
		xs = append(xs, b.MinX(), b.MaxX())
		ys = append(ys, b.MinY(), b.MaxY())
	}
	midlines := func(boxes []Rect, minimum float64) {
		for _, a := range boxes {
			right, below := math.Inf(1), math.Inf(1)
			for _, b := range boxes {
				if b.MinX() >= a.MaxX() && b.MinY() < a.MaxY() && b.MaxY() > a.MinY() {
					right = swiftMin(right, b.MinX())
				}
				if b.MinY() >= a.MaxY() && b.MinX() < a.MaxX() && b.MaxX() > a.MinX() {
					below = swiftMin(below, b.MinY())
				}
			}
			if !math.IsInf(right, 0) && right-a.MaxX() > minimum {
				xs = append(xs, (a.MaxX()+right)/2)
			}
			if !math.IsInf(below, 0) && below-a.MaxY() > minimum {
				ys = append(ys, (a.MaxY()+below)/2)
			}
		}
	}
	midlines(rects, 2*plannerMargin)
	frames := make([]Rect, len(p.router.Regions))
	for i, g := range p.router.Regions {
		frames[i] = g.Frame
	}
	midlines(frames, 2*regionClearance)
	for _, f := range frames {
		xs = append(xs, f.MinX()-regionClearance, f.MaxX()+regionClearance)
		ys = append(ys, f.MinY()-regionClearance, f.MaxY()+regionClearance)
	}
	for _, item := range items {
		for _, b := range item.extra {
			xs = append(xs, b.MinX(), b.MaxX())
			ys = append(ys, b.MinY(), b.MaxY())
		}
		for _, end := range []ArrowEnd{item.from, item.to} {
			switch end.Kind {
			case EndPoint:
				xs = append(xs, end.Point.X)
				ys = append(ys, end.Point.Y)
			case EndRow:
				xs = append(xs, end.Rect.MinX()-plannerMargin, end.Rect.MaxX()+plannerMargin)
				ys = append(ys, end.Y)
			}
		}
	}
	return xs, ys, blocks
}

func boxPtr(e ArrowEnd) *Rect {
	if b, ok := e.box(); ok {
		return &b
	}
	return nil
}

func (p planner) candidates(item prepared, source bool) []port {
	end, other := item.to, item.from.Aim()
	if source {
		end, other = item.from, item.to.Aim()
	}
	var out []port
	for heading := range 4 {
		pt, ok := endPort(end, heading, nil, other)
		if !ok {
			continue
		}
		pt.cost = sideCost(heading, boxPtr(end), other, item.flow, source)
		out = append(out, pt)
	}
	return out
}

func (p planner) query(item prepared, g *grid, starts, goals []port, congestion, whole bool) gridQuery {
	window := [4]int{0, g.nx - 1, 0, g.ny - 1}
	if !whole {
		reach := item.from.Aim().Union(item.to.Aim()).InsetBy(-searchReach, -searchReach)
		window = [4]int{g.lower(g.xs, reach.MinX()), max(0, g.upper(g.xs, reach.MaxX())-1),
			g.lower(g.ys, reach.MinY()), max(0, g.upper(g.ys, reach.MaxY())-1)}
	}
	return gridQuery{starts: starts, goals: goals, window: window, exempt: item.exempt, extra: item.extra, congestion: congestion}
}

func (p planner) search(item prepared, g *grid, starts, goals []port, congestion bool) *found {
	if f := g.search(p.query(item, g, starts, goals, congestion, false)); f != nil {
		return f
	}
	return g.search(p.query(item, g, starts, goals, congestion, true))
}

type chosenRoute struct {
	start, goal port
	path        []Point
}

type portPair struct{ start, goal port }

// solve routes `indices`: those in `keep` keep their routes (unless a side they share gets new
// ports), the rest go through passes 1–3 around them.
func (p planner) solve(indices []int, flows map[int]Flow, keep map[int]keptRoute) map[int]planned {
	items := make([]prepared, len(indices))
	for i, index := range indices {
		flow, ok := flows[index]
		if !ok {
			flow = FlowRight
		}
		items[i] = p.prepare(index, flow)
	}
	baseXs, baseYs, blocks := p.baseLines(items)
	result := map[int]planned{}

	// Kept routes' ports, read off their first and last segments.
	chosen := map[int]chosenRoute{}
	for _, item := range items {
		k, ok := keep[item.index]
		if !ok {
			continue
		}
		start, ok1 := p.derivedPort(item, k.route, true)
		goal, ok2 := p.derivedPort(item, reversed(k.route), false)
		if !ok1 || !ok2 {
			continue
		}
		chosen[item.index] = chosenRoute{start, goal, k.sketch}
	}
	kept := map[int]bool{}
	for index := range chosen {
		kept[index] = true
	}

	// Pass 1: every side of both ends, each arrow alone.
	type ends struct{ starts, goals []port }
	candidates := map[int]ends{}
	for _, item := range items {
		candidates[item.index] = ends{p.candidates(item, true), p.candidates(item, false)}
	}
	var fresh []prepared
	for _, item := range items {
		if !kept[item.index] {
			fresh = append(fresh, item)
		}
	}
	if len(fresh) > 0 {
		xs1 := append([]float64(nil), baseXs...)
		ys1 := append([]float64(nil), baseYs...)
		for _, item := range fresh {
			e := candidates[item.index]
			for _, pt := range append(append([]port(nil), e.starts...), e.goals...) {
				xs1 = append(xs1, pt.stub.X, pt.point.X)
				ys1 = append(ys1, pt.stub.Y, pt.point.Y)
			}
		}
		grid1 := newGrid(xs1, ys1, blocks, p.router.Regions)
		if grid1 == nil {
			return p.fallback(items)
		}
		for _, item := range fresh {
			e := candidates[item.index]
			f := p.search(item, grid1, e.starts, e.goals, false)
			if f == nil {
				continue
			}
			chosen[item.index] = chosenRoute{f.start, f.goal, grid1.points(f)}
		}
	}

	// Ports: arrows sharing a side spread along it; a kept route whose port moves routes again.
	assigned := p.assignPorts(items, chosen)
	for index := range kept {
		ports, ok1 := assigned[index]
		pk, ok2 := chosen[index]
		if !ok1 || !ok2 {
			continue
		}
		if ports.start.heading != pk.start.heading || ports.goal.heading != pk.goal.heading ||
			hypot(ports.start.point.X-pk.start.point.X, ports.start.point.Y-pk.start.point.Y) > 0.5 ||
			hypot(ports.goal.point.X-pk.goal.point.X, ports.goal.point.Y-pk.goal.point.Y) > 0.5 {
			delete(kept, index)
		}
	}

	// Passes 2 and 3: between the ports, around kept routes and the arrows routed so far, then
	// each rerouted against all the others.
	xs2 := append([]float64(nil), baseXs...)
	ys2 := append([]float64(nil), baseYs...)
	for _, ports := range assigned {
		for _, pt := range []port{ports.start, ports.goal} {
			xs2 = append(xs2, pt.stub.X, pt.point.X)
			ys2 = append(ys2, pt.stub.Y, pt.point.Y)
		}
	}
	for _, item := range items {
		if kept[item.index] {
			continue
		}
		e := candidates[item.index]
		for _, pt := range append(append([]port(nil), e.starts...), e.goals...) {
			xs2 = append(xs2, pt.stub.X, pt.point.X)
			ys2 = append(ys2, pt.stub.Y, pt.point.Y)
		}
	}
	keptSorted := make([]int, 0, len(kept))
	for index := range kept {
		keptSorted = append(keptSorted, index)
	}
	sort.Ints(keptSorted)
	for _, index := range keptSorted {
		for _, pt := range keep[index].route {
			xs2 = append(xs2, pt.X)
			ys2 = append(ys2, pt.Y)
		}
	}
	g := newGrid(xs2, ys2, blocks, p.router.Regions)
	if g == nil {
		for _, item := range items {
			if c, ok := chosen[item.index]; ok {
				result[item.index] = planned{points: c.path, sketch: c.path, nudges: true}
			} else {
				result[item.index] = p.fallbackPath(item)
			}
		}
		return result
	}
	for _, index := range keptSorted {
		if nodes, ok := g.nodesAlong(keep[index].route); ok {
			g.use(nodes, 1)
		}
	}
	var order []prepared
	for _, item := range items {
		if _, ok := assigned[item.index]; ok && !kept[item.index] {
			order = append(order, item)
		}
	}
	span := func(index int) float64 {
		pa := assigned[index]
		return math.Abs(pa.start.point.X-pa.goal.point.X) + math.Abs(pa.start.point.Y-pa.goal.point.Y)
	}
	sort.SliceStable(order, func(a, b int) bool {
		la, lb := span(order[a].index), span(order[b].index)
		if la != lb {
			return la < lb
		}
		return p.router.Connectors[order[a].index].ID < p.router.Connectors[order[b].index].ID
	})
	routes := map[int]*found{}
	routeOne := func(item prepared) *found {
		ports := assigned[item.index]
		if f := p.search(item, g, []port{ports.start}, []port{ports.goal}, true); f != nil {
			return f
		}
		e := candidates[item.index]
		return p.search(item, g, e.starts, e.goals, true)
	}
	for _, item := range order {
		f := routeOne(item)
		if f == nil {
			continue
		}
		g.use(f.nodes, 1)
		routes[item.index] = f
	}
	for _, item := range order {
		old, ok := routes[item.index]
		if !ok {
			continue
		}
		g.use(old.nodes, -1)
		f := routeOne(item)
		if f == nil {
			f = old
		}
		g.use(f.nodes, 1)
		routes[item.index] = f
	}
	for _, item := range items {
		var sketch []Point
		if c, ok := chosen[item.index]; ok {
			sketch = c.path
		}
		if kept[item.index] {
			result[item.index] = planned{points: keep[item.index].route, sketch: sketch, nudges: true}
		} else if f, ok := routes[item.index]; ok {
			result[item.index] = planned{points: g.points(f), sketch: sketch, nudges: true}
		} else if c, ok := chosen[item.index]; ok {
			result[item.index] = planned{points: c.path, sketch: sketch, nudges: true}
		} else {
			result[item.index] = p.fallbackPath(item)
		}
	}
	return result
}

func reversed(path []Point) []Point {
	out := make([]Point, len(path))
	for i, pt := range path {
		out[len(path)-1-i] = pt
	}
	return out
}

// derivedPort: the port a kept route leaves `item`'s source by (`source`), or enters its target
// by (`route` reversed), read off its first segment.
func (p planner) derivedPort(item prepared, route []Point, source bool) (port, bool) {
	if len(route) < 2 {
		return port{}, false
	}
	a, b := route[0], route[1]
	var heading int
	if math.Abs(b.X-a.X) >= math.Abs(b.Y-a.Y) {
		heading = 2
		if b.X > a.X {
			heading = 0
		}
	} else {
		heading = 3
		if b.Y > a.Y {
			heading = 1
		}
	}
	end, other := item.to, item.from.Aim()
	if source {
		end, other = item.from, item.to.Aim()
	}
	along := a.X
	if heading%2 == 0 {
		along = a.Y
	}
	pt, ok := endPort(end, heading, &along, other)
	if !ok {
		return port{}, false
	}
	pt.cost = sideCost(heading, boxPtr(end), other, item.flow, source)
	return pt, true
}

func (p planner) fallbackPath(item prepared) planned {
	return planned{points: orthogonal(item.from, item.to, 0, ArrowGap)}
}

func (p planner) fallback(items []prepared) map[int]planned {
	result := map[int]planned{}
	for _, item := range items {
		result[item.index] = p.fallbackPath(item)
	}
	return result
}

type sideKey struct {
	object  string
	heading int
}

// assignPorts gives each arrow its two ports: a side one arrow uses keeps its lined-up port; a
// side several share spreads them ParallelSpacing apart (closer on a short side) around its
// middle, in the order in which their first routes head along it. Rows and free points keep
// theirs.
func (p planner) assignPorts(items []prepared, chosen map[int]chosenRoute) map[int]portPair {
	assigned := map[int]portPair{}
	type member struct {
		index    int
		source   bool
		key, tie float64
		id       string
	}
	sides := map[sideKey][]member{}
	var sideOrder []sideKey
	byIndex := map[int]prepared{}
	for _, item := range items {
		byIndex[item.index] = item
		pk, ok := chosen[item.index]
		if !ok {
			continue
		}
		assigned[item.index] = portPair{pk.start, pk.goal}
		c := p.router.Connectors[item.index]
		for _, e := range []struct {
			source bool
			end    ArrowEnd
			other  Rect
			object string
			port   port
		}{{true, item.from, item.to.Aim(), c.FromObject, pk.start}, {false, item.to, item.from.Aim(), c.ToObject, pk.goal}} {
			if e.end.Kind != EndBound || e.object == "" {
				continue
			}
			alongY := e.port.heading%2 == 0
			// Where the route heads along the side once it has left it: the end of its second
			// segment, else its far end.
			path := pk.path
			if !e.source {
				path = reversed(pk.path)
			}
			heading := path[len(path)-1]
			if len(path) > 2 {
				heading = path[2]
			}
			m := member{index: item.index, source: e.source, id: c.ID}
			if alongY {
				m.key, m.tie = heading.Y, e.other.MidY()
			} else {
				m.key, m.tie = heading.X, e.other.MidX()
			}
			k := sideKey{e.object, e.port.heading}
			if _, seen := sides[k]; !seen {
				sideOrder = append(sideOrder, k)
			}
			sides[k] = append(sides[k], m)
		}
	}
	// Each end is on one side, so the order sides are spread in doesn't matter (Swift walks a
	// dictionary); first-seen order keeps runs reproducible.
	for _, side := range sideOrder {
		members := sides[side]
		if len(members) <= 1 {
			continue
		}
		ordered := append([]member(nil), members...)
		srcRank := func(m member) int {
			if m.source {
				return 0
			}
			return 1
		}
		sort.SliceStable(ordered, func(i, j int) bool {
			a, b := ordered[i], ordered[j]
			if a.key != b.key {
				return a.key < b.key
			}
			if a.tie != b.tie {
				return a.tie < b.tie
			}
			if a.id != b.id {
				return a.id < b.id
			}
			return srcRank(a) < srcRank(b)
		})
		first, ok := byIndex[ordered[0].index]
		if !ok {
			continue
		}
		end := first.to
		if ordered[0].source {
			end = first.from
		}
		box, ok := end.box()
		if !ok {
			continue
		}
		alongY := side.heading%2 == 0
		low, high := box.MinX(), box.MaxX()
		if alongY {
			low, high = box.MinY(), box.MaxY()
		}
		length := high - low
		pad := swiftMin(16, length/4)
		spacing := swiftMin(ParallelSpacing, (length-2*pad)/float64(len(ordered)-1))
		middle := (low + high) / 2
		for rank, m := range ordered {
			item, ok1 := byIndex[m.index]
			pk, ok2 := assigned[m.index]
			if !ok1 || !ok2 {
				continue
			}
			along := middle + float64((float64(rank)-float64(len(ordered)-1)/2)*spacing)
			end, other := item.to, item.from.Aim()
			if m.source {
				end, other = item.from, item.to.Aim()
			}
			pt, ok := endPort(end, side.heading, &along, other)
			if !ok {
				continue
			}
			if m.source {
				pt.cost = pk.start.cost
				assigned[m.index] = portPair{pt, pk.goal}
			} else {
				pt.cost = pk.goal.cost
				assigned[m.index] = portPair{pk.start, pt}
			}
		}
	}
	return assigned
}
