package route

import (
	"math"
	"sort"
)

// DrawingGeometry and ArrowRouting constants.
const (
	// ArrowGap is the space between an arrow tip and the outline it's bound to.
	ArrowGap = 6.0
	// ParallelSpacing is the distance between arrows drawn between the same two objects.
	ParallelSpacing = 20.0
	// AvoidMargin is the clearance an `avoid` route keeps from the tiles it passes.
	AvoidMargin = 18.0
	// LabelClearance is the space between an arrow and its label.
	LabelClearance = 6.0
)

// Outline is what a bound arrow end attaches to: a rect, or the ellipse inscribed in it.
type Outline struct {
	Rect    Rect
	Ellipse bool
}

// EndKind tells the three kinds of arrow end apart.
type EndKind int

const (
	// EndPoint is a free point.
	EndPoint EndKind = iota
	// EndBound is bound to an outline.
	EndBound
	// EndRow is bound to one row of a tile (a code line, `Binding.lines`): it attaches to the
	// tile's left or right edge at Y, whichever faces the other end (the right edge when the
	// two overlap horizontally), and never moves along the edge for parallel offsets.
	EndRow
)

// ArrowEnd is DrawingGeometry.ArrowEnd. Comparable with ==.
type ArrowEnd struct {
	Kind    EndKind
	Point   Point   // EndPoint
	Outline Outline // EndBound
	Rect    Rect    // EndRow
	Y       float64 // EndRow
}

func PointEnd(p Point) ArrowEnd { return ArrowEnd{Kind: EndPoint, Point: p} }
func RectEnd(r Rect) ArrowEnd   { return ArrowEnd{Kind: EndBound, Outline: Outline{Rect: r}} }
func EllipseEnd(r Rect) ArrowEnd {
	return ArrowEnd{Kind: EndBound, Outline: Outline{Rect: r, Ellipse: true}}
}
func RowEnd(r Rect, y float64) ArrowEnd { return ArrowEnd{Kind: EndRow, Rect: r, Y: y} }

// Aim is what the other end aims at: the outline's bounds, the row (zero height), or the point.
func (e ArrowEnd) Aim() Rect {
	switch e.Kind {
	case EndBound:
		return e.Outline.Rect
	case EndRow:
		return Rect{X: e.Rect.MinX(), Y: e.Y, W: e.Rect.Width(), H: 0}
	}
	return Rect{X: e.Point.X, Y: e.Point.Y}
}

// box is the bound object's box; false for a free point.
func (e ArrowEnd) box() (Rect, bool) {
	switch e.Kind {
	case EndBound:
		return e.Outline.Rect, true
	case EndRow:
		return e.Rect, true
	}
	return Rect{}, false
}

func (e ArrowEnd) boxOrAim() Rect {
	if b, ok := e.box(); ok {
		return b
	}
	return e.Aim()
}

// rowSideIsRight: a row end on `rect` attaches on its right edge to reach `other` unless
// `other` lies wholly to its left.
func rowSideIsRight(rect, other Rect) bool { return other.MaxX() > rect.MinX() }

// RouteEnds is DrawingGeometry.route: the straight route between two ends. A bound end leaves
// from the side of its outline that faces the other end: through the middle of the overlap when
// the two sit side by side (or stacked), else aiming center to center. `offset` moves the whole
// route sideways (positive: left of travel).
func RouteEnds(from, to ArrowEnd, gap, offset float64) (Point, Point) {
	var shift Point
	if offset != 0 {
		a, b := from.Aim(), to.Aim()
		d := Point{b.MidX() - a.MidX(), b.MidY() - a.MidY()}
		length := hypot(d.X, d.Y)
		if length > 0 {
			shift = Point{float64(d.Y/length) * offset, float64(-d.X/length) * offset}
		}
	}
	return attach(from, to.Aim(), gap, shift), attach(to, from.Aim(), gap, shift)
}

func attach(end ArrowEnd, other Rect, gap float64, shift Point) Point {
	var outline Outline
	switch end.Kind {
	case EndPoint:
		return end.Point
	case EndRow:
		if rowSideIsRight(end.Rect, other) {
			return Point{end.Rect.MaxX() + gap, end.Y}
		}
		return Point{end.Rect.MinX() - gap, end.Y}
	default:
		outline = end.Outline
	}
	rect := outline.Rect
	y0, y1 := swiftMax(rect.MinY(), other.MinY()), swiftMin(rect.MaxY(), other.MaxY())
	x0, x1 := swiftMax(rect.MinX(), other.MinX()), swiftMin(rect.MaxX(), other.MaxX())
	if y0 <= y1 && (other.MinX() >= rect.MaxX() || other.MaxX() <= rect.MinX()) {
		right := other.MinX() >= rect.MaxX()
		y := clamp((y0+y1)/2+shift.Y, y0+2, y1-2)
		dir := -1.0
		if right {
			dir = 1
		}
		edge := boundary(outline, Point{rect.MidX(), y}, Point{dir, 0})
		return Point{edge.X + dir*gap, y}
	}
	if x0 <= x1 && (other.MinY() >= rect.MaxY() || other.MaxY() <= rect.MinY()) {
		down := other.MinY() >= rect.MaxY()
		x := clamp((x0+x1)/2+shift.X, x0+2, x1-2)
		dir := -1.0
		if down {
			dir = 1
		}
		edge := boundary(outline, Point{x, rect.MidY()}, Point{0, dir})
		return Point{x, edge.Y + dir*gap}
	}
	center := Point{clamp(rect.MidX()+shift.X, rect.MinX()+2, rect.MaxX()-2), clamp(rect.MidY()+shift.Y, rect.MinY()+2, rect.MaxY()-2)}
	direction := Point{other.MidX() + shift.X - center.X, other.MidY() + shift.Y - center.Y}
	length := hypot(direction.X, direction.Y)
	if length > 0 {
		direction = Point{direction.X / length, direction.Y / length}
	} else {
		direction = Point{0, -1}
	}
	edge := boundary(outline, center, direction)
	return Point{edge.X + float64(direction.X*gap), edge.Y + float64(direction.Y*gap)}
}

// overlapMid is the midpoint of the overlap of two closed intervals; false when apart.
func overlapMid(a0, a1, b0, b1 float64) (float64, bool) {
	low, high := swiftMax(a0, b0), swiftMin(a1, b1)
	if low <= high {
		return (low + high) / 2, true
	}
	return 0, false
}

// boundary is where a ray from `origin` (inside the outline) along a unit `direction` leaves it.
func boundary(outline Outline, origin, direction Point) Point {
	rect := outline.Rect
	if !outline.Ellipse {
		tx, ty := math.Inf(1), math.Inf(1)
		if direction.X > 0 {
			tx = (rect.MaxX() - origin.X) / direction.X
		} else if direction.X < 0 {
			tx = (rect.MinX() - origin.X) / direction.X
		}
		if direction.Y > 0 {
			ty = (rect.MaxY() - origin.Y) / direction.Y
		} else if direction.Y < 0 {
			ty = (rect.MinY() - origin.Y) / direction.Y
		}
		t := swiftMax(0, swiftMin(tx, ty))
		return Point{origin.X + float64(direction.X*t), origin.Y + float64(direction.Y*t)}
	}
	// Solve |((o + t·d) - c) / r|² = 1 for the positive root.
	rx := swiftMax(rect.Width()/2, 0.0001)
	ry := swiftMax(rect.Height()/2, 0.0001)
	ox := (origin.X - rect.MidX()) / rx
	oy := (origin.Y - rect.MidY()) / ry
	dx := direction.X / rx
	dy := direction.Y / ry
	a := float64(dx*dx) + float64(dy*dy)
	b := 2 * (float64(ox*dx) + float64(oy*dy))
	c := float64(ox*ox) + float64(oy*oy) - 1
	t := 0.0
	if a > 0 {
		t = swiftMax(0, (-b+math.Sqrt(float64(b*b)-float64(4*a*c)))/(2*a))
	}
	return Point{origin.X + float64(direction.X*t), origin.Y + float64(direction.Y*t)}
}

// DistanceToSegment is the distance from p to segment a–b.
func DistanceToSegment(p, a, b Point) float64 {
	dx, dy := b.X-a.X, b.Y-a.Y
	lengthSquared := float64(dx*dx) + float64(dy*dy)
	if !(lengthSquared > 0) {
		return hypot(p.X-a.X, p.Y-a.Y)
	}
	t := swiftMax(0, swiftMin(1, (float64((p.X-a.X)*dx)+float64((p.Y-a.Y)*dy))/lengthSquared))
	return hypot(p.X-(a.X+float64(t*dx)), p.Y-(a.Y+float64(t*dy)))
}

func distanceToRectBorder(p Point, r Rect) float64 {
	if r.Contains(p) {
		return swiftMin(p.X-r.MinX(), r.MaxX()-p.X, p.Y-r.MinY(), r.MaxY()-p.Y)
	}
	dx := swiftMax(r.MinX()-p.X, 0, p.X-r.MaxX())
	dy := swiftMax(r.MinY()-p.Y, 0, p.Y-r.MaxY())
	return hypot(dx, dy)
}

// Path is DrawingGeometry.path: a routed arrow's polyline (at least two points) from `from` to
// `to`. `offset` moves a straight or orthogonal route sideways so parallel arrows draw apart;
// `obstacles` are what a lone `avoid` route goes around (a board routes its `avoid` arrows
// together, see Geometry.Routing).
func Path(from, to ArrowEnd, style RouteStyle, offset float64, obstacles []Rect, gap float64) []Point {
	switch style {
	case Orthogonal:
		return orthogonal(from, to, offset, gap)
	case Avoid:
		obs := make([]Obstacle, len(obstacles))
		for i, r := range obstacles {
			obs[i] = Obstacle{ID: "obstacle." + itoa(i), Rect: r}
		}
		router := Router{Connectors: []Connector{{ID: "", From: from, To: to}}, Obstacles: obs}
		if path, ok := router.Route(nil).Paths[""]; ok {
			return path
		}
		return orthogonal(from, to, offset, gap)
	}
	start, end := RouteEnds(from, to, gap, offset)
	return []Point{start, end}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for ; i > 0; i /= 10 {
		b = append([]byte{byte('0' + i%10)}, b...)
	}
	return string(b)
}

// ParallelArrow is one arrow for ParallelOffsets: its id and bound objects ("" for a free end).
type ParallelArrow struct{ ID, From, To string }

// ParallelOffsets gives arrows whose two ends are bound to the same pair of objects (either
// direction) signed sideways offsets so none draws on top of another; lone arrows get none.
// Offsets are relative to each arrow's own direction, so opposite arrows land on opposite sides.
func ParallelOffsets(arrows []ParallelArrow) map[string]float64 {
	type member struct {
		id        string
		canonical bool
	}
	pairs := map[string][]member{}
	for _, a := range arrows {
		if a.From == "" || a.To == "" || a.From == a.To {
			continue
		}
		lo, hi := a.From, a.To
		if hi < lo {
			lo, hi = hi, lo
		}
		key := lo + "|" + hi
		pairs[key] = append(pairs[key], member{a.ID, a.From < a.To})
	}
	offsets := map[string]float64{}
	for _, members := range pairs {
		if len(members) < 2 {
			continue
		}
		sorted := append([]member(nil), members...)
		sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].id < sorted[j].id })
		for index, m := range sorted {
			shift := float64((float64(index) - float64(len(sorted)-1)/2) * ParallelSpacing)
			if m.canonical {
				offsets[m.id] = shift
			} else {
				offsets[m.id] = -shift
			}
		}
	}
	return offsets
}

// orthogonal leaves the facing side, jogs once halfway, and enters the other's facing side;
// runs straight when the sides line up. A row end always leaves sideways: when the two overlap
// horizontally the route loops around their right edges.
func orthogonal(from, to ArrowEnd, offset, gap float64) []Point {
	a, b := from.boxOrAim(), to.boxOrAim()
	gapX := swiftMax(b.MinX()-a.MaxX(), a.MinX()-b.MaxX())
	gapY := swiftMax(b.MinY()-a.MaxY(), a.MinY()-b.MaxY())
	if !(gapX > 0 || gapY > 0) {
		return Path(from, to, Straight, offset, nil, gap)
	}
	rows := from.Kind == EndRow || to.Kind == EndRow
	if rows && gapX <= 0 {
		start := sidePort(from, true, true, -offset, to.Aim(), gap)
		end := sidePort(to, true, true, -offset, from.Aim(), gap)
		x := swiftMax(a.MaxX(), b.MaxX()) + gap + 24 + offset
		return simplified([]Point{start, {x, start.Y}, {x, end.Y}, end})
	}
	horizontal := rows || gapX >= gapY
	// Offsets are perpendicular to travel; along a horizontal run that is -y when heading right.
	var forward bool
	if horizontal {
		forward = b.MidX() >= a.MidX()
	} else {
		forward = b.MidY() >= a.MidY()
	}
	across := offset
	if horizontal == forward {
		across = -offset
	}
	start := sidePort(from, horizontal, forward, across, to.Aim(), gap)
	end := sidePort(to, horizontal, !forward, across, from.Aim(), gap)
	if horizontal {
		jog := (start.X+end.X)/2 + pick(forward, offset, -offset)
		return simplified([]Point{start, {jog, start.Y}, {jog, end.Y}, end})
	}
	jog := (start.Y+end.Y)/2 + pick(forward, -offset, offset)
	return simplified([]Point{start, {start.X, jog}, {end.X, jog}, end})
}

func pick(c bool, a, b float64) float64 {
	if c {
		return a
	}
	return b
}

// sidePort is DrawingGeometry.port: where a route leaves `end` along an axis: the middle of its
// side (moved `across` along the side, and lined up with `other` when their extents overlap),
// `gap` off the outline. A row end leaves its left or right edge at its row.
func sidePort(end ArrowEnd, horizontal, positive bool, across float64, other Rect, gap float64) Point {
	switch end.Kind {
	case EndPoint:
		return end.Point
	case EndRow:
		return Point{pick(positive, end.Rect.MaxX()+gap, end.Rect.MinX()-gap), end.Y}
	}
	outline := end.Outline
	rect := outline.Rect
	dir := pick(positive, 1, -1)
	if horizontal {
		shared, ok := overlapMid(rect.MinY(), rect.MaxY(), other.MinY(), other.MaxY())
		if !ok {
			shared = rect.MidY()
		}
		y := clamp(shared+across, rect.MinY()+4, rect.MaxY()-4)
		edge := boundary(outline, Point{rect.MidX(), y}, Point{dir, 0})
		return Point{edge.X + dir*gap, y}
	}
	shared, ok := overlapMid(rect.MinX(), rect.MaxX(), other.MinX(), other.MaxX())
	if !ok {
		shared = rect.MidX()
	}
	x := clamp(shared+across, rect.MinX()+4, rect.MaxX()-4)
	edge := boundary(outline, Point{x, rect.MidY()}, Point{0, dir})
	return Point{x, edge.Y + dir*gap}
}

func clamp(value, low, high float64) float64 {
	if low <= high {
		return swiftMin(swiftMax(value, low), high)
	}
	return (low + high) / 2
}

// simplified drops repeated points and middle points of straight runs.
func simplified(points []Point) []Point {
	result := make([]Point, 0, len(points))
	for _, p := range points {
		if n := len(result); n > 0 {
			last := result[n-1]
			if math.Abs(last.X-p.X) < 0.01 && math.Abs(last.Y-p.Y) < 0.01 {
				continue
			}
		}
		if n := len(result); n >= 2 {
			a, b := result[n-2], result[n-1]
			cross := float64((b.X-a.X)*(p.Y-b.Y)) - float64((b.Y-a.Y)*(p.X-b.X))
			if math.Abs(cross) < 0.01 {
				result[n-1] = p
				continue
			}
		}
		result = append(result, p)
	}
	if len(result) == 1 {
		result = append(result, result[0])
	}
	return result
}

// LabelAlong is DrawingGeometry.label(along:): where one arrow's label of `size` goes along
// `path` alone, clear of `obstacles` and `titles` where it can be.
func LabelAlong(path []Point, size Size, obstacles, titles []Rect) Label {
	var first, last Point
	if len(path) > 0 {
		first, last = path[0], path[len(path)-1]
	}
	connector := Connector{ID: "", From: PointEnd(first), To: PointEnd(last), Label: &size, Path: path}
	if label, ok := placeLabels([]Connector{connector}, [][]Point{path}, obstacles, titles, nil)[""]; ok {
		return label
	}
	return Label{Rect: Rect{first.X, first.Y, size.W, size.H}}
}

// DistanceToPath is the distance from a point to a polyline.
func DistanceToPath(p Point, path []Point) float64 {
	if len(path) <= 1 {
		if len(path) == 1 {
			return hypot(path[0].X-p.X, path[0].Y-p.Y)
		}
		return math.Inf(1)
	}
	best := math.Inf(1)
	for i := range len(path) - 1 {
		d := DistanceToSegment(p, path[i], path[i+1])
		if i == 0 || d < best {
			best = d
		}
	}
	return best
}

// distanceFromPath is the smallest gap between the path and a rect (0 when they touch).
func distanceFromPath(path []Point, r Rect) float64 {
	for i := range len(path) - 1 {
		if segmentIntersects(path[i], path[i+1], r) {
			return 0
		}
	}
	corners := []Point{{r.MinX(), r.MinY()}, {r.MaxX(), r.MinY()}, {r.MinX(), r.MaxY()}, {r.MaxX(), r.MaxY()}}
	fromCorners := math.Inf(1)
	for i, c := range corners {
		if d := DistanceToPath(c, path); i == 0 || d < fromCorners {
			fromCorners = d
		}
	}
	fromPoints := math.Inf(1)
	for i, p := range path {
		if d := distanceToRectBorder(p, r); i == 0 || d < fromPoints {
			fromPoints = d
		}
	}
	return swiftMin(fromCorners, fromPoints)
}

// PathCrosses is DrawingGeometry.path(_:crosses:): whether any segment of the path passes
// through the rect's interior.
func PathCrosses(path []Point, r Rect) bool {
	inner := r.InsetBy(0.5, 0.5)
	if inner.IsEmpty() {
		return false
	}
	for i := range len(path) - 1 {
		if segmentIntersects(path[i], path[i+1], inner) {
			return true
		}
	}
	return false
}

// segmentIntersects is the Liang–Barsky clip of segment a–b against a rect.
func segmentIntersects(a, b Point, r Rect) bool {
	t0, t1 := 0.0, 1.0
	dx, dy := b.X-a.X, b.Y-a.Y
	for _, pq := range [4][2]float64{{-dx, a.X - r.MinX()}, {dx, r.MaxX() - a.X}, {-dy, a.Y - r.MinY()}, {dy, r.MaxY() - a.Y}} {
		p, q := pq[0], pq[1]
		if p == 0 {
			if q < 0 {
				return false
			}
			continue
		}
		ratio := q / p
		if p < 0 {
			t0 = swiftMax(t0, ratio)
		} else {
			t1 = swiftMin(t1, ratio)
		}
		if t0 > t1 {
			return false
		}
	}
	return true
}

// minHeap is the binary min-heap of (state, priority) the route search uses; its tie order is
// Swift's, which the search's result depends on.
type minHeap struct {
	items []heapItem
}

type heapItem struct {
	state    int
	priority float64
}

func (h *minHeap) push(state int, priority float64) {
	h.items = append(h.items, heapItem{state, priority})
	child := len(h.items) - 1
	for child > 0 {
		parent := (child - 1) / 2
		if !(h.items[child].priority < h.items[parent].priority) {
			break
		}
		h.items[child], h.items[parent] = h.items[parent], h.items[child]
		child = parent
	}
}

func (h *minHeap) pop() (int, bool) {
	if len(h.items) == 0 {
		return 0, false
	}
	top := h.items[0]
	last := h.items[len(h.items)-1]
	h.items = h.items[:len(h.items)-1]
	if len(h.items) > 0 {
		h.items[0] = last
		parent := 0
		for {
			left := 2*parent + 1
			right := left + 1
			smallest := parent
			if left < len(h.items) && h.items[left].priority < h.items[smallest].priority {
				smallest = left
			}
			if right < len(h.items) && h.items[right].priority < h.items[smallest].priority {
				smallest = right
			}
			if smallest == parent {
				break
			}
			h.items[parent], h.items[smallest] = h.items[smallest], h.items[parent]
			parent = smallest
		}
	}
	return top.state, true
}
