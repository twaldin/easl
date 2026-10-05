package board

import (
	"math"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/route"
)

const (
	// PlacementGap is the room kept between a placed object and its neighbours.
	PlacementGap = 24.0
	// AnswerStackWindow is how recent an agent's last object must be for its next one to stack
	// beside it.
	AnswerStackWindow = 10 * time.Minute
	// NearbyDistance is how far a slot beside a tile may be and still win for being in view.
	NearbyDistance = 600.0
)

// Size is a width and height.
type Size struct{ W, H float64 }

// FollowMinimumSize is the smallest a follow tile gets so that it lands wholly in view.
var FollowMinimumSize = Size{400, 300}

type side int

const (
	sideRight side = iota
	sideBelow
	sideLeft
	sideAbove
)

func (b *Board) viewport() *model.Frame {
	if b.Viewport == nil {
		return nil
	}
	return b.Viewport()
}

// Place is where a new object goes when nobody gave it a frame (Board.place(width:height:near:)):
// the free slot nearest the caller's tile, else nearest the viewport center; stacking (an
// agent's own create) stacks an agent's answers beside its latest one.
func (b *Board) Place(w, h float64, caller string, minimum *Size, stacking bool) model.Frame {
	anchor, ok := b.objects[caller]
	if caller == "" || !ok {
		view := model.Frame{}
		if v := b.viewport(); v != nil {
			view = *v
		}
		return b.PlaceIdeal(model.Frame{X: view.X + view.W/2 - w/2, Y: view.Y + view.H/2 - h/2, W: w, H: h})
	}
	order := []side{sideRight, sideBelow, sideLeft, sideAbove}
	beside, _ := b.freeSlot(w, h, anchor.Frame, true, minimum, order, nil, nil)
	if !stacking {
		return beside
	}
	previous, ok := b.latestAnswer(caller)
	if !ok {
		return beside
	}
	prev := previous.Frame
	stacked, _ := b.freeSlot(w, h, prev, true, minimum, []side{sideBelow, sideRight, sideLeft, sideAbove}, nil, nil)
	gap := PlacementGap
	below := math.Abs(stacked.Y-(prev.MaxY()+gap)) < 1 && stacked.X < prev.MaxX() && stacked.MaxX() > prev.X
	right := math.Abs(stacked.X-(prev.MaxX()+gap)) < 1 && stacked.Y < prev.MaxY() && stacked.MaxY() > prev.Y
	if (below || right) && b.inViewClass(stacked) <= b.inViewClass(beside) {
		return stacked
	}
	return beside
}

func (b *Board) latestAnswer(caller string) (model.Object, bool) {
	since := time.Now().Add(-AnswerStackWindow)
	var best model.Object
	found := false
	for _, o := range b.objects {
		if o.CreatedBy.Kind != "agent" || o.CreatedBy.Tile != caller || o.CreatedAt.Before(since) || !o.Type.IsTile() {
			continue
		}
		if _, follow := o.Props["followOf"]; follow {
			continue
		}
		if !found || o.CreatedAt.After(best.CreatedAt) || (o.CreatedAt.Equal(best.CreatedAt) && o.Z > best.Z) {
			best, found = o, true
		}
	}
	return best, found
}

func (b *Board) inViewClass(slot model.Frame) int {
	gap := PlacementGap
	view := b.viewport()
	if view == nil || view.W <= 2*gap || view.H <= 2*gap {
		return 0
	}
	screen := model.Frame{X: view.X + gap, Y: view.Y + gap, W: view.W - 2*gap, H: view.H - 2*gap}
	if screen.Contains(slot) {
		return 0
	}
	if screen.Intersects(slot) {
		return 1
	}
	return 2
}

// PlaceIdeal is the free slot nearest ideal (Board.place(_:)).
func (b *Board) PlaceIdeal(ideal model.Frame) model.Frame {
	f, _ := b.freeSlot(ideal.W, ideal.H, ideal, false, nil, []side{sideRight, sideBelow, sideLeft, sideAbove}, nil, nil)
	return f
}

// RefitFrame is where id goes when it grows to size in place (`size: "fit"` without a given
// origin): grown from a corner clear of what it didn't already cover, else the nearest free
// slot within its longer side, else grown from its top-left anyway.
func (b *Board) RefitFrame(id string, w, h float64) (model.Frame, error) {
	current, err := b.Object(id)
	if err != nil {
		return model.Frame{}, err
	}
	cur := current.Frame
	grown := model.Frame{X: cur.X, Y: cur.Y, W: w, H: h}
	containers := map[string]bool{}
	for gid, g := range b.objects {
		if g.Type == model.Group && contains(route.LeafMembers(gid, b.objects), id) {
			containers[gid] = true
		}
	}
	var neighbours []model.Frame
	for _, o := range b.objects {
		if o.ID != id && !containers[o.ID] && route.CountsForOverlaps(o) {
			neighbours = append(neighbours, o.Frame)
		}
	}
	if corner, ok := LayoutRefit(cur, w, h, neighbours); ok {
		return corner, nil
	}
	ignoring := map[string]bool{id: true}
	for k := range containers {
		ignoring[k] = true
	}
	within := math.Max(grown.W, grown.H)
	if nearby, ok := b.freeSlot(grown.W, grown.H, grown, false, nil, []side{sideRight, sideBelow, sideLeft, sideAbove}, ignoring, &within); ok {
		return nearby, nil
	}
	return model.Frame{X: math.Round(grown.X), Y: math.Round(grown.Y), W: grown.W, H: grown.H}, nil
}

// LayoutRefit is Layout.refit: current grown to size from its top-left, top-right, bottom-left
// or bottom-right corner, the first that overlaps none of neighbours current didn't overlap.
func LayoutRefit(current model.Frame, w, h float64, neighbours []model.Frame) (model.Frame, bool) {
	var fresh []model.Frame
	for _, n := range neighbours {
		if !n.Intersects(current) {
			fresh = append(fresh, n)
		}
	}
	left, right := current.X, current.MaxX()-w
	top, bottom := current.Y, current.MaxY()-h
	for _, c := range [][2]float64{{left, top}, {right, top}, {left, bottom}, {right, bottom}} {
		f := model.Frame{X: c[0], Y: c[1], W: w, H: h}
		clear := true
		for _, n := range fresh {
			if n.Intersects(f) {
				clear = false
				break
			}
		}
		if clear {
			return f, true
		}
	}
	return model.Frame{}, false
}

type slotCost [6]float64

func (c slotCost) less(o slotCost) bool {
	for i := range c {
		if c[i] != o[i] {
			return c[i] < o[i]
		}
	}
	return false
}

// freeSlot is Board.freeSlot: beside anchor (nearest by gap, then side in order) or replacing it
// (nearest by origin), clear of every object but shapes and arrows by PlacementGap.
func (b *Board) freeSlot(w, h float64, anchor model.Frame, beside bool, minimum *Size, order []side, ignoring map[string]bool, within *float64) (model.Frame, bool) {
	gap := PlacementGap
	var blocked []model.Frame
	for _, o := range b.objects {
		if o.Type == model.Arrow || o.Type == model.Shape || ignoring[o.ID] {
			continue
		}
		blocked = append(blocked, model.Frame{X: o.Frame.X - gap, Y: o.Frame.Y - gap, W: o.Frame.W + 2*gap, H: o.Frame.H + 2*gap})
	}
	var screen *model.Frame
	if view := b.viewport(); view != nil && view.Intersects(anchor) && view.W > 2*gap && view.H > 2*gap {
		screen = &model.Frame{X: view.X + gap, Y: view.Y + gap, W: view.W - 2*gap, H: view.H - 2*gap}
	}
	xs := map[float64]bool{math.Round(anchor.X): true, math.Round(anchor.MaxX() - w): true}
	ys := map[float64]bool{math.Round(anchor.Y): true, math.Round(anchor.MaxY() - h): true}
	for _, f := range blocked {
		xs[math.Ceil(f.MaxX())] = true
		xs[math.Floor(f.X-w)] = true
		ys[math.Ceil(f.MaxY())] = true
		ys[math.Floor(f.Y-h)] = true
	}
	if screen != nil {
		xs[math.Ceil(screen.X)] = true
		xs[math.Floor(screen.MaxX()-w)] = true
		ys[math.Ceil(screen.Y)] = true
		ys[math.Floor(screen.MaxY()-h)] = true
	}
	indexOf := func(s side) int {
		for i, x := range order {
			if x == s {
				return i
			}
		}
		return len(order)
	}
	cost := func(slot model.Frame, cut bool) slotCost {
		outside := 0.0
		if cut {
			outside = 1
		} else if screen != nil {
			switch {
			case screen.Contains(slot):
				outside = 0
			case !screen.Intersects(slot):
				outside = 4
			case slot.Y >= screen.Y && slot.Y < screen.MaxY():
				outside = 2
			default:
				outside = 3
			}
		}
		if !beside {
			return slotCost{outside, 0, 0, math.Hypot(slot.X-anchor.X, slot.Y-anchor.Y), slot.Y, slot.X}
		}
		dx := math.Max(0, math.Max(anchor.X-slot.MaxX(), slot.X-anchor.MaxX()))
		dy := math.Max(0, math.Max(anchor.Y-slot.MaxY(), slot.Y-anchor.MaxY()))
		distance := math.Round(math.Hypot(dx, dy))
		var s side
		var ix, iy float64
		switch {
		case slot.X >= anchor.MaxX():
			s, ix, iy = sideRight, anchor.MaxX()+gap, anchor.Y
		case slot.Y >= anchor.MaxY():
			s, ix, iy = sideBelow, anchor.X, anchor.MaxY()+gap
		case slot.MaxX() <= anchor.X:
			s, ix, iy = sideLeft, anchor.X-w-gap, anchor.Y
		default:
			s, ix, iy = sideAbove, anchor.X, anchor.Y-h-gap
		}
		if distance > NearbyDistance {
			outside = 5
		}
		return slotCost{outside, distance, float64(indexOf(s)), math.Hypot(slot.X-ix, slot.Y-iy), slot.Y, slot.X}
	}
	cutDown := func(slot model.Frame) (model.Frame, bool) {
		if minimum == nil || screen == nil || screen.Contains(slot) {
			return model.Frame{}, false
		}
		x, y := math.Max(slot.X, math.Ceil(screen.X)), math.Max(slot.Y, math.Ceil(screen.Y))
		c := model.Frame{X: x, Y: y, W: math.Min(slot.MaxX(), math.Floor(screen.MaxX())) - x, H: math.Min(slot.MaxY(), math.Floor(screen.MaxY())) - y}
		if c.W >= minimum.W && c.H >= minimum.H {
			return c, true
		}
		return model.Frame{}, false
	}
	var best model.Frame
	var bestCost slotCost
	found := false
	consider := func(slot model.Frame, cut bool) {
		if within != nil && math.Hypot(slot.X-anchor.X, slot.Y-anchor.Y) > *within {
			return
		}
		c := cost(slot, cut)
		if found && !c.less(bestCost) {
			return
		}
		for _, f := range blocked {
			if f.Intersects(slot) {
				return
			}
		}
		best, bestCost, found = slot, c, true
	}
	for x := range xs {
		for y := range ys {
			slot := model.Frame{X: x, Y: y, W: w, H: h}
			consider(slot, false)
			if smaller, ok := cutDown(slot); ok {
				consider(smaller, true)
			}
		}
	}
	return best, found
}
