package route

import (
	"sort"

	"github.com/twaldin/easl/easld/internal/model"
)

// docOrigin is CanvasDocumentView.origin: the app draws in a document whose (0, 0) is canvas
// (-100000, -100000). Its drawing layer routes from document rects offset back to canvas
// coordinates and keeps the routes in document coordinates, so every coordinate the app reports
// of a route has been through `x + 100000 - 100000`, which rounds away bits below 2⁻³⁶.
const docOrigin = 100000.0

func toDoc(v float64) float64 { return v + docOrigin }

// docRoundTrip is canvasPoint(docPoint(p)) on one coordinate.
func docRoundTrip(v float64) float64 { return (v + docOrigin) - docOrigin }

func canvasRectOfDoc(r Rect) Rect {
	if r.IsNull() {
		return r
	}
	return Rect{r.MinX() - docOrigin, r.MinY() - docOrigin, r.Width(), r.Height()}
}

func docRect(f model.Frame) Rect { return Rect{f.X + docOrigin, f.Y + docOrigin, f.W, f.H} }

// DrawnPath is an arrow's route as the app draws and reports it (Board.arrowPath): the routing's
// path through document coordinates and back.
func (r *Result) DrawnPath(id string) ([]Point, bool) {
	path, ok := r.Paths[id]
	if !ok {
		return nil, false
	}
	out := make([]Point, len(path))
	for i, p := range path {
		out[i] = Point{docRoundTrip(p.X), docRoundTrip(p.Y)}
	}
	return out, true
}

// DrawnRouting is the routing the app's drawing layer settles on (ShapeLayer.settleRouting),
// which object frames, arrow detaching, and the next routing (Settled) come from. It differs
// from Routing in three ways, all the app's: ends and obstacles go through document coordinates
// (docRect, then back), a straight or orthogonal arrow's parallel offset counts every arrow
// between the same two objects (`avoid` ones too), and groups are the regions the shown
// obstacles imply (BoardGeometry.regions(shown:)). Code tiles' lines sit at `rows` (the tile's
// wrapped rows as shown; one row per line when absent).
func (g Geometry) DrawnRouting(rows map[string]CodeRows) *Result {
	type arrow struct {
		id   string
		spec ArrowSpec
	}
	var arrows []arrow
	bound := map[string]map[string]bool{}
	for _, o := range sortedObjects(g.Objects, func(o model.Object) bool { return o.Type == model.Arrow }) {
		spec, ok := ParseArrow(o.Props)
		if !ok {
			continue
		}
		arrows = append(arrows, arrow{o.ID, spec})
		for _, id := range []string{spec.From.Object, spec.To.Object} {
			if id == "" {
				continue
			}
			if bound[id] == nil {
				bound[id] = map[string]bool{}
			}
			bound[id][o.ID] = true
		}
	}
	specs := map[string]ArrowSpec{}
	for _, a := range arrows {
		specs[a.id] = a.spec
	}
	// parallelOffset: among the arrows bound to both of the spec's objects.
	parallelOffset := func(id string, spec ArrowSpec) float64 {
		a, b := spec.From.Object, spec.To.Object
		if a == "" || b == "" || a == b {
			return 0
		}
		siblings := map[string]bool{id: true}
		for s := range bound[a] {
			if bound[b][s] {
				siblings[s] = true
			}
		}
		if len(siblings) <= 1 {
			return 0
		}
		var entries []ParallelArrow
		for s := range siblings {
			sp := specs[s]
			entries = append(entries, ParallelArrow{s, sp.From.Object, sp.To.Object})
		}
		return ParallelOffsets(entries)[id]
	}
	// end is ShapeLayer.arrowEnd/end(of:) in document coordinates, then canvasEnd.
	end := func(b Binding) (ArrowEnd, bool) {
		if b.IsPoint() {
			return PointEnd(Point{docRoundTrip(b.Point.X), docRoundTrip(b.Point.Y)}), true
		}
		o, ok := g.Objects[b.Object]
		if !ok || o.Type == model.Arrow {
			return ArrowEnd{}, false
		}
		frame := docRect(o.Frame)
		if b.Lines != nil && o.Type == model.Code {
			zoom := zoomOf(o.Props)
			var r CodeRows
			if rows != nil {
				r = rows[o.ID]
			}
			y := codeNaturalLineY(b.Lines.Start, TileTitleHeight+(frame.Height()-TileTitleHeight)/zoom, o.Props, r)
			docY := frame.MinY() + TileTitleHeight + float64(zoom*(y-TileTitleHeight))
			return RowEnd(canvasRectOfDoc(frame), docY-docOrigin), true
		}
		if b.Node != nil && o.Type == model.Diagram {
			if box, ok := diagramBodyRect(*b.Node, o.Frame, o.Props); ok {
				zoom := zoomOf(o.Props)
				top := frame.MinY() + TileTitleHeight
				rect := Rect{frame.MinX() + float64(zoom*box.MinX()), top + float64(zoom*box.MinY()), zoom * box.Width(), zoom * box.Height()}
				return RectEnd(canvasRectOfDoc(rect)), true
			}
		}
		if o.Type == model.Shape {
			if spec, ok := ParseShape(o.Props); ok && spec.Kind == ShapeEllipse {
				return EllipseEnd(canvasRectOfDoc(frame)), true
			}
		}
		return RectEnd(canvasRectOfDoc(frame)), true
	}
	var connectors []Connector
	for _, a := range arrows {
		from, ok1 := end(a.spec.From)
		to, ok2 := end(a.spec.To)
		if !ok1 || !ok2 {
			continue
		}
		c := Connector{ID: a.id, From: from, To: to, FromObject: a.spec.From.Object, ToObject: a.spec.To.Object}
		if size, ok := g.LabelSizes[a.id]; ok {
			s := size
			c.Label = &s
		}
		if a.spec.Route != Avoid {
			c.Path = Path(from, to, a.spec.Route, parallelOffset(a.id, a.spec), nil, ArrowGap)
		}
		connectors = append(connectors, c)
	}
	var obstacles []Obstacle
	shown := map[string]Rect{}
	for _, o := range sortedObjects(g.Objects, BlocksRoutes) {
		r := canvasRectOfDoc(docRect(o.Frame))
		obstacles = append(obstacles, Obstacle{ID: o.ID, Rect: r})
		shown[o.ID] = r
	}
	sort.SliceStable(obstacles, func(i, j int) bool { return obstacles[i].ID < obstacles[j].ID })
	regions := Geometry{Objects: g.Objects}.RegionsShown(shown)
	return Router{Connectors: connectors, Obstacles: obstacles, Regions: regions}.Route(g.Settled)
}

// diagramBodyRect is DiagramTile.rect(ofNode:): the node's box in the tile body's own points.
func diagramBodyRect(id string, frame model.Frame, props map[string]any) (Rect, bool) {
	g, ok := parseDiagramGraph(props["graph"])
	if !ok {
		return Rect{}, false
	}
	natural := naturalFrame(frame, zoomOf(props))
	return diagramRectIn(g, id, Size{natural.W, swiftMax(0, natural.H-TileTitleHeight)})
}
