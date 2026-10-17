package conformance

import (
	"strings"
	"testing"
	"time"
)

func TestExpectationsPreventRecordingErrorsAsSuccess(t *testing.T) {
	s := Scenario{Name: "expected", Steps: []Step{{Call: "object.create", Expect: map[string]any{"response.ok": false, "response.error.code": "invalid_params"}}}}
	_, err := RunScenario(s, Options{Socket: startFake(t, false), Settle: time.Millisecond})
	if err == nil || !strings.Contains(err.Error(), "step 2 (object.create)") {
		t.Fatalf("unexpected success must not be recordable: %v", err)
	}
}

func TestExpectedFrameRetainsOwnershipAndFields(t *testing.T) {
	schema := map[string]any{"definitions": map[string]any{"Frame": map[string]any{
		"type": "object", "required": []any{"seq", "data"},
		"properties":           map[string]any{"seq": map[string]any{"type": "integer"}, "data": map[string]any{"type": "string"}},
		"additionalProperties": false,
	}}}
	step := Step{
		Expect:      map[string]any{"eventCount": 1, "events.0.conn": "owner", "events.0.data.seq": 1},
		ExpectShape: map[string]string{"events.0.data": "Frame"},
	}
	frame := map[string]any{"seq": float64(1), "data": "YWJj"}
	event := map[string]any{"conn": "owner", "data": frame}
	if err := checkExpectations(step, nil, []any{event}, nil, schema); err != nil {
		t.Fatal(err)
	}
	event["conn"] = "observer"
	if err := checkExpectations(step, nil, []any{event}, nil, schema); err == nil || !strings.Contains(err.Error(), "events.0.conn") {
		t.Fatalf("observer received private frame: %v", err)
	}
	event["conn"] = "owner"
	delete(frame, "data")
	if err := checkExpectations(step, nil, []any{event}, nil, schema); err == nil || !strings.Contains(err.Error(), "data missing") {
		t.Fatalf("image-less ack accepted: %v", err)
	}
}
