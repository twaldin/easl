package api

import (
	"bytes"
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// The generated tables must say what schema/easl-api.json says, in its order.
func TestMethodsAndErrorCodesFollowTheSchema(t *testing.T) {
	raw, err := os.ReadFile("../../../schema/easl-api.json")
	if err != nil {
		t.Fatal(err)
	}
	var schema struct {
		Version int               `json:"version"`
		Errors  map[string]string `json:"errors"`
		Methods map[string]struct {
			Params struct {
				Properties json.RawMessage `json:"properties"`
				Required   []string        `json:"required"`
			} `json:"params"`
		} `json:"methods"`
	}
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatal(err)
	}
	if SchemaVersion != schema.Version {
		t.Errorf("SchemaVersion %d, schema %d", SchemaVersion, schema.Version)
	}
	if len(Methods) != len(schema.Methods) {
		t.Errorf("%d methods, schema has %d", len(Methods), len(schema.Methods))
	}
	for name, m := range schema.Methods {
		spec, ok := Methods[name]
		if !ok {
			t.Errorf("method %s missing", name)
			continue
		}
		if !reflect.DeepEqual(spec.Required, nilIfEmpty(m.Params.Required)) {
			t.Errorf("%s required %v, schema %v", name, spec.Required, m.Params.Required)
		}
		if got := keysInOrder(t, m.Params.Properties); !reflect.DeepEqual(spec.Accepted, got) {
			t.Errorf("%s accepted %v, schema %v", name, spec.Accepted, got)
		}
	}
	codes := map[string]bool{}
	for _, code := range []string{CodeInvalidParams, CodeNotFound, CodeConflict, CodeUnsupported, CodeUnavailable, CodeTimeout, CodeInternal} {
		codes[code] = true
	}
	if len(codes) != len(schema.Errors) {
		t.Errorf("%d error code constants, schema has %d", len(codes), len(schema.Errors))
	}
	for code := range schema.Errors {
		if !codes[code] {
			t.Errorf("no constant for error code %s", code)
		}
	}
}

func nilIfEmpty(s []string) []string {
	if len(s) == 0 {
		return nil
	}
	return s
}

// keysInOrder returns an object's keys as written.
func keysInOrder(t *testing.T, raw json.RawMessage) []string {
	t.Helper()
	if len(raw) == 0 {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		t.Fatalf("not an object: %s", raw)
	}
	var keys []string
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, tok.(string))
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			t.Fatal(err)
		}
	}
	return keys
}
