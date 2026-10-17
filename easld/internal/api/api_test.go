package api

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

// A message's id, easl's own or the one its sender gave (agent.prompt `message`), fits the schema
// everywhere a message id goes: as it is sent, answered, handed out and acked.
func TestEveryMessageIdFitsTheSchemaWhereverItGoes(t *testing.T) {
	raw, err := os.ReadFile("../../../schema/easl-api.json")
	if err != nil {
		t.Fatal(err)
	}
	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatal(err)
	}
	ids := []string{model.NewID("msg"), "msg_write_toolu_01", "msg_8f3c2a91d4e64b7f9a0c1d2e3f405162"}
	for _, place := range []string{
		"methods/agent.prompt/params/properties/message",
		"methods/agent.prompt/result/properties/message",
		"definitions/AgentMessage/properties/id",
		"methods/agent.inbox/params/properties/ack/items",
	} {
		node := pointer(t, schema, place)
		for ref, _ := node["$ref"].(string); ref != ""; ref, _ = node["$ref"].(string) {
			node = pointer(t, schema, strings.TrimPrefix(ref, "#/"))
		}
		pattern, _ := node["pattern"].(string)
		re, err := regexp.Compile(pattern)
		if err != nil || pattern == "" {
			t.Errorf("%s: pattern %q: %v", place, pattern, err)
			continue
		}
		for _, id := range ids {
			if !re.MatchString(id) {
				t.Errorf("%s: %s doesn't fit %s", place, id, pattern)
			}
		}
	}
}

// pointer is the schema object at a slash-separated path.
func pointer(t *testing.T, schema map[string]any, path string) map[string]any {
	t.Helper()
	node := schema
	for _, key := range strings.Split(path, "/") {
		next, ok := node[key].(map[string]any)
		if !ok {
			t.Fatalf("no %s in the schema", path)
		}
		node = next
	}
	return node
}
