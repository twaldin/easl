package mention

import (
	"strings"
	"unicode"

	"github.com/twaldin/easl/easld/internal/measure"
)

// AnchoredFence is NoteMarkdown.AnchoredFence: an excerpt or proposal fence; fences with the
// same info string resolve once.
type AnchoredFence struct {
	Key   string
	Fence measure.Fence
	Body  []string
	Lines []int // opening fence lines, 1-based
}

// AnchoredFences is NoteMarkdown.anchoredFences(in: parse(markdown)).
func AnchoredFences(markdown string) []AnchoredFence {
	var out []AnchoredFence
	index := map[string]int{}
	for _, block := range parseMarkdown(markdown).codeBlocks() {
		key := measure.TrimWS(block.info)
		fence := measure.ParseFenceInfo(key)
		if fence.Mode() == measure.FenceFree {
			continue
		}
		if i, ok := index[key]; ok {
			if block.line > 0 {
				out[i].Lines = append(out[i].Lines, block.line)
			}
			continue
		}
		index[key] = len(out)
		f := AnchoredFence{Key: key, Fence: fence, Body: measure.NoteLines(block.code)}
		if block.line > 0 {
			f.Lines = []int{block.line}
		}
		out = append(out, f)
	}
	return out
}

func resolveFences(fences []AnchoredFence, reading measure.LinkReading) map[string]measure.Excerpt {
	results := map[string]measure.Excerpt{}
	for _, f := range fences {
		results[f.Key] = measure.ExcerptFor(reading.Fence(f.Fence), reading.Root, nil, f.Body)
	}
	return results
}

// NoteFences is `object.get`'s `fences` for a note (NoteMarkdown.status): each anchored fence as
// written with how it resolves now, read as reading says (measure.ReadingFor).
func NoteFences(markdown string, reading measure.LinkReading) []any {
	fences := AnchoredFences(markdown)
	excerpts := resolveFences(fences, reading)
	out := make([]any, 0, len(fences))
	for _, f := range fences {
		lines := make([]any, len(f.Lines))
		for i, l := range f.Lines {
			lines[i] = float64(l)
		}
		entry := map[string]any{"info": f.Key, "markdownLines": lines, "propose": f.Fence.Mode() == measure.FencePropose}
		if f.Fence.Symbol != nil {
			entry["symbol"] = *f.Fence.Symbol
		}
		if f.Fence.Commit != nil {
			entry["commit"] = *f.Fence.Commit
		}
		excerpt, resolved := excerpts[f.Key]
		if resolved && excerpt.Path != "" {
			entry["path"] = excerpt.Path
		} else if f.Fence.Path != nil {
			entry["path"] = *f.Fence.Path
		}
		if resolved {
			for k, v := range excerpt.StatusJSON() {
				entry[k] = v
			}
		}
		out = append(out, entry)
	}
	return out
}

func needsAnchor(f AnchoredFence) bool {
	return f.Fence.Lines != nil && f.Fence.Anchor == nil && f.Fence.Symbol == nil && f.Fence.Commit == nil
}

// AnchoringRanges is NoteMarkdown.anchoringRanges(_:reading:): markdown with each unanchored
// line-range fence anchored at its resolved first line, as the note tile writes them back.
func AnchoringRanges(markdown string, reading measure.LinkReading) string {
	var fences []AnchoredFence
	for _, f := range AnchoredFences(markdown) {
		if needsAnchor(f) {
			fences = append(fences, f)
		}
	}
	if len(fences) == 0 {
		return markdown
	}
	results := resolveFences(fences, reading)
	text := markdown
	for _, f := range fences {
		excerpt, ok := results[f.Key]
		if !ok || excerpt.Status.Kind != "exact" || len(excerpt.Lines) == 0 {
			continue
		}
		if anchored, ok := anchoring(text, f.Lines, excerpt.Lines[0]); ok {
			text = anchored
		}
	}
	return text
}

// anchoring is NoteMarkdown.anchoring: ` anchor="…"` appended to the opening fence lines.
func anchoring(markdown string, fenceLines []int, anchor string) (string, bool) {
	text := measure.TrimWS(anchor)
	if text == "" || len(fenceLines) == 0 || strings.ContainsFunc(text, isNewlineRune) {
		return "", false
	}
	lines := strings.Split(markdown, "\n")
	attribute := " anchor=" + escapeForCommonMark(quoted(text))
	for _, number := range fenceLines {
		if number < 1 || number > len(lines) {
			return "", false
		}
		marker, ok := fenceMarker(lines[number-1])
		if !ok {
			return "", false
		}
		if marker == '`' && strings.Contains(text, "`") {
			return "", false
		}
		line := lines[number-1]
		carriageReturn := strings.HasSuffix(line, "\r")
		line = strings.TrimSuffix(line, "\r")
		line = strings.TrimRightFunc(line, func(r rune) bool { return unicode.IsSpace(r) || r == 0x2028 || r == 0x2029 })
		if carriageReturn {
			lines[number-1] = line + attribute + "\r"
		} else {
			lines[number-1] = line + attribute
		}
	}
	return strings.Join(lines, "\n"), true
}

func isNewlineRune(r rune) bool {
	switch r {
	case '\n', '\r', '\v', '\f', 0x85, 0x2028, 0x2029:
		return true
	}
	return false
}

func fenceMarker(line string) (byte, bool) {
	for _, marker := range []byte{'`', '~'} {
		at := strings.Index(line, strings.Repeat(string(marker), 3))
		if at < 0 {
			continue
		}
		ok := true
		for _, r := range line[:at] {
			if !(unicode.IsSpace(r) || r == '>' || r == '-' || r == '*' || r == '+' || r == '.' || unicode.IsNumber(r)) {
				ok = false
			}
		}
		if ok {
			return marker, true
		}
	}
	return 0, false
}

func quoted(text string) string {
	escaped := strings.ReplaceAll(text, "\\", "\\\\")
	if strings.Contains(text, "\"") && !strings.Contains(text, "'") {
		return "'" + escaped + "'"
	}
	return "\"" + strings.ReplaceAll(escaped, "\"", "\\\"") + "\""
}

func escapeForCommonMark(info string) string {
	return strings.ReplaceAll(strings.ReplaceAll(info, "\\", "\\\\"), "&", "\\&")
}
