package board

import (
	"sort"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/route"
)

// DefaultLayoutGap is layout.*'s default gap (Layout.defaultGap).
const DefaultLayoutGap = 40.0

// Layout option values, in Swift's CaseIterable order (error messages list them).
var (
	LayoutSides      = []string{"right", "left", "above", "below"}
	LayoutAligns     = []string{"start", "center", "end"}
	LayoutDirections = []string{"row", "column"}
)

// Point is an origin.
type Point struct{ X, Y float64 }

// LayoutPlace is Layout.place: the origin for a size box gap away from anchor on side, aligned
// along that side.
func LayoutPlace(w, h float64, anchor model.Frame, side string, gap float64, align string) Point {
	along := func(start, length, extent float64) float64 {
		switch align {
		case "center":
			return start + (length-extent)/2
		case "end":
			return start + length - extent
		}
		return start
	}
	switch side {
	case "left":
		return Point{anchor.X - gap - w, along(anchor.Y, anchor.H, h)}
	case "below":
		return Point{along(anchor.X, anchor.W, w), anchor.MaxY() + gap}
	case "above":
		return Point{along(anchor.X, anchor.W, w), anchor.Y - gap - h}
	}
	return Point{anchor.MaxX() + gap, along(anchor.Y, anchor.H, h)}
}

// LayoutStack is Layout.stack: origins for boxes laid one after another from origin, wrapping
// at wrapAt (nil: never).
func LayoutStack(sizes []Size, origin Point, direction string, gap float64, wrapAt *float64, align string) []Point {
	row := direction != "column"
	main := func(s Size) float64 {
		if row {
			return s.W
		}
		return s.H
	}
	cross := func(s Size) float64 {
		if row {
			return s.H
		}
		return s.W
	}
	lines := [][]int{{}}
	length := 0.0
	for i, s := range sizes {
		last := len(lines) - 1
		grown := main(s)
		if len(lines[last]) > 0 {
			grown = length + gap + main(s)
		}
		if wrapAt != nil && len(lines[last]) > 0 && grown > *wrapAt {
			lines = append(lines, []int{i})
			length = main(s)
		} else {
			lines[last] = append(lines[last], i)
			length = grown
		}
	}
	origins := make([]Point, len(sizes))
	crossOffset := 0.0
	for _, line := range lines {
		if len(line) == 0 {
			continue
		}
		thickness := 0.0
		for _, i := range line {
			thickness = max(thickness, cross(sizes[i]))
		}
		mainOffset := 0.0
		for _, i := range line {
			s := sizes[i]
			slack := thickness - cross(s)
			shift := 0.0
			if align == "center" {
				shift = slack / 2
			} else if align == "end" {
				shift = slack
			}
			if row {
				origins[i] = Point{origin.X + mainOffset, origin.Y + crossOffset + shift}
			} else {
				origins[i] = Point{origin.X + crossOffset + shift, origin.Y + mainOffset}
			}
			mainOffset += main(s) + gap
		}
		crossOffset += thickness + gap
	}
	return origins
}

// GridCell is a box at row, col.
type GridCell struct {
	ID       string
	Row, Col int
	Size     Size
}

// Track is one column (x, width) or row (y, height) of a grid.
type Track struct {
	Index         int
	Start, Length float64
}

// Grid is Layout.grid's result.
type Grid struct {
	Origins       []Point
	Columns, Rows []Track
}

// LayoutGrid is Layout.grid: cells in shared columns and rows from origin.
func LayoutGrid(cells []GridCell, origin Point, colGap, rowGap float64, colAlign, rowAlign string) Grid {
	tracks := func(index func(GridCell) int, extent func(GridCell) float64, start, gap float64) []Track {
		lengths := map[int]float64{}
		for _, c := range cells {
			lengths[index(c)] = max(lengths[index(c)], extent(c))
		}
		keys := make([]int, 0, len(lengths))
		for k := range lengths {
			keys = append(keys, k)
		}
		sort.Ints(keys)
		pos := start
		out := make([]Track, len(keys))
		for i, k := range keys {
			out[i] = Track{k, pos, lengths[k]}
			pos += lengths[k] + gap
		}
		return out
	}
	offset := func(slack float64, align string) float64 {
		switch align {
		case "center":
			return slack / 2
		case "end":
			return slack
		}
		return 0
	}
	columns := tracks(func(c GridCell) int { return c.Col }, func(c GridCell) float64 { return c.Size.W }, origin.X, colGap)
	rows := tracks(func(c GridCell) int { return c.Row }, func(c GridCell) float64 { return c.Size.H }, origin.Y, rowGap)
	colAt, rowAt := map[int]Track{}, map[int]Track{}
	for _, t := range columns {
		colAt[t.Index] = t
	}
	for _, t := range rows {
		rowAt[t.Index] = t
	}
	origins := make([]Point, len(cells))
	for i, c := range cells {
		col, row := colAt[c.Col], rowAt[c.Row]
		origins[i] = Point{col.Start + offset(col.Length-c.Size.W, colAlign), row.Start + offset(row.Length-c.Size.H, rowAlign)}
	}
	return Grid{origins, columns, rows}
}

// PlaceNear moves id gap beside anchor; one step. Groups move their members.
func (b *Board) PlaceNear(id, anchor, side string, gap float64, align, caller string) (map[string]model.Frame, error) {
	moving, err := b.Object(id)
	if err != nil {
		return nil, err
	}
	target, err := b.Object(anchor)
	if err != nil {
		return nil, err
	}
	if id == anchor {
		return nil, InvalidParams("an object can't be placed beside itself")
	}
	origin := LayoutPlace(moving.Frame.W, moving.Frame.H, target.Frame, side, gap, align)
	return b.shift([]move{{id, origin.X - moving.Frame.X, origin.Y - moving.Frame.Y}}, caller)
}

// Stack lays ids out in a row or column from where the first is (or origin); one step.
func (b *Board) Stack(ids []string, direction string, gap float64, wrapAt *float64, align string, origin *Point, caller string) (map[string]model.Frame, error) {
	if len(ids) == 0 {
		return map[string]model.Frame{}, nil
	}
	seen := map[string]bool{}
	for _, id := range ids {
		if seen[id] {
			return nil, InvalidParams("ids repeat")
		}
		seen[id] = true
	}
	frames := make([]model.Frame, len(ids))
	sizes := make([]Size, len(ids))
	for i, id := range ids {
		o, err := b.Object(id)
		if err != nil {
			return nil, err
		}
		frames[i], sizes[i] = o.Frame, Size{o.Frame.W, o.Frame.H}
	}
	start := Point{frames[0].X, frames[0].Y}
	if origin != nil {
		start = *origin
	}
	origins := LayoutStack(sizes, start, direction, gap, wrapAt, align)
	moves := make([]move, len(ids))
	for i, id := range ids {
		moves[i] = move{id, origins[i].X - frames[i].X, origins[i].Y - frames[i].Y}
	}
	return b.shift(moves, caller)
}

// Translate moves ids by (dx, dy) in one step.
func (b *Board) Translate(ids []string, dx, dy float64, caller string) (map[string]model.Frame, error) {
	if len(ids) == 0 {
		return map[string]model.Frame{}, nil
	}
	moves := make([]move, len(ids))
	for i, id := range ids {
		moves[i] = move{id, dx, dy}
	}
	return b.shift(moves, caller)
}

// GridLayout places cells in shared columns and rows from origin (default the cells' current
// top-left); one step.
func (b *Board) GridLayout(cells []GridCell, colGap, rowGap float64, colAlign, rowAlign string, origin *Point, caller string) (map[string]model.Frame, Grid, error) {
	if len(cells) == 0 {
		return nil, Grid{}, InvalidParams("cells must not be empty")
	}
	ids := map[string]bool{}
	for _, c := range cells {
		if ids[c.ID] {
			return nil, Grid{}, InvalidParams("cell ids repeat")
		}
		ids[c.ID] = true
	}
	taken := map[[2]int]bool{}
	for _, c := range cells {
		if c.Row < 0 || c.Col < 0 {
			return nil, Grid{}, InvalidParams("cell %s: row and col must be non-negative", c.ID)
		}
		if taken[[2]int{c.Row, c.Col}] {
			return nil, Grid{}, InvalidParams("two cells at row %d, col %d", c.Row, c.Col)
		}
		taken[[2]int{c.Row, c.Col}] = true
	}
	frames := make([]model.Frame, len(cells))
	for i := range cells {
		o, err := b.Object(cells[i].ID)
		if err != nil {
			return nil, Grid{}, err
		}
		frames[i] = o.Frame
		cells[i].Size = Size{o.Frame.W, o.Frame.H}
	}
	start := Point{frames[0].X, frames[0].Y}
	for _, f := range frames {
		start.X, start.Y = min(start.X, f.X), min(start.Y, f.Y)
	}
	if origin != nil {
		start = *origin
	}
	grid := LayoutGrid(cells, start, colGap, rowGap, colAlign, rowAlign)
	moves := make([]move, len(cells))
	for i, c := range cells {
		moves[i] = move{c.ID, grid.Origins[i].X - frames[i].X, grid.Origins[i].Y - frames[i].Y}
	}
	placed, err := b.shift(moves, caller)
	return placed, grid, err
}

type move struct {
	id     string
	dx, dy float64
}

// shift moves each object by its offset as one step and one revision and returns the moved
// objects' frames. A group moves its members (re-fit once, after every member moved); an
// object reached twice with the same offset moves once. Arrows carry free ends.
func (b *Board) shift(moves []move, caller string) (map[string]model.Frame, error) {
	offsets := map[string][2]float64{}
	var order []string
	for _, m := range moves {
		o, err := b.Object(m.id)
		if err != nil {
			return nil, err
		}
		targets := []string{m.id}
		if o.Type == model.Group {
			targets = route.LeafMembers(m.id, b.objects)
		}
		for _, t := range targets {
			if earlier, ok := offsets[t]; ok {
				if earlier != [2]float64{m.dx, m.dy} {
					return nil, InvalidParams("%s would move twice: %s and a group containing it are both listed", t, m.id)
				}
				continue
			}
			offsets[t] = [2]float64{m.dx, m.dy}
			order = append(order, t)
		}
	}
	result := map[string]model.Frame{}
	err := b.Atomically(func() error {
		err := b.deferringRefits(func() error {
			for _, t := range order {
				d := offsets[t]
				if d[0] == 0 && d[1] == 0 {
					continue
				}
				current, err := b.Object(t)
				if err != nil {
					return err
				}
				frame := current.Frame
				frame.X += d[0]
				frame.Y += d[1]
				var props map[string]any
				if current.Type == model.Arrow {
					if spec, ok := route.ParseArrow(current.Props); ok {
						props = spec.Translated(d[0], d[1]).Props()
					}
				}
				if _, err := b.Update(t, nil, &frame, nil, props, caller, ""); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
		for _, m := range moves {
			if _, done := result[m.id]; done {
				continue
			}
			o, err := b.Object(m.id)
			if err != nil {
				return err
			}
			result[m.id] = o.Frame
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

// FramesJSON encodes {id: frame} as the API returns it.
func FramesJSON(frames map[string]model.Frame) map[string]any {
	out := make(map[string]any, len(frames))
	for id, f := range frames {
		out[id] = f.JSON()
	}
	return out
}
