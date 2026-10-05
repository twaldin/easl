package conformance

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
)

// Shape steps (Step.Shape) call a method whose result is the server's own measurements: the
// result is checked against the method's result schema in schema/easl-api.json instead of
// compared, and the transcript keeps the verdict.

// shapeFits is a Shape step's result when it fits the schema.
const shapeFits = "<fits the result schema>"

const maxShapeProblems = 8

// loadSchema reads schema/easl-api.json.
func loadSchema(path string) (map[string]any, error) {
	if path == "" {
		return nil, fmt.Errorf("a step checks a result's shape, and no schema was given (Options.Schema)")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var schema map[string]any
	return schema, json.Unmarshal(data, &schema)
}

// shapeVerdict is shapeFits, or the places the result departs from method's result schema.
func shapeVerdict(schema map[string]any, method string, result any) string {
	methods, _ := schema["methods"].(map[string]any)
	spec, _ := methods[method].(map[string]any)
	node, ok := spec["result"].(map[string]any)
	if !ok {
		return "<the schema has no result for " + method + ">"
	}
	var problems []string
	shapeProblems(schema, node, result, "result", &problems)
	if len(problems) == 0 {
		return shapeFits
	}
	return "<doesn't fit the result schema: " + strings.Join(problems, "; ") + ">"
}

// shapeProblems lists where v departs from the schema node: `$ref`, `type`, `enum`, `const`,
// `required`, `properties` with `additionalProperties` (false, or a schema for the rest),
// `items`, `oneOf` and `anyOf` (fitting one is enough). Other keywords (bounds, formats,
// patterns) aren't checked.
func shapeProblems(root, node map[string]any, v any, path string, out *[]string) {
	if len(*out) >= maxShapeProblems {
		return
	}
	add := func(format string, args ...any) {
		if len(*out) < maxShapeProblems {
			*out = append(*out, path+": "+fmt.Sprintf(format, args...))
		}
	}
	if ref, ok := node["$ref"].(string); ok {
		target, ok := resolveRef(root, ref)
		if !ok {
			add("unresolved $ref %s", ref)
			return
		}
		shapeProblems(root, target, v, path, out)
		return
	}
	for _, key := range []string{"oneOf", "anyOf"} {
		alternatives, ok := node[key].([]any)
		if !ok {
			continue
		}
		fits := false
		for _, a := range alternatives {
			alt, _ := a.(map[string]any)
			var none []string
			shapeProblems(root, alt, v, path, &none)
			if len(none) == 0 {
				fits = true
				break
			}
		}
		if !fits {
			add("fits none of its %s", key)
			return
		}
	}
	if t, ok := node["type"]; ok && !typeFits(t, v) {
		add("got %s, want %v", jsonType(v), t)
		return
	}
	if c, ok := node["const"]; ok && !jsonEqual(c, v) {
		add("%s, want %s", short(v), short(c))
	}
	if enum, ok := node["enum"].([]any); ok {
		found := false
		for _, e := range enum {
			found = found || jsonEqual(e, v)
		}
		if !found {
			add("%s, not one of %s", short(v), short(enum))
		}
	}
	switch x := v.(type) {
	case map[string]any:
		properties, _ := node["properties"].(map[string]any)
		required, _ := node["required"].([]any)
		for _, r := range required {
			if name, _ := r.(string); name != "" {
				if _, ok := x[name]; !ok {
					add("%s missing", name)
				}
			}
		}
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if p, ok := properties[k].(map[string]any); ok {
				shapeProblems(root, p, x[k], join(path, k), out)
				continue
			}
			switch rest := node["additionalProperties"].(type) {
			case bool:
				if !rest {
					add("%s isn't in the schema", k)
				}
			case map[string]any:
				shapeProblems(root, rest, x[k], join(path, k), out)
			}
		}
	case []any:
		if items, ok := node["items"].(map[string]any); ok {
			for i, e := range x {
				shapeProblems(root, items, e, join(path, fmt.Sprint(i)), out)
			}
		}
	}
}

// resolveRef finds a local reference (`#/definitions/Name`).
func resolveRef(root map[string]any, ref string) (map[string]any, bool) {
	if !strings.HasPrefix(ref, "#/") {
		return nil, false
	}
	var node any = root
	for _, part := range strings.Split(ref[2:], "/") {
		m, ok := node.(map[string]any)
		if !ok {
			return nil, false
		}
		node = m[part]
	}
	out, ok := node.(map[string]any)
	return out, ok
}

func typeFits(t, v any) bool {
	switch x := t.(type) {
	case string:
		return x == jsonType(v) || (x == "number" && jsonType(v) == "integer")
	case []any:
		for _, e := range x {
			if typeFits(e, v) {
				return true
			}
		}
	}
	return false
}

// jsonType is a decoded JSON value's schema type; a whole number is an integer.
func jsonType(v any) string {
	switch x := v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case string:
		return "string"
	case float64:
		if x == math.Trunc(x) && !math.IsInf(x, 0) {
			return "integer"
		}
		return "number"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	}
	return fmt.Sprintf("%T", v)
}

func jsonEqual(a, b any) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}
