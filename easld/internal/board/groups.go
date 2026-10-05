package board

import (
	"sort"
	"strings"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/route"
)

// GroupRefitCause is the activity log's cause of a group's re-fit.
const GroupRefitCause = "fit to its members"

// fittedFrame is the frame a group has for its current members (arrows and missing members
// don't count); ok false when it isn't a group or no member is left.
func (b *Board) fittedFrame(group model.Object) (model.Frame, bool) {
	if group.Type != model.Group {
		return model.Frame{}, false
	}
	spec, ok := route.ParseGroup(group.Props)
	if !ok {
		return model.Frame{}, false
	}
	var rects []route.Rect
	for _, id := range spec.Members {
		m, ok := b.objects[id]
		if !ok || m.Type == model.Arrow || m.ID == group.ID {
			continue
		}
		rects = append(rects, route.RectOf(m.Frame))
	}
	r, ok := spec.FrameAround(rects)
	if !ok {
		return model.Frame{}, false
	}
	return r.Frame(), true
}

func groupMembers(o model.Object) []string {
	spec, ok := route.ParseGroup(o.Props)
	if !ok {
		return nil
	}
	return spec.Members
}

// refitGroups re-bounds every group listing id, recursively, as part of the caller's change.
func (b *Board) refitGroups(id string, actor Actor, caller string, visited map[string]bool) {
	if b.history.replaying {
		return
	}
	if b.refitDeferral > 0 {
		b.pendingRefits = append(b.pendingRefits, refit{id, actor, caller})
		return
	}
	var parents []model.Object
	for _, gid := range b.sortedIDs() {
		g := b.objects[gid]
		if g.Type == model.Group && !visited[g.ID] && contains(groupMembers(g), id) {
			parents = append(parents, g)
		}
	}
	for _, g := range parents {
		frame, ok := b.fittedFrame(g)
		current, exists := b.objects[g.ID]
		if !ok || (exists && frame == current.Frame) {
			continue
		}
		next := map[string]bool{id: true}
		for k := range visited {
			next[k] = true
		}
		_, _ = b.write(g.ID, nil, &frame, nil, nil, caller, actor, GroupRefitCause, next)
	}
}

// deferringRefits holds group re-fits back until body returns, then re-fits each affected
// group once.
func (b *Board) deferringRefits(body func() error) error {
	b.refitDeferral++
	defer func() {
		b.refitDeferral--
		if b.refitDeferral == 0 {
			pending := b.pendingRefits
			b.pendingRefits = nil
			seen := map[string]bool{}
			for _, r := range pending {
				if seen[r.member] {
					continue
				}
				seen[r.member] = true
				b.refitGroups(r.member, r.actor, r.caller, nil)
			}
		}
	}()
	return body()
}

// GroupsContaining is the groups (transitively) listing id, sorted.
func (b *Board) GroupsContaining(id string) []string {
	var found []string
	queue := []string{id}
	for len(queue) > 0 {
		next := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		for _, gid := range b.sortedIDs() {
			g := b.objects[gid]
			if g.Type == model.Group && !contains(found, gid) && contains(groupMembers(g), next) {
				found = append(found, gid)
				queue = append(queue, gid)
			}
		}
	}
	sort.Strings(found)
	return found
}

// --- keys (Board+Keys.swift) ---

// Key is an object's key: its props.key when that is a non-empty string.
func Key(props map[string]any) (string, bool) {
	k, ok := props["key"].(string)
	return k, ok && k != ""
}

func (b *Board) holders(key string) map[string]bool {
	h, ok := b.keyHolders[key]
	if !ok {
		h = map[string]bool{}
		b.keyHolders[key] = h
	}
	return h
}

func (b *Board) reindexKey(id string, old, new map[string]any) {
	before, hadBefore := Key(old)
	after, hasAfter := Key(new)
	if hadBefore == hasAfter && before == after {
		return
	}
	if hadBefore {
		delete(b.keyHolders[before], id)
		if len(b.keyHolders[before]) == 0 {
			delete(b.keyHolders, before)
		}
	}
	if hasAfter {
		b.holders(after)[id] = true
	}
}

func sortedKeys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// CheckKey fails unless props may give object id ("" for one about to be created) its key: a
// non-empty string (or null, which removes it) no other object on the board holds.
func (b *Board) CheckKey(props map[string]any, id string) error {
	value, ok := props["key"]
	if !ok || value == nil {
		return nil
	}
	key, ok := value.(string)
	if !ok || key == "" {
		return InvalidParams("props.key must be a non-empty string")
	}
	for _, holder := range sortedKeys(b.keyHolders[key]) {
		if holder == id {
			continue
		}
		o, ok := b.objects[holder]
		if !ok {
			return nil
		}
		return Conflict("key \"%s\" is held by %s (%s)", key, holder, Describe(o))
	}
	return nil
}

// Holder is the object holding key (ok false when none does); a conflict when two do.
func (b *Board) Holder(key string) (model.Object, bool, error) {
	holders := sortedKeys(b.keyHolders[key])
	if len(holders) == 0 {
		return model.Object{}, false, nil
	}
	if len(holders) > 1 {
		return model.Object{}, false, Conflict("key \"%s\" is held by %s", key, strings.Join(holders, ", "))
	}
	o, ok := b.objects[holders[0]]
	return o, ok, nil
}

// ObjectsWithKeyPrefix is every object whose key starts with prefix, in key order.
func (b *Board) ObjectsWithKeyPrefix(prefix string) []model.Object {
	var keys []string
	for k := range b.keyHolders {
		if strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var out []model.Object
	for _, k := range keys {
		for _, id := range sortedKeys(b.keyHolders[k]) {
			if o, ok := b.objects[id]; ok {
				out = append(out, o)
			}
		}
	}
	return out
}
