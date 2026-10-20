package mention

import (
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestDrawingMentionsIgnoreArchivedQuestionGeometry(t *testing.T) {
	b := newBoard(t)
	box := b.create(model.Shape, map[string]any{"kind": "rect"}, frame(0, 0, 400, 400))
	q := b.create(model.Question, map[string]any{"question": "Answer", "status": "answered", "archived": false}, frame(100, 100, 100, 100))
	mark := b.create(model.Shape, map[string]any{"kind": "rect"}, frame(120, 120, 20, 20))
	b.create(model.Arrow, map[string]any{"from": map[string]any{"object": q.ID}, "to": map[string]any{"point": []any{10.0, 10.0}}}, model.Frame{})
	for _, object := range []model.Object{box, mark} {
		b.stage(t, map[string]any{"kind": "object", "object": object.ID})
		contains(t, b.drain(), q.ID)
	}
	b.update(q.ID, map[string]any{"archived": true}, nil)
	for _, object := range []model.Object{box, mark} {
		b.stage(t, map[string]any{"kind": "object", "object": object.ID})
		lacks(t, b.drain(), q.ID)
	}
}
