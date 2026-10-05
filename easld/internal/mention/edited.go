package mention

import (
	"strconv"
	"strings"

	"github.com/twaldin/easl/easld/internal/model"
)

// bookkeepingProps say how an object looks or what the app keeps about it, not what it holds.
var bookkeepingProps = map[string]bool{"zoom": true, "textSize": true, "viewed": true, "lifecycle": true, "agent": true, "pageTitle": true}

// IsEdited is MentionTarget.isEdited(from:to:): whether an update of one of the mention's objects
// (before → after) changed what the mention holds. Moving, resizing, zooming, restacking and
// bookkeeping never do; a code mention changes only with its changes tile's base, head, ref or
// root, or a review action (or its undo) over its lines; terminal text and page log entries are
// what they were when staged.
func IsEdited(target map[string]any, before, after model.Object) bool {
	t, err := DecodeTarget(target)
	if err != nil {
		return false
	}
	switch t.Kind {
	case "code":
		if after.Type != model.Changes {
			return false
		}
		for _, key := range []string{"base", "root", "head", "ref"} {
			a, aok := before.Props[key]
			b, bok := after.Props[key]
			if aok != bok || !model.Equal(a, b) {
				return true
			}
		}
		old, _ := before.Props["reviewed"].([]any)
		new, _ := after.Props["reviewed"].([]any)
		added := missingFrom(new, old)
		changed := added
		if len(added) == 0 {
			changed = missingFrom(old, new)
		}
		for _, entry := range changed {
			if reviewTouches(entry, t.Path, t.Lines, t.Side) {
				return true
			}
		}
		return false
	case "terminal", "console":
		return false
	}
	return !model.Equal(content(before), content(after))
}

// missingFrom are the entries of list that other doesn't contain.
func missingFrom(list, other []any) []any {
	var out []any
	for _, entry := range list {
		found := false
		for _, o := range other {
			if model.Equal(entry, o) {
				found = true
				break
			}
		}
		if !found {
			out = append(out, entry)
		}
	}
	return out
}

func content(o model.Object) map[string]any {
	out := map[string]any{}
	for k, v := range o.Props {
		if !bookkeepingProps[k] {
			out[k] = v
		}
	}
	return out
}

// reviewTouches is whether a `props.reviewed` entry acted on these lines of path: its whole
// file, or a hunk whose span on the mention's side (either side without one) meets them.
func reviewTouches(entry any, path string, lines model.LineRange, side *string) bool {
	e, _ := entry.(map[string]any)
	if p, ok := e["path"].(string); !ok || p != path {
		return false
	}
	if scope, ok := e["scope"].(string); ok && scope == "file" {
		return true
	}
	header, ok := e["header"].(string)
	if !ok {
		return true
	}
	original, modified, ok := hunkMapping(header)
	if !ok {
		return true
	}
	meets := func(span [2]int) bool {
		low, high := span[0], span[1]-1
		if span[0] == span[1] {
			low, high = span[0]-1, span[0]
		}
		return low <= lines.End && lines.Start <= high
	}
	switch {
	case side != nil && *side == "old":
		return meets(original)
	case side != nil && *side == "new":
		return meets(modified)
	}
	return meets(original) || meets(modified)
}

// hunkMapping is UnifiedDiff.mapping(fromHeader:): `@@ -a[,b] +c[,d] @@` as half-open line
// spans; a zero count is an empty span after line a/c.
func hunkMapping(header string) (original, modified [2]int, ok bool) {
	fields := strings.FieldsFunc(header, func(r rune) bool { return r == ' ' })
	if len(fields) < 3 || fields[0] != "@@" || !strings.HasPrefix(fields[1], "-") || !strings.HasPrefix(fields[2], "+") {
		return original, modified, false
	}
	o, ok1 := hunkRange(fields[1][1:])
	m, ok2 := hunkRange(fields[2][1:])
	return o, m, ok1 && ok2
}

func hunkRange(field string) ([2]int, bool) {
	parts := strings.FieldsFunc(field, func(r rune) bool { return r == ',' })
	if len(parts) == 0 {
		return [2]int{}, false
	}
	start, err := strconv.Atoi(parts[0])
	if err != nil {
		return [2]int{}, false
	}
	count := 1
	if len(parts) > 1 {
		if c, err := strconv.Atoi(parts[1]); err == nil {
			count = c
		}
	}
	lower := start
	if count == 0 {
		lower = start + 1
	}
	return [2]int{lower, lower + count}, true
}
