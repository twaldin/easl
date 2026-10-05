package route

import (
	"math"
	"sort"

	"github.com/twaldin/easl/easld/internal/model"
)

// The part of DiagramGraph / DiagramLayout (Sources/CanvasCore/Diagram) an arrow bound to a
// diagram node needs: the node's box as the tile draws it.

type diagramNode struct {
	id       string
	level    int
	excerpts int
}

type diagramGraph struct {
	nodes []diagramNode
	edges [][2]string
}

// parseDiagramGraph is DiagramGraph.init?(props.graph): the Codable decode, so a graph with any
// required field missing or of the wrong type is no graph.
func parseDiagramGraph(v any) (diagramGraph, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return diagramGraph{}, false
	}
	aim, ok := m["aim"].(map[string]any)
	if !ok || aim["kind"] != "calls" || !optString(aim["path"]) || !optString(aim["symbol"]) || !optInt(aim["line"]) {
		return diagramGraph{}, false
	}
	switch aim["direction"] {
	case "incoming", "outgoing", "both":
	default:
		return diagramGraph{}, false
	}
	if !optString(m["root"]) || !optString(m["error"]) || !optInt(m["omitted"]) {
		return diagramGraph{}, false
	}
	if _, ok := m["computedAt"].(string); !ok {
		return diagramGraph{}, false
	}
	nodes, ok1 := m["nodes"].([]any)
	edges, ok2 := m["edges"].([]any)
	if !ok1 || !ok2 {
		return diagramGraph{}, false
	}
	var g diagramGraph
	for _, item := range nodes {
		n, ok := item.(map[string]any)
		if !ok {
			return diagramGraph{}, false
		}
		id, ok1 := n["id"].(string)
		_, ok2 := n["name"].(string)
		_, ok3 := n["kind"].(string)
		_, ok4 := n["path"].(string)
		_, ok5 := model.Int(n["line"])
		level, ok6 := model.Int(n["level"])
		_, ok7 := model.LineRangeFromJSON(n["lines"])
		excerpt, ok8 := n["excerpt"].([]any)
		if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && ok8) || !optString(n["container"]) ||
			!optBool(n["stale"]) || !optBool(n["expandable"]) || !optBool(n["expanded"]) {
			return diagramGraph{}, false
		}
		for _, line := range excerpt {
			l, ok := line.(map[string]any)
			if !ok {
				return diagramGraph{}, false
			}
			_, okLine := model.Int(l["line"])
			_, okText := l["text"].(string)
			if !okLine || !okText {
				return diagramGraph{}, false
			}
		}
		g.nodes = append(g.nodes, diagramNode{id: id, level: level, excerpts: len(excerpt)})
	}
	for _, item := range edges {
		e, ok := item.(map[string]any)
		if !ok {
			return diagramGraph{}, false
		}
		from, ok1 := e["from"].(string)
		to, ok2 := e["to"].(string)
		lines, ok3 := e["lines"].([]any)
		if !(ok1 && ok2 && ok3) || !optBool(e["stale"]) {
			return diagramGraph{}, false
		}
		for _, l := range lines {
			if _, ok := model.Int(l); !ok {
				return diagramGraph{}, false
			}
		}
		g.edges = append(g.edges, [2]string{from, to})
	}
	return g, true
}

func optString(v any) bool {
	if v == nil {
		return true
	}
	_, ok := v.(string)
	return ok
}

func optBool(v any) bool {
	if v == nil {
		return true
	}
	_, ok := v.(bool)
	return ok
}

func optInt(v any) bool {
	if v == nil {
		return true
	}
	_, ok := model.Int(v)
	return ok
}

const (
	diagramNodeWidth         = 300.0
	diagramColumnGap         = 76.0
	diagramRowGap            = 14.0
	diagramMargin            = 36.0
	diagramHeaderHeight      = 28.0
	diagramPadding           = 8.0
	diagramNameHeight        = 18.0
	diagramPlaceHeight       = 16.0
	diagramExcerptLineHeight = 16.0
	diagramEmptyHeight       = 160.0
	diagramEmptyWidth        = 520.0
)

func diagramNodeHeight(n diagramNode) float64 {
	h := 2*diagramPadding + diagramNameHeight + diagramPlaceHeight + float64(n.excerpts)*diagramExcerptLineHeight
	if n.excerpts > 0 {
		h += 4
	}
	return h
}

// diagramLayout is DiagramLayout.init: each node's box in graph coordinates and the extent.
func diagramLayout(g diagramGraph) (map[string]Rect, Size) {
	rects := map[string]Rect{}
	levelSet := map[int]bool{}
	for _, n := range g.nodes {
		levelSet[n.level] = true
	}
	if len(levelSet) == 0 {
		return rects, Size{diagramEmptyWidth, diagramEmptyHeight - diagramHeaderHeight}
	}
	levels := make([]int, 0, len(levelSet))
	for l := range levelSet {
		levels = append(levels, l)
	}
	sort.Ints(levels)
	neighbours := map[string][]string{}
	for _, e := range g.edges {
		neighbours[e[0]] = append(neighbours[e[0]], e[1])
		neighbours[e[1]] = append(neighbours[e[1]], e[0])
	}
	levelOf := map[string]int{}
	for _, n := range g.nodes {
		if _, seen := levelOf[n.id]; !seen {
			levelOf[n.id] = n.level
		}
	}
	columns := map[int][]diagramNode{}
	for _, n := range g.nodes {
		columns[n.level] = append(columns[n.level], n)
	}
	// Outward from the root: a column sorts by the mean position of its neighbours in the column
	// nearer the root, already placed.
	position := map[string]float64{}
	outward := append([]int(nil), levels...)
	sort.SliceStable(outward, func(i, j int) bool {
		a, b := outward[i], outward[j]
		return abs(a) < abs(b) || (abs(a) == abs(b) && a < b)
	})
	for _, level := range outward {
		inward := 0
		if level > 0 {
			inward = level - 1
		} else if level < 0 {
			inward = level + 1
		}
		nodes := columns[level]
		key := func(n diagramNode) float64 {
			sum, count := 0.0, 0
			for _, id := range neighbours[n.id] {
				if l, ok := levelOf[id]; !ok || l != inward {
					continue
				}
				if p, ok := position[id]; ok {
					sum += p
					count++
				}
			}
			if count == 0 {
				return math.MaxFloat64
			}
			return sum / float64(count)
		}
		keys := make([]float64, len(nodes))
		order := make([]int, len(nodes))
		for i, n := range nodes {
			keys[i], order[i] = key(n), i
		}
		sort.SliceStable(order, func(i, j int) bool {
			ka, kb := keys[order[i]], keys[order[j]]
			if ka != kb {
				return ka < kb
			}
			return order[i] < order[j]
		})
		sorted := make([]diagramNode, len(nodes))
		for i, k := range order {
			sorted[i] = nodes[k]
		}
		columns[level] = sorted
		for i, n := range sorted {
			position[n.id] = float64(i)
		}
	}
	heights := map[int]float64{}
	tallest := 0.0
	for i, level := range levels {
		h := 0.0
		for _, n := range columns[level] {
			h += diagramNodeHeight(n)
		}
		h += float64(max(0, len(columns[level])-1)) * diagramRowGap
		heights[level] = h
		if i == 0 || h > tallest {
			tallest = h
		}
	}
	for column, level := range levels {
		x := diagramMargin + float64(float64(column)*(diagramNodeWidth+diagramColumnGap))
		y := diagramMargin + (tallest-heights[level])/2
		for _, n := range columns[level] {
			h := diagramNodeHeight(n)
			rects[n.id] = Rect{x, y, diagramNodeWidth, h}
			y += h + diagramRowGap
		}
	}
	size := Size{
		2*diagramMargin + float64(len(levels))*diagramNodeWidth + float64(len(levels)-1)*diagramColumnGap,
		2*diagramMargin + tallest,
	}
	return rects, size
}

// diagramCanvasRect is DiagramLayout.canvasRect(of:frame:props:): where a diagram tile draws
// node `id`, in canvas coordinates; false without a graph or that node.
func diagramCanvasRect(id string, frame model.Frame, props map[string]any) (Rect, bool) {
	r, ok := diagramBodyRect(id, frame, props)
	if !ok {
		return Rect{}, false
	}
	// ObjectZoom.canvasRect(_:inBodyOf:zoom:).
	zoom := zoomOf(props)
	return Rect{frame.X + float64(zoom*r.MinX()), frame.Y + TileTitleHeight + float64(zoom*r.MinY()), zoom * r.Width(), zoom * r.Height()}, true
}

// diagramRectIn is DiagramLayout.rect(of:in:): node `id`'s box in body points, as a tile whose
// body is `body` draws it: the graph scaled down (never up) to fit below the header, centred.
func diagramRectIn(g diagramGraph, id string, body Size) (Rect, bool) {
	rects, size := diagramLayout(g)
	rect, ok := rects[id]
	if !ok {
		return Rect{}, false
	}
	room := Size{body.W, swiftMax(1, body.H-diagramHeaderHeight)}
	scale := swiftMin(1, room.W/swiftMax(size.W, 1), room.H/swiftMax(size.H, 1))
	origin := Point{(room.W - float64(size.W*scale)) / 2, diagramHeaderHeight + (room.H-float64(size.H*scale))/2}
	return Rect{origin.X + float64(rect.MinX()*scale), origin.Y + float64(rect.MinY()*scale), rect.Width() * scale, rect.Height() * scale}, true
}
