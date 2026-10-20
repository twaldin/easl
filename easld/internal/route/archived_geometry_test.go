package route

import (
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestArchivedQuestionDoesNotDeflectCanvasOrDrawnRoutes(t *testing.T) {
	var b board
	q := b.tile(250, 0, 100, 100)
	q.Type, q.Props = model.Question, map[string]any{"archived": false}
	arrow := b.line(Point{0, 50}, Point{600, 50})
	arrow.Props["route"] = "avoid"
	for name, routing := range map[string]func(Geometry) *Result{
		"canvas": func(g Geometry) *Result { return g.Routing(nil) },
		"drawn":  func(g Geometry) *Result { return g.DrawnRouting(nil) },
	} {
		t.Run(name, func(t *testing.T) {
			q := q.Clone()
			g := Geometry{Objects: map[string]model.Object{q.ID: q, arrow.ID: arrow}}
			visible := routing(g)
			if path := visible.Paths[arrow.ID]; len(path) < 2 || PathCrosses(path, RectOf(q.Frame)) {
				t.Fatalf("visible question was not avoided: %v", path)
			}
			q.Props["archived"] = true
			g.Objects[q.ID], g.Settled = q, visible
			path := routing(g).Paths[arrow.ID]
			if len(path) < 2 || !PathCrosses(path, RectOf(q.Frame)) {
				t.Fatalf("archived question still deflects route: %v", path)
			}
			for _, p := range path {
				if p.Y != 50 {
					t.Fatalf("archived question left a detour: %v", path)
				}
			}
		})
	}
}

func TestArchivedQuestionIsNotAnArrowCrossing(t *testing.T) {
	var b board
	q := b.tile(250, 0, 100, 100)
	q.Type, q.Props = model.Question, map[string]any{}
	arrow := b.line(Point{0, 50}, Point{600, 50})
	g := Geometry{Objects: map[string]model.Object{q.ID: q, arrow.ID: arrow}}
	if got := g.LayoutCheck(nil, nil).Crossings; len(got) != 1 || len(got[0].Crosses) != 1 || got[0].Crosses[0] != q.ID {
		t.Fatalf("visible crossing = %v", got)
	}
	q.Props["archived"] = true
	g.Objects[q.ID] = q
	if got := g.LayoutCheck(nil, nil).Crossings; len(got) != 0 {
		t.Fatalf("archived question crossing = %v", got)
	}
}

func TestArrowsBoundToArchivedQuestionsHaveNoRoutesOrLabels(t *testing.T) {
	for name, routing := range map[string]func(Geometry) *Result{
		"canvas": func(g Geometry) *Result { return g.Routing(nil) },
		"drawn":  func(g Geometry) *Result { return g.DrawnRouting(nil) },
	} {
		t.Run(name, func(t *testing.T) {
			var b board
			q, target := b.tile(0, 0), b.tile(500, 0)
			q.Type, q.Props = model.Question, map[string]any{}
			arrow := b.arrow(q, target, "answer", "avoid")
			g := Geometry{Objects: map[string]model.Object{q.ID: q, target.ID: target, arrow.ID: arrow}, LabelSizes: map[string]Size{arrow.ID: {60, 16}}}
			visible := routing(g)
			if len(visible.Paths[arrow.ID]) < 2 {
				t.Fatal("visible question arrow has no route")
			}
			if _, ok := visible.Labels[arrow.ID]; !ok {
				t.Fatal("visible question arrow has no label")
			}
			q.Props["archived"] = true
			g.Objects[q.ID], g.Settled = q, visible
			hidden := routing(g)
			if len(hidden.Paths) != 0 || len(hidden.Labels) != 0 {
				t.Fatalf("arrow to archived question remains drawn: paths %v labels %v", hidden.Paths, hidden.Labels)
			}
			delete(q.Props, "archived")
			g.Objects[q.ID], g.Settled = q, hidden
			if restored := routing(g); len(restored.Paths[arrow.ID]) < 2 || len(restored.Labels) != 1 {
				t.Fatalf("unarchived question arrow did not return: %v", restored)
			}
		})
	}
}
