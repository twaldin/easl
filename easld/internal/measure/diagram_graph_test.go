package measure

import (
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

// A caller-supplied graph measures by reasoning depth: one column per level, a node with detail
// as tall as its label and the two rows the tile shows before a click.
func TestACallerGraphMeasuresItsLevelsAndDetailRows(t *testing.T) {
	graph := map[string]any{
		"aim": map[string]any{"kind": "graph", "direction": "incoming"},
		"nodes": []any{
			map[string]any{"id": "cold", "name": "Tests fail on a cold start", "level": 0.0, "detail": "The first read returns an empty cache."},
			map[string]any{"id": "stale", "name": "The cache keeps a stale stamp", "level": 1.0},
			map[string]any{"id": "fix", "name": "Write the stamp after the read", "level": 1.0},
		},
		"edges": []any{
			map[string]any{"from": "cold", "to": "stale", "lines": []any{}, "label": "observed by"},
			map[string]any{"from": "cold", "to": "fix", "lines": []any{}, "label": "fixed by"},
		},
		"computedAt": "2026-10-24T00:00:00Z",
	}
	w, h, err := size(t, model.Diagram, map[string]any{"kind": "graph", "knowledge": graph}, nil, "")
	// Two columns (748 wide); the deeper column (two 50-point nodes, 14 apart) is the taller,
	// 108 tall against the detail node's 70. The frame adds the 34-point title bar and the
	// 28-point status strip.
	if err != nil || w != 2*36+2*300+76 || h != 34+28+2*36+50+14+50 {
		t.Errorf("graph diagram: %v×%v %v", w, h, err)
	}

	// A graph whose node fields are a graph node's, not a symbol's, decodes.
	if _, ok := DecodeDiagramGraph(graph); !ok {
		t.Error("a caller graph doesn't decode")
	}
	// A graph node with a non-text detail does not.
	broken := map[string]any{"aim": graph["aim"], "edges": []any{}, "computedAt": "x",
		"nodes": []any{map[string]any{"id": "a", "name": "A", "level": 0.0, "detail": 7.0}}}
	if _, ok := DecodeDiagramGraph(broken); ok {
		t.Error("a numeric detail decodes as text")
	}
}
