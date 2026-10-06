// Package check is `layout.check` (ApiRouter.check in Sources/CanvasCore/ApiRouter.swift):
// accidental overlaps, arrows through objects, labels on tiles, lines or labels, arrows on top of
// or crossing each other (route.Geometry.LayoutCheck), and content that doesn't fit its frame:
// `overflow`, a code tile's rows past its frame (`scrolls`), and cut captions and note tables
// (`truncated`), for `ids`, for what intersects `rect`, or for the whole board.
//
// What only the app can measure comes in through Env: arrow label chip sizes, notes, text shapes
// and code captions (AppKit text layout, through Texts: a Mac client's or the glyph table's), and
// HTML pages (WebKit). Without them those objects are not measured, as Swift skips what it can't
// measure. A finding that rests on a size the glyph table approximated makes the result
// `approximate`.
package check

import (
	"math"
	"sort"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/route"
)

// Env is what a check reads besides the objects.
type Env struct {
	// Root is the board's root: code tiles' relative paths resolve there.
	Root string
	// LabelSizes are the arrows' caption chip sizes (DrawingStyle.arrowLabel), and
	// LabelApproximate the arrows whose chip the glyph table approximated; Settled the board's
	// last drawn routing (Board.settledRouting).
	LabelSizes       map[string]route.Size
	LabelApproximate map[string]bool
	Settled          *route.Result
	// Texts measures the notes, text shapes and code captions checked for fit, in one batch
	// (ObjectMeasure.note at a natural width, a text shape at its frame's width, captionWidth).
	// Nil: none are measured.
	Texts measure.Texts
	// NoteRoot is where a note's fences and images are read (its link root).
	NoteRoot func(o model.Object) string
	// HTMLSize is ObjectMeasure.htmlExtent: the page laid out at `width`. Nil when there is no
	// page measurer (ObjectMeasure.html == nil): HTML tiles aren't checked for fit.
	HTMLSize func(o model.Object, width float64) (w, h float64, ok bool)
}

// Check is layout.check's result for `ids` (nil: by `rect`, nil: the whole board). The caller
// validates `ids` (not empty, every object on this board) and decodes `rect`, as the router does
// before it reaches the board.
func Check(objects map[string]model.Object, env Env, ids []string, rect *model.Frame) map[string]any {
	geometry := route.Geometry{Objects: objects, LabelSizes: env.LabelSizes, Settled: env.Settled}
	var scope map[string]bool
	if ids != nil {
		scope = map[string]bool{}
		for _, id := range ids {
			scope[id] = true
		}
	} else if rect != nil {
		scope = ScopeOfRect(geometry, *rect)
	}
	// Code tiles read from disk: those checked for fit, and those line-bound arrows attach to
	// (their line count bounds the scroll their anchors assume).
	lineBound := LineBound(objects, scope)
	excerpts := map[string]measure.Excerpt{}
	for _, o := range objects {
		if o.Type != model.Code || !(scope == nil || scope[o.ID] || lineBound[o.ID]) {
			continue
		}
		if excerpt, err := measure.CodeExcerpt(o.Props, env.Root); err == nil {
			excerpts[o.ID] = excerpt
		}
	}
	var tiles []model.Object
	for id := range lineBound {
		if _, ok := excerpts[id]; !ok {
			continue
		}
		if o, ok := objects[id]; ok {
			tiles = append(tiles, o)
		}
	}
	rows := LineRows(tiles, excerpts, env.Root, ReadFile)

	var measurable []model.Object
	for _, o := range objects {
		if scope != nil && !scope[o.ID] {
			continue
		}
		_, follow := o.Props["followOf"].(string)
		switch {
		case o.Type == model.Code && !follow, o.Type == model.Note, o.Type == model.HTML && env.HTMLSize != nil:
		case o.Type == model.Shape && isTextShape(o):
		default:
			continue
		}
		measurable = append(measurable, o)
	}
	sort.Slice(measurable, func(i, j int) bool { return measurable[i].ID < measurable[j].ID })

	routeRows := map[string]route.CodeRows{}
	for id, r := range rows {
		routeRows[id] = r
	}
	report := geometry.LayoutCheck(scope, routeRows)

	// The text in them, measured in one batch: notes at their natural width, text shapes at
	// their frame's width, code captions.
	var items []measure.TextItem
	itemOf := map[string]int{}
	for _, o := range measurable {
		var item measure.TextItem
		switch o.Type {
		case model.Code:
			caption, _ := o.Props["caption"].(string)
			if caption == "" {
				continue
			}
			item = measure.TextItem{Kind: "caption", Text: caption}
		case model.Note:
			markdown, _ := o.Props["markdown"].(string)
			root := env.Root
			if env.NoteRoot != nil {
				root = env.NoteRoot(o)
			}
			item = measure.TextItem{Kind: "note", Text: markdown, Width: new(o.Frame.W / measure.ObjectZoom(o)), Root: root}
		case model.Shape:
			text, _ := o.Props["text"].(string)
			item = measure.TextItem{Kind: "text", Text: text, Width: new(o.Frame.W), TextSize: measure.ShapeTextSize(o.Props)}
		default:
			continue
		}
		itemOf[o.ID] = len(items)
		items = append(items, item)
	}
	var sizes []measure.TextSize
	if env.Texts != nil && len(items) > 0 {
		sizes = env.Texts.MeasureText(items)
	}
	text := func(id string) (measure.TextSize, bool) {
		i, ok := itemOf[id]
		if !ok || sizes == nil {
			return measure.TextSize{}, false
		}
		return sizes[i], true
	}

	approximate := false
	overflow, scrolls, truncated := []any{}, []any{}, []any{}
	for _, o := range measurable {
		var w, h float64
		measuredApproximately := false
		zoom := measure.ObjectZoom(o)
		natural := o.Frame.W / zoom
		switch o.Type {
		case model.Code:
			// The rows' own extent, wrapped at the frame's (natural) width, zoomed like the tile;
			// a caption too long for the frame is `truncated`.
			excerpt, ok := excerpts[o.ID]
			if !ok {
				continue
			}
			caption, _ := o.Props["caption"].(string)
			w, h = measure.CodeRowsSize(excerpt.Lines, excerpt.FileLineCount, caption != "", false, natural)
			w, h = measure.Zoomed(w, h, zoom)
			if size, ok := text(o.ID); ok {
				if missing := float64((size.W - natural) * zoom); missing >= 1 {
					truncated = append(truncated, map[string]any{"id": o.ID, "what": "caption", "x": math.Ceil(missing)})
					approximate = approximate || size.Approximate
				}
			}
		case model.HTML:
			var ok bool
			if w, h, ok = env.HTMLSize(o, o.Frame.W); !ok {
				continue
			}
		case model.Note:
			// Wrapped at the frame's (natural) width; a table too wide for it even with its cells
			// wrapped is cut, `truncated`.
			size, ok := text(o.ID)
			if !ok {
				continue
			}
			w, h = measure.Zoomed(size.W, size.H, zoom)
			measuredApproximately = size.Approximate
			if size.TableShortfall >= 1 {
				truncated = append(truncated, map[string]any{"id": o.ID, "what": "table", "x": math.Ceil(float64(size.TableShortfall * zoom))})
				approximate = approximate || size.Approximate
			}
		default:
			// Text wraps at the frame's width.
			size, ok := text(o.ID)
			if !ok {
				continue
			}
			w, h = o.Frame.W, size.H
			measuredApproximately = size.Approximate
		}
		x := max(0, w-o.Frame.W)
		y := max(0, h-o.Frame.H)
		if !(x >= 1 || y >= 1) {
			continue
		}
		// A code tile wraps at its width and scrolls to its range: rows past its frame are a
		// viewer's scrolling, often meant, not content cut off.
		if o.Type == model.Code {
			scrolls = append(scrolls, map[string]any{"id": o.ID, "y": math.Ceil(y)})
		} else {
			overflow = append(overflow, map[string]any{"id": o.ID, "x": math.Ceil(x), "y": math.Ceil(y)})
			approximate = approximate || measuredApproximately
		}
	}
	// A label finding rests on the chips involved: the arrow's own and any label it lies on.
	for _, l := range report.LabelOverlaps {
		if env.LabelApproximate[l.Arrow] {
			approximate = true
		}
		for _, id := range l.Overlaps {
			if env.LabelApproximate[id] {
				approximate = true
			}
		}
	}
	result := ResultJSON(report, overflow, scrolls, truncated)
	if approximate {
		result["approximate"] = true
	}
	return result
}

func isTextShape(o model.Object) bool {
	spec, ok := route.ParseShape(o.Props)
	return ok && spec.Kind == route.ShapeText
}

// ScopeOfRect: the objects a `rect` check covers: arrows whose route crosses it or has a
// point in it, everything else whose frame intersects it.
func ScopeOfRect(geometry route.Geometry, rect model.Frame) map[string]bool {
	routes := geometry.Routes(nil, nil)
	r := route.RectOf(rect)
	scope := map[string]bool{}
	for id, o := range geometry.Objects {
		if path, ok := routes[id]; ok {
			hit := route.PathCrosses(path, r)
			for _, p := range path {
				if hit {
					break
				}
				hit = r.Contains(p)
			}
			if hit {
				scope[id] = true
			}
			continue
		}
		if o.Frame.Intersects(rect) {
			scope[id] = true
		}
	}
	return scope
}

// LineBound: the code tiles line-bound arrows attach to: arrows in scope, and arrows whose route
// and label may lie on a scoped object (within 300 points of their ends).
func LineBound(objects map[string]model.Object, scope map[string]bool) map[string]bool {
	var scoped []route.Rect
	if scope != nil {
		for id := range scope {
			if o, ok := objects[id]; ok {
				scoped = append(scoped, route.RectOf(o.Frame))
			}
		}
	}
	bound := map[string]bool{}
	for _, o := range objects {
		if o.Type != model.Arrow {
			continue
		}
		spec, ok := route.ParseArrow(o.Props)
		if !ok {
			continue
		}
		if scope != nil && !scope[o.ID] {
			reach, any := route.NullRect, false
			for _, b := range []route.Binding{spec.From, spec.To} {
				var end route.Rect
				if b.IsPoint() {
					end = route.Rect{X: b.Point.X, Y: b.Point.Y}
				} else if target, ok := objects[b.Object]; ok {
					end = route.RectOf(target.Frame)
				} else {
					continue
				}
				if !any {
					reach, any = end, true
				} else {
					reach = reach.Union(end)
				}
			}
			if !any {
				continue
			}
			reach = reach.InsetBy(-300, -300)
			near := false
			for _, s := range scoped {
				if s.Intersects(reach) {
					near = true
					break
				}
			}
			if !near {
				continue
			}
		}
		for _, b := range []route.Binding{spec.From, spec.To} {
			if !b.IsPoint() && b.Lines != nil {
				bound[b.Object] = true
			}
		}
	}
	return bound
}

// ReadFile is NoteSource.read for LineRows: the file's text at `commit` ("" for the working
// tree).
func ReadFile(path, commit, root string) (string, bool) {
	var at *string
	if commit != "" {
		at = &commit
	}
	text, err := measure.ReadSource(path, at, root)
	return text, err == nil
}

type sourceFile struct{ path, commit, root string }

// LineRows is ApiRouter.lineRows: the visual rows line anchors sit on for each of `tiles` (code
// tiles with an excerpt): its whole file (at its pinned commit, else where its ref is now) wrapped
// at its natural width, the way the tile shows it, or one row per line when the file can't be
// read. `read` reads a file (ReadFile).
func LineRows(tiles []model.Object, excerpts map[string]measure.Excerpt, root string, read func(path, commit, root string) (string, bool)) map[string]*measure.CodeRows {
	fileOf := map[string]sourceFile{}
	for _, tile := range tiles {
		path, ok := tile.Props["path"].(string)
		if !ok {
			continue
		}
		pinned, _ := tile.Props["pinnedCommit"].(string)
		if ref := measure.RefOf(tile.Props); pinned == "" && ref != "" {
			refSha, _ := tile.Props["refSha"].(string)
			source, err := measure.ResolveRef(ref, refSha, root)
			if err != nil {
				continue
			}
			p := path
			if fenced := source.Fence(measure.Fence{Path: &path}); fenced.Path != nil {
				p = *fenced.Path
			}
			commit := ""
			if source.Commit != nil {
				commit = *source.Commit
			}
			fileOf[tile.ID] = sourceFile{p, commit, source.Root}
		} else {
			fileOf[tile.ID] = sourceFile{path, pinned, root}
		}
	}
	texts := map[sourceFile]string{}
	for _, f := range fileOf {
		if _, done := texts[f]; done {
			continue
		}
		if text, ok := read(f.path, f.commit, f.root); ok {
			texts[f] = text
		}
	}
	type key struct {
		file  sourceFile
		width float64
	}
	wrapped := map[key]*measure.CodeRows{}
	rows := map[string]*measure.CodeRows{}
	for _, tile := range tiles {
		f, ok := fileOf[tile.ID]
		text, read := texts[f]
		if ok && read {
			k := key{f, tile.Frame.W / measure.ObjectZoom(tile)}
			if wrapped[k] == nil {
				wrapped[k] = measure.CodeRowsForFile(text, k.width)
			}
			rows[tile.ID] = wrapped[k]
		} else if excerpt, ok := excerpts[tile.ID]; ok {
			rows[tile.ID] = measure.CodeRowsForLineCount(excerpt.FileLineCount)
		}
	}
	return rows
}

// ResultJSON is layout.check's result: label frames rounded outward, overlap lengths and points
// to whole points; `hints` only when there are some.
func ResultJSON(report route.Report, overflow, scrolls, truncated []any) map[string]any {
	strs := func(ids []string) []any {
		out := make([]any, len(ids))
		for i, id := range ids {
			out[i] = id
		}
		return out
	}
	overlaps := []any{}
	for _, pair := range report.Overlaps {
		overlaps = append(overlaps, strs(pair))
	}
	crossings := []any{}
	for _, c := range report.Crossings {
		crossings = append(crossings, map[string]any{"arrow": c.Arrow, "crosses": strs(c.Crosses)})
	}
	labels := []any{}
	for _, l := range report.LabelOverlaps {
		labels = append(labels, map[string]any{"arrow": l.Arrow, "label": l.Label,
			"frame":    map[string]any{"x": math.Floor(l.Frame.X), "y": math.Floor(l.Frame.Y), "w": math.Ceil(l.Frame.W), "h": math.Ceil(l.Frame.H)},
			"overlaps": strs(l.Overlaps), "lines": strs(l.Lines)})
	}
	arrowOverlaps := []any{}
	for _, o := range report.ArrowOverlaps {
		arrowOverlaps = append(arrowOverlaps, map[string]any{"arrows": strs(o.Arrows[:]), "length": math.Round(o.Length),
			"at": map[string]any{"x": math.Round(o.At.X), "y": math.Round(o.At.Y)}})
	}
	intersections := []any{}
	for _, x := range report.ArrowIntersections {
		intersections = append(intersections, map[string]any{"arrows": strs(x.Arrows[:]), "count": float64(x.Count),
			"at": map[string]any{"x": math.Round(x.At.X), "y": math.Round(x.At.Y)}})
	}
	result := map[string]any{
		"overlaps":           overlaps,
		"arrowCrossings":     crossings,
		"labelOverlaps":      labels,
		"arrowOverlaps":      arrowOverlaps,
		"arrowIntersections": intersections,
		"overflow":           overflow,
		"scrolls":            scrolls,
		"truncated":          truncated,
	}
	if len(report.Hints) > 0 {
		result["hints"] = strs(report.Hints)
	}
	return result
}
