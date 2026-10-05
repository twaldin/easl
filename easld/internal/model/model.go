// Package model holds the board's data types, shared by every easld package. It mirrors
// Sources/CanvasCore/Models.swift and the `definitions` of schema/easl-api.json.
//
// JSON values are the encoding/json generic forms: map[string]any, []any, string, float64,
// bool, nil. Props stay generic (each object type defines its own; unknown ones are kept).
package model

import (
	"crypto/rand"
	"fmt"
	"math"
	"sort"
	"time"
)

type (
	ObjectID  = string
	BoardID   = string
	MentionID = string
)

// Crockford base32, as IDs.make.
const idAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// NewID returns a prefixed, time-sortable id: `obj_01J…` (10 time characters, 8 random).
func NewID(prefix string) string {
	value := uint64(time.Now().UnixMilli())
	var t [10]byte
	for i := 9; i >= 0; i-- {
		t[i] = idAlphabet[value&31]
		value >>= 5
	}
	var r [8]byte
	rand.Read(r[:])
	for i := range r {
		r[i] = idAlphabet[int(r[i])%len(idAlphabet)]
	}
	return prefix + "_" + string(t[:]) + string(r[:])
}

// Frame is an object's box in board coordinates; a tile's includes its title bar.
type Frame struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	W float64 `json:"w"`
	H float64 `json:"h"`
}

func (f Frame) MaxX() float64 { return f.X + f.W }
func (f Frame) MaxY() float64 { return f.Y + f.H }

func (f Frame) Intersects(o Frame) bool {
	return f.X < o.MaxX() && o.X < f.MaxX() && f.Y < o.MaxY() && o.Y < f.MaxY()
}

func (f Frame) Contains(o Frame) bool {
	return o.X >= f.X && o.Y >= f.Y && o.MaxX() <= f.MaxX() && o.MaxY() <= f.MaxY()
}

func (f Frame) JSON() map[string]any {
	return map[string]any{"x": f.X, "y": f.Y, "w": f.W, "h": f.H}
}

// Actor is who created or last changed an object: the user, or an agent's terminal tile.
type Actor struct {
	Kind string `json:"kind"` // "user" | "agent"
	Tile string `json:"tile,omitempty"`
}

// ActorFor is the actor a call with this caller (a terminal tile id, or "") acts as.
func ActorFor(caller ObjectID) Actor {
	if caller == "" {
		return Actor{Kind: "user"}
	}
	return Actor{Kind: "agent", Tile: caller}
}

func (a Actor) JSON() map[string]any {
	if a.Kind == "agent" {
		return map[string]any{"kind": "agent", "tile": a.Tile}
	}
	return map[string]any{"kind": "user"}
}

func ActorFromJSON(v any) Actor {
	m, _ := v.(map[string]any)
	if m["kind"] == "agent" {
		tile, _ := m["tile"].(string)
		return Actor{Kind: "agent", Tile: tile}
	}
	return Actor{Kind: "user"}
}

type ObjectType string

const (
	Terminal ObjectType = "terminal"
	Browser  ObjectType = "browser"
	Code     ObjectType = "code"
	Note     ObjectType = "note"
	HTML     ObjectType = "html"
	Changes  ObjectType = "changes"
	Image    ObjectType = "image"
	Diagram  ObjectType = "diagram"
	Shape    ObjectType = "shape"
	Arrow    ObjectType = "arrow"
	Group    ObjectType = "group"
)

var ObjectTypes = []ObjectType{Terminal, Browser, Code, Note, HTML, Changes, Image, Diagram, Shape, Arrow, Group}

func ParseObjectType(s string) (ObjectType, bool) {
	for _, t := range ObjectTypes {
		if string(t) == s {
			return t, true
		}
	}
	return "", false
}

// IsTile: drawn with a title bar (everything but shapes, arrows, groups).
func (t ObjectType) IsTile() bool {
	return t != Shape && t != Arrow && t != Group
}

// KnownProps are the props the type defines (schema TerminalProps … GroupProps), `key` included.
func (t ObjectType) KnownProps() []string {
	own := map[ObjectType][]string{
		Terminal: {"cwd", "command", "zmxSession", "title", "name", "agent", "lifecycle", "follow", "zoom", "worktree", "branch"},
		Browser:  {"url", "title", "pageTitle", "zoom"},
		Code:     {"path", "range", "anchor", "symbol", "caption", "diffBase", "followOf", "lastAction", "lastChanges", "history", "pinnedCommit", "ref", "refSha", "zoom"},
		Note:     {"markdown", "title", "root", "ref", "refSha", "zoom"},
		HTML:     {"html", "title", "root", "ref", "refSha", "allowNetwork", "state", "zoom"},
		Changes:  {"root", "base", "head", "ref", "refSha", "paths", "title", "reviewed", "viewed", "zoom"},
		Image:    {"path", "caption", "title"},
		Diagram:  {"kind", "path", "symbol", "line", "direction", "depth", "expanded", "title", "graph", "zoom"},
		Shape:    {"kind", "text", "points", "color", "fill", "textSize"},
		Arrow:    {"from", "to", "relation", "label", "color", "route"},
		Group:    {"members", "title", "color", "padding", "flow"},
	}[t]
	out := append(append([]string{}, own...), "key")
	sort.Strings(out)
	return out
}

// UnknownPropWarnings: one warning per prop the type doesn't define, in key order
// (ObjectType.unknownPropWarnings).
func (t ObjectType) UnknownPropWarnings(props any) []string {
	m, _ := props.(map[string]any)
	known := t.KnownProps()
	isKnown := map[string]bool{}
	for _, k := range known {
		isKnown[k] = true
	}
	var keys []string
	for k := range m {
		if !isKnown[k] {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var out []string
	for _, k := range keys {
		list := ""
		for i, p := range known {
			if i > 0 {
				list += ", "
			}
			list += p
		}
		out = append(out, fmt.Sprintf("unknown prop %q for %s (kept, but nothing reads it; %s props: %s)", k, t, t, list))
	}
	return out
}

// DefaultSize is the frame size a new object gets without one (Board.defaultSize).
func DefaultSize(t ObjectType) (w, h float64) {
	switch t {
	case Terminal:
		return 1000, 620
	case Browser:
		return 1000, 726
	case Code:
		return 640, 446
	case Note:
		return 280, 266
	case HTML:
		return 640, 506
	case Changes:
		return 820, 620
	case Image:
		return 640, 506
	case Diagram:
		return 760, 480
	case Shape:
		return 160, 100
	}
	return 0, 0
}

// Object is a CanvasObject.
type Object struct {
	ID        ObjectID
	Type      ObjectType
	Frame     Frame
	Z         float64
	Rev       int
	Parent    ObjectID // "" for none
	CreatedBy Actor
	UpdatedBy *Actor
	CreatedAt time.Time
	UpdatedAt time.Time
	Props     map[string]any
}

// Clone copies the object deeply (props included), so a copy can be changed freely.
func (o Object) Clone() Object {
	c := o
	c.Props, _ = Clone(o.Props).(map[string]any)
	if c.Props == nil {
		c.Props = map[string]any{}
	}
	if o.UpdatedBy != nil {
		u := *o.UpdatedBy
		c.UpdatedBy = &u
	}
	return c
}

// referenceDate is Foundation's reference date: the API encodes dates as seconds since it
// (Swift JSONEncoder's default strategy), the board file as ISO 8601.
var referenceDate = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

// APITime encodes a time as the API does: seconds since 2001-01-01, fractional.
func APITime(t time.Time) float64 {
	return float64(t.Sub(referenceDate).Nanoseconds()) / 1e9
}

// FileTime encodes a time as the board file does: ISO 8601 to the second, UTC.
func FileTime(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

func parseFileTime(v any) time.Time {
	s, _ := v.(string)
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t
	}
	if f, ok := v.(float64); ok {
		return referenceDate.Add(time.Duration(f * 1e9))
	}
	return time.Time{}
}

func (o Object) encode(timeOf func(time.Time) any) map[string]any {
	m := map[string]any{
		"id": o.ID, "type": string(o.Type), "frame": o.Frame.JSON(), "z": o.Z, "rev": float64(o.Rev),
		"createdBy": o.CreatedBy.JSON(), "createdAt": timeOf(o.CreatedAt), "updatedAt": timeOf(o.UpdatedAt),
		"props": Clone(o.Props),
	}
	if o.Props == nil {
		m["props"] = map[string]any{}
	}
	if o.Parent != "" {
		m["parent"] = o.Parent
	}
	if o.UpdatedBy != nil {
		m["updatedBy"] = o.UpdatedBy.JSON()
	}
	return m
}

// APIJSON is the object as API results and events carry it.
func (o Object) APIJSON() map[string]any {
	return o.encode(func(t time.Time) any { return APITime(t) })
}

// FileJSON is the object as the board file stores it.
func (o Object) FileJSON() map[string]any {
	return o.encode(func(t time.Time) any { return FileTime(t) })
}

// ObjectFromJSON decodes a stored (or API-shaped) object.
func ObjectFromJSON(v any) (Object, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return Object{}, fmt.Errorf("object is not a JSON object")
	}
	id, _ := m["id"].(string)
	typ, ok := ParseObjectType(fmt.Sprint(m["type"]))
	if id == "" || !ok {
		return Object{}, fmt.Errorf("object needs an id and a known type")
	}
	o := Object{ID: id, Type: typ, CreatedBy: ActorFromJSON(m["createdBy"])}
	o.Frame = FrameFromJSON(m["frame"])
	o.Z, _ = m["z"].(float64)
	if r, ok := m["rev"].(float64); ok {
		o.Rev = int(r)
	} else {
		o.Rev = 1
	}
	o.Parent, _ = m["parent"].(string)
	if u, ok := m["updatedBy"]; ok && u != nil {
		a := ActorFromJSON(u)
		o.UpdatedBy = &a
	}
	o.CreatedAt = parseFileTime(m["createdAt"])
	o.UpdatedAt = parseFileTime(m["updatedAt"])
	o.Props, _ = Clone(m["props"]).(map[string]any)
	if o.Props == nil {
		o.Props = map[string]any{}
	}
	return o, nil
}

func FrameFromJSON(v any) Frame {
	m, _ := v.(map[string]any)
	num := func(k string) float64 { f, _ := m[k].(float64); return f }
	return Frame{X: num("x"), Y: num("y"), W: num("w"), H: num("h")}
}

// LineRange is a 1-based inclusive line span.
type LineRange struct {
	Start int `json:"start"`
	End   int `json:"end"`
}

func (r LineRange) JSON() map[string]any {
	return map[string]any{"start": float64(r.Start), "end": float64(r.End)}
}

// LineRangeFromJSON decodes {start, end}; ok is false when either is missing or not an integer.
func LineRangeFromJSON(v any) (LineRange, bool) {
	m, _ := v.(map[string]any)
	s, ok1 := Int(m["start"])
	e, ok2 := Int(m["end"])
	return LineRange{Start: s, End: e}, ok1 && ok2
}

// Mention is a staged tray item. Target stays generic JSON (schema MentionTarget: kind object,
// code, dom, terminal, group, image, note, console), encoded exactly as received after
// validation.
type Mention struct {
	ID       MentionID
	Target   map[string]any
	Label    string
	StagedAt time.Time
	Edited   bool
}

func (m Mention) encode(timeOf func(time.Time) any) map[string]any {
	return map[string]any{"id": m.ID, "target": Clone(m.Target), "label": m.Label, "stagedAt": timeOf(m.StagedAt), "edited": m.Edited}
}

func (m Mention) APIJSON() map[string]any {
	return m.encode(func(t time.Time) any { return APITime(t) })
}

func (m Mention) FileJSON() map[string]any {
	return m.encode(func(t time.Time) any { return FileTime(t) })
}

func MentionFromJSON(v any) (Mention, bool) {
	m, _ := v.(map[string]any)
	id, _ := m["id"].(string)
	target, _ := m["target"].(map[string]any)
	if id == "" || target == nil {
		return Mention{}, false
	}
	label, _ := m["label"].(string)
	edited, _ := m["edited"].(bool)
	return Mention{ID: id, Target: target, Label: label, StagedAt: parseFileTime(m["stagedAt"]), Edited: edited}, true
}

// MentionObjects are the objects a mention target depends on; deleting any removes the mention.
func MentionObjects(target map[string]any) []ObjectID {
	if target["kind"] == "group" {
		var out []ObjectID
		list, _ := target["objects"].([]any)
		for _, x := range list {
			if s, ok := x.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	if s, ok := target["object"].(string); ok {
		return []ObjectID{s}
	}
	return nil
}

// Lifecycle states an agent reports.
var LifecycleStates = []string{"working", "blocked", "idle", "done", "unknown"}

// Event is one board event as events.subscribe delivers it ({event, board, data}).
type Event struct {
	Name string
	Data any
}

// --- generic JSON helpers ---

// Clone deep-copies a generic JSON value.
func Clone(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			out[k] = Clone(e)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = Clone(e)
		}
		return out
	default:
		return v
	}
}

// Merge is the shallow merge object.update uses (JSONValue.merging): keys in patch replace
// keys in base, a null deletes; a non-object on either side yields patch.
func Merge(base, patch any) any {
	b, ok1 := base.(map[string]any)
	p, ok2 := patch.(map[string]any)
	if !ok1 || !ok2 {
		return Clone(patch)
	}
	out := Clone(b).(map[string]any)
	for k, v := range p {
		if v == nil {
			delete(out, k)
		} else {
			out[k] = Clone(v)
		}
	}
	return out
}

// Int reads an integral JSON number (JSONValue.int: a number with no fractional part).
func Int(v any) (int, bool) {
	f, ok := v.(float64)
	if !ok || f != math.Trunc(f) || math.IsInf(f, 0) {
		return 0, false
	}
	return int(f), true
}

// Equal compares two generic JSON values.
func Equal(a, b any) bool {
	switch x := a.(type) {
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, v := range x {
			w, ok := y[k]
			if !ok || !Equal(v, w) {
				return false
			}
		}
		return true
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !Equal(x[i], y[i]) {
				return false
			}
		}
		return true
	default:
		return a == b
	}
}
