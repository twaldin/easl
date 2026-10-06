package textmeasure

import (
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/measure/glyphs"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/text"
)

// Note geometry (ObjectMeasure, NoteRenderer, NoteBlockFragment).
const (
	DefaultNoteWidth  = 280.0 // Board.defaultSize(.note).w
	noteInsetW        = 8.0
	noteInsetH        = 10.0
	fragmentPadding   = 2.0
	blockInset        = 6.0 // NoteBlockFragment.inset
	maxRows           = 400
	columnGap         = 18.0
	minColumnWidth    = 36.0
	notePlaceholder   = "Double-click or ↩ to write a note"
	proseLineMultiple = 1.05
)

var noteMarkdown = goldmark.New(goldmark.WithExtensions(extension.Table, extension.Strikethrough, extension.TaskList))

// paragraph is one TextKit paragraph as NoteRenderer styles it.
type paragraph struct {
	spans    []span
	base     *glyphs.Face
	indent   float64 // where its lines start, past the line fragment padding
	multiple float64
	before   float64
	after    float64
	// oneLine: truncated, never wrapped (code rows, captions); lines: a table row's height in
	// lines, set already.
	oneLine bool
	lines   int
}

type noteRenderer struct {
	source    []byte
	root      string
	lineWidth float64
	excerpts  map[string]measure.Excerpt
	out       []paragraph
	shortfall float64
}

// note is ObjectMeasure.note approximated: the frame (title bar included) a note `width` wide
// needs to show markdown without scrolling, and how much wider it must be to show every table
// cell whole.
func note(markdown string, width float64, root string) (w, h, shortfall float64) {
	source := []byte(markdown)
	doc := noteMarkdown.Parser().Parse(text.NewReader(source))
	textWidth := width - 2*noteInsetW
	r := &noteRenderer{source: source, root: root, lineWidth: max(1, textWidth-2*fragmentPadding), excerpts: map[string]measure.Excerpt{}}
	if doc.ChildCount() == 0 {
		face := glyphs.System(13, "regular", false, false)
		r.out = append(r.out, paragraph{spans: []span{{text: notePlaceholder, face: face}}, base: face, multiple: 1})
	} else {
		r.blocks(doc, context{})
	}
	height := 0.0
	for i, p := range r.out {
		if i > 0 {
			height += r.out[i-1].after + p.before
		}
		height += r.height(p)
	}
	return width, ceil(measure.TitleHeight + 2*noteInsetH + height), r.shortfall
}

func (r *noteRenderer) height(p paragraph) float64 {
	if p.lines > 0 {
		lh := p.base.LineHeight
		for _, s := range p.spans {
			lh = max(lh, s.face.LineHeight)
		}
		return float64(p.lines) * lh * p.multiple
	}
	available := math.Inf(1)
	if !p.oneLine {
		available = max(1, r.lineWidth-p.indent)
	}
	ls := lines(p.spans, available, p.base)
	if p.oneLine {
		ls = ls[:1]
		for _, l := range lines(p.spans, math.Inf(1), p.base) {
			ls[0].height = max(ls[0].height, l.height)
		}
	}
	h := 0.0
	for _, l := range ls {
		h += max(l.height, l.image) * p.multiple
	}
	return h
}

// context is NoteRenderer.Context: nesting for block rendering.
type context struct {
	indent float64
	quoted bool
}

func (r *noteRenderer) blocks(n ast.Node, c context) {
	for child := n.FirstChild(); child != nil; child = child.NextSibling() {
		r.block(child, c)
	}
}

var bodySize = 13.0

func (r *noteRenderer) block(n ast.Node, c context) {
	switch b := n.(type) {
	case *ast.Heading:
		sizes := []float64{20, 17, 15, 13}
		size := sizes[min(len(sizes), max(1, b.Level))-1]
		weight, before := "semibold", 3.0
		if b.Level <= 2 {
			weight, before = "bold", 6
		}
		r.paragraph(b, style{size: size, weight: weight}, c, before)
	case *ast.Paragraph, *ast.TextBlock:
		r.paragraph(n, style{size: bodySize, weight: "regular"}, c, 0)
	case *ast.Blockquote:
		r.blocks(b, context{indent: c.indent + 14, quoted: true})
	case *ast.List:
		for item := b.FirstChild(); item != nil; item = item.NextSibling() {
			markerWidth := 22.0
			if !b.IsOrdered() {
				markerWidth = 14
				if checkbox(item) {
					markerWidth = 20
				}
			}
			r.blocks(item, context{indent: c.indent + markerWidth + 4, quoted: c.quoted})
		}
	case *ast.FencedCodeBlock:
		info := ""
		if b.Info != nil {
			info = string(b.Info.Segment.Value(r.source))
		}
		r.fence(strings.TrimFunc(info, measure.IsWS), r.code(b), c)
	case *ast.CodeBlock:
		r.fence("", r.code(b), c)
	case *east.Table:
		r.table(b, c)
	case *ast.ThematicBreak:
		face := glyphs.System(bodySize, "regular", false, false)
		r.out = append(r.out, paragraph{spans: []span{{text: " ", face: face}}, base: face, indent: c.indent, multiple: proseLineMultiple, after: 8})
	case *ast.HTMLBlock:
		raw := r.code(b)
		if b.HasClosure() {
			raw += string(b.ClosureLine.Value(r.source))
		}
		r.rows(rowsOf(measure.NoteLines(raw), true), c, false)
	default:
		if n.ChildCount() > 0 {
			r.blocks(n, c)
		}
	}
}

func (r *noteRenderer) code(n ast.Node) string {
	var b strings.Builder
	lines := n.Lines()
	for i := range lines.Len() {
		seg := lines.At(i)
		b.Write(seg.Value(r.source))
	}
	return b.String()
}

func checkbox(item ast.Node) bool {
	first := item.FirstChild()
	if first == nil {
		return false
	}
	_, ok := first.FirstChild().(*east.TaskCheckBox)
	return ok
}

// style is the font of a run of inlines: NoteRenderer's attributes as they nest.
type style struct {
	size         float64
	weight       string
	bold, italic bool
	mono         bool
	protected    bool
}

func (s style) face() *glyphs.Face {
	if s.mono {
		return glyphs.Mono(s.size * 0.9)
	}
	return glyphs.System(s.size, s.weight, s.bold, s.italic)
}

func (r *noteRenderer) paragraph(n ast.Node, s style, c context, before float64) {
	spans := r.inlines(n, s, nil)
	r.out = append(r.out, paragraph{spans: spans, base: s.face(), indent: c.indent, multiple: proseLineMultiple, before: before, after: 6})
}

func (r *noteRenderer) inlines(n ast.Node, s style, out []span) []span {
	for child := n.FirstChild(); child != nil; child = child.NextSibling() {
		out = r.inline(child, s, out)
	}
	return out
}

func (r *noteRenderer) inline(n ast.Node, s style, out []span) []span {
	switch x := n.(type) {
	case *ast.Text:
		out = append(out, span{text: string(x.Segment.Value(r.source)), face: s.face(), protected: s.protected})
		if x.HardLineBreak() {
			out = append(out, span{text: "\u2028", face: s.face()})
		} else if x.SoftLineBreak() {
			out = append(out, span{text: " ", face: s.face(), protected: s.protected})
		}
	case *ast.String:
		out = append(out, span{text: string(x.Value), face: s.face(), protected: s.protected})
	case *ast.Emphasis:
		inner := s
		if x.Level >= 2 {
			inner.bold = true
		} else {
			inner.italic = true
		}
		out = r.inlines(x, inner, out)
	case *ast.CodeSpan:
		var b strings.Builder
		for t := x.FirstChild(); t != nil; t = t.NextSibling() {
			if text, ok := t.(*ast.Text); ok {
				b.Write(text.Segment.Value(r.source))
			} else if str, ok := t.(*ast.String); ok {
				b.Write(str.Value)
			}
		}
		code := s
		code.mono, code.protected = true, true
		out = append(out, span{text: b.String(), face: code.face(), protected: true})
	case *ast.Link:
		linked := s
		linked.protected = true
		out = r.inlines(x, linked, out)
	case *ast.AutoLink:
		out = append(out, span{text: string(x.Label(r.source)), face: s.face(), protected: true})
	case *ast.Image:
		alt := plainText(x, r.source)
		if size, ok := r.image(string(x.Destination)); ok {
			out = append(out, span{face: s.face(), image: &size})
		} else {
			out = append(out, span{text: "[image: " + alt + "]", face: s.face(), protected: s.protected})
		}
	case *ast.RawHTML:
		var b strings.Builder
		for i := range x.Segments.Len() {
			seg := x.Segments.At(i)
			b.Write(seg.Value(r.source))
		}
		out = append(out, span{text: b.String(), face: s.face(), protected: s.protected})
	case *east.TaskCheckBox:
		// The list marker shows it, in the hanging indent.
	default:
		out = r.inlines(n, s, out)
	}
	return out
}

func plainText(n ast.Node, source []byte) string {
	var b strings.Builder
	_ = ast.Walk(n, func(child ast.Node, entering bool) (ast.WalkStatus, error) {
		if entering {
			if t, ok := child.(*ast.Text); ok {
				b.Write(t.Segment.Value(source))
			}
		}
		return ast.WalkContinue, nil
	})
	return b.String()
}

// image is a note picture's laid-out size (NoteImageAttachment: its natural size, scaled down
// to the line's width): a file under the note's root or the temp directory
// (LocalImage.sandboxed) that easld can read the size of.
func (r *noteRenderer) image(source string) (box, bool) {
	if source == "" {
		return box{}, false
	}
	path := strings.TrimPrefix(source, "file://")
	if !filepath.IsAbs(path) {
		if strings.Contains(path, "://") {
			return box{}, false
		}
		path = filepath.Join(r.root, path)
	}
	path = filepath.Clean(path)
	inside := func(dir string) bool {
		dir = filepath.Clean(measure.RealPath(dir))
		real := measure.RealPath(path)
		return real == dir || strings.HasPrefix(real, dir+string(filepath.Separator))
	}
	if !inside(r.root) && !inside(os.TempDir()) {
		return box{}, false
	}
	w, h, ok, err := measure.ImageNaturalSize(path)
	if err != nil || !ok || w <= 0 || h <= 0 {
		return box{}, false
	}
	width := min(w, max(1, r.lineWidth-4))
	return box{w: width, h: math.Round(h * width / w)}, true
}

// --- fences ---

type row struct {
	text     string
	authored bool
}

func rowsOf(lines []string, authored bool) []row {
	out := make([]row, len(lines))
	for i, l := range lines {
		out[i] = row{l, authored}
	}
	return out
}

func (r *noteRenderer) fence(key, code string, c context) {
	fence := measure.ParseFenceInfo(key)
	body := measure.NoteLines(code)
	if fence.Mode() == measure.FenceFree {
		r.rows(rowsOf(body, true), c, false)
		return
	}
	excerpt, ok := r.excerpts[key]
	if !ok {
		excerpt = measure.ExcerptFor(fence, r.root, nil, body)
		r.excerpts[key] = excerpt
	}
	proposing := fence.Mode() == measure.FencePropose
	r.caption(fence, excerpt, c)
	switch {
	case excerpt.Range == nil:
		shown := excerpt.Lines
		if proposing || len(excerpt.Lines) == 0 {
			shown = body
		}
		r.rows(rowsOf(shown, proposing), c, false)
	case proposing && excerpt.HasDiff:
		lines := make([]string, len(excerpt.Diff))
		for i, d := range excerpt.Diff {
			lines[i] = "  " + d.Text
		}
		r.rows(rowsOf(lines, false), c, true)
	default:
		width := len(strconv.Itoa(excerpt.Range.End))
		lines := make([]string, len(excerpt.Lines))
		for i, l := range excerpt.Lines {
			number := strconv.Itoa(excerpt.Range.Start + i)
			lines[i] = strings.Repeat(" ", max(0, width-len(number))) + number + "  " + l
		}
		r.rows(rowsOf(lines, false), c, true)
	}
}

// caption is the strip above an excerpt: one line, cut in the middle when it doesn't fit.
func (r *noteRenderer) caption(fence measure.Fence, excerpt measure.Excerpt, c context) {
	face := glyphs.System(10.5, "medium", false, false)
	path := excerpt.Path
	if path == "" && fence.Path != nil {
		path = *fence.Path
	}
	r.out = append(r.out, paragraph{spans: []span{{text: path, face: face}}, base: face, indent: c.indent + blockInset + 4, multiple: proseLineMultiple, before: 2, oneLine: true})
}

// rows is one paragraph per code row, truncated rather than wrapped; past maxRows a caption says
// how many more there are.
func (r *noteRenderer) rows(rows []row, c context, numbered bool) {
	face := glyphs.Mono(11.5)
	shown := rows[:min(len(rows), maxRows)]
	for i, row := range shown {
		after := 0.0
		if i == len(shown)-1 && len(rows) <= maxRows {
			after = 8
		}
		before := 0.0
		if i == 0 && !numbered && row.authored {
			before = 2
		}
		text := strings.ReplaceAll(row.text, "\t", "    ")
		r.out = append(r.out, paragraph{spans: []span{{text: text, face: face}}, base: face, indent: c.indent + blockInset + 4, multiple: 1, before: before, after: after, oneLine: true})
	}
	if len(rows) > maxRows {
		caption := glyphs.System(10.5, "medium", false, false)
		r.out = append(r.out, paragraph{spans: []span{{text: "… " + strconv.Itoa(len(rows)-maxRows) + " more lines", face: caption}}, base: caption, indent: c.indent, multiple: proseLineMultiple, after: 8})
	}
}

// --- tables ---

func (r *noteRenderer) table(t *east.Table, c context) {
	var rows [][][]span
	for row := t.FirstChild(); row != nil; row = row.NextSibling() {
		_, header := row.(*east.TableHeader)
		s := style{size: bodySize, weight: "regular", bold: header}
		var cells [][]span
		for cell := row.FirstChild(); cell != nil; cell = cell.NextSibling() {
			cells = append(cells, r.inlines(cell, s, nil))
		}
		rows = append(rows, cells)
	}
	columns := 0
	for _, cells := range rows {
		columns = max(columns, len(cells))
	}
	if columns == 0 {
		return
	}
	left := c.indent + 4
	widths, shortfall := columnWidths(rows, columns, r.lineWidth-left-float64(columns-1)*columnGap-1)
	r.shortfall = max(r.shortfall, shortfall)
	body := glyphs.System(bodySize, "regular", false, false)
	for index, cells := range rows {
		after := 2.0
		if index == len(rows)-1 {
			after = 8
		}
		count := 1
		var all []span
		for column, cell := range cells {
			all = append(all, cell...)
			if shortfall == 0 {
				count = max(count, len(wrapCell(cell, widths[column])))
			}
		}
		r.out = append(r.out, paragraph{spans: all, base: body, indent: left, multiple: proseLineMultiple, after: after, lines: count})
	}
}

// measureSpans is NoteRenderer.measure: the width a cell (or part of one) draws at on one line,
// rounded up.
func measureSpans(spans []span) float64 { return ceil(widthOf(spans)) }

// cellChars is a cell as characters with their faces and whether a link or code span protects
// them.
func cellChars(cell []span) []cluster { return clusters(cell) }

func spansOf(chars []cluster) []span {
	out := make([]span, 0, len(chars))
	for _, c := range chars {
		out = append(out, span{text: c.text, face: c.face, image: c.image})
	}
	return out
}

// runs is NoteRenderer.runs: the stretches a line may not break inside, as [start, end) indexes
// into chars: words between spaces, where a link or code span counts as one word with the text
// touching it.
func runs(chars []cluster) [][2]int {
	var out [][2]int
	start := -1
	for i, c := range chars {
		breaks := !c.protected && (c.space || c.forced || c.text == "\n")
		if breaks {
			if start >= 0 {
				out = append(out, [2]int{start, i})
			}
			start = -1
		} else if start < 0 {
			start = i
		}
	}
	if start >= 0 {
		out = append(out, [2]int{start, len(chars)})
	}
	return out
}

// columnWidths is NoteRenderer.columnWidths: column widths for rows of cells in `available`
// points, and the shortfall when even broken words don't fit.
func columnWidths(rows [][][]span, columns int, available float64) ([]float64, float64) {
	natural := make([]float64, columns)
	unbreakable := make([]float64, columns)
	for _, cells := range rows {
		for column, cell := range cells {
			natural[column] = max(natural[column], measureSpans(cell))
			chars := cellChars(cell)
			for _, run := range runs(chars) {
				unbreakable[column] = max(unbreakable[column], measureSpans(spansOf(chars[run[0]:run[1]])))
			}
		}
	}
	least := make([]float64, columns)
	minimum := make([]float64, columns)
	for i := range natural {
		least[i] = min(natural[i], minColumnWidth)
		minimum[i] = max(unbreakable[i], least[i])
	}
	sum := func(ws []float64) float64 {
		t := 0.0
		for _, w := range ws {
			t += w
		}
		return t
	}
	grow := func(from, to []float64, room float64) []float64 {
		total := 0.0
		gaps := make([]float64, len(from))
		for i := range from {
			gaps[i] = to[i] - from[i]
			total += gaps[i]
		}
		if total <= 0 {
			return from
		}
		out := make([]float64, len(from))
		for i := range from {
			out[i] = math.Floor(from[i] + gaps[i]*room/total)
		}
		return out
	}
	if sum(natural) <= available {
		return natural, 0
	}
	if sum(minimum) <= available {
		return grow(minimum, natural, available-sum(minimum)), 0
	}
	if sum(least) <= available {
		capped := func(limit float64) []float64 {
			out := make([]float64, columns)
			for i := range out {
				out[i] = max(least[i], min(minimum[i], limit))
			}
			return out
		}
		low, high := 0.0, 0.0
		for _, m := range minimum {
			high = max(high, m)
		}
		for range 24 {
			mid := (low + high) / 2
			if sum(capped(mid)) <= available {
				low = mid
			} else {
				high = mid
			}
		}
		out := capped(low)
		for i := range out {
			out[i] = math.Floor(out[i])
		}
		return out, 0
	}
	return natural, ceil(sum(least) - available)
}

// wrapCell is NoteRenderer.wrap: a cell in lines at most `width` wide, whole runs while they fit,
// a run wider than the column broken after its last separator that fits, else between characters.
func wrapCell(cell []span, width float64) [][]cluster {
	chars := cellChars(cell)
	var lines [][]cluster
	open := -1
	for _, run := range runs(chars) {
		if open >= 0 {
			if measureSpans(spansOf(chars[open:run[1]])) <= width {
				continue
			}
			lines = append(lines, chars[open:openEnd(chars, open, run[0])])
		}
		start := run[0]
		for measureSpans(spansOf(chars[start:run[1]])) > width {
			cut := breakOffset(chars[start:run[1]], width)
			lines = append(lines, chars[start:start+cut])
			start += cut
		}
		open = start
	}
	if open >= 0 {
		lines = append(lines, chars[open:])
	}
	if len(lines) == 0 {
		return [][]cluster{nil}
	}
	return lines
}

// openEnd is where the open line ends: before the spaces that precede the next run.
func openEnd(chars []cluster, open, next int) int {
	end := next
	for end > open && (chars[end-1].space || chars[end-1].forced) {
		end--
	}
	return end
}

// breakOffset is how many characters of run fit `width` (at least one), cut back to just after a
// path or word separator in their latter two thirds.
func breakOffset(run []cluster, width float64) int {
	low, high := 1, len(run)
	for low < high {
		mid := (low + high + 1) / 2
		if measureSpans(spansOf(run[:mid])) <= width {
			low = mid
		} else {
			high = mid - 1
		}
	}
	fits := low
	for length := fits; length > fits/3; length-- {
		if length < len(run) && strings.ContainsAny(run[length-1].text, "/.-_:,\\") {
			return length
		}
	}
	return fits
}
