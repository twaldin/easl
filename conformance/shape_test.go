package conformance

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestShapeVerdict(t *testing.T) {
	var schema map[string]any
	if err := json.Unmarshal([]byte(`{
		"definitions": {
			"Tally": {"type": "object", "required": ["n"], "properties": {"n": {"type": "integer"}, "ms": {"type": "number"}}}
		},
		"methods": {
			"m": {"result": {
				"type": "object",
				"required": ["counters", "mode"],
				"properties": {
					"counters": {"type": "object", "additionalProperties": {"$ref": "#/definitions/Tally"}},
					"mode": {"enum": ["a", "b"]},
					"list": {"type": "array", "items": {"type": "string"}},
					"closed": {"type": "object", "properties": {"x": {"type": "number"}}, "additionalProperties": false},
					"either": {"oneOf": [{"type": "string"}, {"type": "object", "required": ["k"]}]}
				}
			}}
		}
	}`), &schema); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		result string
		want   []string // parts of the verdict; none: it fits
	}{
		{`{"counters": {"api.x": {"n": 2, "ms": 1.5}}, "mode": "a", "list": ["p"], "closed": {"x": 1}, "either": {"k": 1}, "extra": true}`, nil},
		{`{"counters": {}, "mode": "b", "either": "s"}`, nil},
		{`{"mode": "a"}`, []string{"result: counters missing"}},
		{`{"counters": {"api.x": {"ms": 1}}, "mode": "a"}`, []string{"result.counters.api.x: n missing"}},
		{`{"counters": {"api.x": {"n": 1.5}}, "mode": "a"}`, []string{"result.counters.api.x.n: got number, want integer"}},
		{`{"counters": {}, "mode": "c"}`, []string{`result.mode: "c", not one of`}},
		{`{"counters": {}, "mode": "a", "list": ["p", 3]}`, []string{"result.list.1: got integer, want string"}},
		{`{"counters": {}, "mode": "a", "closed": {"x": 1, "y": 2}}`, []string{"result.closed: y isn't in the schema"}},
		{`{"counters": {}, "mode": "a", "either": {"j": 1}}`, []string{"result.either: fits none of its oneOf"}},
		{`[1]`, []string{"result: got array, want object"}},
	}
	for _, c := range cases {
		var result any
		if err := json.Unmarshal([]byte(c.result), &result); err != nil {
			t.Fatal(err)
		}
		got := shapeVerdict(schema, "m", result)
		if c.want == nil {
			if got != shapeFits {
				t.Errorf("%s: %s, want it to fit", c.result, got)
			}
			continue
		}
		for _, part := range c.want {
			if !strings.Contains(got, part) {
				t.Errorf("%s: %s, want it to name %q", c.result, got, part)
			}
		}
	}
	if got := shapeVerdict(schema, "nope", map[string]any{}); got == shapeFits {
		t.Errorf("a method without a result schema fits: %s", got)
	}
}
