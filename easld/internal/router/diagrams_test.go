package router

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/model"
)

type diagramPeer struct {
	*conn
	incoming chan map[string]any
}

func (p *diagramPeer) Send(value any) bool {
	if !p.IsOpen() {
		return false
	}
	p.incoming <- value.(map[string]any)
	return true
}

func diagramMessage(t *testing.T, incoming <-chan map[string]any) map[string]any {
	t.Helper()
	select {
	case message := <-incoming:
		return message
	case <-time.After(5 * time.Second):
		t.Fatal("no diagram message arrived")
		return nil
	}
}

func attachDiagramPeer(t *testing.T, f *fixture) *diagramPeer {
	t.Helper()
	peer := &diagramPeer{conn: &conn{}, incoming: make(chan map[string]any, 16)}
	t.Cleanup(peer.close)
	reply := f.router.HandleConn(map[string]any{"id": "attach", "method": "client.attach", "params": map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash,
		"serves": []any{"object.reload"}, "boards": []any{f.board.ID()},
	}}, peer).(map[string]any)
	if reply["ok"] != true {
		t.Fatalf("client.attach = %v", reply)
	}
	return peer
}

func diagramUpdates(t *testing.T, f *fixture) *diagramPeer {
	t.Helper()
	stream := &diagramPeer{conn: &conn{}, incoming: make(chan map[string]any, 16)}
	t.Cleanup(stream.close)
	f.router.HandleConn(map[string]any{"id": "subscribe", "method": "events.subscribe", "params": map[string]any{
		"board": f.board.ID(), "events": []any{"object.updated"},
	}}, stream)
	if reply := diagramMessage(t, stream.incoming); reply["ok"] != true {
		t.Fatalf("events.subscribe = %v", reply)
	}
	return stream
}

func createDiagram(f *fixture) string {
	return idOf(f.result("object.create", map[string]any{
		"type": "diagram", "props": map[string]any{"path": "main.go", "symbol": "run", "direction": "outgoing"},
		"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 760.0, "h": 480.0},
	}))
}

func diagramObject(f *fixture, id string) map[string]any {
	return f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
}

func diagramReload(f *fixture, id string, timeout float64) <-chan map[string]any {
	done := make(chan map[string]any, 1)
	go func() {
		done <- f.router.HandleConn(map[string]any{"id": "reload", "method": "object.reload", "params": map[string]any{
			"id": id, "timeoutMs": timeout,
		}}, &conn{}).(map[string]any)
	}()
	return done
}

func computedDiagram() map[string]any {
	return map[string]any{
		"aim":  map[string]any{"kind": "calls", "path": "main.go", "symbol": "run", "direction": "outgoing"},
		"root": "main.go#run", "computedAt": "2026-10-17T12:00:00Z",
		"nodes": []any{
			map[string]any{"id": "main.go#run", "name": "run", "kind": "function", "path": "main.go", "line": 3.0,
				"lines": map[string]any{"start": 3.0, "end": 5.0}, "excerpt": []any{map[string]any{"line": 3.0, "text": "func run() {"}}, "level": 0.0},
			map[string]any{"id": "main.go#work", "name": "work", "kind": "function", "path": "main.go", "line": 7.0,
				"lines": map[string]any{"start": 7.0, "end": 9.0}, "excerpt": []any{}, "level": 1.0, "stale": true},
		},
		"edges": []any{map[string]any{"from": "main.go#run", "to": "main.go#work", "lines": []any{4.0}}},
	}
}

func answerDiagram(f *fixture, peer *diagramPeer, request map[string]any, id string, rev any, graph any) {
	f.router.clients.Answer(peer, map[string]any{"id": request["id"], "ok": true, "result": map[string]any{
		"id": id, "loaded": true, "graph": graph, "rev": rev,
		"nodes": 999.0, "edges": 888.0, "root": "untrusted", "stale": []any{"untrusted"}, "extra": "internal",
	}})
}

func TestDiagramTimeoutZeroPublishesLateGraphAsAuthoritativeBookkeeping(t *testing.T) {
	f := newFixture(t)
	caller := f.namedTerminal("author", "")
	id := createDiagram(f)
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{"title": "Keep this title"}, "caller": caller})
	before := diagramObject(f, id)
	history := f.result("board.history", map[string]any{})
	peer := attachDiagramPeer(t, f)
	updates := diagramUpdates(t, f)

	reply := diagramMessage(t, diagramReload(f, id, 0))
	if want := map[string]any{"id": id, "loaded": false}; reply["ok"] != true || !reflect.DeepEqual(reply["result"], want) {
		t.Fatalf("timeout0 = %v, want %v", reply, want)
	}
	if got := diagramObject(f, id); !reflect.DeepEqual(got, before) {
		t.Fatalf("timeout0 changed the object before computation: %v", got)
	}
	request := diagramMessage(t, peer.incoming)
	graph := computedDiagram()
	answerDiagram(f, peer, request, id, before["rev"], graph)
	event := diagramMessage(t, updates.incoming)
	want := model.Clone(before).(map[string]any)
	want["props"].(map[string]any)["graph"] = graph
	if event["event"] != "object.updated" || !reflect.DeepEqual(event["data"], want) {
		t.Fatalf("authoritative event = %v, want object.updated %v", event, want)
	}
	if got := diagramObject(f, id); !reflect.DeepEqual(got, want) {
		t.Fatalf("late graph changed metadata/content or was not stored: %v, want %v", got, want)
	}
	if got := f.result("board.history", map[string]any{}); !reflect.DeepEqual(got, history) {
		t.Fatalf("bookkeeping entered activity history: %v, before %v", got, history)
	}
	f.router.reg.Flush()
	snapshot, err := f.router.reg.Store.Read(f.board.ID())
	if err != nil {
		t.Fatal(err)
	}
	if snapshot == nil {
		t.Fatal("authoritative board snapshot was not saved")
	}
	stored := false
	for _, object := range snapshot.Objects {
		if object.ID == id {
			stored = reflect.DeepEqual(object.Props["graph"], graph)
		}
	}
	if !stored {
		t.Fatalf("late graph was not saved authoritatively: %v", snapshot)
	}
}

func TestDiagramLateFailurePublishesAuthoritativeError(t *testing.T) {
	for _, timeout := range []float64{0, 1} {
		for _, previous := range []bool{false, true} {
			for _, failure := range []string{"error", "disconnect", "invalid result"} {
				t.Run(fmt.Sprintf("timeout%g/previous%t/%s", timeout, previous, failure), func(t *testing.T) {
					f := newFixture(t)
					id := createDiagram(f)
					peer := attachDiagramPeer(t, f)
					if previous {
						initial := diagramReload(f, id, 1000)
						answerDiagram(f, peer, diagramMessage(t, peer.incoming), id, diagramObject(f, id)["rev"], computedDiagram())
						if reply := diagramMessage(t, initial); reply["ok"] != true {
							t.Fatalf("initial diagram = %v", reply)
						}
					}
					before := diagramObject(f, id)
					history := f.result("board.history", map[string]any{})
					updates := diagramUpdates(t, f)
					waiting := diagramReload(f, id, timeout)
					request := diagramMessage(t, peer.incoming)
					if reply := diagramMessage(t, waiting); reply["ok"] != true || asMap(reply["result"])["loaded"] != false {
						t.Fatalf("reload did not return before host failure: %v", reply)
					}
					f.router.reg.Mu.Lock()
					job := f.router.diagrams[id]
					f.router.reg.Mu.Unlock()
					reason := "host transport failed"
					switch failure {
					case "error":
						f.router.clients.Answer(peer, map[string]any{"id": request["id"], "ok": false, "error": map[string]any{
							"code": "unavailable", "message": reason,
						}})
					case "disconnect":
						reason = job.client.Name() + " disconnected before answering object.reload"
						peer.close()
					case "invalid result":
						reason = job.client.Name() + " answered object.reload with an invalid diagram result"
						f.router.clients.Answer(peer, map[string]any{"id": request["id"], "ok": true, "result": map[string]any{}})
					}
					select {
					case <-job.done:
					case <-time.After(5 * time.Second):
						t.Fatal("host failure did not finish the diagram job")
					}
					after := diagramObject(f, id)
					graph, valid := checkedDiagramGraph(asMap(after["props"])["graph"])
					if !valid || graph.raw["error"] != reason || graph.aim != diagramSpecOf(asMap(before["props"])).aim {
						t.Fatalf("late %s after loaded:false left no authoritative error graph: %v, want error %q", failure, asMap(after["props"])["graph"], reason)
					}
					if _, err := time.Parse(time.RFC3339Nano, graph.raw["computedAt"].(string)); err != nil {
						t.Fatalf("failure graph has no completion timestamp: %v", graph.raw)
					}
					if previous {
						want := computedDiagram()
						want["error"] = reason
						want["computedAt"] = graph.raw["computedAt"]
						if !reflect.DeepEqual(graph.raw, want) {
							t.Fatalf("failure discarded the previous graph: %v, want %v", graph.raw, want)
						}
					} else if len(graph.nodes) != 0 || len(graph.edges) != 0 {
						t.Fatalf("first failed computation invented nodes or edges: %v", graph.raw)
					}
					want := model.Clone(before).(map[string]any)
					want["props"].(map[string]any)["graph"] = graph.raw
					if !reflect.DeepEqual(after, want) {
						t.Fatalf("failure changed content or metadata: %v, want %v", after, want)
					}
					if event := diagramMessage(t, updates.incoming); event["event"] != "object.updated" || !reflect.DeepEqual(event["data"], want) {
						t.Fatalf("failure was not published to viewers: %v", event)
					}
					if got := f.result("board.history", map[string]any{}); !reflect.DeepEqual(got, history) {
						t.Fatalf("failure bookkeeping entered activity history: %v", got)
					}
				})
			}
		}
	}
}

func TestDiagramFailureDoesNotReuseGraphOfPreviousAim(t *testing.T) {
	f := newFixture(t)
	id := createDiagram(f)
	peer := attachDiagramPeer(t, f)
	initial := diagramReload(f, id, 1000)
	answerDiagram(f, peer, diagramMessage(t, peer.incoming), id, diagramObject(f, id)["rev"], computedDiagram())
	if reply := diagramMessage(t, initial); reply["ok"] != true {
		t.Fatalf("initial graph = %v", reply)
	}
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{
		"path": "other.go", "symbol": nil, "line": 1.0, "direction": "incoming",
	}})
	updates := diagramUpdates(t, f)
	if reply := diagramMessage(t, diagramReload(f, id, 0)); asMap(reply["result"])["loaded"] != false {
		t.Fatalf("reload before failure = %v", reply)
	}
	request := diagramMessage(t, peer.incoming)
	f.router.clients.Answer(peer, map[string]any{"id": request["id"], "ok": false, "error": map[string]any{
		"code": "unavailable", "message": "host transport failed",
	}})
	event := diagramMessage(t, updates.incoming)
	graph := asMap(asMap(asMap(event["data"])["props"])["graph"])
	want := map[string]any{
		"aim":   map[string]any{"kind": "calls", "path": "other.go", "line": 1.0, "direction": "incoming"},
		"nodes": []any{}, "edges": []any{}, "error": "host transport failed", "computedAt": graph["computedAt"],
	}
	if event["event"] != "object.updated" || !reflect.DeepEqual(graph, want) {
		t.Fatalf("failure retained the previous aim's graph: %v, want %v", event, want)
	}
	if got := asMap(diagramObject(f, id)["props"])["graph"]; !reflect.DeepEqual(got, want) {
		t.Fatalf("failure graph was not stored authoritatively: %v", got)
	}
}

func TestDiagramReloadCoalescesViewersAndDerivesItsPublicSummary(t *testing.T) {
	f := newFixture(t)
	id := createDiagram(f)
	before := diagramObject(f, id)
	first := attachDiagramPeer(t, f)
	if got := f.result("object.reload", map[string]any{"id": id, "timeoutMs": 0.0}); !reflect.DeepEqual(got, map[string]any{"id": id, "loaded": false}) {
		t.Fatalf("first wait = %v", got)
	}
	request := diagramMessage(t, first.incoming)
	second := attachDiagramPeer(t, f)
	if got := f.result("object.reload", map[string]any{"id": id, "timeoutMs": 0.0}); !reflect.DeepEqual(got, map[string]any{"id": id, "loaded": false}) {
		t.Fatalf("second wait = %v", got)
	}
	updates := diagramUpdates(t, f)
	graph := computedDiagram()
	answerDiagram(f, first, request, id, before["rev"], graph)
	if event := diagramMessage(t, updates.incoming); event["event"] != "object.updated" {
		t.Fatalf("coalesced publication = %v", event)
	}
	if got := diagramObject(f, id)["props"].(map[string]any)["graph"]; !reflect.DeepEqual(got, graph) {
		t.Fatalf("coalesced graph was not stored: %v", got)
	}
	select {
	case extra := <-second.incoming:
		t.Fatalf("another viewer raced a graph writer: %v", extra)
	default:
	}
	select {
	case extra := <-first.incoming:
		t.Fatalf("same-revision reload computed twice: %v", extra)
	default:
	}
	waiting := diagramReload(f, id, 1000)
	answerDiagram(f, second, diagramMessage(t, second.incoming), id, before["rev"], graph)
	reply := diagramMessage(t, waiting)
	want := map[string]any{"id": id, "loaded": true, "nodes": 2.0, "edges": 1.0, "root": "main.go#run", "stale": []any{"main.go#work"}}
	if reply["ok"] != true || !reflect.DeepEqual(reply["result"], want) {
		t.Fatalf("public summary = %v, want %v", reply, want)
	}
	if got := diagramObject(f, id)["props"].(map[string]any)["graph"]; !reflect.DeepEqual(got, graph) {
		t.Fatalf("reload answered before authoritative storage: %v", got)
	}
}

func TestDiagramReloadWithoutAClientRemainsUnavailable(t *testing.T) {
	f := newFixture(t)
	id := createDiagram(f)
	before := diagramObject(f, id)
	for _, timeout := range []float64{0, 1000} {
		code, message := errorOf(f.call("object.reload", map[string]any{"id": id, "timeoutMs": timeout}))
		if code != "unavailable" || !strings.Contains(message, "object.reload computes the diagram through its language servers") {
			t.Fatalf("no-client reload = %s %q", code, message)
		}
	}
	if got := diagramObject(f, id); !reflect.DeepEqual(got, before) {
		t.Fatalf("no-client reload changed the object: %v", got)
	}
}

func TestDiagramReloadRejectsDeletedOrSupersededTargets(t *testing.T) {
	for _, change := range []string{"aim", "depth", "expanded", "revision", "deleted", "same-rev depth", "same-rev expanded"} {
		t.Run(change, func(t *testing.T) {
			f := newFixture(t)
			id := createDiagram(f)
			before := diagramObject(f, id)
			peer := attachDiagramPeer(t, f)
			waiting := diagramReload(f, id, 1000)
			request := diagramMessage(t, peer.incoming)
			code := "conflict"
			switch change {
			case "aim":
				f.result("object.update", map[string]any{"id": id, "props": map[string]any{"symbol": "other"}})
			case "depth":
				f.result("object.update", map[string]any{"id": id, "props": map[string]any{"depth": 3.0}})
			case "expanded":
				f.result("object.update", map[string]any{"id": id, "props": map[string]any{"expanded": []any{"main.go#work"}}})
			case "revision":
				f.result("object.update", map[string]any{"id": id, "props": map[string]any{"title": "new revision"}})
			case "deleted":
				f.result("object.delete", map[string]any{"id": id})
				code = "not_found"
			case "same-rev depth", "same-rev expanded":
				f.router.reg.Mu.Lock()
				object := f.board.Objects()[id].Clone()
				if change == "same-rev depth" {
					object.Props["depth"] = 3.0
				} else {
					object.Props["expanded"] = []any{"main.go#work"}
				}
				f.board.Objects()[id] = object
				f.router.reg.Mu.Unlock()
			}
			answerDiagram(f, peer, request, id, before["rev"], computedDiagram())
			if got, message := errorOf(diagramMessage(t, waiting)); got != code {
				t.Fatalf("superseded reload = %s %q, want %s", got, message, code)
			}
			if change == "deleted" {
				if got, _ := errorOf(f.call("object.get", map[string]any{"id": id})); got != "not_found" {
					t.Fatalf("late graph resurrected deleted target: %s", got)
				}
			} else if graph := diagramObject(f, id)["props"].(map[string]any)["graph"]; graph != nil {
				t.Fatalf("late graph published over a changed target: %v", graph)
			}
			f.router.reg.Mu.Lock()
			jobs := len(f.router.diagrams)
			f.router.reg.Mu.Unlock()
			if jobs != 0 {
				t.Fatalf("supersession retained %d diagram jobs", jobs)
			}
		})
	}
}

func TestDiagramReloadValidatesTheClientResultBeforePublishing(t *testing.T) {
	for _, malformed := range []string{"id", "rev", "fractional rev", "loaded", "missing graph", "aim", "nodes", "excerpt", "edge"} {
		t.Run(malformed, func(t *testing.T) {
			f := newFixture(t)
			id := createDiagram(f)
			before := diagramObject(f, id)
			peer := attachDiagramPeer(t, f)
			waiting := diagramReload(f, id, 1000)
			request := diagramMessage(t, peer.incoming)
			graph := computedDiagram()
			result := map[string]any{"id": id, "loaded": true, "graph": graph, "rev": before["rev"]}
			code := "internal"
			switch malformed {
			case "id":
				result["id"] = "obj_wrong"
			case "rev":
				result["rev"] = before["rev"].(float64) + 1
			case "fractional rev":
				result["rev"] = before["rev"].(float64) + 0.5
			case "loaded":
				result["loaded"] = false
			case "missing graph":
				delete(result, "graph")
			case "aim":
				graph["aim"].(map[string]any)["symbol"] = "other"
				code = "conflict"
			case "nodes":
				graph["nodes"] = "not nodes"
			case "excerpt":
				graph["nodes"].([]any)[0].(map[string]any)["excerpt"] = []any{map[string]any{"text": 7.0}}
			case "edge":
				graph["edges"].([]any)[0].(map[string]any)["lines"] = []any{"not a line"}
			}
			f.router.clients.Answer(peer, map[string]any{"id": request["id"], "ok": true, "result": result})
			got, message := errorOf(diagramMessage(t, waiting))
			if got != code {
				t.Fatalf("malformed result = %s %q, want %s", got, message, code)
			}
			after := diagramObject(f, id)
			failed, valid := checkedDiagramGraph(asMap(after["props"])["graph"])
			if !valid || failed.raw["error"] != message || len(failed.nodes) != 0 || len(failed.edges) != 0 {
				t.Fatalf("invalid result did not publish an empty error graph: %v", after)
			}
			want := model.Clone(before).(map[string]any)
			want["props"].(map[string]any)["graph"] = failed.raw
			if !reflect.DeepEqual(after, want) {
				t.Fatalf("invalid result changed authoritative content or metadata: %v", after)
			}
		})
	}
}

func TestDiagramDisconnectRetiresTheJobAndPublishesOnlyTheFailure(t *testing.T) {
	f := newFixture(t)
	id := createDiagram(f)
	before := diagramObject(f, id)
	peer := attachDiagramPeer(t, f)
	waiting := diagramReload(f, id, 1000)
	request := diagramMessage(t, peer.incoming)
	peer.close()
	answerDiagram(f, peer, request, id, before["rev"], computedDiagram())
	code, message := errorOf(diagramMessage(t, waiting))
	if code != "unavailable" {
		t.Fatalf("disconnected reload = %s %q", code, message)
	}
	after := diagramObject(f, id)
	failed, valid := checkedDiagramGraph(asMap(after["props"])["graph"])
	if !valid || failed.raw["error"] != message || len(failed.nodes) != 0 || len(failed.edges) != 0 {
		t.Fatalf("disconnected client did not publish only its failure: %v", after)
	}
	want := model.Clone(before).(map[string]any)
	want["props"].(map[string]any)["graph"] = failed.raw
	if !reflect.DeepEqual(after, want) {
		t.Fatalf("disconnect changed authoritative content or metadata: %v", after)
	}
	f.router.reg.Mu.Lock()
	jobs := len(f.router.diagrams)
	f.router.reg.Mu.Unlock()
	if jobs != 0 {
		t.Fatalf("disconnect retained %d jobs", jobs)
	}
	fresh := attachDiagramPeer(t, f)
	waiting = diagramReload(f, id, 1000)
	answerDiagram(f, fresh, diagramMessage(t, fresh.incoming), id, before["rev"], computedDiagram())
	if reply := diagramMessage(t, waiting); reply["ok"] != true || reply["result"].(map[string]any)["loaded"] != true {
		t.Fatalf("new client could not replace disconnected job: %v", reply)
	}
}

func TestDiagramFiniteWaitReturnsStoredSummaryAndStillPublishesLateResult(t *testing.T) {
	f := newFixture(t)
	id := createDiagram(f)
	before := diagramObject(f, id)
	peer := attachDiagramPeer(t, f)
	updates := diagramUpdates(t, f)
	previous := computedDiagram()
	previous["error"] = "previous snapshot"
	initial := diagramReload(f, id, 1000)
	answerDiagram(f, peer, diagramMessage(t, peer.incoming), id, before["rev"], previous)
	if reply := diagramMessage(t, initial); reply["ok"] != true || reply["result"].(map[string]any)["loaded"] != true {
		t.Fatalf("initial diagram = %v", reply)
	}
	diagramMessage(t, updates.incoming)

	waiting := diagramReload(f, id, 1)
	request := diagramMessage(t, peer.incoming)
	reply := diagramMessage(t, waiting)
	want := map[string]any{"id": id, "loaded": false, "nodes": 2.0, "edges": 1.0, "root": "main.go#run", "stale": []any{"main.go#work"}, "error": "previous snapshot"}
	if reply["ok"] != true || !reflect.DeepEqual(reply["result"], want) {
		t.Fatalf("expired wait = %v, want %v", reply, want)
	}
	fresh := computedDiagram()
	fresh["computedAt"] = "2026-10-17T12:01:00Z"
	fresh["nodes"] = fresh["nodes"].([]any)[:1]
	fresh["edges"] = []any{}
	answerDiagram(f, peer, request, id, before["rev"], fresh)
	event := diagramMessage(t, updates.incoming)
	if event["event"] != "object.updated" || !reflect.DeepEqual(asMap(asMap(event["data"])["props"])["graph"], fresh) {
		t.Fatalf("late publication after finite wait = %v", event)
	}
	if stored := diagramObject(f, id)["props"].(map[string]any)["graph"]; !reflect.DeepEqual(stored, fresh) {
		t.Fatalf("late result did not replace the stored graph: %v", stored)
	}
}
