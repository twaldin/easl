package route

import (
	"math"
	"sort"
)

// Router is ConnectorRouter: it routes a board's `avoid` arrows together, after libavoid's
// orthogonal connector routing and ELK's layered edge routing, then places every arrow's label:
// sides (a grid search from every side of each source to every side of its target), ports
// (arrows sharing a side spread along it), routes (searched again between the ports, paying for
// crossings, then each rerouted once against the others), nudging (collinear runs spread into
// parallel tracks), and labels (beside each arrow's own line, clear of tiles, titles, other
// lines and labels). A pure function of its input.
type Router struct {
	Connectors []Connector
	Obstacles  []Obstacle
	Regions    []Region
	// Flow of arrows no region's flow covers; nil infers it from the arrows between groups.
	Flow *Flow
}

// Connector is one arrow to route (or, with Path, one drawn as given).
type Connector struct {
	ID       string
	From, To ArrowEnd
	// FromObject and ToObject are the objects the ends are bound to ("" for none): an arrow's
	// own ends are never in its way.
	FromObject, ToObject string
	// Label is the caption chip's size; nil without a caption.
	Label *Size
	// Path is a route drawn as given (a straight or orthogonal arrow): routed arrows keep off it
	// and its label is placed with the rest. Nil routes it here.
	Path []Point
}

// Obstacle is something arrows go around and labels keep off: a tile, text, or filled shape.
type Obstacle struct {
	ID   string
	Rect Rect
}

// Region is a group: arrows cross its border but don't run along it, and keep off its title.
type Region struct {
	ID    string
	Frame Rect
	// Members are the leaf members (nested groups expanded).
	Members map[string]bool
	Flow    *Flow
}

// Title is the band holding the region's title.
func (r Region) Title() Rect {
	return Rect{X: r.Frame.MinX(), Y: r.Frame.MinY(), W: r.Frame.Width(), H: swiftMin(r.Frame.Height(), GroupTitleHeight)}
}

// Label is where a caption's chip is drawn, with a leader from the route when it sits away.
type Label struct {
	Rect   Rect
	Leader []Point
}

func (l Label) equal(o Label) bool {
	return l.Rect == o.Rect && pathEqual(l.Leader, o.Leader) && (l.Leader == nil) == (o.Leader == nil)
}

func pathEqual(a, b []Point) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Result is a routing: every arrow's path and label, and what it came from (so routing the board
// again keeps what nothing touched; pass it back as Geometry.Settled).
type Result struct {
	Paths  map[string][]Point
	Labels map[string]Label
	memo   memo
}

// memo is each routed arrow's route before nudging, with what it was routed around.
type memo struct {
	centerlines map[string][]Point
	sketches    map[string][]Point
	ends        map[string][2]ArrowEnd
	flows       map[string]Flow
	obstacles   map[string]Rect
	regions     map[string]Rect
}

// Tuning.
const (
	bendCost  = 60.0
	crossCost = 50.0
	shareCost = 0.0
	hugCost   = 0.3
	// narrowShareCost per point of length and arrow already there in a one-track gap.
	narrowShareCost = 2.0
	borderCost      = 1.5
	titleCost       = 2.0
	borderBand      = 6.0
	offFlowCost     = 150.0
	offAxisCost     = 20.0
	sideExitCost    = 100.0
	uTurnCost       = 240.0
	trackClearance  = 10.0
	borderClearance = 8.0
	regionClearance = 12.0
	minStub         = 10.0
	searchReach     = 480.0
	leaderCost      = 2
	shortLeader     = 72.0
	underCost       = 5
	bundleCost      = 3
	coverCost       = 12
)

var leaderReaches = []float64{24, 44, 72, 96, 120, 160}

// Route routes and labels every connector. With `previous` (this board's last routing), an arrow
// whose ends, flow, and surroundings haven't changed keeps its route; tracks and labels are
// placed afresh.
func (r Router) Route(previous *Result) *Result {
	routes := make([][]Point, len(r.Connectors))
	for i, c := range r.Connectors {
		routes[i] = c.Path
	}
	movable := make([]bool, len(r.Connectors))
	var pending []int
	for i, c := range r.Connectors {
		if c.Path == nil {
			pending = append(pending, i)
		}
	}
	sort.SliceStable(pending, func(a, b int) bool { return r.Connectors[pending[a]].ID < r.Connectors[pending[b]].ID })
	flows := r.flows(pending)
	m := memo{centerlines: map[string][]Point{}, sketches: map[string][]Point{}, ends: map[string][2]ArrowEnd{},
		flows: map[string]Flow{}, obstacles: map[string]Rect{}, regions: map[string]Rect{}}
	for _, o := range r.Obstacles {
		m.obstacles[o.ID] = o.Rect
	}
	for _, g := range r.Regions {
		m.regions[g.ID] = g.Frame
	}
	if len(pending) > 0 {
		var prev *memo
		if previous != nil {
			prev = &previous.memo
		}
		planner := planner{router: r}
		for index, path := range planner.solve(pending, flows, r.kept(pending, flows, prev)) {
			c := r.Connectors[index]
			// Nudging moves routes in place; the memo keeps them as planned.
			routes[index] = append([]Point(nil), path.points...)
			movable[index] = path.nudges
			m.centerlines[c.ID] = path.points
			if path.sketch != nil {
				m.sketches[c.ID] = path.sketch
			} else {
				m.sketches[c.ID] = path.points
			}
			m.ends[c.ID] = [2]ArrowEnd{c.From, c.To}
			m.flows[c.ID] = flows[index]
		}
	}
	rects := make([]Rect, len(r.Obstacles))
	for i, o := range r.Obstacles {
		rects[i] = o.Rect
	}
	soft := r.softLines()
	titles := make([]Rect, len(r.Regions))
	frames := make([]Rect, len(r.Regions))
	for i, g := range r.Regions {
		titles[i] = g.Title()
		frames[i] = g.Frame
	}
	centered := clonePaths(routes)
	settle := func(routes [][]Point, chips []Rect) map[string]Label {
		blocks := append(append([]Rect(nil), rects...), chips...)
		nudge(routes, movable, blocks, soft, true)
		nudge(routes, movable, blocks, soft, false)
		for i := range routes {
			if movable[i] {
				routes[i] = simplified(routes[i])
			}
		}
		return placeLabels(r.Connectors, routes, rects, titles, frames)
	}
	labels := settle(routes, nil)
	// A label left on another arrow's line: nudge that line's track clear of the chip, and keep
	// the result when it leaves fewer labels on lines, tiles, or titles.
	blocked := append(append([]Rect(nil), rects...), titles...)
	clashing := r.clashes(labels, routes, blocked)
	if len(clashing) > 0 {
		retry := centered
		chips := make([]Rect, len(clashing))
		for i, owner := range clashing {
			chips[i] = labels[r.Connectors[owner].ID].Rect
		}
		for i, owner := range clashing {
			clearChip(retry, chips[i], owner, movable, rects)
		}
		relabelled := settle(retry, chips)
		if len(r.clashes(relabelled, retry, blocked)) < len(clashing) && !worsened(routes, retry, movable, rects) {
			routes = retry
			labels = relabelled
		}
	}
	paths := map[string][]Point{}
	for i, c := range r.Connectors {
		if len(routes[i]) >= 2 {
			paths[c.ID] = routes[i]
		}
	}
	return &Result{Paths: paths, Labels: labels, memo: m}
}

// worsened: some movable route of `retry` crosses a tile its route in `routes` didn't.
func worsened(routes, retry [][]Point, movable []bool, rects []Rect) bool {
	for i := range routes {
		if i >= len(retry) || !movable[i] {
			continue
		}
		crossesNow, crossedBefore := false, false
		for _, rect := range rects {
			if PathCrosses(retry[i], rect) {
				crossesNow = true
				break
			}
		}
		if !crossesNow {
			continue
		}
		for _, rect := range rects {
			if PathCrosses(routes[i], rect) {
				crossedBefore = true
				break
			}
		}
		if !crossedBefore {
			return true
		}
	}
	return false
}

func clonePaths(paths [][]Point) [][]Point {
	out := make([][]Point, len(paths))
	for i, p := range paths {
		if p != nil {
			out[i] = append([]Point(nil), p...)
		}
	}
	return out
}

// clashes: connectors whose label lies on another arrow's line, or on a tile or title.
func (r Router) clashes(labels map[string]Label, routes [][]Point, obstacles []Rect) []int {
	var out []int
	for index, c := range r.Connectors {
		label, ok := labels[c.ID]
		if !ok {
			continue
		}
		inner := label.Rect.InsetBy(0.5, 0.5)
		hit := false
		for _, o := range obstacles {
			if o.Intersects(inner) {
				hit = true
				break
			}
		}
		for other := 0; !hit && other < len(routes); other++ {
			if other == index {
				continue
			}
			route := routes[other]
			for i := range len(route) - 1 {
				if segmentIntersects(route[i], route[i+1], inner) {
					hit = true
					break
				}
			}
		}
		if hit {
			out = append(out, index)
		}
	}
	return out
}

// clearChip moves the inner segments of other arrows that run through `chip` to the roomier
// side of it, between it and the nearest tile, so nudging (with the chip as an obstacle) keeps
// them there.
func clearChip(routes [][]Point, chip Rect, owner int, movable []bool, obstacles []Rect) {
	for r := range routes {
		if r == owner || !movable[r] || len(routes[r]) < 4 {
			continue
		}
		points := routes[r]
		for i := 1; i < len(points)-2; i++ {
			a, b := points[i], points[i+1]
			if !segmentIntersects(a, b, chip) {
				continue
			}
			vertical := math.Abs(a.X-b.X) < 0.01
			var c0, c1, e0, e1 float64
			if vertical {
				c0, c1 = chip.MinX(), chip.MaxX()
				e0, e1 = swiftMin(a.Y, b.Y), swiftMax(a.Y, b.Y)
			} else {
				c0, c1 = chip.MinY(), chip.MaxY()
				e0, e1 = swiftMin(a.X, b.X), swiftMax(a.X, b.X)
			}
			below, above := c0-searchReach, c1+searchReach
			for _, rect := range obstacles {
				var r0, r1, s0, s1 float64
				if vertical {
					r0, r1, s0, s1 = rect.MinX(), rect.MaxX(), rect.MinY(), rect.MaxY()
				} else {
					r0, r1, s0, s1 = rect.MinY(), rect.MaxY(), rect.MinX(), rect.MaxX()
				}
				if !(s0 < e1 && s1 > e0) {
					continue
				}
				if r1 <= c0 {
					below = swiftMax(below, r1)
				} else if r0 >= c1 {
					above = swiftMin(above, r0)
				}
			}
			target := (c1 + above) / 2
			if c0-below >= above-c1 {
				target = (below + c0) / 2
			}
			if vertical {
				points[i].X, points[i+1].X = target, target
			} else {
				points[i].Y, points[i+1].Y = target, target
			}
		}
		routes[r] = points
	}
}

type keptRoute struct {
	route, sketch []Point
}

// kept: the previous routes (before nudging) of `pending` arrows nothing has touched since.
func (r Router) kept(pending []int, flows map[int]Flow, previous *memo) map[int]keptRoute {
	if previous == nil {
		return map[int]keptRoute{}
	}
	var changed []Rect
	current := map[string]Rect{}
	for _, o := range r.Obstacles {
		current[o.ID] = o.Rect
	}
	for id, rect := range previous.obstacles {
		if c, ok := current[id]; !ok || c != rect {
			changed = append(changed, rect)
		}
	}
	for id, rect := range current {
		if p, ok := previous.obstacles[id]; !ok || p != rect {
			changed = append(changed, rect)
		}
	}
	frames := map[string]Rect{}
	for _, g := range r.Regions {
		frames[g.ID] = g.Frame
	}
	var moved []Rect
	for id, f := range previous.regions {
		if c, ok := frames[id]; !ok || c != f {
			moved = append(moved, f)
		}
	}
	for id, f := range frames {
		if p, ok := previous.regions[id]; !ok || p != f {
			moved = append(moved, f)
		}
	}
	reach := AvoidMargin + 2
	var areas []Rect
	for _, c := range changed {
		areas = append(areas, c.InsetBy(-reach, -reach))
	}
	for _, f := range moved {
		// Only a group's border and title band change costs.
		band := borderBand + reach
		areas = append(areas,
			Rect{f.MinX(), f.MinY(), f.Width(), GroupTitleHeight}.InsetBy(-band, -band),
			Rect{f.MinX(), f.MaxY(), f.Width(), 0}.InsetBy(-band, -band),
			Rect{f.MinX(), f.MinY(), 0, f.Height()}.InsetBy(-band, -band),
			Rect{f.MaxX(), f.MinY(), 0, f.Height()}.InsetBy(-band, -band))
	}
	result := map[int]keptRoute{}
	for _, index := range pending {
		c := r.Connectors[index]
		route, ok := previous.centerlines[c.ID]
		if !ok || len(route) < 2 {
			continue
		}
		if ends, ok := previous.ends[c.ID]; !ok || ends != [2]ArrowEnd{c.From, c.To} {
			continue
		}
		if f, ok := previous.flows[c.ID]; !ok || f != flows[index] {
			continue
		}
		touched := false
		for _, a := range areas {
			if PathCrosses(route, a) {
				touched = true
				break
			}
		}
		if touched {
			continue
		}
		sketch, ok := previous.sketches[c.ID]
		if !ok {
			sketch = route
		}
		result[index] = keptRoute{route, sketch}
	}
	return result
}

type softLine struct {
	rect     Rect
	vertical bool
}

// softLines: borders and title bands nudged tracks keep off; vertical ones bound vertical
// segments.
func (r Router) softLines() []softLine {
	var lines []softLine
	for _, g := range r.Regions {
		f := g.Frame
		lines = append(lines,
			softLine{Rect{f.MinX(), f.MinY(), 0, f.Height()}, true},
			softLine{Rect{f.MaxX(), f.MinY(), 0, f.Height()}, true},
			softLine{Rect{f.MinX(), f.MaxY(), f.Width(), 0}, false},
			softLine{g.Title(), false})
	}
	return lines
}

// flows: the flow each arrow follows: the innermost group holding both ends that sets one, else
// the innermost holding its source, else the board's (Flow, else the way arrows between groups
// mostly point).
func (r Router) flows(indices []int) map[int]Flow {
	byArea := append([]Region(nil), r.Regions...)
	sort.SliceStable(byArea, func(i, j int) bool {
		ai := float64(byArea[i].Frame.Width() * byArea[i].Frame.Height())
		aj := float64(byArea[j].Frame.Width() * byArea[j].Frame.Height())
		if ai != aj {
			return ai < aj
		}
		return byArea[i].ID < byArea[j].ID
	})
	innermost := func(id string) string {
		if id == "" {
			return ""
		}
		for _, g := range byArea {
			if g.Members[id] {
				return g.ID
			}
		}
		return ""
	}
	var board Flow
	if r.Flow != nil {
		board = *r.Flow
	} else {
		sx, sy := 0.0, 0.0
		for _, across := range []bool{true, false} {
			if !(sx == 0 && sy == 0) {
				continue
			}
			for _, c := range r.Connectors {
				a, b := c.FromObject, c.ToObject
				if a == "" || b == "" || a == b {
					continue
				}
				if across && (len(r.Regions) == 0 || innermost(a) == innermost(b)) {
					continue
				}
				sx += c.To.Aim().MidX() - c.From.Aim().MidX()
				sy += c.To.Aim().MidY() - c.From.Aim().MidY()
			}
		}
		switch {
		case math.Abs(sx) >= math.Abs(sy) && sx >= 0:
			board = FlowRight
		case math.Abs(sx) >= math.Abs(sy):
			board = FlowLeft
		case sy >= 0:
			board = FlowDown
		default:
			board = FlowUp
		}
	}
	result := map[int]Flow{}
	for _, index := range indices {
		c := r.Connectors[index]
		var both, source *Flow
		for _, g := range byArea {
			if g.Flow == nil {
				continue
			}
			if both == nil && c.FromObject != "" && c.ToObject != "" && g.Members[c.FromObject] && g.Members[c.ToObject] {
				both = g.Flow
			}
			if source == nil && c.FromObject != "" && g.Members[c.FromObject] {
				source = g.Flow
			}
		}
		switch {
		case both != nil:
			result[index] = *both
		case source != nil:
			result[index] = *source
		default:
			result[index] = board
		}
	}
	return result
}

// port is where an arrow leaves or enters an end.
type port struct {
	// point is on the outline (plus the arrow gap), where the arrow starts or ends.
	point Point
	// stub is AvoidMargin out from the outline: where the grid search starts or ends.
	stub Point
	// heading is outward: 0 right, 1 down, 2 left, 3 up.
	heading int
	// cost is added to a route that uses it (a side against the flow).
	cost float64
}

// endPort is the port on `end`'s side `heading`, `along` it (nil: lined up with `other` where
// their extents overlap, else the side's middle). A row end has only its left and right ports
// at its row; a free point is its own port every way.
func endPort(end ArrowEnd, heading int, along *float64, other Rect) (port, bool) {
	margin, gap := AvoidMargin, ArrowGap
	switch end.Kind {
	case EndPoint:
		return port{point: end.Point, stub: end.Point, heading: heading}, true
	case EndRow:
		if heading%2 != 0 {
			return port{}, false
		}
		right := heading == 0
		return port{point: Point{pick(right, end.Rect.MaxX()+gap, end.Rect.MinX()-gap), end.Y},
			stub: Point{pick(right, end.Rect.MaxX()+margin, end.Rect.MinX()-margin), end.Y}, heading: heading}, true
	}
	outline := end.Outline
	rect := outline.Rect
	horizontal := heading%2 == 0
	sign := pick(heading < 2, 1, -1)
	var position float64
	if horizontal {
		v := rect.MidY()
		if along != nil {
			v = *along
		} else if m, ok := overlapMid(rect.MinY(), rect.MaxY(), other.MinY(), other.MaxY()); ok {
			v = m
		}
		position = clamp(v, rect.MinY()+4, rect.MaxY()-4)
	} else {
		v := rect.MidX()
		if along != nil {
			v = *along
		} else if m, ok := overlapMid(rect.MinX(), rect.MaxX(), other.MinX(), other.MaxX()); ok {
			v = m
		}
		position = clamp(v, rect.MinX()+4, rect.MaxX()-4)
	}
	var origin, direction Point
	if horizontal {
		origin, direction = Point{rect.MidX(), position}, Point{sign, 0}
	} else {
		origin, direction = Point{position, rect.MidY()}, Point{0, sign}
	}
	edge := boundary(outline, origin, direction)
	point := Point{edge.X + direction.X*gap, edge.Y + direction.Y*gap}
	var stub Point
	if horizontal {
		stub = Point{pick(sign > 0, rect.MaxX()+margin, rect.MinX()-margin), position}
	} else {
		stub = Point{position, pick(sign > 0, rect.MaxY()+margin, rect.MinY()-margin)}
	}
	return port{point: point, stub: stub, heading: heading}, true
}

// sideCost: what leaving (`source`) or entering an end by side `heading` costs: nothing for a
// side facing the other end along the flow (or across the wider gap when the ends aren't in
// flow order); a little for another facing side; more for a side facing across, and a lot for a
// side facing away, when some side faces the other end at all.
func sideCost(heading int, box *Rect, other Rect, flow Flow, source bool) float64 {
	if box == nil {
		return 0
	}
	gaps := [4]float64{other.MinX() - box.MaxX(), other.MinY() - box.MaxY(), box.MinX() - other.MaxX(), box.MinY() - other.MaxY()}
	any := false
	for _, g := range gaps {
		if g > 0 {
			any = true
		}
	}
	if !any {
		return 0
	}
	if !(gaps[heading] > 0) {
		if gaps[(heading+2)%4] > 0 {
			return uTurnCost
		}
		return sideExitCost
	}
	preferred := flow.heading()
	if !source {
		preferred = (flow.heading() + 2) % 4
	}
	if gaps[preferred] > 0 {
		if heading == preferred {
			return 0
		}
		return offFlowCost
	}
	// The widest gap, the lowest heading among equals (max by (gap, -heading)).
	widest := -1
	for h := 0; h < 4; h++ {
		if !(gaps[h] > 0) {
			continue
		}
		if widest < 0 || gaps[h] > gaps[widest] || (gaps[h] == gaps[widest] && -h >= -widest) {
			widest = h
		}
	}
	if widest < 0 {
		widest = heading
	}
	if heading == widest {
		return 0
	}
	return offAxisCost
}
