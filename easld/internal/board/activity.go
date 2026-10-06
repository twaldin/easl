package board

import (
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

// Actor is who did something, as the activity log names them: "user", "system", "agent:<tile>".
type Actor string

const (
	UserActor   Actor = "user"
	SystemActor Actor = "system"
)

// AgentActor is the actor a terminal tile's agent is.
func AgentActor(tile string) Actor { return Actor("agent:" + tile) }

// ActorFor is the actor a call with this caller ("" for none) acts as.
func ActorFor(caller string) Actor {
	if caller == "" {
		return UserActor
	}
	return AgentActor(caller)
}

// Entry kinds of the activity log.
const (
	KindCreated   = "created"
	KindUpdated   = "updated"
	KindDeleted   = "deleted"
	KindViewport  = "viewport"
	KindSelection = "selection"
	KindFollow    = "follow"
	KindRestart   = "restart"
	// KindMessage is a peer message that bounced, its receiver's agent gone before taking it.
	KindMessage = "message"
)

// EntryKinds are every kind board.history filters by.
var EntryKinds = []string{KindCreated, KindUpdated, KindDeleted, KindViewport, KindSelection, KindFollow, KindRestart, KindMessage}

// Entry is one activity log entry (ActivityEntry).
type Entry struct {
	Seq     int
	Rev     int
	At      time.Time
	Actor   Actor
	Kind    string
	ID      string // "" for none
	Type    model.ObjectType
	Summary string
	Cause   string
}

func (e Entry) JSON() map[string]any {
	m := map[string]any{
		"seq": float64(e.Seq), "rev": float64(e.Rev), "at": model.FileTime(e.At),
		"actor": string(e.Actor), "kind": e.Kind, "summary": e.Summary,
	}
	if e.ID != "" {
		m["id"] = e.ID
	}
	if e.Type != "" {
		m["type"] = string(e.Type)
	}
	if e.Cause != "" {
		m["cause"] = e.Cause
	}
	return m
}

// ActivityLog keeps a board's newest `capacity` entries in memory (`board.history`). The API
// server has no viewport or selection of its own, so only object changes, follow re-aims and
// starts are logged.
type ActivityLog struct {
	capacity int
	clock    func() time.Time
	ring     []Entry
	head     int
	cursor   int
}

const DefaultActivityCapacity = 2000

func NewActivityLog(capacity int, clock func() time.Time) *ActivityLog {
	if capacity < 1 {
		capacity = 1
	}
	if clock == nil {
		clock = time.Now
	}
	return &ActivityLog{capacity: capacity, clock: clock}
}

func (l *ActivityLog) Capacity() int { return l.capacity }
func (l *ActivityLog) Cursor() int   { return l.cursor }

// Entries are oldest first.
func (l *ActivityLog) Entries() []Entry {
	if len(l.ring) < l.capacity {
		return append([]Entry(nil), l.ring...)
	}
	return append(append([]Entry(nil), l.ring[l.head:]...), l.ring[:l.head]...)
}

func (l *ActivityLog) Record(kind string, actor Actor, rev int, id string, typ model.ObjectType, summary, cause string) {
	l.append(Entry{Rev: rev, At: l.clock(), Actor: actor, Kind: kind, ID: id, Type: typ, Summary: summary, Cause: cause})
}

func (l *ActivityLog) append(e Entry) {
	l.cursor++
	e.Seq = l.cursor
	if len(l.ring) < l.capacity {
		l.ring = append(l.ring, e)
	} else {
		l.ring[l.head] = e
		l.head = (l.head + 1) % l.capacity
	}
}

// Amend rewrites a logged entry's summary; false when it has left the ring.
func (l *ActivityLog) Amend(seq int, summary string) bool {
	i, ok := l.ringIndex(seq)
	if !ok {
		return false
	}
	l.ring[i].Summary = summary
	return true
}

// Remove drops a logged entry.
func (l *ActivityLog) Remove(seq int) {
	if _, ok := l.ringIndex(seq); !ok {
		return
	}
	var kept []Entry
	for _, e := range l.Entries() {
		if e.Seq != seq {
			kept = append(kept, e)
		}
	}
	l.ring, l.head = kept, 0
}

func (l *ActivityLog) ringIndex(seq int) (int, bool) {
	n := len(l.ring)
	for offset := range n {
		i := (l.head + n - 1 - offset) % n
		if l.ring[i].Seq == seq {
			return i, true
		}
		if l.ring[i].Seq < seq {
			return 0, false
		}
	}
	return 0, false
}

// Since is a board.history cursor: a seq, or a time.
type Since struct {
	Seq  *int
	Time *time.Time
}

// Page is one board.history answer.
type Page struct {
	Entries   []Entry
	Cursor    int
	Truncated bool
	Restarted bool
}

func (l *ActivityLog) Query(since Since, limit int, kinds map[string]bool) Page {
	all := l.Entries()
	restarted := false
	matching := all
	switch {
	case since.Seq != nil && *since.Seq > l.cursor:
		restarted = true
	case since.Seq != nil:
		i := 0
		for i < len(all) && all[i].Seq <= *since.Seq {
			i++
		}
		matching = all[i:]
	case since.Time != nil:
		i := 0
		for i < len(all) && !all[i].At.After(*since.Time) {
			i++
		}
		matching = all[i:]
	}
	truncated := false
	if since.Seq != nil && !restarted && len(all) > 0 && all[0].Seq > *since.Seq+1 {
		truncated = true
	}
	if since.Time != nil && len(all) > 0 && all[0].Seq > 1 && all[0].At.After(*since.Time) {
		truncated = true
	}
	var filtered []Entry
	for _, e := range matching {
		if kinds == nil || kinds[e.Kind] {
			filtered = append(filtered, e)
		}
	}
	if len(filtered) > limit {
		truncated = true
		filtered = filtered[len(filtered)-max(0, limit):]
	}
	return Page{Entries: filtered, Cursor: l.cursor, Truncated: truncated, Restarted: restarted}
}

// --- summaries ---

func firstLine(text string) string {
	lines := strings.FieldsFunc(text, isNewline)
	if len(lines) == 0 {
		return ""
	}
	return strings.TrimFunc(lines[0], func(r rune) bool { return r == ' ' || r == '\t' || (unicode.IsSpace(r) && !isNewline(r)) })
}

func isNewline(r rune) bool {
	switch r {
	case '\n', '\r', '\v', '\f', 0x85, 0x2028, 0x2029:
		return true
	}
	return false
}

func quoted(text string, present bool) string {
	if !present {
		return ""
	}
	line := firstLine(text)
	if line == "" {
		return ""
	}
	if runes := []rune(line); len(runes) > 40 {
		line = string(runes[:40]) + "…"
	}
	return fmt.Sprintf(" \"%s\"", line)
}

func propString(props map[string]any, key string) (string, bool) {
	s, ok := props[key].(string)
	return s, ok
}

// Describe names an object in one line for summaries: `note "Plan for…"`, `code src/a.ts:10-20`.
func Describe(o model.Object) string {
	p := o.Props
	str := func(k string) string { s, _ := propString(p, k); return s }
	q := func(k string) string { s, ok := propString(p, k); return quoted(s, ok) }
	switch o.Type {
	case model.Code:
		rng := ""
		if r, ok := p["range"].(map[string]any); ok {
			if start, ok := jsonInt(r["start"]); ok {
				end, ok := jsonInt(r["end"])
				if !ok {
					end = start
				}
				rng = fmt.Sprintf(":%d-%d", start, end)
			}
		}
		path, ok := propString(p, "path")
		if !ok {
			path = "?"
		}
		return "code " + path + rng
	case model.Note:
		if t, ok := propString(p, "title"); ok && t != "" {
			return "note" + quoted(t, true)
		}
		return "note" + q("markdown")
	case model.HTML:
		return "html" + q("title")
	case model.Changes:
		return changesName(p) + q("title")
	case model.Image:
		path, ok := propString(p, "path")
		if !ok {
			path = "?"
		}
		return "image " + path + q("title")
	case model.Diagram:
		return "diagram" + quoted(diagramTitle(p), true)
	case model.Question:
		return "question" + q("question")
	case model.Browser:
		return "browser " + str("url")
	case model.Terminal:
		if n, ok := propString(p, "name"); ok {
			return "terminal" + quoted(n, true)
		}
		return "terminal" + q("title")
	case model.Shape:
		return "shape " + str("kind") + q("text")
	case model.Arrow:
		from, to := "point", "point"
		if b, ok := p["from"].(map[string]any); ok {
			if s, ok := b["object"].(string); ok {
				from = s
			}
		}
		if b, ok := p["to"].(map[string]any); ok {
			if s, ok := b["object"].(string); ok {
				to = s
			}
		}
		return "arrow " + from + " → " + to + q("label")
	case model.Group:
		members := 0
		if list, ok := p["members"].([]any); ok {
			members = len(list)
		}
		return fmt.Sprintf("group%s (%d members)", q("name"), members)
	}
	return string(o.Type)
}

// changesName is ChangesSpec.name: `changes vs HEAD`, `changes fm/x vs merge-base`.
func changesName(p map[string]any) string {
	nonEmpty := func(k string) string { s, _ := p[k].(string); return s }
	head, ref := nonEmpty("head"), nonEmpty("ref")
	base := nonEmpty("base")
	if base == "" {
		if head != "" || ref != "" {
			base = "merge-base"
		} else {
			base = "HEAD"
		}
	}
	shown := head
	if shown == "" {
		shown = ref
	}
	if shown != "" {
		shown += " "
	}
	return "changes " + shown + "vs " + base
}

// diagramTitle is DiagramSpec.title.
func diagramTitle(p map[string]any) string {
	if t, ok := p["title"].(string); ok && t != "" {
		return t
	}
	nonEmpty := func(k string) string { s, _ := p[k].(string); return s }
	root := nonEmpty("symbol")
	if root == "" {
		if g, ok := p["graph"].(map[string]any); ok {
			if r, ok := g["root"].(string); ok {
				nodes, _ := g["nodes"].([]any)
				for _, n := range nodes {
					node, _ := n.(map[string]any)
					if node["id"] == r {
						name, _ := node["name"].(string)
						if c, ok := node["container"].(string); ok {
							root = c + "." + name
						} else {
							root = name
						}
						break
					}
				}
			}
		}
	}
	if root == "" {
		if path := nonEmpty("path"); path != "" {
			line := 1
			if l, ok := jsonInt(p["line"]); ok && l >= 1 {
				line = l
			}
			root = fmt.Sprintf("%s:%d", shortPath(path), line)
		}
	}
	if root == "" {
		root = "?"
	}
	switch p["direction"] {
	case "outgoing":
		return "Calls from " + root
	case "both":
		return "Calls around " + root
	}
	return "Callers of " + root
}

// shortPath is PathLabel.short: an absolute path in a git worktree as `<worktree>/<relative>`.
func shortPath(path string) string {
	if !strings.HasPrefix(path, "/") {
		return path
	}
	w := store.Containing(path)
	if w == nil {
		return path
	}
	rel, ok := w.RelativePath(path)
	if !ok {
		return path
	}
	return w.Name() + "/" + rel
}

// Position is a frame as summaries write it: `(0, 0) 280×200`.
func Position(f model.Frame) string {
	return fmt.Sprintf("(%.0f, %.0f) %.0f×%.0f", f.X, f.Y, f.W, f.H)
}

// Changes says what changed between two revisions of an object, ok false when nothing a person
// sees did.
func Changes(before, after model.Object) (string, bool) {
	var parts []string
	if before.Frame.X != after.Frame.X || before.Frame.Y != after.Frame.Y {
		parts = append(parts, fmt.Sprintf("moved (%.0f, %.0f) → (%.0f, %.0f)", before.Frame.X, before.Frame.Y, after.Frame.X, after.Frame.Y))
	}
	if before.Frame.W != after.Frame.W || before.Frame.H != after.Frame.H {
		parts = append(parts, fmt.Sprintf("resized %.0f×%.0f → %.0f×%.0f", before.Frame.W, before.Frame.H, after.Frame.W, after.Frame.H))
	}
	if before.Z != after.Z {
		parts = append(parts, "restacked")
	}
	var skipped map[string]bool
	if before.Type == model.Terminal {
		skipped = terminalBookkeeping
	}
	old, new := propsWithout(before.Props, skipped), propsWithout(after.Props, skipped)
	keys := map[string]bool{}
	for k := range old {
		keys[k] = true
	}
	for k := range new {
		keys[k] = true
	}
	var changed []string
	for k := range keys {
		ov, ok1 := old[k]
		nv, ok2 := new[k]
		if ok1 != ok2 || !model.Equal(ov, nv) {
			changed = append(changed, k)
		}
	}
	sort.Strings(changed)
	if len(changed) > 0 {
		parts = append(parts, "props "+strings.Join(changed, ", "))
	}
	if len(parts) == 0 {
		return "", false
	}
	return strings.Join(parts, "; "), true
}
