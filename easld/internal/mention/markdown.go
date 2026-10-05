package mention

import (
	"strconv"
	"strings"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/parser"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// Note markdown as swift-markdown (cmark-gfm with tables, strikethrough and task lists, smart
// punctuation off) reads it: blocks with their 1-based source line spans, and the plain text of
// their inlines. goldmark parses; wrapped block parsers record the lines each block consumed,
// as cmark's source positions give them.

type span struct{ start, end int } // 1-based, inclusive

type document struct {
	root   ast.Node
	source []byte
	spans  map[ast.Node]*span
	lines  []int // byte offset of each line's start
}

var spansKey = parser.NewContextKey()

type spanRecorder struct{ inner parser.BlockParser }

func spansIn(pc parser.Context) map[ast.Node]*span {
	return pc.ComputeIfAbsent(spansKey, func() any { return map[ast.Node]*span{} }).(map[ast.Node]*span)
}

func (w spanRecorder) Trigger() []byte { return w.inner.Trigger() }

func (w spanRecorder) Open(parent ast.Node, reader text.Reader, pc parser.Context) (ast.Node, parser.State) {
	line, _ := reader.Position()
	var paragraph ast.Node
	if last := pc.LastOpenedBlock(); last.Node != nil {
		if _, ok := last.Node.(*ast.Paragraph); ok {
			paragraph = last.Node
		}
	}
	node, state := w.inner.Open(parent, reader, pc)
	if node != nil {
		spans := spansIn(pc)
		start := line + 1
		if _, ok := node.(*ast.Heading); ok && paragraph != nil {
			if s := spans[paragraph]; s != nil && state&parser.RequireParagraph != 0 {
				start = s.start
			}
		}
		spans[node] = &span{start, line + 1}
	}
	return node, state
}

func (w spanRecorder) Continue(node ast.Node, reader text.Reader, pc parser.Context) parser.State {
	line, before := reader.Position()
	state := w.inner.Continue(node, reader, pc)
	_, after := reader.Position()
	if s := spansIn(pc)[node]; s != nil && (state&parser.Continue != 0 || after.Start > before.Start) {
		s.end = max(s.end, line+1)
	}
	return state
}

func (w spanRecorder) Close(node ast.Node, reader text.Reader, pc parser.Context) {
	w.inner.Close(node, reader, pc)
}

func (w spanRecorder) CanInterruptParagraph() bool { return w.inner.CanInterruptParagraph() }
func (w spanRecorder) CanAcceptIndentedLine() bool { return w.inner.CanAcceptIndentedLine() }

var markdownParser = func() goldmark.Markdown {
	var blocks []util.PrioritizedValue
	for _, b := range parser.DefaultBlockParsers() {
		blocks = append(blocks, util.Prioritized(spanRecorder{b.Value.(parser.BlockParser)}, b.Priority))
	}
	p := parser.NewParser(parser.WithBlockParsers(blocks...), parser.WithInlineParsers(parser.DefaultInlineParsers()...),
		parser.WithParagraphTransformers(parser.DefaultParagraphTransformers()...))
	return goldmark.New(goldmark.WithParser(p), goldmark.WithExtensions(extension.Table, extension.Strikethrough, extension.TaskList))
}()

// parseMarkdown is NoteMarkdown.parse.
func parseMarkdown(markdown string) *document {
	source := []byte(markdown)
	pc := parser.NewContext()
	root := markdownParser.Parser().Parse(text.NewReader(source), parser.WithContext(pc))
	d := &document{root: root, source: source, spans: spansIn(pc), lines: []int{0}}
	for i, b := range source {
		if b == '\n' {
			d.lines = append(d.lines, i+1)
		}
	}
	d.finish(root)
	return d
}

// lineOf is the 1-based line holding byte offset.
func (d *document) lineOf(offset int) int {
	low, high := 0, len(d.lines)-1
	for low < high {
		mid := (low + high + 1) / 2
		if d.lines[mid] <= offset {
			low = mid
		} else {
			high = mid - 1
		}
	}
	return low + 1
}

// finish gives tables their rows' lines and stretches every container over its children.
func (d *document) finish(node ast.Node) *span {
	s := d.spans[node]
	if table, ok := node.(*east.Table); ok {
		first, last := -1, -1
		for row := table.FirstChild(); row != nil; row = row.NextSibling() {
			if cell := row.FirstChild(); cell != nil && cell.Lines().Len() > 0 {
				line := d.lineOf(cell.Lines().At(0).Start)
				if first < 0 {
					first = line
				}
				last = line
			}
		}
		if first > 0 {
			s = &span{first, last}
			d.spans[node] = s
		}
		return s
	}
	for child := node.FirstChild(); child != nil; child = child.NextSibling() {
		if child.Type() != ast.TypeBlock {
			continue
		}
		if cs := d.finish(child); cs != nil && s != nil && cs.end > s.end {
			s.end = cs.end
		}
	}
	return s
}

// blockChildren are a node's block children with spans, in order.
func (d *document) blockChildren(node ast.Node) []ast.Node {
	var out []ast.Node
	for child := node.FirstChild(); child != nil; child = child.NextSibling() {
		if child.Type() == ast.TypeBlock && d.spans[child] != nil {
			out = append(out, child)
		}
	}
	return out
}

type heading struct {
	line, level int
	title       string
}

// headings is NoteMarkdown.headings: the top-level headings in order.
func (d *document) headings() []heading {
	var out []heading
	for _, child := range d.blockChildren(d.root) {
		if h, ok := child.(*ast.Heading); ok {
			out = append(out, heading{d.spans[child].start, h.Level, d.plainText(h)})
		}
	}
	return out
}

// isInlineContainer is swift-markdown's InlineContainer: paragraphs, headings, table cells and
// the inline containers.
func isInlineContainer(n ast.Node) bool {
	switch n.(type) {
	case *ast.Paragraph, *ast.TextBlock, *ast.Heading, *east.TableCell, *ast.Emphasis, *ast.Link, *ast.Image, *east.Strikethrough:
		return true
	}
	return false
}

// firstChild is swift-markdown's child(at: 0) for the block chain plainText walks: a table's
// head row stands between it and its cells.
func firstChild(n ast.Node) ast.Node {
	if table, ok := n.(*east.Table); ok {
		if head := table.FirstChild(); head != nil {
			return head
		}
	}
	return n.FirstChild()
}

// plainText is InlineContainer.plainText: the inlines' text, escapes and entities decoded, a
// code span in backticks, a soft break a space, a hard break a newline.
func (d *document) plainText(n ast.Node) string {
	var b strings.Builder
	d.writePlain(&b, n)
	return b.String()
}

func (d *document) writePlain(b *strings.Builder, n ast.Node) {
	for c := n.FirstChild(); c != nil; c = c.NextSibling() {
		switch node := c.(type) {
		case *ast.Text:
			if node.IsRaw() {
				b.Write(node.Segment.Value(d.source))
			} else {
				b.WriteString(decodeInline(node.Segment.Value(d.source)))
			}
			if node.HardLineBreak() {
				b.WriteString("\n")
			} else if node.SoftLineBreak() {
				b.WriteString(" ")
			}
		case *ast.String:
			b.Write(node.Value)
		case *ast.CodeSpan:
			var code strings.Builder
			for t := node.FirstChild(); t != nil; t = t.NextSibling() {
				if txt, ok := t.(*ast.Text); ok {
					code.Write(txt.Segment.Value(d.source))
				} else if s, ok := t.(*ast.String); ok {
					code.Write(s.Value)
				}
			}
			b.WriteString("`" + strings.ReplaceAll(code.String(), "\n", " ") + "`")
		case *ast.AutoLink:
			b.Write(node.Label(d.source))
		case *ast.RawHTML:
			for i := range node.Segments.Len() {
				seg := node.Segments.At(i)
				b.Write(seg.Value(d.source))
			}
		case *east.TaskCheckBox:
		default:
			d.writePlain(b, c)
		}
	}
}

// decodeInline resolves CommonMark backslash escapes and entity references in one pass.
func decodeInline(raw []byte) string {
	var b strings.Builder
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		if c == '\\' && i+1 < len(raw) && util.IsPunct(raw[i+1]) {
			b.WriteByte(raw[i+1])
			i++
			continue
		}
		if c == '&' {
			if end := strings.IndexByte(string(raw[i:min(len(raw), i+40)]), ';'); end > 1 {
				if s, ok := entity(string(raw[i+1 : i+end])); ok {
					b.WriteString(s)
					i += end
					continue
				}
			}
		}
		b.WriteByte(c)
	}
	return b.String()
}

func entity(name string) (string, bool) {
	if strings.HasPrefix(name, "#") {
		digits, base := name[1:], 10
		if strings.HasPrefix(digits, "x") || strings.HasPrefix(digits, "X") {
			digits, base = digits[1:], 16
		}
		if digits == "" || (base == 10 && len(digits) > 7) || (base == 16 && len(digits) > 6) {
			return "", false
		}
		n, err := strconv.ParseUint(digits, base, 32)
		if err != nil {
			return "", false
		}
		if n == 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF) {
			return "\uFFFD", true
		}
		return string(rune(n)), true
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return "", false
		}
	}
	if e, ok := util.LookUpHTML5EntityByName(name); ok {
		return string(e.Characters), true
	}
	return "", false
}

// PlainTextOfLine is NoteMarkdown.plainText(ofLine:): one line of note markdown as it reads.
func PlainTextOfLine(line string) string {
	d := parseMarkdown(line)
	for node := firstChild(d.root); node != nil; node = firstChild(node) {
		if isInlineContainer(node) {
			return measure.TrimWS(d.plainText(node))
		}
	}
	return measure.TrimWS(strings.TrimLeft(line, "#"))
}

// fencedBlock is a fenced or indented code block: its info string (escapes and entities
// processed), its code, and its opening line.
type fencedBlock struct {
	info string
	code string
	line int
}

// codeBlocks are every code block in document order (NoteMarkdown.anchoredFences' walk).
func (d *document) codeBlocks() []fencedBlock {
	var out []fencedBlock
	var walk func(n ast.Node)
	walk = func(n ast.Node) {
		switch block := n.(type) {
		case *ast.FencedCodeBlock:
			info := ""
			if block.Info != nil {
				info = decodeInline(block.Info.Segment.Value(d.source))
			}
			line := 0
			if s := d.spans[n]; s != nil {
				line = s.start
			}
			out = append(out, fencedBlock{info: info, code: d.code(block), line: line})
			return
		case *ast.CodeBlock:
			line := 0
			if s := d.spans[n]; s != nil {
				line = s.start
			}
			out = append(out, fencedBlock{code: d.code(block), line: line})
			return
		}
		for c := n.FirstChild(); c != nil; c = c.NextSibling() {
			walk(c)
		}
	}
	walk(d.root)
	return out
}

func (d *document) code(n ast.Node) string {
	var b strings.Builder
	lines := n.Lines()
	for i := 0; i < lines.Len(); i++ {
		seg := lines.At(i)
		b.WriteString(strings.Repeat(" ", seg.Padding))
		b.Write(seg.Value(d.source))
	}
	return b.String()
}
