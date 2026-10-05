// Package textmeasure approximates the app's AppKit text layout from the glyph table
// (measure/glyphs) for text.measure when no Mac client measures it: notes as NoteRenderer
// renders them and TextKit 2 stacks them, text shapes and labels as
// NSAttributedString.boundingRect sets them, arrow caption chips, and code captions. Text is
// unkerned and unshaped, and lines break after spaces (a word wider than its line between
// characters), so sizes are a few points off what the app draws (docs/design/next.md, "The
// client protocol").
package textmeasure

import (
	"math"
	"unicode"

	"github.com/rivo/uniseg"
	"github.com/twaldin/easl/easld/internal/measure/glyphs"
)

// span is text set in one face.
type span struct {
	text string
	face *glyphs.Face
	// protected: a link or code span, which a table cell never breaks inside (NoteRenderer.runs).
	protected bool
	// image: an attachment this wide and tall instead of text (a note's picture).
	image *box
}

type box struct{ w, h float64 }

// cluster is one character (grapheme cluster) of a span.
type cluster struct {
	text      string
	width     float64
	face      *glyphs.Face
	space     bool // breaks after it, and hangs past the line's end
	forced    bool // a line separator: the line ends here
	alone     bool // East Asian wide: a line may break before and after it
	protected bool
	image     *box
}

func clusters(spans []span) []cluster {
	var out []cluster
	for _, s := range spans {
		if s.image != nil {
			out = append(out, cluster{text: "\uFFFC", width: s.image.w, face: s.face, image: s.image, protected: s.protected})
			continue
		}
		g := uniseg.NewGraphemes(s.text)
		for g.Next() {
			text := g.Str()
			first := g.Runes()[0]
			c := cluster{text: text, face: s.face, protected: s.protected}
			switch {
			case text == "\u2028" || text == "\n" || text == "\r\n":
				c.forced = true
			case first == '\t' || unicode.Is(unicode.Zs, first):
				c.space = true
				c.width = s.face.Advance(first)
				if first == '\t' {
					c.width = 4 * s.face.Advance(' ')
				}
			default:
				c.width = s.face.Width(text)
				c.alone = isWide(first)
			}
			out = append(out, c)
		}
	}
	return out
}

func isWide(c rune) bool {
	return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF00 && c <= 0xFF60) || (c >= 0x20000 && c <= 0x3FFFD)
}

// line is one laid-out line: how wide its text is (trailing spaces left out) and the faces and
// pictures on it.
type line struct {
	width  float64
	height float64 // the tallest face's line height
	image  float64 // the tallest picture plus the descent below it
}

// word is what a line may not break inside: characters up to a space (and the spaces after
// them), one wide character, or a line separator.
type word struct {
	chars  []cluster
	width  float64 // without the trailing spaces
	spaces float64
	forced bool
}

func words(cs []cluster) []word {
	var out []word
	var cur word
	flush := func() {
		if len(cur.chars) > 0 || cur.forced {
			out = append(out, cur)
		}
		cur = word{}
	}
	for _, c := range cs {
		switch {
		case c.forced:
			cur.forced = true
			flush()
		case c.space:
			cur.chars = append(cur.chars, c)
			cur.spaces += c.width
		default:
			if cur.spaces > 0 || (c.alone && len(cur.chars) > 0) {
				flush()
			}
			cur.chars = append(cur.chars, c)
			cur.width += c.width
			if c.alone {
				flush()
			}
		}
	}
	flush()
	return out
}

// lines breaks spans into lines at most `width` wide (math.Inf(1): never wrapped). base is the
// paragraph's face, which sets an empty line's height. A paragraph is at least one line.
func lines(spans []span, width float64, base *glyphs.Face) []line {
	var out []line
	cur := line{}
	pos := 0.0 // where the next word starts, the trailing spaces included
	used := false
	emit := func() {
		if cur.height == 0 {
			cur.height = base.LineHeight
		}
		out = append(out, cur)
		cur, pos, used = line{}, 0, false
	}
	add := func(c cluster) {
		if c.face != nil && c.face.LineHeight > cur.height {
			cur.height = c.face.LineHeight
		}
		if c.image != nil && c.face != nil {
			cur.image = max(cur.image, c.image.h+c.face.Descent)
		}
	}
	const slack = 1e-6
	for _, w := range words(clusters(spans)) {
		if used && pos+w.width > width+slack {
			emit()
		}
		if !used && w.width > width+slack {
			// A word wider than the line breaks between characters.
			for _, c := range w.chars {
				if c.space {
					continue
				}
				if used && pos+c.width > width+slack {
					emit()
				}
				add(c)
				pos += c.width
				cur.width = pos
				used = true
			}
			pos += w.spaces
		} else if len(w.chars) > 0 {
			for _, c := range w.chars {
				add(c)
			}
			cur.width = pos + w.width
			pos += w.width + w.spaces
			used = true
		}
		if w.forced {
			emit()
		}
	}
	if used || len(out) == 0 || cur.height > 0 {
		emit()
	}
	return out
}

// widthOf is how wide spans set on one line (NSAttributedString.size().width).
func widthOf(spans []span) float64 {
	w := 0.0
	for _, s := range spans {
		if s.image != nil {
			w += s.image.w
			continue
		}
		w += s.face.Width(s.text)
	}
	return w
}

// bounds is NSAttributedString.boundingRect(with: (width, ∞), options: .usesLineFragmentOrigin):
// the widest line and the lines' height, for text in one face (paragraphs split at newlines).
func bounds(text string, face *glyphs.Face, width float64) (w, h float64) {
	if text == "" {
		return 0, 0
	}
	for _, l := range lines([]span{{text: text, face: face}}, width, face) {
		w = max(w, l.width)
		h += l.height
	}
	return w, h
}

func ceil(x float64) float64 { return math.Ceil(x - 1e-9) }
