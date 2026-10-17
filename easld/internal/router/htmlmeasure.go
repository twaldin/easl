package router

import (
	"math"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
)

// fitGuard is the board identity and the objects a fit or a batch plan read,
// checked again after an html measure releases the registry lock. An unrelated
// object, one the plan did not read, may change: create placement and key
// holders are rechecked when the write is applied. A whole-board revision
// check would conflict every fit on a busy agent board. Layout targets are
// not noted; apply re-reads them.
type fitGuard struct {
	boards  []*board.Board
	objects map[string]int
	homes   map[string]*board.Board
}

func newFitGuard(boards ...*board.Board) *fitGuard {
	g := &fitGuard{objects: map[string]int{}, homes: map[string]*board.Board{}}
	for _, b := range boards {
		g.keep(b)
	}
	return g
}

func (g *fitGuard) keep(b *board.Board) {
	if g == nil || b == nil {
		return
	}
	for _, have := range g.boards {
		if have == b {
			return
		}
	}
	g.boards = append(g.boards, b)
}

// note records id's rev on b the first time the plan reads that object. A "$n"
// ref, and an id that is not on b, is not an object yet.
func (g *fitGuard) note(b *board.Board, id string) {
	if g == nil || b == nil || id == "" {
		return
	}
	if _, isRef := reference(id); isRef {
		return
	}
	g.keep(b)
	if _, ok := g.objects[id]; ok {
		return
	}
	o, ok := b.Objects()[id]
	if !ok {
		return
	}
	g.objects[id] = o.Rev
	g.homes[id] = b
}

func (r *Router) checkFit(g *fitGuard) error {
	if g == nil {
		return nil
	}
	for _, b := range g.boards {
		current, ok := r.reg.Board(b.ID())
		if !ok || current != b {
			return fail(api.CodeConflict, "board %s changed identity while its html page was measured: retry", b.ID())
		}
	}
	for id, rev := range g.objects {
		o, ok := g.homes[id].Objects()[id]
		if !ok {
			return fail(api.CodeConflict, "object %s is gone while its html page was measured: retry", id)
		}
		if o.Rev != rev {
			return fail(api.CodeConflict, "object %s changed while its html page was measured (rev %d, now %d): retry", id, rev, o.Rev)
		}
	}
	return nil
}

// measuredSize is object.measure and size "fit". HTML goes to the client that
// serves object.measure for the board; everything else uses measure.Size.
// guard nil is a read-only measure: the requested props are the size, even if
// the board changes while the client works.
func (r *Router) measuredSize(typ model.ObjectType, props map[string]any, width *float64, b *board.Board, caller string, guard *fitGuard) (float64, float64, bool, error) {
	if typ == model.HTML {
		return r.measureHTML(props, width, b, caller, guard)
	}
	return measure.Size(typ, props, width, pathRoot(b, typ, props), r.clients)
}

func (r *Router) measureHTML(props map[string]any, width *float64, b *board.Board, caller string, guard *fitGuard) (float64, float64, bool, error) {
	if guard != nil {
		guard.keep(b)
	}
	c := r.clients.Choose("object.measure", b.ID())
	if c == nil {
		return 0, 0, false, &measure.Failure{Code: api.CodeUnavailable, Message: "an html page is measured by the app"}
	}
	params := map[string]any{
		"board": b.ID(),
		"type":  string(model.HTML),
		"props": htmlMeasureProps(props, pathRoot(b, model.HTML, props)),
	}
	if width != nil {
		params["width"] = *width
	}
	if caller != "" {
		params["caller"] = caller
	}
	result, err := r.await(c, "object.measure", params, clients.HTMLMeasureDeadline)
	if err != nil {
		return 0, 0, false, err
	}
	if err := r.checkFit(guard); err != nil {
		return 0, 0, false, err
	}
	w, wok := positiveFinite(result["w"])
	h, hok := positiveFinite(result["h"])
	if !wok || !hok {
		return 0, 0, false, fail(api.CodeInternal, "%s answered object.measure with w=%v h=%v, not a positive finite size", c.Name(), result["w"], result["h"])
	}
	return w, h, result["approximate"] == true, nil
}

func htmlMeasureProps(props map[string]any, root string) map[string]any {
	out := map[string]any{}
	if props != nil {
		out = copyParams(props)
	}
	out["root"] = root
	return out
}

func positiveFinite(v any) (float64, bool) {
	n, ok := v.(float64)
	if !ok || math.IsNaN(n) || math.IsInf(n, 0) || n <= 0 {
		return 0, false
	}
	return n, true
}
