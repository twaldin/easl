package route

import (
	"sort"

	"github.com/twaldin/easl/easld/internal/model"
)

// Geometry is BoardGeometry: a board's objects as a value, with the arrow label sizes the
// drawing layer measured, and the routing drawn last (Settled), from which routes nothing has
// touched since keep their way.
//
// Label sizes come from AppKit text layout in Swift (DrawingStyle.arrowLabel: the caption in
// Shantell Sans 15 pt wrapped at 240 pt, chip = ceil(width) + 8 by ceil(height)), which isn't
// portable; nil LabelSizes routes as Swift's Board.arrowPaths does (no labels).
type Geometry struct {
	Objects    map[string]model.Object
	LabelSizes map[string]Size
	Settled    *Result
}

// Routes is a board's arrow routes from object frames alone, labels unmeasured: shorthand for
// Geometry{objects, labelSizes, nil}.Routes(nil, only).
func Routes(objects map[string]model.Object, labelSizes map[string]Size, only []string) map[string][]Point {
	return Geometry{Objects: objects, LabelSizes: labelSizes}.Routes(nil, only)
}

func sortedObjects(objects map[string]model.Object, keep func(model.Object) bool) []model.Object {
	var out []model.Object
	for _, o := range objects {
		if keep(o) {
			out = append(out, o)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// BlocksRoutes: whether arrows route around this object and count as crossing it: tiles, text,
// and filled shapes. Unfilled rects and ellipses, ink, arrows, and groups never block.
func BlocksRoutes(o model.Object) bool {
	switch o.Type {
	case model.Arrow, model.Group:
		return false
	case model.Shape:
		spec, ok := ParseShape(o.Props)
		if !ok {
			return false
		}
		return spec.Kind == ShapeText || (spec.Kind != ShapeInk && spec.Fill != FillNone)
	}
	return true
}

// LeafMembers: members of a group, nested groups expanded, without the groups themselves.
func LeafMembers(id string, objects map[string]model.Object) []string {
	seen := map[string]bool{id: true}
	var result []string
	queue := []string{id}
	for len(queue) > 0 {
		next := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		group, ok := objects[next]
		if !ok {
			continue
		}
		spec, ok := ParseGroup(group.Props)
		if !ok {
			continue
		}
		for _, member := range spec.Members {
			if seen[member] {
				continue
			}
			seen[member] = true
			o, ok := objects[member]
			if !ok {
				continue
			}
			if o.Type == model.Group {
				queue = append(queue, member)
			} else {
				result = append(result, member)
			}
		}
	}
	return result
}

// Routes is every arrow's routed polyline (BoardGeometry.routes(rows:only:)); `only` keeps just
// those arrows (all are routed together). `rows` gives code tiles' visual rows for ends bound to
// lines (one row per line when absent).
func (g Geometry) Routes(rows map[string]CodeRows, only []string) map[string][]Point {
	paths := g.Routing(rows).Paths
	if only == nil {
		return paths
	}
	keep := map[string]bool{}
	for _, id := range only {
		keep[id] = true
	}
	out := map[string][]Point{}
	for id, p := range paths {
		if keep[id] {
			out[id] = p
		}
	}
	return out
}

// Routing is every arrow's route and label placement, as drawn (BoardGeometry.routing): straight
// and orthogonal arrows between the same two objects offset apart; `avoid` arrows routed together
// around blocking objects; an end bound to `lines` of a code tile at that line's row; captions
// clear of tiles, group titles, other arrows, and each other where there is room.
func (g Geometry) Routing(rows map[string]CodeRows) *Result {
	type arrow struct {
		object model.Object
		spec   ArrowSpec
	}
	var arrows []arrow
	for _, o := range sortedObjects(g.Objects, func(o model.Object) bool { return o.Type == model.Arrow }) {
		if spec, ok := ParseArrow(o.Props); ok {
			arrows = append(arrows, arrow{o, spec})
		}
	}
	var parallel []ParallelArrow
	for _, a := range arrows {
		if a.spec.Route != Avoid {
			parallel = append(parallel, ParallelArrow{a.object.ID, a.spec.From.Object, a.spec.To.Object})
		}
	}
	offsets := ParallelOffsets(parallel)
	var connectors []Connector
	for _, a := range arrows {
		from, ok1 := g.arrowEnd(a.spec.From, rows)
		to, ok2 := g.arrowEnd(a.spec.To, rows)
		if !ok1 || !ok2 {
			continue
		}
		c := Connector{ID: a.object.ID, From: from, To: to, FromObject: a.spec.From.Object, ToObject: a.spec.To.Object}
		if size, ok := g.LabelSizes[a.object.ID]; ok {
			s := size
			c.Label = &s
		}
		if a.spec.Route != Avoid {
			c.Path = Path(from, to, a.spec.Route, offsets[a.object.ID], nil, ArrowGap)
		}
		connectors = append(connectors, c)
	}
	var obstacles []Obstacle
	for _, o := range sortedObjects(g.Objects, BlocksRoutes) {
		obstacles = append(obstacles, Obstacle{ID: o.ID, Rect: RectOf(o.Frame)})
	}
	return Router{Connectors: connectors, Obstacles: obstacles, Regions: g.Regions()}.Route(g.Settled)
}

// Regions is the board's groups as the router sees them: frame, leaf members, and flow.
func (g Geometry) Regions() []Region {
	var out []Region
	for _, o := range sortedObjects(g.Objects, func(o model.Object) bool { return o.Type == model.Group }) {
		spec, ok := ParseGroup(o.Props)
		if !ok {
			continue
		}
		members := map[string]bool{}
		for _, id := range LeafMembers(o.ID, g.Objects) {
			members[id] = true
		}
		out = append(out, Region{ID: o.ID, Frame: RectOf(o.Frame), Members: members, Flow: spec.Flow})
	}
	return out
}

// RegionsShown is BoardGeometry.regions(shown:): the groups as they are shown while objects are
// shown away from their frames (tiles held mid-drag): a group holding such a member, nested
// groups included, takes the frame the drop will fit it to; every other group keeps its frame.
func (g Geometry) RegionsShown(shown map[string]Rect) []Region {
	moved := map[string]bool{}
	for id, rect := range shown {
		if o, ok := g.Objects[id]; ok && RectOf(o.Frame) != rect {
			moved[id] = true
		}
	}
	regions := g.Regions()
	if len(moved) == 0 {
		return regions
	}
	type fit struct {
		rect Rect
		ok   bool
	}
	fitted := map[string]fit{}
	var frameOf func(id string, visiting map[string]bool) (Rect, bool)
	frameOf = func(id string, visiting map[string]bool) (Rect, bool) {
		if known, ok := fitted[id]; ok {
			return known.rect, known.ok
		}
		group, ok := g.Objects[id]
		if !ok {
			return Rect{}, false
		}
		spec, ok := ParseGroup(group.Props)
		if !ok {
			return Rect{}, false
		}
		result := RectOf(group.Frame)
		holds := false
		for _, leaf := range LeafMembers(id, g.Objects) {
			if moved[leaf] {
				holds = true
				break
			}
		}
		if holds {
			var rects []Rect
			for _, member := range spec.Members {
				o, ok := g.Objects[member]
				if member == id || visiting[member] || !ok || o.Type == model.Arrow {
					continue
				}
				if o.Type == model.Group {
					inner := map[string]bool{id: true}
					for k := range visiting {
						inner[k] = true
					}
					if r, ok := frameOf(member, inner); ok {
						rects = append(rects, r)
					}
					continue
				}
				if r, ok := shown[member]; ok {
					rects = append(rects, r)
				} else {
					rects = append(rects, RectOf(o.Frame))
				}
			}
			if r, ok := spec.FrameAround(rects); ok {
				result = r
			}
		}
		fitted[id] = fit{result, true}
		return result, true
	}
	for i := range regions {
		if r, ok := frameOf(regions[i].ID, map[string]bool{}); ok {
			regions[i].Frame = r
		}
	}
	return regions
}

// arrowEnd is what a binding attaches to: a point, an object's frame (an ellipse's curve), the
// row of the first of `lines` on a code tile, or a diagram node's box. False when the object is
// gone.
func (g Geometry) arrowEnd(b Binding, rows map[string]CodeRows) (ArrowEnd, bool) {
	if b.IsPoint() {
		return PointEnd(b.Point), true
	}
	o, ok := g.Objects[b.Object]
	if !ok {
		return ArrowEnd{}, false
	}
	if b.Lines != nil && o.Type == model.Code {
		var r CodeRows
		if rows != nil {
			r = rows[b.Object]
		}
		return RowEnd(RectOf(o.Frame), CodeLineY(b.Lines.Start, o.Frame, o.Props, r)), true
	}
	if b.Node != nil && o.Type == model.Diagram {
		if rect, ok := diagramCanvasRect(*b.Node, o.Frame, o.Props); ok {
			return RectEnd(rect), true
		}
	}
	if o.Type == model.Shape {
		if spec, ok := ParseShape(o.Props); ok && spec.Kind == ShapeEllipse {
			return EllipseEnd(RectOf(o.Frame)), true
		}
	}
	return RectEnd(RectOf(o.Frame)), true
}

// CountsForOverlaps: whether an object can overlap others by accident: not arrows, ink, or
// unfilled rects and ellipses (annotations drawn over or around things).
func CountsForOverlaps(o model.Object) bool {
	switch o.Type {
	case model.Arrow:
		return false
	case model.Shape:
		spec, ok := ParseShape(o.Props)
		if !ok {
			return true
		}
		return spec.Kind != ShapeInk && !((spec.Kind == ShapeRect || spec.Kind == ShapeEllipse) && spec.Fill == FillNone)
	}
	return true
}

// Overlaps is BoardGeometry.overlaps(scope:): pairs (sorted ids) of objects that overlap by
// accident, involving `scope` (every object when nil): CountsForOverlaps objects, a group and
// its (nested) members never.
func Overlaps(objects map[string]model.Object, scope []string) [][]string {
	var inScope map[string]bool
	if scope != nil {
		inScope = map[string]bool{}
		for _, id := range scope {
			inScope[id] = true
		}
	}
	return overlaps(objects, inScope)
}

func overlaps(objects map[string]model.Object, scope map[string]bool) [][]string {
	solid := sortedObjects(objects, CountsForOverlaps)
	groupMembers := map[string]map[string]bool{}
	members := func(group model.Object) map[string]bool {
		if cached, ok := groupMembers[group.ID]; ok {
			return cached
		}
		all := map[string]bool{}
		for _, id := range LeafMembers(group.ID, objects) {
			all[id] = true
		}
		queue := []string{group.ID}
		for len(queue) > 0 {
			next := queue[len(queue)-1]
			queue = queue[:len(queue)-1]
			var props any
			if o, ok := objects[next]; ok {
				props = o.Props
			}
			spec, _ := ParseGroup(props)
			for _, member := range spec.Members {
				if o, ok := objects[member]; ok && o.Type == model.Group && !all[member] {
					all[member] = true
					queue = append(queue, member)
				}
			}
		}
		groupMembers[group.ID] = all
		return all
	}
	result := [][]string{}
	for index, a := range solid {
		for _, b := range solid[index+1:] {
			if scope != nil && !scope[a.ID] && !scope[b.ID] {
				continue
			}
			if !a.Frame.Intersects(b.Frame) { // Frame.intersects, not CGRect's
				continue
			}
			if a.Type == model.Group && members(a)[b.ID] {
				continue
			}
			if b.Type == model.Group && members(b)[a.ID] {
				continue
			}
			result = append(result, []string{a.ID, b.ID})
		}
	}
	return result
}
