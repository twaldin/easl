package router

import (
	"fmt"
	"maps"
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
)

type receiptClient struct {
	*conn
	calls chan map[string]any
}

func (c *receiptClient) Send(value any) bool {
	request := value.(map[string]any)
	if _, call := request["method"]; call {
		c.calls <- request
		return true
	}
	return c.conn.Send(value)
}

func receiptRequest(f *fixture, params map[string]any) map[string]any {
	return f.router.HandleConn(map[string]any{"id": "receipt", "method": "agent.prompt", "params": params}, &conn{}).(map[string]any)
}

func receiptParams(f *fixture, target, id string) map[string]any {
	return map[string]any{
		"target": target, "text": "inspect this prompt", "composer": true,
		"submission": map[string]any{"id": id, "epoch": f.result("system.ping", map[string]any{"promptReceipts": true})["promptEpoch"], "createdAt": time.Now().UTC().Format(time.RFC3339Nano)},
	}
}

func receiptReconcile(params map[string]any) map[string]any {
	query := maps.Clone(params)
	query["reconcile"] = true
	return query
}

func receiptResult(t *testing.T, reply map[string]any) map[string]any {
	t.Helper()
	if reply["ok"] != true {
		t.Fatalf("receipt failed: %v", reply)
	}
	return reply["result"].(map[string]any)
}

func receiptAwait(t *testing.T, replies <-chan map[string]any) map[string]any {
	t.Helper()
	select {
	case reply := <-replies:
		return reply
	case <-time.After(3 * time.Second):
		t.Fatal("receipt request did not complete")
		return nil
	}
}

func attachReceiptClient(t *testing.T, f *fixture) *receiptClient {
	t.Helper()
	client := &receiptClient{conn: &conn{}, calls: make(chan map[string]any, 4)}
	reply := f.router.HandleConn(map[string]any{"id": "attach", "method": "client.attach", "params": map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash, "serves": []any{"agent.prompt"}, "boards": []any{f.board.ID()},
	}}, client).(map[string]any)
	if reply["ok"] != true {
		t.Fatalf("attach: %v", reply)
	}
	t.Cleanup(client.close)
	return client
}

func TestPromptReceiptsPingEpochIsStableAndRouterScoped(t *testing.T) {
	f := newFixture(t)
	first := f.result("system.ping", map[string]any{"promptReceipts": true})["promptEpoch"]
	second := f.result("system.ping", map[string]any{"promptReceipts": true})["promptEpoch"]
	other := newFixture(t).result("system.ping", map[string]any{"promptReceipts": true})["promptEpoch"]
	if first == "" || first == nil || first != second || first == other {
		t.Fatalf("epochs: %v %v %v", first, second, other)
	}
	if _, present := f.result("system.ping", map[string]any{})["promptEpoch"]; present {
		t.Fatal("legacy ping changed its response")
	}
}

func TestPromptReceiptsSuccessReplaysAfterDeletionWithoutAnotherMessage(t *testing.T) {
	f := newFixture(t)
	tile := f.agentTerminal("", map[string]any{"name": "worker"})
	f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "protocol": 1.0})
	params := receiptParams(f, tile, "sub_success01")
	delete(params, "composer")
	first := receiptRequest(f, params)
	if receiptResult(t, first)["delivery"] != "message" {
		t.Fatalf("message not delivered: %v", first)
	}
	if duplicate := receiptRequest(f, params); !reflect.DeepEqual(first, duplicate) {
		t.Fatalf("duplicate changed result: %v %v", first, duplicate)
	}
	if messages := f.board.Messages(tile); len(messages) != 1 {
		t.Fatalf("executed %d times", len(messages))
	}
	f.result("object.delete", map[string]any{"id": tile})
	if recovered := receiptRequest(f, receiptReconcile(params)); !reflect.DeepEqual(first, recovered) {
		t.Fatalf("deleted target erased success: %v %v", first, recovered)
	}
	changed := maps.Clone(params)
	changed["text"] = "another prompt"
	if code, _ := errorOf(receiptRequest(f, changed)); code != api.CodeInvalidParams {
		t.Fatalf("changed payload: %s", code)
	}
}

func TestPromptReceiptsReserveBeforeDelegateAndNeverForwardQueries(t *testing.T) {
	f := newFixture(t)
	tile := f.agentTerminal("", map[string]any{"name": "worker"})
	app := attachReceiptClient(t, f)
	params := receiptParams(f, tile, "sub_concurrent01")
	completed := make(chan map[string]any, 1)
	go func() { completed <- receiptRequest(f, params) }()
	forwarded := receiptAwait(t, app.calls)
	for _, duplicate := range []map[string]any{params, receiptReconcile(params)} {
		if result := receiptResult(t, receiptRequest(f, duplicate)); result["delivery"] != "pending" {
			t.Fatalf("in-flight duplicate: %v", result)
		}
	}
	changed := maps.Clone(params)
	changed["answer"] = true
	if code, _ := errorOf(receiptRequest(f, changed)); code != api.CodeInvalidParams {
		t.Fatalf("in-flight payload mutation: %s", code)
	}
	if len(app.calls) != 0 {
		t.Fatal("duplicate or receipt query forwarded")
	}
	original := map[string]any{"sent": true, "detail": map[string]any{"value": "original"}}
	f.router.clients.Answer(app, map[string]any{"id": forwarded["id"], "ok": true, "result": original})
	if result := receiptResult(t, receiptAwait(t, completed)); !reflect.DeepEqual(result, original) {
		t.Fatalf("original success changed: %v", result)
	}
	original["detail"].(map[string]any)["value"] = "mutated"
	cached := receiptResult(t, receiptRequest(f, receiptReconcile(params)))
	if cached["detail"].(map[string]any)["value"] != "original" || len(app.calls) != 0 {
		t.Fatalf("cached result changed or query forwarded: %v", cached)
	}
}

func TestPromptReceiptsCancellationBeforeOriginalNeverDelivers(t *testing.T) {
	f := newFixture(t)
	tile := f.agentTerminal("", map[string]any{})
	app := attachReceiptClient(t, f)
	params := receiptParams(f, tile, "sub_cancelled01")
	for _, request := range []map[string]any{receiptReconcile(params), params, receiptReconcile(params)} {
		if result := receiptResult(t, receiptRequest(f, request)); result["delivery"] != "not-delivered" {
			t.Fatalf("cancelled submission: %v", result)
		}
	}
	if len(app.calls) != 0 {
		t.Fatal("cancelled original reached the delegate")
	}
}

func TestPromptReceiptsCacheValidationRefusalBeforeTargetParsing(t *testing.T) {
	f := newFixture(t)
	params := receiptParams(f, "obj_missing", "sub_refused01")
	params["force"] = true
	first := receiptRequest(f, params)
	if code, _ := errorOf(first); code != api.CodeInvalidParams {
		t.Fatalf("composer refusal: %v", first)
	}
	if recovered := receiptResult(t, receiptRequest(f, receiptReconcile(params))); recovered["delivery"] != "not-delivered" || !reflect.DeepEqual(recovered["error"], first["error"]) {
		t.Fatalf("refusal receipt changed: %v %v", first, recovered)
	}
	for _, field := range []string{"epoch", "createdAt"} {
		changed := maps.Clone(params)
		submission := maps.Clone(params["submission"].(map[string]any))
		if field == "epoch" {
			submission[field] = "different-epoch"
		} else {
			submission[field] = time.Now().Add(-25 * time.Hour).Format(time.RFC3339Nano)
		}
		changed["submission"] = submission
		if code, _ := errorOf(receiptRequest(f, changed)); code != api.CodeInvalidParams {
			t.Fatalf("changed %s bypassed mismatch check: %s", field, code)
		}
	}
}

func TestPromptReceiptsUnknownEpochAndAgeNeverExecuteOrCancel(t *testing.T) {
	for _, kind := range []string{"epoch", "expired", "future"} {
		t.Run(kind, func(t *testing.T) {
			f := newFixture(t)
			tile := f.agentTerminal("", map[string]any{})
			app := attachReceiptClient(t, f)
			params := receiptParams(f, tile, "sub_unknown01")
			submission := params["submission"].(map[string]any)
			switch kind {
			case "epoch":
				submission["epoch"] = "previous-router"
			case "expired":
				submission["createdAt"] = time.Now().Add(-25 * time.Hour).Format(time.RFC3339Nano)
			case "future":
				submission["createdAt"] = time.Now().Add(6 * time.Minute).Format(time.RFC3339Nano)
			}
			for _, request := range []map[string]any{params, receiptReconcile(params)} {
				if result := receiptResult(t, receiptRequest(f, request)); result["delivery"] != "unknown" {
					t.Fatalf("unsafe stale result: %v", result)
				}
			}
			if len(app.calls) != 0 {
				t.Fatal("uncertain submission forwarded")
			}
		})
	}
}

func TestPromptReceiptsMetadataValidationAndReconcileRequirement(t *testing.T) {
	f := newFixture(t)
	for _, params := range []map[string]any{
		{"reconcile": true}, {"reconcile": false}, {"reconcile": "true"},
		{"submission": "not an object"},
		{"submission": map[string]any{"id": "sub_bad!", "epoch": "e", "createdAt": time.Now().Format(time.RFC3339Nano)}},
		{"submission": map[string]any{"id": "sub_valid01", "epoch": "", "createdAt": time.Now().Format(time.RFC3339Nano)}},
		{"submission": map[string]any{"id": "sub_valid01", "epoch": "e", "createdAt": "yesterday"}},
		{"submission": map[string]any{"id": "sub_valid01", "epoch": "e", "createdAt": "2026-10-20T01:02:03,123Z"}},
		{"submission": map[string]any{"id": "sub_valid01", "epoch": "e", "createdAt": "2026-10-20T01:02:03+24:00"}},
	} {
		if code, _ := errorOf(receiptRequest(f, params)); code != api.CodeInvalidParams {
			t.Errorf("invalid metadata accepted: %v: %s", params, code)
		}
	}
}

func TestPromptReceiptsDelegateUncertaintyRetainsMentionsAndDefiniteRefusalWithdraws(t *testing.T) {
	for _, uncertain := range []bool{true, false} {
		t.Run(fmt.Sprint(uncertain), func(t *testing.T) {
			f := newFixture(t)
			tile := f.agentTerminal("", map[string]any{})
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "protocol": 1.0})
			noteID := idOf(f.result("object.create", note(0, map[string]any{"markdown": "context"})))
			app := attachReceiptClient(t, f)
			params := receiptParams(f, tile, "sub_transport01")
			params["viewer"] = "vw_viewer01"
			params["staged"] = []any{map[string]any{"id": "men_origin", "label": "context", "edited": false, "stagedAt": time.Now().Format(time.RFC3339Nano), "target": map[string]any{"kind": "object", "object": noteID}}}
			completed := make(chan map[string]any, 1)
			go func() { completed <- receiptRequest(f, params) }()
			forwarded := receiptAwait(t, app.calls)
			if uncertain {
				app.close()
			} else {
				f.router.clients.Answer(app, map[string]any{"id": forwarded["id"], "ok": false, "error": map[string]any{"code": api.CodeUnavailable, "message": "no terminal surface"}})
			}
			first := receiptAwait(t, completed)
			if uncertain {
				if result := receiptResult(t, first); result["delivery"] != "unknown" {
					t.Fatalf("disconnect asserted refusal: %v", result)
				}
			} else if code, message := errorOf(first); code != api.CodeUnavailable || message != "no terminal surface" {
				t.Fatalf("definite delegate refusal changed: %v", first)
			}
			cached := receiptResult(t, receiptRequest(f, receiptReconcile(params)))
			if uncertain && !reflect.DeepEqual(cached, first["result"]) || !uncertain && (cached["delivery"] != "not-delivered" || !reflect.DeepEqual(cached["error"], first["error"])) {
				t.Fatalf("delegate outcome changed: %v %v", first, cached)
			}
			if duplicate := receiptRequest(f, params); !reflect.DeepEqual(duplicate, first) || len(app.calls) != 0 {
				t.Fatalf("uncertain or refused original retried: %v", duplicate)
			}
			drained := f.result("tray.drain", map[string]any{"caller": tile, "prompt": params["text"]})["mentions"].([]any)
			want := 0
			if uncertain {
				want = 1
			}
			if len(drained) != want {
				t.Fatalf("queued mentions after outcome: %v, want %d", drained, want)
			}
		})
	}
}

func TestPromptReceiptsCapacityNeverMakesAnUnrecordedCancellationClaim(t *testing.T) {
	f := newFixture(t)
	params := receiptParams(f, "obj_missing", "sub_capacity_full")
	for index := range 4096 {
		request := maps.Clone(params)
		submission := maps.Clone(params["submission"].(map[string]any))
		submission["id"] = fmt.Sprintf("sub_capacity_%04d", index)
		request["submission"] = submission
		if result := receiptResult(t, receiptRequest(f, receiptReconcile(request))); result["delivery"] != "not-delivered" {
			t.Fatalf("capacity reservation %d: %v", index, result)
		}
	}
	if result := receiptResult(t, receiptRequest(f, receiptReconcile(params))); result["delivery"] != "unknown" {
		t.Fatalf("full registry claimed cancellation without a tombstone: %v", result)
	}
	if code, _ := errorOf(receiptRequest(f, params)); code != api.CodeUnavailable {
		t.Fatalf("full registry original: %s", code)
	}
}
