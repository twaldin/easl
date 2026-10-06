// Package glyphs is the glyph table easld approximates text with when no Mac client measures it
// (docs/design/next.md, "The client protocol"): advance widths and line heights of every face the
// app sets text in, extracted on a Mac by scripts/glyph-widths.swift into glyphs.json. No font
// data ships beyond those numbers, and nothing here is kerned or shaped.
package glyphs

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"sync"

	"github.com/rivo/uniseg"
)

//go:embed glyphs.json
var table []byte

// Face is one font at one size, as the app's text layout sets it.
type Face struct {
	Key string
	// Size is the point size; LineHeight how far TextKit (and NSAttributedString.boundingRect)
	// advances one line of this face at line height multiple 1; Descent below the baseline.
	Size, LineHeight, Ascent, Descent float64
	// fallback is the advance of a character outside the table (the face's mean lowercase
	// advance); East Asian wide characters and emoji take 1 em instead.
	fallback float64
	advances map[rune]float64
}

type rawFace struct {
	Font       string             `json:"font"`
	Size       float64            `json:"size"`
	LineHeight float64            `json:"lineHeight"`
	Ascent     float64            `json:"ascent"`
	Descent    float64            `json:"descent"`
	Fallback   float64            `json:"fallback"`
	Advances   []float64          `json:"advances"`
	AdvancesOf string             `json:"advancesOf"`
	Advance    *float64           `json:"advance"`
	Except     map[string]float64 `json:"except"`
}

var (
	loadOnce sync.Once
	faces    map[string]*Face
)

func load() {
	var raw struct {
		CodePoints [][2]rune          `json:"codePoints"`
		Faces      map[string]rawFace `json:"faces"`
	}
	if err := json.Unmarshal(table, &raw); err != nil {
		panic(fmt.Sprintf("glyphs.json: %v", err))
	}
	var points []rune
	for _, r := range raw.CodePoints {
		for c := r[0]; c <= r[1]; c++ {
			points = append(points, c)
		}
	}
	faces = map[string]*Face{}
	// Faces that repeat another's advances name it; resolve those after the rest.
	var aliases []string
	for key, f := range raw.Faces {
		face := &Face{Key: key, Size: f.Size, LineHeight: f.LineHeight, Ascent: f.Ascent, Descent: f.Descent, fallback: f.Fallback / 100, advances: map[rune]float64{}}
		switch {
		case f.AdvancesOf != "":
			aliases = append(aliases, key)
		case f.Advance != nil:
			for _, c := range points {
				face.advances[c] = *f.Advance / 100
			}
			for code, advance := range f.Except {
				c, err := strconv.Atoi(code)
				if err != nil {
					panic(fmt.Sprintf("glyphs.json: %s: code point %q", key, code))
				}
				face.advances[rune(c)] = advance / 100
			}
		default:
			if len(f.Advances) != len(points) {
				panic(fmt.Sprintf("glyphs.json: %s has %d advances for %d code points", key, len(f.Advances), len(points)))
			}
			for i, c := range points {
				face.advances[c] = f.Advances[i] / 100
			}
		}
		faces[key] = face
	}
	for _, key := range aliases {
		of, ok := faces[raw.Faces[key].AdvancesOf]
		if !ok || raw.Faces[raw.Faces[key].AdvancesOf].AdvancesOf != "" {
			panic(fmt.Sprintf("glyphs.json: %s repeats %q, which has no advances of its own", key, raw.Faces[key].AdvancesOf))
		}
		faces[key].advances = of.advances
	}
}

func lookup(key string) (*Face, bool) {
	loadOnce.Do(load)
	f, ok := faces[key]
	return f, ok
}

func sizeKey(size float64) string {
	return strconv.FormatFloat(math.Round(size*100)/100, 'f', -1, 64)
}

// System is NSFont.systemFont(ofSize: size, weight: weight) ("regular", "medium", "semibold",
// "bold") with NoteRenderer's bold (strong) and italic (emphasis) traits added. Faces the app
// never sets fall back to the nearest one the table has.
func System(size float64, weight string, bold, italic bool) *Face {
	key := "system-" + sizeKey(size) + "-" + weight
	if bold && weight != "bold" {
		key += "-bold"
	}
	if italic {
		key += "-italic"
	}
	if f, ok := lookup(key); ok {
		return f
	}
	return nearest("system-", size, weight, bold, italic)
}

// Mono is NSFont.monospacedSystemFont(ofSize: size, weight: .regular).
func Mono(size float64) *Face {
	if f, ok := lookup("mono-" + sizeKey(size)); ok {
		return f
	}
	return scaled(nearest("mono-", size, "", false, false), size)
}

// Shantell is DrawingStyle.font(size:): Shantell Sans, which scales linearly (it has no
// optical sizes), so sizes the table doesn't list scale its 20 pt face.
func Shantell(size float64) *Face {
	if f, ok := lookup("shantell-" + sizeKey(size)); ok {
		return f
	}
	f, _ := lookup("shantell-20")
	return scaled(f, size)
}

// nearest is the table's face closest in size with the same prefix, preferring the same weight
// and traits.
func nearest(prefix string, size float64, weight string, bold, italic bool) *Face {
	loadOnce.Do(load)
	var best *Face
	score := func(f *Face) float64 {
		s := math.Abs(f.Size - size)
		if weight != "" && !containsWord(f.Key, weight) {
			s += 100
		}
		if containsWord(f.Key, "italic") != italic {
			s += 50
		}
		if containsWord(f.Key, "bold") != (bold || weight == "bold") {
			s += 25
		}
		return s
	}
	for key, f := range faces {
		if len(key) < len(prefix) || key[:len(prefix)] != prefix {
			continue
		}
		if best == nil || score(f) < score(best) || (score(f) == score(best) && f.Key < best.Key) {
			best = f
		}
	}
	return best
}

func containsWord(key, word string) bool {
	for start := 0; start < len(key); {
		end := start
		for end < len(key) && key[end] != '-' {
			end++
		}
		if key[start:end] == word {
			return true
		}
		start = end + 1
	}
	return false
}

// scaled is f at another size: advances and metrics in proportion, the line height rounded as
// TextKit rounds it (ascent and descent each to whole points).
func scaled(f *Face, size float64) *Face {
	if f.Size == size {
		return f
	}
	k := size / f.Size
	out := &Face{Key: f.Key + "@" + sizeKey(size), Size: size, Ascent: f.Ascent * k, Descent: f.Descent * k, fallback: f.fallback * k, advances: make(map[rune]float64, len(f.advances))}
	out.LineHeight = math.Round(out.Ascent) + math.Round(out.Descent)
	for c, a := range f.advances {
		out.advances[c] = a * k
	}
	return out
}

// Width is how wide text sets in this face on one line: the sum of its characters' advances
// (a character is a grapheme cluster, measured by its first scalar), unkerned.
func (f *Face) Width(text string) float64 {
	w := 0.0
	g := uniseg.NewGraphemes(text)
	for g.Next() {
		w += f.Advance(g.Runes()[0])
	}
	return w
}

// Advance is one character's advance: the table's, else 1 em for East Asian wide characters
// and emoji, nothing for controls and marks, else the face's fallback.
func (f *Face) Advance(c rune) float64 {
	if a, ok := f.advances[c]; ok {
		return a
	}
	switch {
	case c < 0x20, c >= 0x7F && c < 0xA0, c == 0x200B, c == 0x200D, c == 0xFEFF, c >= 0xFE00 && c <= 0xFE0F, isMark(c):
		return 0
	case wide(c):
		return f.Size
	}
	return f.fallback
}

func isMark(c rune) bool {
	return (c >= 0x0300 && c <= 0x036F) || (c >= 0x1AB0 && c <= 0x1AFF) || (c >= 0x20D0 && c <= 0x20FF)
}

// wide: East Asian wide and fullwidth characters (CodeMetrics.columns' ranges) and emoji.
func wide(c rune) bool {
	switch {
	case c >= 0x1100 && c <= 0x115F, c >= 0x2E80 && c <= 0x303E, c >= 0x3041 && c <= 0x33FF, c >= 0x3400 && c <= 0x4DBF,
		c >= 0x4E00 && c <= 0x9FFF, c >= 0xA000 && c <= 0xA4CF, c >= 0xAC00 && c <= 0xD7A3, c >= 0xF900 && c <= 0xFAFF,
		c >= 0xFE30 && c <= 0xFE4F, c >= 0xFF00 && c <= 0xFF60, c >= 0xFFE0 && c <= 0xFFE6,
		c >= 0x2600 && c <= 0x27BF, c >= 0x1F000 && c <= 0x1FAFF, c >= 0x20000 && c <= 0x3FFFD:
		return true
	}
	return false
}
