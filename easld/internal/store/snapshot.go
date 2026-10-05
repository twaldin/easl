package store

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

// Format is the on-disk format Board.snapshot writes. 2: a tile's frame is its whole drawn box,
// title bar included (format 1 stored the body below the title bar).
const Format = 2

// Snapshot is the serializable board state BoardStore persists (BoardSnapshot in Board.swift).
// Optional parts are nil when absent, so older board files load and are written back as they
// were.
type Snapshot struct {
	// Format is nil in boards saved before tile frames included the title bar (format 1).
	Format   *int
	ID       string
	Root     string
	Revision int
	Objects  []model.Object
	// Tray is nil when absent (older files); the board always writes it.
	Tray         []model.Mention
	HasTray      bool
	Attention    []Attention
	PromptTarget *PromptTargetState
	FinalAnswers map[string]string
	TurnErrors   map[string]string
	LifecycleSeq map[string]int
	Repo         *RepoRecord
}

// Attention is an agent's "look here" marker on one object (Attention.swift).
type Attention struct {
	Object   string
	Message  *string
	RaisedBy *string
	RaisedAt time.Time
	// EarlierTurn: its agent has started a later turn since; nil while the raising turn is current.
	EarlierTurn *bool
}

// PromptTargetState is what the prompt target rule remembers (PromptTarget.State).
type PromptTargetState struct {
	FocusOrder []string
	Chosen     string // "" for none
}

// RepoRecord is the repository a board is for and the worktrees it has seen (RepoBoards.swift).
type RepoRecord struct {
	CommonDir string
	Worktrees []WorktreeRecord
	// Merged: legacy per-branch boards merged into this one; nil when absent.
	Merged []string
}

type WorktreeRecord struct {
	Path   string
	Branch *string
	Region string // "" for none
}

// --- encoding ---

func (a Attention) json(timeOf func(time.Time) any) map[string]any {
	m := map[string]any{"object": a.Object, "raisedAt": timeOf(a.RaisedAt)}
	if a.Message != nil {
		m["message"] = *a.Message
	}
	if a.RaisedBy != nil {
		m["raisedBy"] = *a.RaisedBy
	}
	if a.EarlierTurn != nil {
		m["earlierTurn"] = *a.EarlierTurn
	}
	return m
}

func (p PromptTargetState) json() map[string]any {
	order := make([]any, len(p.FocusOrder))
	for i, id := range p.FocusOrder {
		order[i] = id
	}
	m := map[string]any{"focusOrder": order}
	if p.Chosen != "" {
		m["chosen"] = p.Chosen
	}
	return m
}

func (r RepoRecord) json() map[string]any {
	worktrees := make([]any, len(r.Worktrees))
	for i, w := range r.Worktrees {
		e := map[string]any{"path": w.Path}
		if w.Branch != nil {
			e["branch"] = *w.Branch
		}
		if w.Region != "" {
			e["region"] = w.Region
		}
		worktrees[i] = e
	}
	m := map[string]any{"commonDir": r.CommonDir, "worktrees": worktrees}
	if r.Merged != nil {
		merged := make([]any, len(r.Merged))
		for i, id := range r.Merged {
			merged[i] = id
		}
		m["merged"] = merged
	}
	return m
}

// JSON is the snapshot as the board file holds it (dates ISO 8601).
func (s *Snapshot) JSON() map[string]any {
	file := func(t time.Time) any { return model.FileTime(t) }
	objects := make([]any, len(s.Objects))
	for i, o := range s.Objects {
		objects[i] = o.FileJSON()
	}
	m := map[string]any{"id": s.ID, "root": s.Root, "revision": float64(s.Revision), "objects": objects}
	if s.Format != nil {
		m["format"] = float64(*s.Format)
	}
	if s.HasTray {
		tray := make([]any, len(s.Tray))
		for i, t := range s.Tray {
			tray[i] = t.FileJSON()
		}
		m["tray"] = tray
	}
	if s.Attention != nil {
		list := make([]any, len(s.Attention))
		for i, a := range s.Attention {
			list[i] = a.json(file)
		}
		m["attention"] = list
	}
	if s.PromptTarget != nil {
		m["promptTarget"] = s.PromptTarget.json()
	}
	if s.FinalAnswers != nil {
		m["finalAnswers"] = stringMap(s.FinalAnswers)
	}
	if s.TurnErrors != nil {
		m["turnErrors"] = stringMap(s.TurnErrors)
	}
	if s.LifecycleSeq != nil {
		seq := map[string]any{}
		for k, v := range s.LifecycleSeq {
			seq[k] = float64(v)
		}
		m["lifecycleSeq"] = seq
	}
	if s.Repo != nil {
		m["repo"] = s.Repo.json()
	}
	return m
}

func stringMap(in map[string]string) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

// Encode is the board file's bytes, as BoardStore.encoder writes them (sortedKeys, ISO 8601);
// a NonFinite error when a number is NaN or infinite.
func (s *Snapshot) Encode() ([]byte, error) {
	return EncodeSwift(s.JSON(), false, true)
}

// --- decoding ---

// decodeError mirrors a failed Codable decode: the whole snapshot is unreadable.
func decodeError(format string, args ...any) error {
	return fmt.Errorf("board file: "+format, args...)
}

// DecodeSnapshot reads a board file as BoardStore.decoder does: every required field present
// with its type, or the whole file is unreadable.
func DecodeSnapshot(data []byte) (*Snapshot, error) {
	var raw any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	m, ok := raw.(map[string]any)
	if !ok {
		return nil, decodeError("not an object")
	}
	s := &Snapshot{}
	if v, present := m["format"]; present && v != nil {
		f, ok := intOf(v)
		if !ok {
			return nil, decodeError("format is not an integer")
		}
		s.Format = &f
	}
	if s.ID, ok = m["id"].(string); !ok {
		return nil, decodeError("missing id")
	}
	if s.Root, ok = m["root"].(string); !ok {
		return nil, decodeError("missing root")
	}
	if s.Revision, ok = intOf(m["revision"]); !ok {
		return nil, decodeError("missing revision")
	}
	list, ok := m["objects"].([]any)
	if !ok {
		return nil, decodeError("missing objects")
	}
	for i, v := range list {
		o, err := decodeObject(v)
		if err != nil {
			return nil, decodeError("objects[%d]: %v", i, err)
		}
		s.Objects = append(s.Objects, o)
	}
	if v, present := m["tray"]; present && v != nil {
		items, ok := v.([]any)
		if !ok {
			return nil, decodeError("tray is not an array")
		}
		s.HasTray = true
		s.Tray = []model.Mention{}
		for i, item := range items {
			men, err := decodeMention(item)
			if err != nil {
				return nil, decodeError("tray[%d]: %v", i, err)
			}
			s.Tray = append(s.Tray, men)
		}
	}
	if v, present := m["attention"]; present && v != nil {
		items, ok := v.([]any)
		if !ok {
			return nil, decodeError("attention is not an array")
		}
		s.Attention = []Attention{}
		for i, item := range items {
			a, err := decodeAttention(item)
			if err != nil {
				return nil, decodeError("attention[%d]: %v", i, err)
			}
			s.Attention = append(s.Attention, a)
		}
	}
	if v, present := m["promptTarget"]; present && v != nil {
		p, ok := v.(map[string]any)
		order, ok2 := p["focusOrder"].([]any)
		if !ok || !ok2 {
			return nil, decodeError("promptTarget needs focusOrder")
		}
		state := &PromptTargetState{FocusOrder: []string{}}
		for _, id := range order {
			sid, ok := id.(string)
			if !ok {
				return nil, decodeError("promptTarget.focusOrder holds a non-string")
			}
			state.FocusOrder = append(state.FocusOrder, sid)
		}
		if c, present := p["chosen"]; present && c != nil {
			if state.Chosen, ok = c.(string); !ok {
				return nil, decodeError("promptTarget.chosen is not a string")
			}
		}
		s.PromptTarget = state
	}
	var err error
	if s.FinalAnswers, err = decodeStringMap(m, "finalAnswers"); err != nil {
		return nil, err
	}
	if s.TurnErrors, err = decodeStringMap(m, "turnErrors"); err != nil {
		return nil, err
	}
	if v, present := m["lifecycleSeq"]; present && v != nil {
		seq, ok := v.(map[string]any)
		if !ok {
			return nil, decodeError("lifecycleSeq is not an object")
		}
		s.LifecycleSeq = map[string]int{}
		for k, x := range seq {
			n, ok := intOf(x)
			if !ok {
				return nil, decodeError("lifecycleSeq.%s is not an integer", k)
			}
			s.LifecycleSeq[k] = n
		}
	}
	if v, present := m["repo"]; present && v != nil {
		r, err := decodeRepo(v)
		if err != nil {
			return nil, err
		}
		s.Repo = r
	}
	return s, nil
}

func decodeStringMap(m map[string]any, key string) (map[string]string, error) {
	v, present := m[key]
	if !present || v == nil {
		return nil, nil
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, decodeError("%s is not an object", key)
	}
	out := map[string]string{}
	for k, x := range obj {
		s, ok := x.(string)
		if !ok {
			return nil, decodeError("%s.%s is not a string", key, k)
		}
		out[k] = s
	}
	return out, nil
}

// intOf decodes an Int as JSONDecoder does: a number with no fractional part.
func intOf(v any) (int, bool) { return model.Int(v) }

func decodeTime(v any) (time.Time, bool) {
	s, ok := v.(string)
	if !ok {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, s)
	return t, err == nil
}

func decodeObject(v any) (model.Object, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return model.Object{}, fmt.Errorf("not an object")
	}
	if _, ok := m["id"].(string); !ok {
		return model.Object{}, fmt.Errorf("missing id")
	}
	typ, _ := m["type"].(string)
	if _, ok := model.ParseObjectType(typ); !ok {
		return model.Object{}, fmt.Errorf("unknown type %q", typ)
	}
	frame, ok := m["frame"].(map[string]any)
	if !ok {
		return model.Object{}, fmt.Errorf("missing frame")
	}
	for _, k := range []string{"x", "y", "w", "h"} {
		if _, ok := frame[k].(float64); !ok {
			return model.Object{}, fmt.Errorf("frame.%s is not a number", k)
		}
	}
	if _, ok := m["z"].(float64); !ok {
		return model.Object{}, fmt.Errorf("missing z")
	}
	if _, ok := intOf(m["rev"]); !ok {
		return model.Object{}, fmt.Errorf("missing rev")
	}
	if p, present := m["parent"]; present && p != nil {
		if _, ok := p.(string); !ok {
			return model.Object{}, fmt.Errorf("parent is not a string")
		}
	}
	if err := checkActor(m["createdBy"]); err != nil {
		return model.Object{}, fmt.Errorf("createdBy: %v", err)
	}
	if u, present := m["updatedBy"]; present && u != nil {
		if err := checkActor(u); err != nil {
			return model.Object{}, fmt.Errorf("updatedBy: %v", err)
		}
	}
	for _, k := range []string{"createdAt", "updatedAt"} {
		if _, ok := decodeTime(m[k]); !ok {
			return model.Object{}, fmt.Errorf("%s is not an ISO 8601 date", k)
		}
	}
	if _, present := m["props"]; !present {
		return model.Object{}, fmt.Errorf("missing props")
	}
	return model.ObjectFromJSON(m)
}

func checkActor(v any) error {
	m, ok := v.(map[string]any)
	if !ok {
		return fmt.Errorf("not an object")
	}
	kind, ok := m["kind"].(string)
	if !ok {
		return fmt.Errorf("missing kind")
	}
	if kind == "agent" {
		if _, ok := m["tile"].(string); !ok {
			return fmt.Errorf("agent without tile")
		}
	}
	return nil
}

var mentionKinds = map[string]bool{"object": true, "code": true, "dom": true, "terminal": true, "group": true, "image": true, "note": true, "console": true}

func decodeMention(v any) (model.Mention, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return model.Mention{}, fmt.Errorf("not an object")
	}
	target, ok := m["target"].(map[string]any)
	if !ok {
		return model.Mention{}, fmt.Errorf("missing target")
	}
	if kind, _ := target["kind"].(string); !mentionKinds[kind] {
		return model.Mention{}, fmt.Errorf("unknown mention kind %v", target["kind"])
	}
	if _, ok := m["label"].(string); !ok {
		return model.Mention{}, fmt.Errorf("missing label")
	}
	if _, ok := decodeTime(m["stagedAt"]); !ok {
		return model.Mention{}, fmt.Errorf("stagedAt is not an ISO 8601 date")
	}
	men, ok := model.MentionFromJSON(m)
	if !ok {
		return men, fmt.Errorf("missing id")
	}
	return men, nil
}

func decodeAttention(v any) (Attention, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return Attention{}, fmt.Errorf("not an object")
	}
	a := Attention{}
	if a.Object, ok = m["object"].(string); !ok {
		return a, fmt.Errorf("missing object")
	}
	if a.RaisedAt, ok = decodeTime(m["raisedAt"]); !ok {
		return a, fmt.Errorf("raisedAt is not an ISO 8601 date")
	}
	if s, ok := m["message"].(string); ok {
		a.Message = &s
	}
	if s, ok := m["raisedBy"].(string); ok {
		a.RaisedBy = &s
	}
	if b, ok := m["earlierTurn"].(bool); ok {
		a.EarlierTurn = &b
	}
	return a, nil
}

func decodeRepo(v any) (*RepoRecord, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, decodeError("repo is not an object")
	}
	r := &RepoRecord{Worktrees: []WorktreeRecord{}}
	if r.CommonDir, ok = m["commonDir"].(string); !ok {
		return nil, decodeError("repo needs commonDir")
	}
	list, ok := m["worktrees"].([]any)
	if !ok {
		return nil, decodeError("repo needs worktrees")
	}
	for _, item := range list {
		w, ok := item.(map[string]any)
		path, ok2 := w["path"].(string)
		if !ok || !ok2 {
			return nil, decodeError("repo worktree needs path")
		}
		rec := WorktreeRecord{Path: path}
		if b, ok := w["branch"].(string); ok {
			rec.Branch = &b
		}
		rec.Region, _ = w["region"].(string)
		r.Worktrees = append(r.Worktrees, rec)
	}
	if v, present := m["merged"]; present && v != nil {
		items, ok := v.([]any)
		if !ok {
			return nil, decodeError("repo.merged is not an array")
		}
		r.Merged = []string{}
		for _, x := range items {
			if s, ok := x.(string); ok {
				r.Merged = append(r.Merged, s)
			}
		}
	}
	return r, nil
}

// SortObjects orders objects as Board.snapshot does: by z (ties by id, so files are stable).
func SortObjects(list []model.Object) {
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].Z != list[j].Z {
			return list[i].Z < list[j].Z
		}
		return list[i].ID < list[j].ID
	})
}
