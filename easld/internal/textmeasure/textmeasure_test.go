package textmeasure

import (
	"math"
	"testing"

	"github.com/twaldin/easl/easld/internal/measure"
)

func one(t *testing.T, item measure.TextItem) measure.TextSize {
	t.Helper()
	got := Approximate([]measure.TextItem{item})
	if len(got) != 1 || !got[0].Approximate {
		t.Fatalf("%+v: %+v", item, got)
	}
	return got[0]
}

// Notes stack lines as TextKit does (heights exact for plain prose); these are the sizes the app
// measured for the conformance suite's measure-notes scenario and for notes TextKit laid out.
func TestNotesStackLinesAsTextKitDoes(t *testing.T) {
	for _, c := range []struct {
		markdown string
		width    *float64
		w, h     float64
	}{
		{"# Heading\n\nA paragraph of text that wraps at some width.", nil, 280, 110},
		{"short", new(200.0), 200, 63},
		{"fits\n\nits text", new(300.0), 300, 86},
		// Empty: the placeholder, one line at line height multiple 1.
		{"", nil, 280, 62},
	} {
		got := one(t, measure.TextItem{Kind: "note", Text: c.markdown, Width: c.width})
		if got.W != c.w || got.H != c.h {
			t.Errorf("%q: %vx%v, want %vx%v", c.markdown, got.W, got.H, c.w, c.h)
		}
	}
}

func TestBlocksTakeTheirOwnSpacingAndRows(t *testing.T) {
	plain := one(t, measure.TextItem{Kind: "note", Text: "para"}).H
	// A fence's rows are 13 points each (SF Mono 11.5 at multiple 1), after the paragraph's 6
	// points of spacing and the first authored row's 2 before it.
	fenced := one(t, measure.TextItem{Kind: "note", Text: "para\n\n```\na\nb\nc\n```"}).H
	if want := math.Ceil(plain + 6 + 2 + 3*13 - 0.001); math.Abs(fenced-want) > 1 {
		t.Errorf("fence: %v, want about %v", fenced, want)
	}
	// A rule is one body line with 8 points after it.
	ruled := one(t, measure.TextItem{Kind: "note", Text: "para\n\n---\n\npara"}).H
	if want := plain + 6 + 16*1.05 + 8 + 16*1.05; math.Abs(ruled-want) > 1 {
		t.Errorf("rule: %v, want about %v", ruled, want)
	}
	// A long line wraps: a narrower note is taller.
	long := "word word word word word word word word word word word word word word word word"
	wide, narrow := one(t, measure.TextItem{Kind: "note", Text: long, Width: new(600.0)}), one(t, measure.TextItem{Kind: "note", Text: long, Width: new(160.0)})
	if narrow.H <= wide.H {
		t.Errorf("wrapping: %v at 160, %v at 600", narrow.H, wide.H)
	}
}

func TestATableTooWideForItsNoteFallsShort(t *testing.T) {
	table := "| a | b | c | d | e | f | g | h |\n|---|---|---|---|---|---|---|---|\n| `abcdefghijkl` | `abcdefghijkl` | `abcdefghijkl` | `abcdefghijkl` | x | x | x | x |"
	if got := one(t, measure.TextItem{Kind: "note", Text: table, Width: new(200.0)}); got.TableShortfall < 1 {
		t.Errorf("shortfall %v", got.TableShortfall)
	}
	if got := one(t, measure.TextItem{Kind: "note", Text: table, Width: new(1600.0)}); got.TableShortfall != 0 {
		t.Errorf("wide note: shortfall %v", got.TableShortfall)
	}
}

// Shantell Sans sizes AppKit measured (the conformance suite's "Label text" at 20 pt; arrow
// caption chips the routing tests use). The table leaves kerning out, so widths may run a few
// points wide; heights are exact.
func TestShantellTextComesWithinAFewPointsOfAppKit(t *testing.T) {
	text := one(t, measure.TextItem{Kind: "text", Text: "Label text"})
	if text.H != 28 || math.Abs(text.W-98) > 3 {
		t.Errorf("text: %vx%v, AppKit 98x28", text.W, text.H)
	}
	// At 40 pt ascent (40.8) and descent (12.8) each round on their own: 54-point lines.
	big := one(t, measure.TextItem{Kind: "text", Text: "Label text", TextSize: 2})
	if big.H != 54+2 || big.W < 2*text.W-6 {
		t.Errorf("text at 2×: %vx%v", big.W, big.H)
	}
	for caption, want := range map[string][2]float64{
		"calls": {40, 20}, "BridgeConfig.load()": {145, 20}, "input 1": {55, 20}, "this.forward() → bridgeFetch()": {222, 20},
	} {
		got := one(t, measure.TextItem{Kind: "arrowLabel", Text: caption})
		if got.H != want[1] || got.W < want[0]-2 || got.W > want[0]*1.04+2 {
			t.Errorf("%q: %vx%v, AppKit %vx%v", caption, got.W, got.H, want[0], want[1])
		}
	}
	// Past 240 points a caption wraps onto a second line.
	long := one(t, measure.TextItem{Kind: "arrowLabel", Text: "a caption long enough that it has to wrap onto a second line"})
	if long.H != 40 || long.W > 248 {
		t.Errorf("long caption: %vx%v", long.W, long.H)
	}
}

func TestACaptionSetsCodeInTheCodeFont(t *testing.T) {
	plain := one(t, measure.TextItem{Kind: "caption", Text: "the answer"})
	if plain.H != measure.CaptionHeight || plain.W < 21+40 || plain.W > 21+70 {
		t.Errorf("caption %vx%v", plain.W, plain.H)
	}
	code := one(t, measure.TextItem{Kind: "caption", Text: "`the answer`"})
	if code.W <= plain.W {
		t.Errorf("code caption %v, plain %v: monospace is wider", code.W, plain.W)
	}
}
