package measure

import (
	"strings"
	"unicode"

	"github.com/rivo/uniseg"
)

// Swift String semantics the ports need: a Character is an extended grapheme cluster, and
// CharacterSet.whitespaces is the Zs category plus tab.

// Chars splits s into Characters (grapheme clusters).
func Chars(s string) []string {
	var out []string
	g := uniseg.NewGraphemes(s)
	for g.Next() {
		out = append(out, g.Str())
	}
	return out
}

// CharCount is String.count.
func CharCount(s string) int { return uniseg.GraphemeClusterCount(s) }

// CharPrefix is String(s.prefix(n)).
func CharPrefix(s string, n int) string {
	if n <= 0 {
		return ""
	}
	g := uniseg.NewGraphemes(s)
	end := 0
	for i := 0; i < n && g.Next(); i++ {
		_, end = g.Positions()
	}
	return s[:end]
}

// CharSuffix is String(s.suffix(n)).
func CharSuffix(s string, n int) string {
	chars := Chars(s)
	if n >= len(chars) {
		return s
	}
	return strings.Join(chars[len(chars)-n:], "")
}

// IsWS is membership in CharacterSet.whitespaces.
func IsWS(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) }

// TrimWS is trimmingCharacters(in: .whitespaces).
func TrimWS(s string) string { return strings.TrimFunc(s, IsWS) }

// IsWhitespaceChar is Character.isWhitespace for a Character.
func IsWhitespaceChar(c string) bool {
	for _, r := range c {
		return unicode.IsSpace(r) || r == 0x2028 || r == 0x2029
	}
	return false
}

// SplitLF is Swift's text.split(separator: "\n", omittingEmptySubsequences: false): it splits at
// every LF that isn't part of a CRLF, which is one Character and never equals "\n".
func SplitLF(text string) []string {
	var out []string
	start := 0
	for i := 0; i < len(text); i++ {
		if text[i] == '\n' && (i == 0 || text[i-1] != '\r') {
			out = append(out, text[start:i])
			start = i + 1
		}
	}
	return append(out, text[start:])
}

// SplitLFOmittingEmpty is text.split(separator: "\n") (empty pieces left out).
func SplitLFOmittingEmpty(text string) []string {
	var out []string
	for _, piece := range SplitLF(text) {
		if piece != "" {
			out = append(out, piece)
		}
	}
	return out
}

// NoteLines is NoteSource.lines(of:): lines without the empty string after a trailing newline,
// a final CR dropped from each.
func NoteLines(text string) []string {
	lines := SplitLF(text)
	for i, line := range lines {
		lines[i] = strings.TrimSuffix(line, "\r")
	}
	if len(lines) > 1 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// SplitOnce is Swift's split(separator:maxSplits: 1) with empty pieces omitted.
func SplitOnce(s string, sep byte) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] != sep {
			continue
		}
		if i > start {
			out = append(out, s[start:i])
			start = i + 1
			if len(out) == 1 {
				if start < len(s) {
					out = append(out, s[start:])
				}
				return out
			}
			continue
		}
		start = i + 1
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}
