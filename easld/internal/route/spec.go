package route

import (
	"math"

	"github.com/twaldin/easl/easld/internal/model"
)

// RouteStyle is how an arrow travels between its ends (ArrowRouteStyle, `ArrowProps.route`).
type RouteStyle string

const (
	// Straight: one segment between the facing sides.
	Straight RouteStyle = "straight"
	// Orthogonal: horizontal and vertical segments with one jog between the facing sides.
	Orthogonal RouteStyle = "orthogonal"
	// Avoid: horizontal and vertical segments around every tile in the way.
	Avoid RouteStyle = "avoid"
)

// Flow is which way a diagram reads (`GroupProps.flow`, ConnectorRouter.Flow).
type Flow string

const (
	FlowRight Flow = "right"
	FlowDown  Flow = "down"
	FlowLeft  Flow = "left"
	FlowUp    Flow = "up"
)

// heading is the outward heading of the downstream side: 0 right, 1 down, 2 left, 3 up.
func (f Flow) heading() int {
	switch f {
	case FlowDown:
		return 1
	case FlowLeft:
		return 2
	case FlowUp:
		return 3
	}
	return 0
}

func parseFlow(v any) *Flow {
	s, _ := v.(string)
	switch f := Flow(s); f {
	case FlowRight, FlowDown, FlowLeft, FlowUp:
		return &f
	}
	return nil
}

// Binding is one end of an arrow (ArrowBinding): bound to an object (optionally to lines or a
// DOM selector inside it, or to a diagram node), or a free point when Object is "".
type Binding struct {
	Object   string
	Lines    *model.LineRange
	Selector *string
	Node     *string
	Point    Point
}

// IsPoint: a free end.
func (b Binding) IsPoint() bool { return b.Object == "" }

func (b Binding) equal(o Binding) bool {
	if b.Object != o.Object || b.Point != o.Point || !eqPtr(b.Selector, o.Selector) || !eqPtr(b.Node, o.Node) {
		return false
	}
	if (b.Lines == nil) != (o.Lines == nil) {
		return false
	}
	return b.Lines == nil || *b.Lines == *o.Lines
}

func eqPtr[T comparable](a, b *T) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// ParseBinding is ArrowBinding.init?(json): `object` (a string) wins, else `point` holding
// exactly two numbers (other items are skipped, as compactMap does).
func ParseBinding(v any) (Binding, bool) {
	m, _ := v.(map[string]any)
	if id, ok := m["object"].(string); ok {
		b := Binding{Object: id}
		if r, ok := model.LineRangeFromJSON(m["lines"]); ok {
			b.Lines = &r
		}
		if s, ok := m["selector"].(string); ok {
			b.Selector = &s
		}
		if s, ok := m["node"].(string); ok {
			b.Node = &s
		}
		return b, true
	}
	items, _ := m["point"].([]any)
	var values []float64
	for _, item := range items {
		if f, ok := item.(float64); ok {
			values = append(values, f)
		}
	}
	if items != nil && len(values) == 2 {
		return Binding{Point: Point{values[0], values[1]}}, true
	}
	return Binding{}, false
}

// JSON is ArrowBinding.json.
func (b Binding) JSON() map[string]any {
	if b.IsPoint() {
		return map[string]any{"point": []any{b.Point.X, b.Point.Y}}
	}
	out := map[string]any{"object": b.Object}
	if b.Lines != nil {
		out["lines"] = b.Lines.JSON()
	}
	if b.Selector != nil {
		out["selector"] = *b.Selector
	}
	if b.Node != nil {
		out["node"] = *b.Node
	}
	return out
}

// ArrowSpec is the typed view of `ArrowProps`.
type ArrowSpec struct {
	From, To               Binding
	Relation, Label, Color *string
	Route                  RouteStyle
}

// ParseArrow is ArrowSpec.init?(props): nil unless both ends parse; an unknown route is straight.
func ParseArrow(props any) (ArrowSpec, bool) {
	m, _ := props.(map[string]any)
	from, ok1 := ParseBinding(m["from"])
	to, ok2 := ParseBinding(m["to"])
	if m == nil || !ok1 || !ok2 {
		return ArrowSpec{}, false
	}
	spec := ArrowSpec{From: from, To: to, Relation: str(m["relation"]), Label: str(m["label"]), Color: str(m["color"]), Route: Straight}
	if s, ok := m["route"].(string); ok {
		switch r := RouteStyle(s); r {
		case Straight, Orthogonal, Avoid:
			spec.Route = r
		}
	}
	return spec, true
}

func str(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}

// Props is ArrowSpec.props: route only when not straight.
func (s ArrowSpec) Props() map[string]any {
	out := map[string]any{"from": s.From.JSON(), "to": s.To.JSON()}
	if s.Relation != nil {
		out["relation"] = *s.Relation
	}
	if s.Label != nil {
		out["label"] = *s.Label
	}
	if s.Color != nil {
		out["color"] = *s.Color
	}
	if s.Route != Straight {
		out["route"] = string(s.Route)
	}
	return out
}

// Translated moves free ends by (dx, dy); bound ends follow their objects anyway.
func (s ArrowSpec) Translated(dx, dy float64) ArrowSpec {
	move := func(b Binding) Binding {
		if b.IsPoint() {
			b.Point = Point{b.Point.X + dx, b.Point.Y + dy}
		}
		return b
	}
	s.From, s.To = move(s.From), move(s.To)
	return s
}

// Caption is what the arrow draws on its chip (`label`, else `relation`); "" draws none.
func (s ArrowSpec) Caption() string {
	if s.Label != nil {
		return *s.Label
	}
	if s.Relation != nil {
		return *s.Relation
	}
	return ""
}

// ShapeKind and ShapeFill are ShapeSpec.Kind and ShapeSpec.Fill.
type (
	ShapeKind string
	ShapeFill string
)

const (
	ShapeRect    ShapeKind = "rect"
	ShapeEllipse ShapeKind = "ellipse"
	ShapeText    ShapeKind = "text"
	ShapeInk     ShapeKind = "ink"

	FillNone  ShapeFill = "none"
	FillSemi  ShapeFill = "semi"
	FillSolid ShapeFill = "solid"
)

// ShapeSpec is the part of `ShapeProps` geometry reads: kind and fill.
type ShapeSpec struct {
	Kind ShapeKind
	Fill ShapeFill
}

// ParseShape is ShapeSpec.init?(props): nil without a known kind; an unknown fill is none.
func ParseShape(props any) (ShapeSpec, bool) {
	m, _ := props.(map[string]any)
	kind, _ := m["kind"].(string)
	switch k := ShapeKind(kind); k {
	case ShapeRect, ShapeEllipse, ShapeText, ShapeInk:
		spec := ShapeSpec{Kind: k, Fill: FillNone}
		if f, ok := m["fill"].(string); ok {
			switch ShapeFill(f) {
			case FillNone, FillSemi, FillSolid:
				spec.Fill = ShapeFill(f)
			}
		}
		return spec, true
	}
	return ShapeSpec{}, false
}

// GroupTitleHeight is the band above a group's members holding its title (GroupSpec.titleHeight).
const GroupTitleHeight = 32.0

// GroupDefaultPadding is GroupSpec.defaultPadding.
const GroupDefaultPadding = 24.0

// GroupSpec is the typed view of `GroupProps`.
type GroupSpec struct {
	Members      []string
	Title, Color *string
	Padding      float64
	Flow         *Flow
}

// ParseGroup is GroupSpec.init?(props): nil unless `members` is an array (non-strings skipped).
func ParseGroup(props any) (GroupSpec, bool) {
	m, _ := props.(map[string]any)
	items, ok := m["members"].([]any)
	if !ok {
		return GroupSpec{}, false
	}
	spec := GroupSpec{Members: []string{}, Title: str(m["title"]), Color: str(m["color"]), Padding: GroupDefaultPadding, Flow: parseFlow(m["flow"])}
	for _, item := range items {
		if s, ok := item.(string); ok {
			spec.Members = append(spec.Members, s)
		}
	}
	if p, ok := m["padding"].(float64); ok {
		spec.Padding = swiftMax(0, p)
	}
	return spec, true
}

// FrameAround is GroupSpec.frame(around:): the rects' union, `padding` on every side, and the
// title band on top; false without rects.
func (g GroupSpec) FrameAround(rects []Rect) (Rect, bool) {
	if len(rects) == 0 {
		return Rect{}, false
	}
	u := rects[0]
	for _, r := range rects[1:] {
		u = u.Union(r)
	}
	inset := g.Padding
	return Rect{X: u.MinX() - inset, Y: u.MinY() - inset - GroupTitleHeight, W: u.Width() + 2*inset, H: u.Height() + 2*inset + GroupTitleHeight}, true
}

// zoomOf is ObjectZoom.of: `props.zoom` clamped to 0.25…8, 1 when absent or not positive.
func zoomOf(props map[string]any) float64 {
	v, ok := props["zoom"].(float64)
	if !ok || math.IsInf(v, 0) || math.IsNaN(v) || v <= 0 {
		return 1
	}
	return swiftMin(swiftMax(v, 0.25), 8)
}

// TileTitleHeight is RenderMath.tileTitleHeight.
const TileTitleHeight = 26.0

// naturalFrame is ObjectZoom.natural: the frame a tile lays its content out in at `zoom`.
func naturalFrame(f model.Frame, zoom float64) model.Frame {
	return model.Frame{X: f.X, Y: f.Y, W: f.W / zoom, H: TileTitleHeight + swiftMax(0, f.H-TileTitleHeight)/zoom}
}
