package textmeasure

import (
	"math"
	"strings"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/measure/glyphs"
)

// DrawingStyle and CodeCaption sizes.
const (
	textPointSize   = 20.0  // DrawingStyle.textPointSize
	labelSize       = 18.0  // DrawingStyle.labelSize
	arrowLabelSize  = 15.0  // DrawingStyle.arrowLabelSize
	arrowLabelWidth = 240.0 // DrawingStyle.arrowLabelWidth
)

// Approximate measures items from the glyph table, each answer marked approximate.
func Approximate(items []measure.TextItem) []measure.TextSize {
	out := make([]measure.TextSize, len(items))
	for i, item := range items {
		out[i] = approximate(item)
		out[i].Approximate = true
	}
	return out
}

func approximate(item measure.TextItem) measure.TextSize {
	wrap := math.Inf(1)
	if item.Width != nil {
		wrap = max(1, *item.Width)
	}
	switch item.Kind {
	case "note":
		width := measure.DefaultNoteWidth
		if item.Width != nil {
			width = *item.Width
		}
		w, h, shortfall := note(item.Text, width, item.Root)
		return measure.TextSize{W: w, H: h, TableShortfall: shortfall}
	case "text", "label":
		face := glyphs.Shantell(labelSize)
		if item.Kind == "text" {
			size := item.TextSize
			if size <= 0 {
				size = 1
			}
			face = glyphs.Shantell(textPointSize * size)
		}
		// ObjectMeasure.textBounds: rounded up, with a point of slack each way.
		w, h := bounds(item.Text, face, wrap)
		return measure.TextSize{W: ceil(w) + 2, H: ceil(h) + 2}
	case "arrowLabel":
		w, h := bounds(item.Text, glyphs.Shantell(arrowLabelSize), arrowLabelWidth)
		return measure.TextSize{W: ceil(w) + 8, H: ceil(h)}
	case "caption":
		return measure.TextSize{W: captionWidth(item.Text), H: measure.CaptionHeight}
	}
	return measure.TextSize{}
}

// captionWidth is ObjectMeasure.captionWidth: CodeCaption.string's one line (`inline code` in
// the code font) with the caption inset on each side, the label cell's 2-point text padding on
// each side, and a point of slack.
func captionWidth(caption string) float64 {
	body, code := glyphs.System(11.5, "regular", false, false), glyphs.Mono(11)
	var spans []span
	for i, part := range strings.Split(strings.ReplaceAll(caption, "\n", " "), "`") {
		face := body
		if i%2 == 1 {
			face = code
		}
		spans = append(spans, span{text: part, face: face})
	}
	return ceil(ceil(widthOf(spans)) + 2*measure.CaptionInset + 4 + 1)
}
