package board

import (
	"path/filepath"
	"sort"
	"strings"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

// OpenedFrom: the board was opened from worktree (RepoBoards.swift `opened(from:)`): a linked
// worktree becomes the working worktree and is recorded; the main checkout clears it.
func (b *Board) OpenedFrom(w store.Worktree) {
	if b.Repo == nil || b.Repo.CommonDir != w.CommonDir {
		return
	}
	if w.IsMain() {
		b.workingWorktree = nil
		return
	}
	wt := w
	b.workingWorktree = &wt
	b.recordWorktree(w)
}

func (b *Board) recordWorktree(w store.Worktree) {
	if b.Repo == nil {
		return
	}
	if b.Repo.Record(w.Toplevel, store.BranchOf(w)) {
		b.changed()
	}
}

// RegionFor is the region to show for the worktree the board was opened from.
func (b *Board) RegionFor(w store.Worktree) string {
	if b.Repo == nil {
		return ""
	}
	return b.Repo.Region(store.BranchOf(w), store.Normalized(w.Toplevel), b.objects)
}

// stampingWorktree stamps a new terminal's worktree and branch from its cwd when that lies in
// the board's repository.
func (b *Board) stampingWorktree(props map[string]any) map[string]any {
	delete(props, "worktree")
	delete(props, "branch")
	cwd, ok := props["cwd"].(string)
	if !ok || cwd == "" {
		return props
	}
	stamp, ok := b.worktreeStamp(store.Standardized(b.AbsolutePath(cwd)))
	if !ok {
		return props
	}
	for k, v := range stamp {
		if v != nil {
			props[k] = v
		}
	}
	return props
}

func (b *Board) worktreeStamp(directory string) (map[string]any, bool) {
	if b.Repo == nil {
		return nil, false
	}
	w := store.Containing(directory)
	if w == nil || w.CommonDir != b.Repo.CommonDir {
		return nil, false
	}
	if !w.IsMain() {
		b.recordWorktree(*w)
	}
	var branch any
	if name, ok := w.Branch(); ok {
		branch = name
	}
	return map[string]any{"worktree": store.Normalized(w.Toplevel), "branch": branch}, true
}

// RegionsOfBranch is the groups keyed `branch:<name>`, by id.
func (b *Board) RegionsOfBranch(name string) []string {
	var out []string
	for id, o := range b.objects {
		if o.Type == model.Group && o.Props["key"] == "branch:"+name {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out
}

// ObjectsOfBranch is board.get's `branch` filter: the branch's regions and what they hold,
// objects whose ref is the branch, terminals that started on it, and arrows between those.
func (b *Board) ObjectsOfBranch(name string) map[string]bool {
	found := map[string]bool{}
	pending := b.RegionsOfBranch(name)
	for _, id := range b.sortedIDs() {
		o := b.objects[id]
		if o.Props["ref"] == name || (o.Type == model.Terminal && o.Props["branch"] == name) {
			pending = append(pending, id)
		}
	}
	for len(pending) > 0 {
		id := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if found[id] {
			continue
		}
		found[id] = true
		if o, ok := b.objects[id]; ok && o.Type == model.Group {
			pending = append(pending, groupMembers(o)...)
		}
	}
	for _, a := range b.objects {
		if a.Type != model.Arrow {
			continue
		}
		var ends []string
		for _, k := range []string{"from", "to"} {
			if e, ok := a.Props[k].(map[string]any); ok {
				if s, ok := e["object"].(string); ok {
					ends = append(ends, s)
				}
			}
		}
		all := len(ends) > 0
		for _, e := range ends {
			if !found[e] {
				all = false
			}
		}
		if all {
			found[a.ID] = true
		}
	}
	for id := range found {
		if _, ok := b.objects[id]; !ok {
			delete(found, id)
		}
	}
	return found
}

// --- link roots (LinkRoot.swift) ---

// RefOf is props.ref when set (RefSource.ref(of:)).
func RefOf(props map[string]any) (string, bool) {
	ref := measure.RefOf(props)
	return ref, ref != ""
}

// LinkRoot is the directory a note's or HTML tile's relative paths resolve against
// (Board.linkRoot: with a ref, the board root's place in the worktree that has it checked out).
func (b *Board) LinkRoot(props map[string]any) string { return measure.LinkRoot(props, b.root) }

// CheckLinkRoot: a note or HTML tile's root must be an existing directory in the board's
// repository (or under the board root outside git).
func (b *Board) CheckLinkRoot(value string) error {
	path := store.Standardized(b.AbsolutePath(value))
	if !store.IsDirectory(path) {
		return InvalidParams("root %s is not a directory", value)
	}
	if store.Containing(b.root) != nil {
		if !store.SameRepository(path, b.root) {
			return InvalidParams("root %s is not in this board's repository or one of its worktrees", value)
		}
		return nil
	}
	base := store.Standardized(b.root)
	if path != base && !strings.HasPrefix(path, base+"/") {
		return InvalidParams("root %s is outside the board root", value)
	}
	return nil
}

// WorkingDirectory is where a terminal works: as last read, else props.cwd, else the root.
func (b *Board) WorkingDirectory(terminal string) string {
	if d, ok := b.workingDirectories[terminal]; ok {
		return d
	}
	if cwd, ok := b.objects[terminal].Props["cwd"].(string); ok {
		return cwd
	}
	return b.root
}

// CallerCheckout is the checkout caller works in when that is another worktree of the board's
// repository, at the board root's place in it.
func (b *Board) CallerCheckout(caller string) (string, bool) {
	if o, ok := b.objects[caller]; caller == "" || !ok || o.Type != model.Terminal {
		return "", false
	}
	return store.Counterpart(b.root, b.WorkingDirectory(caller))
}

// InCallersCheckout is props with a caller's relative paths meaning its own checkout when it
// works in another worktree of the board's repository (a question's relative `context` paths
// become absolute there, as a code tile's `path`). existing is the tile's props on a re-aim (nil
// on a create).
func (b *Board) InCallersCheckout(props map[string]any, typ model.ObjectType, caller string, existing map[string]any) map[string]any {
	checkout, ok := b.CallerCheckout(caller)
	if props == nil || !ok {
		return props
	}
	fields := model.Clone(props).(map[string]any)
	base := existing
	if base == nil {
		base = map[string]any{}
	}
	merged, _ := model.Merge(base, props).(map[string]any)
	nonEmpty := func(m map[string]any, k string) bool { s, ok := m[k].(string); return ok && s != "" }
	switch typ {
	case model.Code, model.Image, model.Diagram:
		path, ok := fields["path"].(string)
		if !ok || path == "" || strings.HasPrefix(path, "/") || strings.HasPrefix(path, "~") {
			break
		}
		if typ == model.Code && (nonEmpty(merged, "ref") || nonEmpty(merged, "pinnedCommit")) {
			break
		}
		fields["path"] = store.Standardized(filepath.Join(checkout, path))
	case model.Changes, model.Note, model.HTML:
		if existing != nil {
			break
		}
		if r, ok := fields["root"].(string); ok && r != "" {
			break
		}
		if typ == model.Changes && (nonEmpty(fields, "ref") || nonEmpty(fields, "head")) {
			break
		}
		fields["root"] = checkout
	case model.Question:
		items, ok := fields["context"].([]any)
		if !ok {
			break
		}
		for _, item := range items {
			context, ok := item.(map[string]any)
			path, isPath := context["path"].(string)
			if !ok || !isPath || path == "" || strings.HasPrefix(path, "/") || strings.HasPrefix(path, "~") {
				continue
			}
			context["path"] = store.Standardized(filepath.Join(checkout, path))
		}
	}
	return fields
}

// RecordRefSha writes props.refSha (bookkeeping) while the object still anchors to ref.
func (b *Board) RecordRefSha(id, ref, sha string) {
	before, ok := b.objects[id]
	if !ok {
		return
	}
	if current, ok := RefOf(before.Props); !ok || current != ref || before.Props["refSha"] == sha {
		return
	}
	b.commitBookkeeping(before, map[string]any{"refSha": sha})
}

// Reanchor writes a code tile's range re-found by content and the first line it is anchored by,
// as bookkeeping (Board.reanchor: the tile keeps its range on the code it showed; no rev, undo
// step or log). Only a code tile whose range anchors.
func (b *Board) Reanchor(id string, rng model.LineRange, anchor *string) error {
	before, err := b.Object(id)
	if err != nil {
		return err
	}
	_, follow := before.Props["followOf"].(string)
	pinned, _ := before.Props["pinnedCommit"].(string)
	path, _ := before.Props["path"].(string)
	_, hasStart := TruncInt(asJSONMap(before.Props["range"])["start"])
	if before.Type != model.Code || follow || pinned != "" || path == "" || !hasStart {
		return InvalidParams("only a code tile showing a range, not a follow tile or pinned to a commit, is re-anchored")
	}
	var value any
	if anchor != nil {
		value = *anchor
	}
	b.commitBookkeeping(before, map[string]any{"range": rng.JSON(), "anchor": value})
	return nil
}

func asJSONMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

// reanchorShown is the code tile's own write-back when an update re-aims its range or anchor
// while it shows the same file (CodeTile.update → reanchor): the app's tile reacts to the
// update before it is broadcast, so its bookkeeping write is announced first. A tile that must
// load another file first re-anchors after its load (the router's post-call reanchor).
func (b *Board) reanchorShown(before, after model.Object) {
	if after.Type != model.Code || (jsonEqualKey(before.Props, after.Props, "range") && jsonEqualKey(before.Props, after.Props, "anchor")) {
		return
	}
	for _, k := range []string{"path", "diffBase", "pinnedCommit", "ref"} {
		if !jsonEqualKey(before.Props, after.Props, k) {
			return
		}
	}
	if rng, anchor, changed := measure.Reanchor(after.Props, b.root); changed {
		_ = b.Reanchor(after.ID, rng, anchor)
	}
}
