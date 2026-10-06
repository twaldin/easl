package measure

import "math"

// TextItem is one text.measure item: text the app lays out with AppKit (schema text.measure).
type TextItem struct {
	// Kind is note, text, label, arrowLabel or caption.
	Kind string
	Text string
	// Width: a note's frame width (nil: DefaultNoteWidth); the wrap width of text and labels
	// (nil: unwrapped).
	Width *float64
	// TextSize is a text shape's textSize (0: 1).
	TextSize float64
	// Root is where a note's fences and images are read.
	Root string
}

// TextSize is one item's size; Approximate when easld's glyph table measured it rather than a
// Mac client.
type TextSize struct {
	W, H, TableShortfall float64
	Approximate          bool
}

// Texts measures text as the app lays it out: an attached Mac client's exact sizes, else the
// glyph table's approximation. One call is one batch, answered in order.
type Texts interface {
	MeasureText(items []TextItem) []TextSize
}

// DefaultNoteWidth is the width a note is measured at without one (a new note's).
const DefaultNoteWidth = 280.0

// Shape label geometry (ObjectMeasure.shape).
const (
	shapeLabelPadW = 16.0
	shapeLabelPadH = 12.0
)

// ShapeTextSize is ShapeSpec.textSize(of:): props.textSize clamped to 0.25…8, 1 when absent or
// not a positive number.
func ShapeTextSize(props map[string]any) float64 {
	v, ok := props["textSize"].(float64)
	if !ok || math.IsNaN(v) || math.IsInf(v, 0) || v <= 0 {
		return 1
	}
	return min(max(v, 0.25), 8)
}

// shapeSize is ObjectMeasure.shape for a text shape or a labelled rect or ellipse, its text
// measured by texts.
func shapeSize(kind string, props map[string]any, width *float64, texts Texts) (w, h float64, approximate bool) {
	text, _ := props["text"].(string)
	switch kind {
	case "text":
		size := texts.MeasureText([]TextItem{{Kind: "text", Text: text, Width: width, TextSize: ShapeTextSize(props)}})[0]
		w = size.W
		if width != nil {
			w = *width
		}
		return w, size.H, size.Approximate
	}
	// The label wraps 16 points inside the frame and sits centered, with room around it.
	var inner *float64
	if width != nil {
		inner = new(*width - 16 - shapeLabelPadW)
	}
	size := texts.MeasureText([]TextItem{{Kind: "label", Text: text, Width: inner}})[0]
	bw := size.W
	if inner != nil {
		bw = *inner
	}
	bw += 16 + shapeLabelPadW
	bh := size.H + 2*shapeLabelPadH
	if kind != "ellipse" {
		return bw, bh, size.Approximate
	}
	w = math.Ceil(bw * math.Sqrt2)
	if width != nil {
		w = *width
	}
	return w, math.Ceil(bh * math.Sqrt2), size.Approximate
}
