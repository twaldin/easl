package conformance

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// normalizer rewrites what differs between two correct servers (or two runs of one) into stable
// tokens, keeping the relations that matter:
//
//   - ids (`obj_01J…`, `men_…`) become `<obj:1>`, `<obj:2>`, … by first appearance, so "the
//     same object" stays the same token and two objects stay apart;
//   - revisions become `<rev:n>` tokens by value, per kind (an object's `rev`; a board revision:
//     `revision`, `cursor`, `since`, an activity entry's `rev`), so equal revisions stay equal and
//     a write that should have moved one shows (`board.history`'s `cursor` and `seq` count log
//     entries from the board's opening and stay as they are);
//   - timestamps become `<time>`, absolute paths `<root>` (the scenario's directory), `<home>`
//     and `<tmp>`, process ids `<pid>`.
//
// The walk visits object keys in sorted order, so numbering is the same on every run.
type normalizer struct {
	tokens map[string]string
	counts map[string]int
	revs   map[string]map[string]string
	paths  []pathSubst
	// The method of the record being normalised.
	method string
}

type pathSubst struct{ from, to string }

func newNormalizer(paths []pathSubst) *normalizer {
	// Longest first: the scenario root sits inside the temp directory.
	sort.SliceStable(paths, func(i, j int) bool { return len(paths[i].from) > len(paths[j].from) })
	return &normalizer{tokens: map[string]string{}, counts: map[string]int{}, revs: map[string]map[string]string{}, paths: paths}
}

// alias pins a value (the scenario's board id) to a fixed token.
func (n *normalizer) alias(value, token string) {
	if value != "" {
		n.tokens[value] = token
	}
}

var (
	idPattern   = regexp.MustCompile(`\b([a-z]+)_([0-9A-HJKMNP-TV-Z]{18})\b`)
	timePattern = regexp.MustCompile(`\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})\b`)
	pidPattern  = regexp.MustCompile(`\bpid \d+`)
	// Elapsed times in prose ("3s ago", "120 ms").
	msPattern = regexp.MustCompile(`\b\d+(\.\d+)? ?ms\b`)
)

// Keys whose numeric value is a revision, by the revision space it counts in.
var revisionKeys = map[string]string{
	"rev":      "rev",
	"revision": "board",
	"since":    "board",
	"boardRev": "board",
}

// Keys whose value is a moment.
var timeKeys = map[string]bool{
	"createdAt": true, "updatedAt": true, "at": true, "time": true, "savedAt": true, "raisedAt": true,
	"startedAt": true, "reportedAt": true, "modified": true, "ts": true, "date": true, "seenAt": true,
	"stagedAt": true, "endedAt": true, "lastReport": true, "since_ms": true,
}

func (n *normalizer) value(v any, parentKey string, inEntry bool) any {
	switch x := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		// An activity entry (it has `seq`) counts its `rev` in board revisions.
		entry := x["seq"] != nil && x["kind"] != nil
		out := make(map[string]any, len(x))
		for _, k := range keys {
			// Maps keyed by id (layout results' `frames`) normalise their keys too.
			out[n.text(k)] = n.field(k, x[k], entry)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = n.value(e, parentKey, inEntry)
		}
		return out
	case string:
		return n.text(x)
	default:
		return v
	}
}

func (n *normalizer) field(key string, v any, entry bool) any {
	if timeKeys[key] {
		switch v.(type) {
		case string, float64:
			return "<time>"
		}
	}
	if n.method == "board.history" {
		// Activity log positions: the client's own entries (viewport, selection) arrive at times
		// a scenario can't control and are dropped (dropClientEntries), so the positions that
		// remain are compared by order, and the cursor (the log's last position, which may be
		// one of those) not at all.
		switch key {
		case "seq", "since":
			if f, ok := v.(float64); ok {
				return n.revision("seq", f)
			}
		case "cursor":
			return "<cursor>"
		}
	}
	if space, ok := revisionKeys[key]; ok {
		if key == "rev" && entry {
			space = "board"
		}
		if f, ok := v.(float64); ok {
			return n.revision(space, f)
		}
	}
	return n.value(v, key, entry)
}

func (n *normalizer) revision(space string, value float64) string {
	byValue := n.revs[space]
	if byValue == nil {
		byValue = map[string]string{}
		n.revs[space] = byValue
	}
	k := fmt.Sprint(value)
	if t, ok := byValue[k]; ok {
		return t
	}
	t := fmt.Sprintf("<%s:%d>", space, len(byValue)+1)
	byValue[k] = t
	return t
}

func (n *normalizer) text(s string) string {
	if t, ok := n.tokens[s]; ok {
		return t
	}
	for _, p := range n.paths {
		if p.from != "" {
			s = strings.ReplaceAll(s, p.from, p.to)
		}
	}
	s = idPattern.ReplaceAllStringFunc(s, func(id string) string {
		if t, ok := n.tokens[id]; ok {
			return t
		}
		prefix := idPattern.FindStringSubmatch(id)[1]
		n.counts[prefix]++
		t := fmt.Sprintf("<%s:%d>", prefix, n.counts[prefix])
		n.tokens[id] = t
		return t
	})
	for raw, t := range n.tokens {
		// Ids that don't look like ids (a board's) are replaced wherever they appear.
		if !idPattern.MatchString(raw) && len(raw) >= 8 && strings.Contains(s, raw) {
			s = strings.ReplaceAll(s, raw, t)
		}
	}
	s = timePattern.ReplaceAllString(s, "<time>")
	s = pidPattern.ReplaceAllString(s, "pid <pid>")
	s = msPattern.ReplaceAllString(s, "<ms>")
	return s
}
