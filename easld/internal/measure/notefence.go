package measure

import (
	"strconv"
	"strings"
	"unicode"

	"github.com/twaldin/easl/easld/internal/model"
)

// Fence is a NoteFence: what an excerpt fence (or a code tile's range) points at.
type Fence struct {
	Language string
	Path     *string
	Commit   *string
	Lines    *model.LineRange
	Symbol   *string
	Anchor   *string
	Propose  bool
}

// FenceMode is NoteFence.Mode.
type FenceMode int

const (
	FenceFree FenceMode = iota
	FenceExcerpt
	FencePropose
)

// Mode is free without a path or symbol, else an excerpt or a proposal.
func (f Fence) Mode() FenceMode {
	if f.Path == nil && f.Symbol == nil {
		return FenceFree
	}
	if f.Propose {
		return FencePropose
	}
	return FenceExcerpt
}

// ParseFenceInfo is NoteFence(info:).
func ParseFenceInfo(info string) Fence {
	var f Fence
	languageSet := false
	for _, token := range fenceTokens(info) {
		equals := strings.IndexByte(token, '=')
		if equals < 0 {
			if token == "propose" {
				f.Propose = true
			} else if !languageSet {
				f.Language = token
				languageSet = true
			}
			continue
		}
		key := token[:equals]
		value := fenceUnquote(token[equals+1:])
		switch key {
		case "file", "path":
			f.parseLocation(value)
		case "symbol":
			f.Symbol = nonEmpty(value)
		case "anchor":
			f.Anchor = nonEmpty(value)
		case "commit":
			f.Commit = nonEmpty(value)
		case "lines":
			f.Lines = fenceLineRange(value)
		}
	}
	return f
}

func nonEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func (f *Fence) parseLocation(value string) {
	rest := value
	if hash := strings.LastIndexByte(rest, '#'); hash >= 0 {
		after := rest[hash+1:]
		if first, ok := firstRune(after); ok && (first == 'L' || unicode.IsNumber(first)) {
			f.Lines = fenceLineRange(after)
			rest = rest[:hash]
		}
	}
	if at := strings.LastIndexByte(rest, '@'); at > 0 {
		ref := rest[at+1:]
		valid := ref != "" && !strings.Contains(ref, "/")
		for _, r := range ref {
			if !(unicode.IsLetter(r) || unicode.IsNumber(r) || strings.ContainsRune("._~^-", r)) {
				valid = false
			}
		}
		if valid {
			f.Commit = new(ref)
			rest = rest[:at]
		}
	}
	f.Path = nonEmpty(rest)
}

func firstRune(s string) (rune, bool) {
	for _, r := range s {
		return r, true
	}
	return 0, false
}

// fenceLineRange is NoteFence.lineRange: `L10`, `L10-40`, `L10-L40`, `10-40`.
func fenceLineRange(text string) *model.LineRange {
	parts := SplitOnce(text, '-')
	for i, p := range parts {
		parts[i] = strings.TrimPrefix(p, "L")
	}
	if len(parts) == 0 {
		return nil
	}
	start, err := strconv.Atoi(parts[0])
	if err != nil || start < 1 {
		return nil
	}
	if len(parts) != 2 {
		return &model.LineRange{Start: start, End: start}
	}
	end, err := strconv.Atoi(parts[1])
	if err != nil || end < start {
		return nil
	}
	return &model.LineRange{Start: start, End: end}
}

func fenceTokens(info string) []string {
	var tokens []string
	var current strings.Builder
	var quote string
	escaped := false
	for _, c := range Chars(info) {
		switch {
		case escaped:
			current.WriteString(c)
			escaped = false
		case c == "\\" && quote != "":
			current.WriteString(c)
			escaped = true
		case quote != "":
			current.WriteString(c)
			if c == quote {
				quote = ""
			}
		case c == "\"" || c == "'":
			current.WriteString(c)
			quote = c
		case IsWhitespaceChar(c):
			if current.Len() > 0 {
				tokens = append(tokens, current.String())
			}
			current.Reset()
		default:
			current.WriteString(c)
		}
	}
	if current.Len() > 0 {
		tokens = append(tokens, current.String())
	}
	return tokens
}

func fenceUnquote(value string) string {
	chars := Chars(value)
	if len(chars) < 2 || (chars[0] != "\"" && chars[0] != "'") || chars[len(chars)-1] != chars[0] {
		return value
	}
	first := chars[0]
	inner := chars[1 : len(chars)-1]
	var out strings.Builder
	for i := 0; i < len(inner); i++ {
		if inner[i] == "\\" && i+1 < len(inner) && (inner[i+1] == first || inner[i+1] == "\\") {
			i++
		}
		out.WriteString(inner[i])
	}
	return out.String()
}

// CodeAnchorFence is CodeAnchor.fence: the fence a code tile's range resolves as; ok false for
// a follow tile, one pinned to a commit, or one without a range.
func CodeAnchorFence(props map[string]any) (Fence, bool) {
	if _, ok := props["followOf"].(string); ok {
		return Fence{}, false
	}
	if pinned, ok := props["pinnedCommit"].(string); ok && pinned != "" {
		return Fence{}, false
	}
	path, _ := props["path"].(string)
	rangeProp, _ := props["range"].(map[string]any)
	start, ok := JSONInt(rangeProp["start"])
	if path == "" || !ok {
		return Fence{}, false
	}
	end := start
	if e, ok := JSONInt(rangeProp["end"]); ok {
		end = max(start, e)
	}
	f := Fence{Path: &path, Lines: &model.LineRange{Start: start, End: end}}
	if anchor, ok := props["anchor"].(string); ok && anchor != "" {
		f.Anchor = &anchor
	}
	return f, true
}

// JSONInt is JSONValue.int: a number truncated toward zero.
func JSONInt(v any) (int, bool) {
	f, ok := v.(float64)
	if !ok {
		return 0, false
	}
	return int(f), true
}
