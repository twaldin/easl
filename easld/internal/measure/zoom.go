package measure

import (
	"math"

	"github.com/twaldin/easl/easld/internal/model"
)

// ZoomOf is ObjectZoom.of: props.zoom clamped to 0.25…8; 1 when absent or not a positive number.
func ZoomOf(props map[string]any) float64 {
	value, ok := props["zoom"].(float64)
	if !ok || math.IsInf(value, 0) || math.IsNaN(value) || value <= 0 {
		return 1
	}
	return min(max(value, 0.25), 8)
}

// ZoomApplies is ObjectZoom.applies(to:): every tile but an image takes props.zoom.
func ZoomApplies(t model.ObjectType) bool { return t.IsTile() && t != model.Image }

// ObjectZoom is CanvasObject.zoom: props.zoom for tiles that zoom, 1 for everything else.
func ObjectZoom(o model.Object) float64 {
	if ZoomApplies(o.Type) {
		return ZoomOf(o.Props)
	}
	return 1
}

// Zoomed is ObjectZoom.zoomed: the frame size showing content laid out at natural at zoom.
func Zoomed(w, h, zoom float64) (float64, float64) {
	return w * zoom, TitleHeight + max(0, h-TitleHeight)*zoom
}

// Natural is ObjectZoom.natural: the frame a tile lays its content out in at zoom.
func Natural(f model.Frame, zoom float64) model.Frame {
	return model.Frame{X: f.X, Y: f.Y, W: f.W / zoom, H: TitleHeight + max(0, f.H-TitleHeight)/zoom}
}
