package conformance

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

// normalizer rewrites what differs between two correct servers (or two runs of one) into stable
// tokens, keeping the relations that matter:
//
//   - ids become `<obj:1>`, `<obj:2>`, … (the prefix before `_`, numbered by first appearance),
//     so "the same object" stays the same token and two objects stay apart. An id is a value of
//     an id field (idKeys) or a key of an id-keyed map (idMaps) that has the schema's id shape
//     (`definitions/Id`: a lowercase prefix, `_`, letters and digits), whatever generator made
//     it; once known, it is replaced wherever it appears in text (summaries, messages, refs);
//   - revisions become `<rev:n>` tokens by value, per kind (an object's `rev`; a board revision:
//     `revision`, `cursor`, `since`, an activity entry's `rev`), so equal revisions stay equal and
//     a write that should have moved one shows (`board.history`'s `cursor` and `seq` count log
//     entries from the board's opening and stay as they are);
//   - valid timestamps keep their wire type: `<time:number>` (seconds since 2001-01-01, the API's
//     dates) or `<time:iso>` (an ISO 8601 string: activity entries, board files). A value under
//     a time key that is neither, or names a moment before 2020 or in the future, stays as it is
//     and so differs from the recorded token;
//   - absolute paths become `<root>` (the scenario's directory), `<run>` and `~`, process ids
//     `<pid>`.
//
// The walks visit object keys in sorted order, so numbering is the same on every run.
type normalizer struct {
	tokens map[string]string
	counts map[string]int
	revs   map[string]map[string]string
	paths  []pathSubst
	// The method of the record being normalised.
	method string
	// Every known id as a whole word, rebuilt when one is learnt (nil: rebuild).
	idWords *regexp.Regexp
	// Valid moments lie in [earliestTime, latest].
	latest time.Time
}

type pathSubst struct{ from, to string }

func newNormalizer(paths []pathSubst) *normalizer {
	// Longest first: the scenario root sits inside the temp directory.
	sort.SliceStable(paths, func(i, j int) bool { return len(paths[i].from) > len(paths[j].from) })
	return &normalizer{tokens: map[string]string{}, counts: map[string]int{}, revs: map[string]map[string]string{}, paths: paths,
		latest: time.Now().Add(24 * time.Hour)}
}

// alias pins a value (the scenario's board id) to a fixed token.
func (n *normalizer) alias(value, token string) {
	if value != "" {
		n.tokens[value] = token
		n.idWords = nil
	}
}

var (
	// The schema's id (`definitions/Id`).
	idShape     = regexp.MustCompile(`^[a-z]+_[0-9A-Za-z]+$`)
	timePattern = regexp.MustCompile(`\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})\b`)
	pidPattern  = regexp.MustCompile(`\bpid \d+`)
	// Elapsed times in prose ("3s ago", "120 ms").
	msPattern = regexp.MustCompile(`\b\d+(\.\d+)? ?ms\b`)
)

// idKeys are the fields whose string values (or arrays of them, nested too) are ids: every
// property schema/easl-api.json types `#/definitions/Id` (TestIDKeysCoverTheSchema keeps the
// two in step), and the id references the app sends that the schema leaves untyped.
var idKeys = map[string]bool{
	// Typed in the schema.
	"ack": true, "arrow": true, "arrows": true, "board": true, "boards": true, "caller": true, "changed": true, "cleared": true, "client": true,
	"crosses": true, "enteredGroup": true, "exclude": true, "focused": true, "followOf": true, "id": true, "ids": true, "lines": true,
	"members": true, "message": true, "near": true, "object": true, "objects": true, "overlaps": true, "parent": true,
	"promptTarget": true, "region": true, "regions": true, "selection": true, "target": true, "tile": true,
	// Untyped on the wire: an object's graph (arrowsIn/arrowsOut ends, enclosure), the terminal a
	// follow tile follows, who raised an attention marker.
	"from": true, "to": true, "enclosedBy": true, "encloses": true, "follow": true, "raisedBy": true,
}

// idMaps are maps keyed by id (layout results' `frames`).
var idMaps = map[string]bool{"frames": true}

// Keys whose numeric value is a revision, by the revision space it counts in.
var revisionKeys = map[string]string{
	"rev":      "rev",
	"revision": "board",
	"since":    "board",
	"boardRev": "board",
}

// Keys whose value is a moment (schema date-time fields, and the app's API dates).
var timeKeys = map[string]bool{
	"at": true, "computedAt": true, "createdAt": true, "finishedAt": true, "queuedAt": true, "raisedAt": true,
	"releasedAt": true, "stagedAt": true, "submittedAt": true, "time": true, "updatedAt": true,
}

// The API's dates count seconds from here (Foundation's reference date).
var referenceDate = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

// No moment a scenario sees is older (the fixed git commits are dated 2026).
var earliestTime = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

// learnIDs numbers the ids in a record's parts, in order, before any of them is rewritten, so an
// id mentioned in text ahead of its field (an entry's `actor` before its `id`) gets its token.
func (n *normalizer) learnIDs(parts ...any) {
	for _, p := range parts {
		n.collectIDs(p, false)
	}
}

func (n *normalizer) collectIDs(v any, isID bool) {
	switch x := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if m, ok := x[k].(map[string]any); ok && idMaps[k] {
				ids := make([]string, 0, len(m))
				for id := range m {
					ids = append(ids, id)
				}
				sort.Strings(ids)
				for _, id := range ids {
					n.learn(id)
				}
			}
			n.collectIDs(x[k], idKeys[k])
		}
	case []any:
		for _, e := range x {
			n.collectIDs(e, isID)
		}
	case []map[string]any:
		for _, e := range x {
			n.collectIDs(e, isID)
		}
	case string:
		if isID {
			n.learn(x)
		}
	}
}

func (n *normalizer) learn(id string) {
	if _, ok := n.tokens[id]; ok || !idShape.MatchString(id) {
		return
	}
	prefix := id[:strings.IndexByte(id, '_')]
	n.counts[prefix]++
	n.tokens[id] = fmt.Sprintf("<%s:%d>", prefix, n.counts[prefix])
	n.idWords = nil
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
		if t, ok := n.moment(v); ok {
			return t
		}
		if s, ok := v.(string); ok {
			// A malformed time is compared as it is, never rewritten as prose.
			return s
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

// moment is a valid timestamp's token by its wire type; not ok for anything else (an object
// such as layout.check's `at` point, or a malformed time, both compared as they are).
func (n *normalizer) moment(v any) (string, bool) {
	switch x := v.(type) {
	case float64:
		// Seconds since the reference date, compared as seconds (NaN fails both bounds).
		if x >= earliestTime.Sub(referenceDate).Seconds() && x <= n.latest.Sub(referenceDate).Seconds() {
			return "<time:number>", true
		}
	case string:
		if t, err := time.Parse(time.RFC3339Nano, x); err == nil && !t.Before(earliestTime) && !t.After(n.latest) {
			return "<time:iso>", true
		}
	}
	return "", false
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
	if words := n.knownIDs(); words != nil {
		s = words.ReplaceAllStringFunc(s, func(id string) string { return n.tokens[id] })
	}
	s = timePattern.ReplaceAllStringFunc(s, func(m string) string {
		if t, ok := n.moment(m); ok {
			return t
		}
		return m
	})
	s = pidPattern.ReplaceAllString(s, "pid <pid>")
	s = msPattern.ReplaceAllString(s, "<ms>")
	return s
}

// knownIDs matches every id learnt so far as a whole word, longest first (nil: none yet).
func (n *normalizer) knownIDs() *regexp.Regexp {
	if n.idWords != nil || len(n.tokens) == 0 {
		return n.idWords
	}
	ids := make([]string, 0, len(n.tokens))
	for id := range n.tokens {
		ids = append(ids, regexp.QuoteMeta(id))
	}
	sort.Slice(ids, func(i, j int) bool { return len(ids[i]) > len(ids[j]) || len(ids[i]) == len(ids[j]) && ids[i] < ids[j] })
	n.idWords = regexp.MustCompile(`\b(?:` + strings.Join(ids, "|") + `)\b`)
	return n.idWords
}
