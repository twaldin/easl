package route

import (
	"math"

	"github.com/twaldin/easl/easld/internal/model"
)

// CodeRows is a code tile's visual rows (CodeDocument.swift CodeRows; measure.CodeRows
// implements it): where a line's first row is, the rows a line takes (half-open), and how many
// rows there are.
type CodeRows interface {
	IndexOfLine(line int) int
	RowsOfLine(line int) (start, end int)
	Count() int
}

// CodeMetrics constants line anchors use.
const (
	codeRowHeight       = 16.0
	codeHeaderHeight    = 26.0
	codeCaptionHeight   = 20.0
	codeHistoryHeight   = 22.0
	codeVerticalPadding = 4.0
	codeRangeContext    = 3
)

// codeChromeHeight is CodeMetrics.chromeHeight: height above the first row's padding.
func codeChromeHeight(caption, history bool) float64 {
	h := TileTitleHeight + codeHeaderHeight
	if caption {
		h += codeCaptionHeight
	}
	if history {
		h += codeHistoryHeight
	}
	return h
}

// codeScrollOffset is CodeMetrics.scrollOffset: the scroll that shows the range starting at
// visual row `row`, `count` rows long, near the top with up to codeRangeContext rows of context
// above it; clamped to the content when totalRows is known (≥ 0).
func codeScrollOffset(row, count int, viewport float64, totalRows int) float64 {
	visible := int(math.Floor((viewport - codeVerticalPadding) / codeRowHeight))
	context := max(0, min(codeRangeContext, visible-count))
	offset := float64(max(0, row-context)) * codeRowHeight
	if totalRows >= 0 {
		content := 2*codeVerticalPadding + float64(max(1, totalRows))*codeRowHeight
		offset = swiftMin(offset, swiftMax(0, content-viewport))
	}
	return swiftMax(0, offset)
}

// codeLineYIn is CodeMetrics.lineY(line:rows:scroll:rowsTop:frameHeight:): the middle of the
// line's first visual row, clamped into the rows viewport.
func codeLineYIn(line int, rows CodeRows, scroll, rowsTop, frameHeight float64) float64 {
	row := max(0, line-1)
	if rows != nil {
		row = rows.IndexOfLine(line)
	}
	y := rowsTop + codeVerticalPadding + float64(row)*codeRowHeight - scroll + codeRowHeight/2
	return swiftMin(swiftMax(y, rowsTop), swiftMax(rowsTop, frameHeight))
}

// CodeLineY is CodeMetrics.lineY(line:frame:props:rows:): where an arrow bound to `line` of a
// code tile at `frame` attaches (canvas y), the tile freshly aimed at `props.range`, its body
// zoomed by `props.zoom` under a 1× title bar. `rows` nil: one row per line, length unknown.
func CodeLineY(line int, frame model.Frame, props map[string]any, rows CodeRows) float64 {
	zoom := zoomOf(props)
	natural := naturalFrame(frame, zoom)
	y := codeNaturalLineY(line, natural.H, props, rows)
	return frame.Y + TileTitleHeight + float64(zoom*(y-TileTitleHeight))
}

func codeNaturalLineY(line int, frameHeight float64, props map[string]any, rows CodeRows) float64 {
	caption := false
	if s, ok := props["caption"].(string); ok {
		caption = s != ""
	}
	history := false
	if _, ok := props["followOf"].(string); ok {
		items, isArray := props["history"].([]any)
		history = isArray && len(items) > 0
	}
	rowsTop := codeChromeHeight(caption, history)
	viewport := swiftMax(0, frameHeight-rowsTop)
	scroll := 0.0
	rangeProps, _ := props["range"].(map[string]any)
	if start, ok := model.Int(rangeProps["start"]); ok {
		end := start
		if e, ok := model.Int(rangeProps["end"]); ok {
			end = e
		}
		end = max(start, end)
		first, stop, total := max(0, start-1), end, -1
		if rows != nil {
			first = rows.IndexOfLine(start)
			_, stop = rows.RowsOfLine(end)
			total = rows.Count()
		}
		scroll = codeScrollOffset(first, stop-first, viewport, total)
	}
	return codeLineYIn(line, rows, scroll, rowsTop, frameHeight)
}
