// Package measure ports ObjectMeasure.swift (`object.measure`, `size: "fit"`) for what needs no
// AppKit text layout: code tiles (CodeMetrics), images (pixel size from the file header),
// diagrams (DiagramLayout); and the source reading code tiles and note fences share with it
// (NoteFence, NoteAnchor, NoteSource, RefSource/GitRefs, GitWorktree, GitRunner).
package measure

import (
	"errors"
	"math"

	"github.com/twaldin/easl/easld/internal/model"
)

// Failure is ObjectMeasure.Failure: Code is the API error code (unsupported, unavailable,
// not_found, invalid_params), Message Swift's text.
type Failure struct{ Code, Message string }

func (f *Failure) Error() string { return f.Message }

// NotPorted is the failure for what easld could measure but doesn't yet.
type NotPorted struct{ What string }

func (e *NotPorted) Error() string { return e.What + " is not ported to easld" }

// Size is ObjectMeasure.size: the full object frame that shows type's content with props
// without scrolling. width (nil: default) wraps code (its maximum width) and scales images; a
// zoomed tile lays out at width / zoom and measures zoom times that under a 1× title bar.
// Errors are *Failure, or *NeedsApp for what only the app measures: notes, text shapes and
// labelled rects/ellipses (TextKit), HTML (WebKit), changes tiles (the diff engine), a code
// tile's caption when it would widen the tile (system font metrics), image formats ImageIO
// alone reads.
func Size(typ model.ObjectType, props map[string]any, width *float64, root string) (w, h float64, err error) {
	zoom := 1.0
	if ZoomApplies(typ) {
		zoom = ZoomOf(props)
	}
	var natural *float64
	if width != nil {
		natural = new(*width / zoom)
	}
	switch typ {
	case model.Code:
		excerpt, err := CodeExcerpt(props, root)
		if err != nil {
			return 0, 0, err
		}
		caption, _ := props["caption"].(string)
		_, follow := props["followOf"].(string)
		maxWidth := DefaultFitWidth
		if natural != nil {
			maxWidth = *natural
		}
		w, h = CodeRowsSize(excerpt.Lines, excerpt.FileLineCount, caption != "", follow, maxWidth)
		if caption != "" && w < Widest(maxWidth) {
			return 0, 0, &NeedsApp{What: "a code tile's caption width"}
		}
	case model.Note:
		return 0, 0, &NeedsApp{What: "a note's height"}
	case model.Shape:
		kind, _ := props["kind"].(string)
		switch kind {
		case "rect", "ellipse", "text":
			return 0, 0, &NeedsApp{What: "a shape's text"}
		case "ink":
			return 0, 0, &Failure{"unsupported", "ink has no intrinsic size"}
		}
		return 0, 0, &Failure{"invalid_params", "shape props need a kind"}
	case model.HTML:
		return 0, 0, &NeedsApp{What: "an html page"}
	case model.Changes:
		return 0, 0, &NotPorted{What: "measuring a changes tile (ChangeSet.load + ChangesMetrics)"}
	case model.Image:
		path, _ := props["path"].(string)
		if path == "" {
			return 0, 0, &Failure{"invalid_params", "an image needs props.path"}
		}
		file := ImageFile(path, root)
		pw, ph, ok, err := ImageNaturalSize(file)
		if err != nil {
			return 0, 0, err
		}
		if !ok {
			return 0, 0, &Failure{"not_found", "no readable image at " + file}
		}
		maxWidth := ImageDefaultMaxWidth
		if natural != nil {
			maxWidth = *natural
		}
		fw, fh := FittedImage(pw, ph, maxWidth)
		caption := 0.0
		if c, ok := props["caption"].(string); ok && c != "" {
			caption = ImageCaptionHeight
		}
		w, h = fw, TitleHeight+fh+caption
	case model.Diagram:
		graph, ok := DecodeDiagramGraph(props["graph"])
		if !ok {
			return 0, 0, &Failure{"unavailable", "the diagram isn't computed yet: object.reload it (it waits for the language server), then measure or fit"}
		}
		bw, bh := graph.BodySize()
		w, h = bw, TitleHeight+bh
	default:
		return 0, 0, &Failure{"unsupported", string(typ) + " objects have no intrinsic size"}
	}
	w, h = Zoomed(w, h, zoom)
	return w, h, nil
}

// CodeExcerpt is ObjectMeasure.codeExcerpt: the lines a code tile shows fitted: its range,
// else its symbol's declaration, else the whole file, at its pinned commit or its ref.
func CodeExcerpt(props map[string]any, root string) (Excerpt, error) {
	path, ok := props["path"].(string)
	if !ok {
		return Excerpt{}, &Failure{"invalid_params", "code props need a path"}
	}
	fence := Fence{Path: &path}
	if commit, ok := props["pinnedCommit"].(string); ok {
		fence.Commit = &commit
	}
	if r, ok := props["range"].(map[string]any); ok {
		k, _ := DecodeKeyed(r, nil)
		if start, end, err := DecodeLineRangeIn(k); err == nil {
			fence.Lines = &model.LineRange{Start: start, End: end}
		}
	}
	if fence.Lines == nil {
		if symbol, ok := props["symbol"].(string); ok {
			fence.Symbol = &symbol
		}
	}
	if fence.Commit == nil || *fence.Commit == "" {
		if ref := RefOf(props); ref != "" {
			refSha, _ := props["refSha"].(string)
			source, err := ResolveRef(ref, refSha, root)
			if err != nil {
				return Excerpt{}, &Failure{"not_found", DescribeRefFailure(err, ref)}
			}
			fence = source.Fence(fence)
			root = source.Root
		}
	}
	excerpt := ExcerptFor(fence, root, nil, nil)
	if excerpt.Range == nil {
		if excerpt.Status.Kind == "stale" {
			if excerpt.Missing {
				return Excerpt{}, &Failure{"not_found", excerpt.Status.Reason}
			}
			return Excerpt{}, &Failure{"unavailable", excerpt.Status.Reason}
		}
		return Excerpt{}, &Failure{"unavailable", "cannot resolve " + path}
	}
	return excerpt, nil
}

// Widest is ObjectMeasure.widest: maxWidth in whole points, at least MinWidth.
func Widest(maxWidth float64) float64 {
	return max(MinWidth, math.Floor(maxWidth+0.001))
}

// CodeRowsSize is ObjectMeasure.codeRows: the frame the rows need, as wide as the longest line
// or maxWidth (at least MinWidth) with longer lines wrapped, as tall as the rows that makes.
func CodeRowsSize(lines []string, fileLineCount int, caption, follow bool, maxWidth float64) (w, h float64) {
	longest := 0
	units := make([][]uint16, len(lines))
	for i, line := range lines {
		units[i] = UTF16(line)
		longest = max(longest, ColumnsOfUnits(units[i]))
	}
	header := ChromeHeight(caption, follow) - TitleHeight
	gutter := GutterWidth(fileLineCount)
	natural, _ := Content(len(lines), longest, gutter, header)
	width := min(natural, Widest(maxWidth))
	columns := TextColumns(width, fileLineCount)
	rows := len(lines)
	if longest > columns {
		rows = 0
		for _, u := range units {
			breaks, _ := Wrap(u, columns)
			rows += 1 + len(breaks)
		}
	}
	_, height := Content(rows, 0, gutter, header)
	return width, height + TitleHeight
}

// Reanchor is the code tile's anchor write-back (CodeTile.reanchor → Board.reanchor) done
// server-side: the range resolved against the file as the tile shows it, and its first line;
// changed false when the tile doesn't anchor, the file is empty or gone, the range is stale, or
// nothing moved.
func Reanchor(props map[string]any, root string) (rng model.LineRange, anchor *string, changed bool) {
	fence, ok := CodeAnchorFence(props)
	if !ok {
		return model.LineRange{}, nil, false
	}
	readRoot := root
	if ref := RefOf(props); ref != "" {
		refSha, _ := props["refSha"].(string)
		source, err := ResolveRef(ref, refSha, root)
		if err != nil {
			return model.LineRange{}, nil, false
		}
		fence = source.Fence(fence)
		readRoot = source.Root
	}
	text, err := ReadSource(*fence.Path, fence.Commit, readRoot)
	if err != nil || len(SideLines(text)) == 0 {
		return model.LineRange{}, nil, false
	}
	source := NoteLines(text)
	resolution := ResolveAnchor(fence, source, nil, nil)
	if resolution.Range == nil {
		return model.LineRange{}, nil, false
	}
	rng = *resolution.Range
	if first := TrimWS(source[rng.Start-1]); first != "" {
		anchor = &first
	}
	written := *fence.Lines
	same := (anchor == nil) == (fence.Anchor == nil) && (anchor == nil || *anchor == *fence.Anchor)
	return rng, anchor, rng != written || !same
}

// IsNeedsApp reports whether err is a *NeedsApp.
func IsNeedsApp(err error) bool {
	var n *NeedsApp
	return errors.As(err, &n)
}
