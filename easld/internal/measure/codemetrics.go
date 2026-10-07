package measure

import (
	"math"
	"strconv"
	"strings"
	"unicode/utf16"
)

// Code tile geometry in points (CodeMetrics.swift). Text is the system monospaced font at 12
// points, every column CharAdvance wide; rows are RowHeight tall.
const (
	FontSize        = 12.0
	CharAdvance     = 7.41796875
	RowHeight       = 16.0
	TabWidth        = 4
	TitleHeight     = 26.0 // RenderMath.tileTitleHeight
	HeaderHeight    = 26.0
	CaptionHeight   = 20.0
	CaptionInset    = 8.0
	HistoryHeight   = 22.0
	VerticalPadding = 4.0
	MinLineDigits   = 4
	GutterLeading   = 4.0
	SignGap         = 5.0
	SignWidth       = 4.0
	TextGap         = 7.0
	TrailingPadding = 12.0
	MinWidth        = 280.0
	AutoColumns     = 200
	WrapIndent      = 2
	RangeContext    = 3
)

// DefaultFitWidth is the widest frame size "fit" and object.measure give a code tile when the
// caller names no width, and the widest a new tile without a frame gets (AutoWidth):
// AutoColumns columns beside a 4-digit gutter (CodeMetrics.defaultFitWidth).
var DefaultFitWidth = math.Ceil(GutterWidth(1) + AutoColumns*CharAdvance + TrailingPadding)

// AutoWidth is CodeMetrics.autoWidth: the frame width of a new code tile without a frame over
// a file of lineCount lines whose longest is longestLine columns: defaultWidth, widened so that
// line doesn't wrap, up to DefaultFitWidth.
func AutoWidth(longestLine, lineCount int, defaultWidth float64) float64 {
	needed := math.Ceil(GutterWidth(lineCount) + float64(longestLine)*CharAdvance + TrailingPadding)
	return max(defaultWidth, min(needed, DefaultFitWidth))
}

// LongestLine is CodeMetrics.longestLine: the columns of text's longest line (tabs expanded,
// carriage returns not counted) and its number of lines, a final newline ending the last line.
func LongestLine(text string) (columns, lines int) {
	longest, column, open := 0, 0, false
	for _, r := range text {
		switch {
		case r == '\n':
			longest = max(longest, column)
			column = 0
			lines++
			open = false
			continue
		case r == '\r':
			continue
		case r == '\t':
			column += TabWidth - column%TabWidth
		case r > 0xFFFF:
			column += 2 // a surrogate pair: 2 on its high half, 0 on its low
		default:
			column += UnitColumns(uint16(r))
		}
		open = true
	}
	if open {
		lines++
	}
	return max(longest, column), lines
}

// LineNumberDigits is CodeMetrics.lineNumberDigits.
func LineNumberDigits(lineCount int) int {
	return max(MinLineDigits, len(strconv.Itoa(max(1, lineCount))))
}

// GutterWidth is everything left of the text for a file of lineCount lines.
func GutterWidth(lineCount int) float64 {
	return math.Ceil(GutterLeading + float64(LineNumberDigits(lineCount))*CharAdvance + SignGap + SignWidth + TextGap)
}

// TextColumns is the text columns a code tile width points wide shows; at least 1.
func TextColumns(width float64, lineCount int) int {
	return max(1, int(math.Floor((width-GutterWidth(lineCount)-TrailingPadding)/CharAdvance+0.001)))
}

// ChromeHeight is the height above the first row's padding, inside the frame.
func ChromeHeight(caption, history bool) float64 {
	h := TitleHeight + HeaderHeight
	if caption {
		h += CaptionHeight
	}
	if history {
		h += HistoryHeight
	}
	return h
}

// Content is CodeMetrics.content: a code tile's body showing rows rows of at most longestLine
// columns beside a gutterWidth gutter, under header strips headerHeight tall.
func Content(rows, longestLine int, gutterWidth, headerHeight float64) (w, h float64) {
	width := gutterWidth + float64(max(0, longestLine))*CharAdvance + TrailingPadding
	height := headerHeight + 2*VerticalPadding + float64(max(1, rows))*RowHeight
	return max(MinWidth, math.Ceil(width)), math.Ceil(height)
}

// UnitColumns is the columns one UTF-16 unit other than a tab takes.
func UnitColumns(unit uint16) int {
	switch {
	case unit >= 0xD800 && unit <= 0xDBFF:
		return 2
	case unit >= 0xDC00 && unit <= 0xDFFF:
		return 0
	case unit >= 0x1100 && unit <= 0x115F, unit >= 0x2E80 && unit <= 0x303E, unit >= 0x3041 && unit <= 0x33FF,
		unit >= 0x3400 && unit <= 0x4DBF, unit >= 0x4E00 && unit <= 0x9FFF, unit >= 0xA000 && unit <= 0xA4CF,
		unit >= 0xAC00 && unit <= 0xD7A3, unit >= 0xF900 && unit <= 0xFAFF, unit >= 0xFE30 && unit <= 0xFE4F,
		unit >= 0xFF00 && unit <= 0xFF60, unit >= 0xFFE0 && unit <= 0xFFE6:
		return 2
	}
	return 1
}

// UTF16 is s as UTF-16 units (Swift's String.utf16; invalid UTF-8 reads as U+FFFD).
func UTF16(s string) []uint16 { return utf16.Encode([]rune(s)) }

// Columns is the columns a line occupies with tabs expanded.
func Columns(line string) int { return ColumnsOfUnits(UTF16(line)) }

// ColumnsOfUnits is Columns over UTF-16 units.
func ColumnsOfUnits(units []uint16) int {
	column := 0
	for _, unit := range units {
		if unit == 0x09 {
			column += TabWidth - column%TabWidth
		} else {
			column += UnitColumns(unit)
		}
	}
	return column
}

// Wrap is how a line soft-wraps at columns text columns: the UTF-16 offsets where its
// continuation rows start, and their indent (CodeMetrics.wrap).
func Wrap(units []uint16, columns int) (breaks []int, indent int) {
	limit := max(1, columns)
	virtual, used, leading := 0, 0, 0
	inLeading := true
	rowStart := 0
	for offset, unit := range units {
		width := 0
		if unit == 0x09 {
			width = TabWidth - virtual%TabWidth
		} else {
			width = UnitColumns(unit)
		}
		if inLeading {
			if unit == 0x20 || unit == 0x09 {
				leading += width
			} else {
				inLeading = false
			}
		}
		if width > 0 && used+width > limit && offset > rowStart {
			if len(breaks) == 0 {
				indent = min(leading+WrapIndent, max(1, columns)/2)
				limit = max(1, columns-indent)
			}
			breaks = append(breaks, offset)
			rowStart = offset
			used = 0
		}
		used += width
		virtual += width
	}
	return breaks, indent
}

// SideLines are a text's lines as SideText splits them: at LF, a CR before it dropped, no
// empty line after a final newline; empty text has none.
func SideLines(text string) []string {
	if text == "" {
		return nil
	}
	lines := strings.Split(text, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	for i, line := range lines {
		if i < len(lines)-1 || strings.HasSuffix(text, "\n") {
			lines[i] = strings.TrimSuffix(line, "\r")
		}
	}
	return lines
}

// CodeRows are the visual rows of a code tile without peeks (CodeRows.swift): one entry per
// line, lines wider than the text column wrapped onto continuation rows.
type CodeRows struct {
	lineCount int
	wrapped   []wrappedEntry
}

type wrappedEntry struct {
	entry  int
	breaks int
	before int
}

// CodeRowsForLineCount is CodeRows(lineCount:): one row per line.
func CodeRowsForLineCount(n int) *CodeRows { return &CodeRows{lineCount: n} }

// CodeRowsForFile is CodeRows(file:width:): text's rows in a code tile width points wide.
func CodeRowsForFile(text string, width float64) *CodeRows {
	lines := SideLines(text)
	columns := TextColumns(width, len(lines))
	rows := &CodeRows{lineCount: len(lines)}
	before := 0
	for i, line := range lines {
		units := UTF16(line)
		if ColumnsOfUnits(units) <= columns {
			continue
		}
		breaks, _ := Wrap(units, columns)
		if len(breaks) == 0 {
			continue
		}
		rows.wrapped = append(rows.wrapped, wrappedEntry{entry: i, breaks: len(breaks), before: before})
		before += len(breaks)
	}
	return rows
}

func (r *CodeRows) entryOfLine(line int) int {
	return min(max(1, line), max(1, r.lineCount)) - 1
}

func (r *CodeRows) rowsOfEntry(entry int) (start, end int) {
	low, high := 0, len(r.wrapped)
	for low < high {
		mid := (low + high) / 2
		if r.wrapped[mid].entry < entry {
			low = mid + 1
		} else {
			high = mid
		}
	}
	first := entry
	if low > 0 {
		first += r.wrapped[low-1].before + r.wrapped[low-1].breaks
	}
	continuations := 0
	if low < len(r.wrapped) && r.wrapped[low].entry == entry {
		continuations = r.wrapped[low].breaks
	}
	return first, first + 1 + continuations
}

// Count is the number of visual rows.
func (r *CodeRows) Count() int {
	if n := len(r.wrapped); n > 0 {
		return r.lineCount + r.wrapped[n-1].before + r.wrapped[n-1].breaks
	}
	return r.lineCount
}

// IndexOfLine is the first visual row of a 1-based line (clamped to the text).
func (r *CodeRows) IndexOfLine(line int) int {
	start, _ := r.rowsOfEntry(r.entryOfLine(line))
	return start
}

// RowsOfLine is all visual rows of a line, half-open.
func (r *CodeRows) RowsOfLine(line int) (start, end int) {
	return r.rowsOfEntry(r.entryOfLine(line))
}
