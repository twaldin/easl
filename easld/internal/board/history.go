package board

import (
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

// The API has no undo, so the history keeps only what a step needs while it is open: its
// changes, so a failed `atomically` (object.batch, layout ops) reverts exactly what it did
// (UndoHistory.swift: begin/end, mark/discard, merged updates, bookkeeping never recorded).

type changeKind int

const (
	changeCreated changeKind = iota
	changeUpdated
	changeDeleted
	changeUnstaged
)

type placedMention struct {
	index   int
	mention model.Mention
}

type change struct {
	kind     changeKind
	object   model.Object // created/deleted; updated: after
	before   model.Object // updated
	unstaged []placedMention
}

var terminalBookkeeping = map[string]bool{"lifecycle": true, "agent": true, "title": true}
var followBookkeeping = map[string]bool{"path": true, "range": true, "lastAction": true, "lastChanges": true, "history": true}

// bookkeeping is the props of object nobody sets on purpose (UndoHistory.bookkeeping).
func bookkeeping(o model.Object) map[string]bool {
	switch o.Type {
	case model.Terminal:
		return terminalBookkeeping
	case model.Browser:
		return map[string]bool{"pageTitle": true}
	case model.Code:
		if _, ok := o.Props["followOf"].(string); ok {
			return followBookkeeping
		}
	case model.Diagram:
		return map[string]bool{"graph": true}
	}
	return nil
}

func propsWithout(props map[string]any, keys map[string]bool) map[string]any {
	if len(keys) == 0 {
		return props
	}
	out := make(map[string]any, len(props))
	for k, v := range props {
		if !keys[k] {
			out[k] = v
		}
	}
	return out
}

func contentProps(o model.Object) map[string]any { return propsWithout(o.Props, bookkeeping(o)) }

func sameContent(a, b model.Object) bool {
	return a.Frame == b.Frame && a.Z == b.Z && a.Parent == b.Parent && model.Equal(anyMap(contentProps(a)), anyMap(contentProps(b)))
}

func anyMap(m map[string]any) any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

// restoring is target's content applied to current, keeping current's bookkeeping props.
func restoring(target, current model.Object) model.Object {
	o := current.Clone()
	o.Frame, o.Z, o.Parent = target.Frame, target.Z, target.Parent
	props := model.Clone(anyMap(contentProps(target))).(map[string]any)
	for k := range bookkeeping(current) {
		if v, ok := current.Props[k]; ok {
			props[k] = model.Clone(v)
		} else {
			delete(props, k)
		}
	}
	o.Props = props
	return o
}

type history struct {
	depth       int
	open        []change
	openUpdates map[string]int
	mergeFloor  int
	replaying   bool
	muted       int
}

func newHistory() *history { return &history{openUpdates: map[string]int{}} }

func (h *history) record(c change) {
	if h.replaying || h.muted > 0 {
		return
	}
	switch c.kind {
	case changeUpdated:
		if sameContent(c.before, c.object) {
			return
		}
		if i, ok := h.openUpdates[c.object.ID]; ok && i >= h.mergeFloor && h.open[i].kind == changeUpdated {
			h.open[i].object = c.object
			return
		}
		h.openUpdates[c.object.ID] = len(h.open)
	case changeCreated, changeDeleted:
		delete(h.openUpdates, c.object.ID)
	}
	h.open = append(h.open, c)
	if h.depth == 0 {
		h.close()
	}
}

func (h *history) begin()       { h.depth++ }
func (h *history) isOpen() bool { return h.depth > 0 }

func (h *history) mark() int {
	h.mergeFloor = len(h.open)
	return len(h.open)
}

func (h *history) discard(from int) []change {
	dropped := append([]change(nil), h.open[from:]...)
	h.open = h.open[:from]
	for id, i := range h.openUpdates {
		if i >= from {
			delete(h.openUpdates, id)
		}
	}
	return dropped
}

func (h *history) end() {
	h.depth--
	if h.depth == 0 {
		h.close()
	}
}

// close ends the step: with no undo, what it recorded is done with.
func (h *history) close() {
	h.openUpdates = map[string]int{}
	h.mergeFloor = 0
	h.open = nil
}

// unrecorded makes changes no one chose (follow tiles, the app's write-backs).
func (b *Board) unrecorded(body func() error) error {
	b.history.muted++
	defer func() { b.history.muted-- }()
	return body()
}

// revert reverts recorded changes, newest first (UndoHistory.revert).
func (b *Board) revert(step []change) {
	b.history.replaying = true
	defer func() { b.history.replaying = false }()
	for i := len(step) - 1; i >= 0; i-- {
		c := step[i]
		switch c.kind {
		case changeCreated:
			b.removeLive(c.object)
		case changeUpdated:
			b.put(c.before)
		case changeDeleted:
			b.put(c.object)
		case changeUnstaged:
			b.restageMentions(c.unstaged)
		}
	}
}

func (b *Board) removeLive(recorded model.Object) {
	live, ok := b.objects[recorded.ID]
	if !ok {
		return
	}
	_ = b.Delete(recorded.ID, "")
	if live.Type == model.Terminal {
		for _, f := range b.FollowTiles(live.ID) {
			_ = b.Delete(f.ID, "")
		}
	}
}

// put brings an object back to target's content: in place when it exists, else re-created with
// the same id and z.
func (b *Board) put(target model.Object) {
	o := target.Clone()
	if current, ok := b.objects[target.ID]; ok {
		o = restoring(target, current)
	}
	o.UpdatedAt = time.Now()
	user := model.Actor{Kind: "user"}
	o.UpdatedBy = &user
	b.restore(o)
}
