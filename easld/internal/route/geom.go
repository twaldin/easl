// Package route is the pure geometry of a board's arrows, ported from Sources/CanvasCore:
// DrawingGeometry/ArrowRouting (straight and orthogonal paths, parallel offsets, path queries),
// ConnectorRouter (`avoid` routing around tiles, ports, nudged tracks, flow, label placement),
// RouteQuality (arrows on top of or crossing each other) and BoardGeometry (arrow ends from
// bindings, regions, a board's routing).
//
// Numbers follow Swift's CGFloat (float64) exactly: products are rounded before they are added
// (`float64(a*b) + c`) because Go may fuse a multiply-add into one FMA on arm64 where Swift
// doesn't, and iteration orders are Swift's wherever they can change a result.
package route

import (
	"math"

	"github.com/twaldin/easl/easld/internal/model"
)

// Point is a CGPoint.
type Point struct{ X, Y float64 }

// Size is a CGSize.
type Size struct{ W, H float64 }

// Rect is a CGRect with CoreGraphics semantics: negative sizes are standardized by the
// accessors, a null rect (origin at +∞) is what an inset past empty or a missed intersection
// gives, and it intersects and contains nothing.
type Rect struct{ X, Y, W, H float64 }

// NullRect is CGRect.null.
var NullRect = Rect{X: math.Inf(1), Y: math.Inf(1)}

// RectOf is Frame.rect.
func RectOf(f model.Frame) Rect { return Rect{f.X, f.Y, f.W, f.H} }

// Frame is Frame(rect): the rect's standardized origin and size.
func (r Rect) Frame() model.Frame {
	return model.Frame{X: r.MinX(), Y: r.MinY(), W: r.Width(), H: r.Height()}
}

func (r Rect) IsNull() bool { return math.IsInf(r.X, 1) || math.IsInf(r.Y, 1) }

// IsEmpty: null, or no width or no height.
func (r Rect) IsEmpty() bool { return r.IsNull() || r.W == 0 || r.H == 0 }

func (r Rect) MinX() float64 {
	if r.W < 0 {
		return r.X + r.W
	}
	return r.X
}

func (r Rect) MaxX() float64 {
	if r.W < 0 {
		return r.X
	}
	return r.X + r.W
}

func (r Rect) MinY() float64 {
	if r.H < 0 {
		return r.Y + r.H
	}
	return r.Y
}

func (r Rect) MaxY() float64 {
	if r.H < 0 {
		return r.Y
	}
	return r.Y + r.H
}
func (r Rect) MidX() float64   { return r.X + r.W/2 }
func (r Rect) MidY() float64   { return r.Y + r.H/2 }
func (r Rect) Width() float64  { return math.Abs(r.W) }
func (r Rect) Height() float64 { return math.Abs(r.H) }

func (r Rect) standard() Rect { return Rect{r.MinX(), r.MinY(), r.Width(), r.Height()} }

// InsetBy is CGRectInset: null when the result would have a negative size.
func (r Rect) InsetBy(dx, dy float64) Rect {
	if r.IsNull() {
		return NullRect
	}
	s := r.standard()
	s = Rect{s.X + dx, s.Y + dy, s.W - 2*dx, s.H - 2*dy}
	if s.W < 0 || s.H < 0 {
		return NullRect
	}
	return s
}

// Intersects is CGRectIntersectsRect: open overlap on both axes, so rects that only touch
// don't intersect, while a zero-size rect strictly inside does.
func (r Rect) Intersects(o Rect) bool {
	if r.IsNull() || o.IsNull() {
		return false
	}
	return r.MinX() < o.MaxX() && o.MinX() < r.MaxX() && r.MinY() < o.MaxY() && o.MinY() < r.MaxY()
}

// Intersection is CGRectIntersection: closed overlap (touching rects give a zero-size rect),
// null when apart.
func (r Rect) Intersection(o Rect) Rect {
	if r.IsNull() || o.IsNull() {
		return NullRect
	}
	x0, x1 := swiftMax(r.MinX(), o.MinX()), swiftMin(r.MaxX(), o.MaxX())
	y0, y1 := swiftMax(r.MinY(), o.MinY()), swiftMin(r.MaxY(), o.MaxY())
	if x0 > x1 || y0 > y1 {
		return NullRect
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// Union is CGRectUnion: a null side is ignored, zero-size rects count.
func (r Rect) Union(o Rect) Rect {
	if r.IsNull() {
		return o
	}
	if o.IsNull() {
		return r
	}
	x0, x1 := swiftMin(r.MinX(), o.MinX()), swiftMax(r.MaxX(), o.MaxX())
	y0, y1 := swiftMin(r.MinY(), o.MinY()), swiftMax(r.MaxY(), o.MaxY())
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// Contains is CGRectContainsPoint: half-open, [min, max).
func (r Rect) Contains(p Point) bool {
	if r.IsNull() {
		return false
	}
	return p.X >= r.MinX() && p.X < r.MaxX() && p.Y >= r.MinY() && p.Y < r.MaxY()
}

// ContainsRect is CGRectContainsRect: closed bounds (a zero-size rect on the edge is inside).
func (r Rect) ContainsRect(o Rect) bool {
	if o.IsNull() {
		return !r.IsNull()
	}
	if r.IsNull() {
		return false
	}
	return o.MinX() >= r.MinX() && o.MaxX() <= r.MaxX() && o.MinY() >= r.MinY() && o.MaxY() <= r.MaxY()
}

// Offset is CGRect.offsetBy.
func (r Rect) Offset(dx, dy float64) Rect {
	if r.IsNull() {
		return r
	}
	s := r.standard()
	return Rect{s.X + dx, s.Y + dy, s.W, s.H}
}

// Bounds is the frame an arrow reports: its routed path's bounds (Board.bounds(of:)). The
// path must not be empty.
func Bounds(path []Point) model.Frame {
	minX, minY, maxX, maxY := path[0].X, path[0].Y, path[0].X, path[0].Y
	for _, p := range path[1:] {
		// Array.min()/max(): the first of equals.
		if p.X < minX {
			minX = p.X
		}
		if p.X > maxX {
			maxX = p.X
		}
		if p.Y < minY {
			minY = p.Y
		}
		if p.Y > maxY {
			maxY = p.Y
		}
	}
	return model.Frame{X: minX, Y: minY, W: maxX - minX, H: maxY - minY}
}

func (p Point) JSON() []any { return []any{p.X, p.Y} }

// swiftMin and swiftMax are Swift's min/max: min keeps the first unless a later one is strictly
// smaller, max takes a later one that is greater or equal, so ±0 and NaN come out as Swift's.
func swiftMin(a float64, rest ...float64) float64 {
	for _, b := range rest {
		if b < a {
			a = b
		}
	}
	return a
}

func swiftMax(a float64, rest ...float64) float64 {
	for _, b := range rest {
		if b >= a {
			a = b
		}
	}
	return a
}
