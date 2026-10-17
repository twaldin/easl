package conformance

import (
	"fmt"
	"sort"
)

func checkExpectations(step Step, response any, events []any, vars map[string]any, schema map[string]any) error {
	values := map[string]any{"response": response, "events": events, "eventCount": float64(len(events))}
	paths := make([]string, 0, len(step.Expect))
	for path := range step.Expect {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		want, err := expand(step.Expect[path], vars)
		if err != nil {
			return err
		}
		got, err := lookup(values, path)
		if err != nil {
			return err
		}
		if !jsonEqual(want, got) {
			return fmt.Errorf("expect %s = %s, got %s", path, short(want), short(got))
		}
	}
	for path, name := range step.ExpectShape {
		value, err := lookup(values, path)
		if err != nil {
			return err
		}
		node, ok := resolveRef(schema, "#/definitions/"+name)
		if !ok {
			return fmt.Errorf("expectShape %s: unknown definition %s", path, name)
		}
		var problems []string
		shapeProblems(schema, node, value, path, &problems)
		if len(problems) != 0 {
			return fmt.Errorf("expectShape %s: %v", path, problems)
		}
	}
	return nil
}
