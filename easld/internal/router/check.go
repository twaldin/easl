package router

import (
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/check"
	"github.com/twaldin/easl/easld/internal/model"
)

// check is layout.check: the board (by `ids` or `board`) and the scope are the router's; the
// problems are the check package's (BoardGeometry.layoutCheck and ApiRouter.check's fit checks).
// Arrow label sizes, notes, text shapes and captions are measured through the clients (a Mac
// client's AppKit, else the glyph table); HTML pages need the app's WebKit and aren't fit-checked.
func (r *Router) check(p map[string]any) (any, error) {
	var b *board.Board
	var ids []string
	var rect *model.Frame
	if _, present := p["ids"].([]any); present {
		ids = strings_(p["ids"])
		if len(ids) == 0 {
			return nil, invalid("ids must not be empty")
		}
		var err error
		if b, err = r.boardForObject(ids[0]); err != nil {
			return nil, err
		}
		for _, id := range ids {
			if _, ok := b.Objects()[id]; !ok {
				return nil, board.NotFound("object %s on this board", id)
			}
		}
	} else {
		var err error
		if b, err = r.boardOf(p); err != nil {
			return nil, err
		}
		if v, present := p["rect"]; present {
			m := asMap(v)
			f, ok := decodeFrame(m)
			if !ok {
				return nil, invalid("%s", frameDecodeError(m))
			}
			rect = &f
		}
	}
	labels, approximate := b.LabelSizes()
	env := check.Env{
		Root: b.Root(), LabelSizes: labels, LabelApproximate: approximate, Settled: b.Settled(), Texts: r.clients,
		NoteRoot: func(o model.Object) string { return pathRoot(b, o.Type, o.Props) },
	}
	return check.Check(b.Objects(), env, ids, rect), nil
}
