package router

import (
	"context"
	"slices"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
	"github.com/twaldin/easl/easld/internal/model"
)

const (
	languageServerRequestTimeout = 60 * time.Second
	callGraphLoadingWait         = 45 * time.Second
	callGraphLoadingRetry        = 1500 * time.Millisecond
	callGraphMaxSymbolProjects   = 3
	callGraphMaxMentioningFiles  = 40
	callGraphMaxNodes            = 60
)

const (
	diagramPassesPerNode   = 6
	diagramSetupPhases     = 4
	diagramLoadingPauses   = 2
	diagramLoadingAttempts = 1 + int(callGraphLoadingWait/callGraphLoadingRetry)
	diagramRequests        = diagramLoadingAttempts*(callGraphMaxSymbolProjects+1) + diagramPassesPerNode*callGraphMaxNodes + callGraphMaxMentioningFiles + diagramSetupPhases
	diagramComputeDeadline = time.Duration(diagramRequests)*languageServerRequestTimeout + diagramLoadingPauses*callGraphLoadingWait
)

type diagramAim struct {
	kind, path, symbol, direction string
	line                          int
}

type diagramSpec struct {
	aim      diagramAim
	depth    int
	expanded []string
}

func diagramSpecOf(props map[string]any) diagramSpec {
	spec := diagramSpec{aim: diagramAim{kind: "calls", direction: "incoming"}, depth: 2}
	spec.aim.path, _ = props["path"].(string)
	spec.aim.symbol, _ = props["symbol"].(string)
	if line, ok := board.TruncInt(props["line"]); ok && line >= 1 {
		spec.aim.line = line
	}
	if direction, _ := props["direction"].(string); direction == "incoming" || direction == "outgoing" || direction == "both" {
		spec.aim.direction = direction
	}
	if depth, ok := board.TruncInt(props["depth"]); ok {
		spec.depth = min(4, max(1, depth))
	}
	spec.expanded = strings_(props["expanded"])
	return spec
}

func (s diagramSpec) equal(other diagramSpec) bool {
	return s.aim == other.aim && s.depth == other.depth && slices.Equal(s.expanded, other.expanded)
}

type diagramJob struct {
	board      *board.Board
	id         string
	rev        int
	object     model.Object
	spec       diagramSpec
	client     *clients.Client
	ctx        context.Context
	cancel     context.CancelFunc
	done       chan struct{}
	finishedAt time.Time
	summary    map[string]any
	err        error
}

type diagramWait struct {
	requestID any
	job       *diagramJob
	until     time.Time
}

func (r *Router) reloadDiagram(requestID any, b *board.Board, object model.Object, timeout int) (any, error) {
	until := time.Now().Add(millis(timeout))
	spec := diagramSpecOf(object.Props)
	job := r.diagrams[object.ID]
	if job != nil && (job.board != b || job.rev != object.Rev || !job.spec.equal(spec)) {
		r.finishDiagram(job, board.Conflict("diagram %s changed while computing", object.ID))
		job = nil
	}
	if job == nil {
		client, err := r.client("object.reload", b.ID(), "object.reload computes the diagram through its language servers")
		if err != nil {
			return nil, err
		}
		ctx, cancel := context.WithCancel(context.Background())
		job = &diagramJob{board: b, id: object.ID, object: object.Clone(), rev: object.Rev, spec: spec, client: client, ctx: ctx, cancel: cancel, done: make(chan struct{})}
		r.diagrams[object.ID] = job
		go r.computeDiagram(job)
	}
	if timeout == 0 {
		return diagramSummary(object.ID, object.Props["graph"], false), nil
	}
	return diagramWait{requestID: requestID, job: job, until: until}, nil
}

func (r *Router) awaitDiagram(w diagramWait) map[string]any {
	timer := time.NewTimer(max(0, time.Until(w.until)))
	defer timer.Stop()
	select {
	case <-w.job.done:
	case <-timer.C:
	}
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	if !w.job.finishedAt.IsZero() && !w.job.finishedAt.After(w.until) {
		if w.job.err != nil {
			return errorReply(w.requestID, asFailure(w.job.err))
		}
		return okReply(w.requestID, w.job.summary)
	}
	return okReply(w.requestID, diagramSummary(w.job.id, w.job.board.Objects()[w.job.id].Props["graph"], false))
}

func (r *Router) computeDiagram(job *diagramJob) {
	result, failure := r.clients.Call(job.ctx, job.client, job.board.ID(), "object.reload", map[string]any{"id": job.id, "_diagram": job.object.APIJSON()}, diagramComputeDeadline)
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	if r.diagrams[job.id] != job {
		return
	}
	if failure != nil {
		r.finishDiagram(job, failure)
		return
	}
	select {
	case <-job.client.Done():
		r.finishDiagram(job, fail(api.CodeUnavailable, "%s disconnected before publishing object.reload", job.client.Name()))
		return
	default:
	}
	b, open := r.reg.Board(job.board.ID())
	object, live := job.board.Objects()[job.id]
	if !open || b != job.board || !live {
		r.finishDiagram(job, board.NotFound("no object %s", job.id))
		return
	}
	if object.Type != model.Diagram || object.Rev != job.rev || !job.spec.equal(diagramSpecOf(object.Props)) {
		r.finishDiagram(job, board.Conflict("diagram %s changed while computing", job.id))
		return
	}
	answer, ok := result.(map[string]any)
	rev, validRev := diagramInteger(answer["rev"])
	graph, validGraph := checkedDiagramGraph(answer["graph"])
	if !ok || answer["id"] != job.id || answer["loaded"] != true || !validRev || rev != job.rev || !validGraph {
		r.finishDiagram(job, fail(api.CodeInternal, "%s answered object.reload with an invalid diagram result", job.client.Name()))
		return
	}
	if graph.aim != job.spec.aim {
		r.finishDiagram(job, board.Conflict("diagram %s's computed graph has a different aim", job.id))
		return
	}
	if err := b.WriteBookkeeping(job.id, map[string]any{"graph": answer["graph"]}); err != nil {
		r.finishDiagram(job, err)
		return
	}
	job.summary = graph.summary(job.id, true)
	r.finishDiagram(job, nil)
}

func (r *Router) finishDiagram(job *diagramJob, err error) {
	if r.diagrams[job.id] != job {
		return
	}
	delete(r.diagrams, job.id)
	job.err = err
	job.finishedAt = time.Now()
	job.cancel()
	close(job.done)
}

func (r *Router) observeDiagrams(b *board.Board, event model.Event) {
	if event.Name != board.EventObjectUpdated && event.Name != board.EventObjectDeleted {
		return
	}
	id, _ := asMap(event.Data)["id"].(string)
	job := r.diagrams[id]
	if job == nil || job.board != b {
		return
	}
	object, live := b.Objects()[id]
	if !live {
		r.finishDiagram(job, board.NotFound("no object %s", id))
	} else if object.Type != model.Diagram || object.Rev != job.rev || !job.spec.equal(diagramSpecOf(object.Props)) {
		r.finishDiagram(job, board.Conflict("diagram %s changed while computing", id))
	}
}

type diagramGraph struct {
	aim   diagramAim
	nodes []any
	edges []any
	raw   map[string]any
}

func checkedDiagramGraph(value any) (diagramGraph, bool) {
	m, ok := value.(map[string]any)
	if !ok {
		return diagramGraph{}, false
	}
	aim := asMap(m["aim"])
	kind, kindOK := aim["kind"].(string)
	direction, directionOK := aim["direction"].(string)
	if !kindOK || kind != "calls" || !directionOK || (direction != "incoming" && direction != "outgoing" && direction != "both") {
		return diagramGraph{}, false
	}
	graph := diagramGraph{aim: diagramAim{kind: kind, direction: direction}, raw: m}
	for _, field := range []struct {
		key string
		out *string
	}{{"path", &graph.aim.path}, {"symbol", &graph.aim.symbol}} {
		if v := aim[field.key]; v != nil {
			s, valid := v.(string)
			if !valid || s == "" {
				return diagramGraph{}, false
			}
			*field.out = s
		}
	}
	if !diagramOptional(m, "string", "root", "error") {
		return diagramGraph{}, false
	}
	if v := aim["line"]; v != nil {
		line, valid := diagramInteger(v)
		if !valid || line < 1 {
			return diagramGraph{}, false
		}
		graph.aim.line = line
	}
	if _, valid := m["computedAt"].(string); !valid {
		return diagramGraph{}, false
	}
	if v := m["omitted"]; v != nil {
		if _, valid := diagramInteger(v); !valid {
			return diagramGraph{}, false
		}
	}
	graph.nodes, ok = m["nodes"].([]any)
	if !ok {
		return diagramGraph{}, false
	}
	for _, value := range graph.nodes {
		node, valid := value.(map[string]any)
		if !valid || !diagramStrings(node, "id", "name", "kind", "path") || !diagramIntegers(node, "line", "level") || !diagramIntegers(asMap(node["lines"]), "start", "end") || !diagramOptional(node, "string", "container") || !diagramOptional(node, "bool", "stale", "expandable", "expanded") {
			return diagramGraph{}, false
		}
		excerpt, valid := node["excerpt"].([]any)
		if !valid {
			return diagramGraph{}, false
		}
		for _, line := range excerpt {
			if !diagramIntegers(asMap(line), "line") || !diagramStrings(asMap(line), "text") {
				return diagramGraph{}, false
			}
		}
	}
	graph.edges, ok = m["edges"].([]any)
	if !ok {
		return diagramGraph{}, false
	}
	for _, value := range graph.edges {
		edge := asMap(value)
		if !diagramStrings(edge, "from", "to") || !diagramOptional(edge, "bool", "stale") {
			return diagramGraph{}, false
		}
		lines, valid := edge["lines"].([]any)
		if !valid {
			return diagramGraph{}, false
		}
		for _, line := range lines {
			if _, valid := diagramInteger(line); !valid {
				return diagramGraph{}, false
			}
		}
	}
	return graph, true
}

func diagramInteger(value any) (int, bool) {
	n, ok := board.TruncInt(value)
	return n, ok && value == float64(n)
}

func diagramIntegers(m map[string]any, keys ...string) bool {
	for _, key := range keys {
		if _, ok := diagramInteger(m[key]); !ok {
			return false
		}
	}
	return true
}

func diagramStrings(m map[string]any, keys ...string) bool {
	for _, key := range keys {
		if _, ok := m[key].(string); !ok {
			return false
		}
	}
	return true
}

func diagramOptional(m map[string]any, kind string, keys ...string) bool {
	for _, key := range keys {
		if v := m[key]; v != nil {
			switch kind {
			case "string":
				if _, ok := v.(string); !ok {
					return false
				}
			case "bool":
				if _, ok := v.(bool); !ok {
					return false
				}
			}
		}
	}
	return true
}

func diagramSummary(id string, value any, computed bool) map[string]any {
	graph, ok := checkedDiagramGraph(value)
	if !ok {
		return map[string]any{"id": id, "loaded": computed}
	}
	return graph.summary(id, computed)
}

func (graph diagramGraph) summary(id string, computed bool) map[string]any {
	result := map[string]any{"id": id, "loaded": computed}
	result["nodes"] = float64(len(graph.nodes))
	result["edges"] = float64(len(graph.edges))
	stale := make([]any, 0)
	for _, value := range graph.nodes {
		node := asMap(value)
		if node["stale"] == true {
			stale = append(stale, node["id"])
		}
	}
	result["stale"] = stale
	if root, ok := graph.raw["root"].(string); ok {
		result["root"] = root
	}
	if reason, ok := graph.raw["error"].(string); ok {
		result["error"] = reason
	}
	return result
}
