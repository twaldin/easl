package measure

import (
	"math"
	"sort"
)

// DiagramNode is the part of a DiagramNode the layout and titles read.
type DiagramNode struct {
	ID, Name  string
	Container *string
	Level     int
	Excerpts  int
}

// QualifiedName is `Container.name`.
func (n DiagramNode) QualifiedName() string {
	if n.Container != nil {
		return *n.Container + "." + n.Name
	}
	return n.Name
}

// DiagramGraph is a diagram's `props.graph` as last computed (DiagramGraph.swift).
type DiagramGraph struct {
	Root  *string
	Nodes []DiagramNode
	Edges [][2]string
}

// Node is the node with id.
func (g DiagramGraph) Node(id string) (DiagramNode, bool) {
	for _, n := range g.Nodes {
		if n.ID == id {
			return n, true
		}
	}
	return DiagramNode{}, false
}

// DecodeDiagramGraph is DiagramGraph(props["graph"]): ok false when absent or not a whole graph
// (it decodes as Codable would).
func DecodeDiagramGraph(v any) (DiagramGraph, bool) {
	if _, ok := v.(map[string]any); !ok {
		return DiagramGraph{}, false
	}
	g, err := decodeDiagramGraph(v)
	return g, err == nil
}

func decodeDiagramGraph(v any) (DiagramGraph, error) {
	var g DiagramGraph
	k, err := DecodeKeyed(v, nil)
	if err != nil {
		return g, err
	}
	aim, err := k.Nested("aim")
	if err != nil {
		return g, err
	}
	if _, err := aim.Enum("kind", "DiagramKind", "calls"); err != nil {
		return g, err
	}
	for _, key := range []string{"path", "symbol"} {
		if _, err := aim.StringIfPresent(key); err != nil {
			return g, err
		}
	}
	if _, err := aim.IntIfPresent("line"); err != nil {
		return g, err
	}
	if _, err := aim.Enum("direction", "CallDirection", "incoming", "outgoing", "both"); err != nil {
		return g, err
	}
	if g.Root, err = k.StringIfPresent("root"); err != nil {
		return g, err
	}
	nodes, err := k.required("nodes")
	if err != nil {
		return g, err
	}
	list, err := DecodeArray(nodes, k.Path.key("nodes"))
	if err != nil {
		return g, err
	}
	for i, item := range list {
		n, err := DecodeKeyed(item, k.Path.key("nodes").index(i))
		if err != nil {
			return g, err
		}
		var node DiagramNode
		if node.ID, err = n.String("id"); err != nil {
			return g, err
		}
		if node.Name, err = n.String("name"); err != nil {
			return g, err
		}
		if node.Container, err = n.StringIfPresent("container"); err != nil {
			return g, err
		}
		if _, err = n.String("kind"); err != nil {
			return g, err
		}
		if _, err = n.String("path"); err != nil {
			return g, err
		}
		if _, err = n.Int("line"); err != nil {
			return g, err
		}
		if _, _, err = n.LineRange("lines"); err != nil {
			return g, err
		}
		raw, err := n.required("excerpt")
		if err != nil {
			return g, err
		}
		excerpts, err := DecodeArray(raw, n.Path.key("excerpt"))
		if err != nil {
			return g, err
		}
		for j, e := range excerpts {
			line, err := DecodeKeyed(e, n.Path.key("excerpt").index(j))
			if err != nil {
				return g, err
			}
			if _, err := line.Int("line"); err != nil {
				return g, err
			}
			if _, err := line.String("text"); err != nil {
				return g, err
			}
		}
		node.Excerpts = len(excerpts)
		if node.Level, err = n.Int("level"); err != nil {
			return g, err
		}
		for _, key := range []string{"stale", "expandable", "expanded"} {
			if _, err := n.BoolIfPresent(key); err != nil {
				return g, err
			}
		}
		g.Nodes = append(g.Nodes, node)
	}
	edges, err := k.required("edges")
	if err != nil {
		return g, err
	}
	elist, err := DecodeArray(edges, k.Path.key("edges"))
	if err != nil {
		return g, err
	}
	for i, item := range elist {
		e, err := DecodeKeyed(item, k.Path.key("edges").index(i))
		if err != nil {
			return g, err
		}
		from, err := e.String("from")
		if err != nil {
			return g, err
		}
		to, err := e.String("to")
		if err != nil {
			return g, err
		}
		raw, err := e.required("lines")
		if err != nil {
			return g, err
		}
		lines, err := DecodeArray(raw, e.Path.key("lines"))
		if err != nil {
			return g, err
		}
		for j, l := range lines {
			if _, err := DecodeInt(l, e.Path.key("lines").index(j)); err != nil {
				return g, err
			}
		}
		if _, err := e.BoolIfPresent("stale"); err != nil {
			return g, err
		}
		g.Edges = append(g.Edges, [2]string{from, to})
	}
	if _, err := k.StringIfPresent("error"); err != nil {
		return g, err
	}
	if _, err := k.IntIfPresent("omitted"); err != nil {
		return g, err
	}
	if _, err := k.String("computedAt"); err != nil {
		return g, err
	}
	return g, nil
}

// DiagramLayout constants (DiagramLayout.swift).
const (
	diagramNodeWidth   = 300.0
	diagramColumnGap   = 76.0
	diagramRowGap      = 14.0
	diagramMargin      = 36.0
	diagramHeader      = 28.0
	diagramPadding     = 8.0
	diagramNameHeight  = 18.0
	diagramPlaceHeight = 16.0
	diagramExcerptLine = 16.0
	diagramEmptyW      = 520.0
	diagramEmptyH      = 160.0
)

func diagramNodeHeight(n DiagramNode) float64 {
	h := 2*diagramPadding + diagramNameHeight + diagramPlaceHeight + float64(n.Excerpts)*diagramExcerptLine
	if n.Excerpts > 0 {
		h += 4
	}
	return h
}

// BodySize is DiagramLayout(graph).bodySize: the body a tile needs to show the whole graph.
func (g DiagramGraph) BodySize() (w, h float64) {
	levels := map[int]bool{}
	heights := map[int]float64{}
	counts := map[int]int{}
	for _, n := range g.Nodes {
		levels[n.Level] = true
		heights[n.Level] += diagramNodeHeight(n)
		counts[n.Level]++
	}
	var width, height float64
	if len(levels) == 0 {
		width, height = diagramEmptyW, diagramEmptyH-diagramHeader
	} else {
		tallest := 0.0
		keys := make([]int, 0, len(levels))
		for level := range levels {
			keys = append(keys, level)
			tallest = math.Max(tallest, heights[level]+float64(max(0, counts[level]-1))*diagramRowGap)
		}
		sort.Ints(keys)
		width = 2*diagramMargin + float64(len(keys))*diagramNodeWidth + float64(len(keys)-1)*diagramColumnGap
		height = 2*diagramMargin + tallest
	}
	return math.Max(width, diagramEmptyW), diagramHeader + height
}
