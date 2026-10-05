package mention

import (
	"strconv"
	"strings"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/yuin/goldmark/ast"
	east "github.com/yuin/goldmark/extension/ast"
)

// NoteItem is the block of a note a note mention holds (NoteItem.swift).
type NoteItem struct {
	// Kind: paragraph, item, heading, quote, code, row, html.
	Kind     string
	Headings []string
	Lines    model.LineRange
	Text     string
}

var noteItemKinds = []string{"paragraph", "item", "heading", "quote", "code", "row", "html"}

const (
	noteItemMaxLines      = 40
	noteItemMaxCharacters = 2000
)

// Noun is how the mention context names the kind.
func (i NoteItem) Noun() string {
	switch i.Kind {
	case "item":
		return "list item"
	case "heading":
		return "section"
	case "code":
		return "code block"
	case "row":
		return "table row"
	case "html":
		return "html block"
	}
	return i.Kind
}

// OmittedLines are the block's lines Text leaves out.
func (i NoteItem) OmittedLines() int {
	return max(0, i.Lines.End-i.Lines.Start+1-len(measure.NoteLines(i.Text)))
}

// NoteItemAt is NoteItem.at(line:in:): the block holding markdown line; ok false on a blank
// line between blocks, a thematic break, or past the end.
func NoteItemAt(line int, markdown string) (NoteItem, bool) {
	source := measure.NoteLines(markdown)
	if line < 1 || line > len(source) {
		return NoteItem{}, false
	}
	d := parseMarkdown(markdown)
	var chain []ast.Node
	container := d.root
	for {
		var next ast.Node
		for _, child := range d.blockChildren(container) {
			if s := d.spans[child]; s.start <= line && line <= max(s.start, s.end) {
				next = child
				break
			}
		}
		if next == nil {
			break
		}
		chain = append(chain, next)
		if _, ok := next.(*east.Table); ok {
			break
		}
		container = next
	}
	if len(chain) == 0 {
		return NoteItem{}, false
	}
	leaf := chain[len(chain)-1]
	headings := d.headings()
	spanOf := func(n ast.Node) (int, int) {
		s := d.spans[n]
		return s.start, max(s.start, s.end)
	}
	var kind string
	var start, end int
	if block := firstOf(chain, func(n ast.Node) bool { return isCode(n) || isHTML(n) }); block != nil {
		kind = "html"
		if isCode(block) {
			kind = "code"
		}
		start, end = spanOf(block)
	} else if table := firstOf(chain, func(n ast.Node) bool { _, ok := n.(*east.Table); return ok }); table != nil {
		kind = "row"
		s, _ := spanOf(table)
		row := line
		if line == s+1 {
			row = s
		}
		start, end = row, row
	} else if item := lastOf(chain, func(n ast.Node) bool { _, ok := n.(*ast.ListItem); return ok }); item != nil {
		kind = "item"
		start, end = spanOf(item)
	} else if quote := firstOf(chain, func(n ast.Node) bool { _, ok := n.(*ast.Blockquote); return ok }); quote != nil {
		kind = "quote"
		start, end = spanOf(quote)
	} else if h, ok := leaf.(*ast.Heading); ok && len(chain) == 1 {
		kind = "heading"
		start, _ = spanOf(leaf)
		next := len(source) + 1
		for _, other := range headings {
			if other.line > start && other.level <= h.Level {
				next = other.line
				break
			}
		}
		end = next - 1
	} else if isParagraph(leaf) {
		kind = "paragraph"
		start, end = spanOf(leaf)
	} else {
		return NoteItem{}, false
	}
	end = min(end, len(source))
	for end > start && measure.TrimWS(source[end-1]) == "" {
		end--
	}
	return NoteItem{Kind: kind, Headings: headingPath(start, headings), Lines: model.LineRange{Start: start, End: end}, Text: noteExcerpt(source[start-1 : end])}, true
}

func isCode(n ast.Node) bool {
	switch n.(type) {
	case *ast.FencedCodeBlock, *ast.CodeBlock:
		return true
	}
	return false
}

func isHTML(n ast.Node) bool { _, ok := n.(*ast.HTMLBlock); return ok }

func isParagraph(n ast.Node) bool {
	switch n.(type) {
	case *ast.Paragraph, *ast.TextBlock:
		return true
	}
	return false
}

func firstOf(chain []ast.Node, match func(ast.Node) bool) ast.Node {
	for _, n := range chain {
		if match(n) {
			return n
		}
	}
	return nil
}

func lastOf(chain []ast.Node, match func(ast.Node) bool) ast.Node {
	for i := len(chain) - 1; i >= 0; i-- {
		if match(chain[i]) {
			return chain[i]
		}
	}
	return nil
}

func headingPath(line int, headings []heading) []string {
	var stack []heading
	for _, h := range headings {
		if h.line >= line {
			continue
		}
		for len(stack) > 0 && stack[len(stack)-1].level >= h.level {
			stack = stack[:len(stack)-1]
		}
		stack = append(stack, h)
	}
	out := []string{}
	for _, h := range stack {
		out = append(out, h.title)
	}
	return out
}

func leadingWS(line string) int {
	n := 0
	for _, c := range measure.Chars(line) {
		if c != " " && c != "\t" {
			break
		}
		n++
	}
	return n
}

func noteExcerpt(lines []string) string {
	indent := -1
	for _, l := range lines {
		if measure.TrimWS(l) != "" {
			if w := leadingWS(l); indent < 0 || w < indent {
				indent = w
			}
		}
	}
	indent = max(indent, 0)
	var kept []string
	count := 0
	for _, line := range lines[:min(len(lines), noteItemMaxLines)] {
		chars := measure.Chars(line)
		text := strings.Join(chars[min(indent, leadingWS(line)):], "")
		n := measure.CharCount(text)
		if count+n > noteItemMaxCharacters {
			if len(kept) == 0 {
				kept = append(kept, measure.CharPrefix(text, noteItemMaxCharacters-1)+"…")
			}
			break
		}
		kept = append(kept, text)
		count += n + 1
	}
	return strings.Join(kept, "\n")
}

// FindNoteItem is NoteItem.find: where a block mentioned as text (at near) is in markdown now;
// unchanged when it reads as mentioned.
func FindNoteItem(text string, near int, markdown string) (item NoteItem, unchanged, ok bool) {
	wanted := normalizedLines(measure.NoteLines(text))
	if len(wanted) == 0 || wanted[0] == "" {
		return NoteItem{}, false, false
	}
	source := normalizedLines(measure.NoteLines(markdown))
	var starts, whole []int
	for i, l := range source {
		if l != wanted[0] {
			continue
		}
		starts = append(starts, i)
		if i+len(wanted) <= len(source) && equalLines(source[i:i+len(wanted)], wanted) {
			whole = append(whole, i)
		}
	}
	nearest := func(candidates []int) (NoteItem, bool) {
		sorted := append([]int(nil), candidates...)
		// A stable sort by distance from near, as Swift's.
		for i := 1; i < len(sorted); i++ {
			for j := i; j > 0 && abs(sorted[j]+1-near) < abs(sorted[j-1]+1-near); j-- {
				sorted[j], sorted[j-1] = sorted[j-1], sorted[j]
			}
		}
		for _, start := range sorted {
			if item, ok := NoteItemAt(start+1, markdown); ok && item.Lines.Start == start+1 {
				return item, true
			}
		}
		return NoteItem{}, false
	}
	if item, ok := nearest(whole); ok {
		return item, item.Text == text, true
	}
	if item, ok := nearest(starts); ok {
		return item, false, true
	}
	return NoteItem{}, false, false
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func normalizedLines(lines []string) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		out[i] = measure.TrimWS(l)
	}
	return out
}

func equalLines(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Summary is NoteItem.summary: a few words naming it, as its chip does.
func (i NoteItem) Summary() string {
	lines := measure.NoteLines(i.Text)
	switch i.Kind {
	case "row":
		if len(lines) == 0 {
			return ""
		}
		var parts []string
		for _, cell := range tableCells(measure.TrimWS(lines[0])) {
			parts = append(parts, PlainTextOfLine(cell))
		}
		return strings.Join(parts, " · ")
	case "code", "html":
		body := lines
		if i.Kind == "code" && len(body) > 0 {
			body = body[1:]
		}
		for _, l := range body {
			if t := measure.TrimWS(l); t != "" {
				return t
			}
		}
		return ""
	}
	d := parseMarkdown(i.Text)
	number := ""
	hasNumber := false
	for node := firstChild(d.root); node != nil; node = firstChild(node) {
		if list, ok := node.(*ast.List); ok && list.IsOrdered() && !hasNumber {
			number, hasNumber = strconv.Itoa(list.Start)+".", true
		}
		if isInlineContainer(node) {
			if hasNumber {
				return number + " " + d.plainText(node)
			}
			return d.plainText(node)
		}
	}
	if len(lines) > 0 {
		return measure.TrimWS(lines[0])
	}
	return ""
}

func tableCells(row string) []string {
	var cells []string
	var cell strings.Builder
	escaped := false
	for _, c := range measure.Chars(row) {
		if c == "|" && !escaped {
			cells = append(cells, cell.String())
			cell.Reset()
		} else {
			cell.WriteString(c)
		}
		escaped = c == "\\" && !escaped
	}
	cells = append(cells, cell.String())
	var out []string
	for _, c := range cells {
		if t := measure.TrimWS(c); t != "" {
			out = append(out, t)
		}
	}
	return out
}
