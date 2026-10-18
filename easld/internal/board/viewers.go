package board

import (
	"cmp"
	"maps"
	"regexp"
	"slices"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

const (
	viewerLimit = 16
	viewerSteps = 200
)

var viewerPattern = regexp.MustCompile(`^vw_[A-Za-z0-9_-]{8,64}$`)

// ViewerEdit is one API write's place in a remote viewer's history: gesture Step of Viewer.
type ViewerEdit struct {
	Viewer string
	Step   int
}

// ValidViewer is whether s is a ViewerId.
func ValidViewer(s string) bool { return viewerPattern.MatchString(s) }

// ParseViewerEdit reads params' viewer and step: nil when neither is given.
func ParseViewerEdit(p map[string]any) (*ViewerEdit, error) {
	viewer, hasViewer := p["viewer"]
	step, hasStep := p["step"]
	if !hasViewer && !hasStep {
		return nil, nil
	}
	if !hasViewer || !hasStep {
		return nil, InvalidParams("viewer and step come together: a remote window's edit names both")
	}
	id, ok := viewer.(string)
	if !ok || !ValidViewer(id) {
		return nil, InvalidParams("viewer must match ^vw_[A-Za-z0-9_-]{8,64}$")
	}
	n, ok := model.Int(step)
	if !ok || n < 1 {
		return nil, InvalidParams("step must be an integer of 1 or more")
	}
	return &ViewerEdit{Viewer: id, Step: n}, nil
}

type viewerStep struct {
	id      int
	changes []change
}

type viewerReceipt struct {
	redo    bool
	step    int
	kept    []string
	touched []string
	pushed  bool
}

type viewerHistory struct {
	undo         []viewerStep
	redo         []viewerStep
	receipts     map[int]viewerReceipt
	floor        int
	receiptFloor int
	used         uint64
}

// ViewerReplay answers board.undo and board.redo with the replayed step and its current effects.
// A retired outcome names the requested step without replaying it or reporting old effects.
type ViewerReplay struct {
	Step    *int
	Changed []model.Object
	Deleted []string
	Kept    []string
	Pushed  bool
	Retired bool
}

// JSON is the replay as the API answers it.
func (r ViewerReplay) JSON(b *Board) map[string]any {
	changed := []any{}
	for _, o := range b.Reported(r.Changed) {
		changed = append(changed, o.APIJSON())
	}
	out := map[string]any{"changed": changed, "deleted": anyList(r.Deleted), "kept": anyList(r.Kept), "pushed": r.Pushed}
	if r.Step != nil {
		out["step"] = float64(*r.Step)
	}
	if r.Retired {
		out["retired"] = true
	}
	return out
}

func anyList(ids []string) []any {
	out := make([]any, len(ids))
	for i, id := range ids {
		out[i] = id
	}
	return out
}

func (b *Board) viewerOf(viewer string, create bool) *viewerHistory {
	h, ok := b.viewers[viewer]
	if !ok {
		if !create {
			return nil
		}
		if len(b.viewers) >= viewerLimit {
			oldest := ""
			for id, other := range b.viewers {
				if oldest == "" || other.used < b.viewers[oldest].used {
					oldest = id
				}
			}
			delete(b.viewers, oldest)
		}
		h = &viewerHistory{receipts: map[int]viewerReceipt{}}
		b.viewers[viewer] = h
	}
	b.viewerTick++
	h.used = b.viewerTick
	return h
}

// AsViewerEdit runs body, one API write, as gesture edit.Step of remote viewer edit.Viewer: what
// it changed joins that step of the viewer's history. A write that fails, or changes nothing,
// files nothing. Without edit it is just body.
func (b *Board) AsViewerEdit(edit *ViewerEdit, body func() error) error {
	if edit == nil {
		return body()
	}
	if b.history.isOpen() {
		return InvalidParams("viewer and step mark a remote window's own edit; they aren't allowed inside object.batch")
	}
	b.history.begin()
	defer b.endStep()
	if err := body(); err != nil {
		return err
	}
	if changes := b.history.openChanges(); len(changes) > 0 {
		b.viewerOf(edit.Viewer, true).file(changes, edit.Step)
	}
	return nil
}

func byStepID(s viewerStep, id int) int { return cmp.Compare(s.id, id) }

func (h *viewerHistory) file(changes []change, id int) {
	if id <= h.floor {
		return
	}
	h.forget(id)
	h.redo = nil
	if i, found := slices.BinarySearchFunc(h.undo, id, byStepID); found {
		h.undo[i].changes = append(h.undo[i].changes, changes...)
	} else {
		h.undo = slices.Insert(h.undo, i, viewerStep{id, changes})
	}
	if len(h.undo) > viewerSteps {
		h.raise(h.undo[0].id)
	}
	h.trimReceipts()
}

func (h *viewerHistory) forget(id int) {
	maps.DeleteFunc(h.receipts, func(key int, r viewerReceipt) bool {
		if key != id && r.step != id {
			return false
		}
		h.receiptFloor = max(h.receiptFloor, key)
		return true
	})
}

func (h *viewerHistory) raise(f int) {
	h.floor = max(h.floor, f)
	below := func(s viewerStep) bool { return s.id <= h.floor }
	h.undo = slices.DeleteFunc(h.undo, below)
	h.redo = slices.DeleteFunc(h.redo, below)
	maps.DeleteFunc(h.receipts, func(key int, r viewerReceipt) bool {
		if key > h.floor && r.step > h.floor {
			return false
		}
		h.receiptFloor = max(h.receiptFloor, key)
		return true
	})
}

func (h *viewerHistory) holds(id int) bool {
	has := func(s viewerStep) bool { return s.id == id }
	return slices.ContainsFunc(h.undo, has) || slices.ContainsFunc(h.redo, has)
}

func (h *viewerHistory) trimReceipts() {
	var consumed []int
	for key, r := range h.receipts {
		if !h.holds(r.step) {
			consumed = append(consumed, key)
		}
	}
	if len(consumed) <= viewerSteps {
		return
	}
	slices.Sort(consumed)
	for _, key := range consumed[:len(consumed)-viewerSteps] {
		h.receiptFloor = max(h.receiptFloor, key)
		delete(h.receipts, key)
	}
}

func (h *viewerHistory) retired(step int, redo bool) bool {
	stack := h.undo
	if redo {
		stack = h.redo
	}
	return step <= h.receiptFloor && !slices.ContainsFunc(stack, func(s viewerStep) bool { return s.id == step })
}

func (h *viewerHistory) answer(r viewerReceipt, b *Board) ViewerReplay {
	step := r.step
	out := ViewerReplay{Step: &step, Changed: []model.Object{}, Deleted: []string{}, Kept: append([]string{}, r.kept...)}
	for _, id := range r.touched {
		if o, ok := b.objects[id]; ok {
			out.Changed = append(out.Changed, o)
		} else {
			out.Deleted = append(out.Deleted, id)
		}
	}
	opposite := h.redo
	if r.redo {
		opposite = h.undo
	}
	out.Pushed = r.pushed && slices.ContainsFunc(opposite, func(s viewerStep) bool { return s.id == r.step })
	return out
}

// ReplayViewer is board.undo (redo false) or board.redo for remote viewer: an undo replays its
// latest step at or before step (a step whose writes never reached the host has nothing here),
// a redo exactly step, dropping the steps undone after it. Only what is still as the step left
// it goes back; what someone changed since stays, named in Kept. A retry of the same request
// answers what the first did, as things are now, and replays nothing.
func (b *Board) ReplayViewer(viewer string, step int, redo bool) (ViewerReplay, error) {
	if b.history.isOpen() {
		return ViewerReplay{}, InvalidParams("board.undo and board.redo replay a remote window's own step; they aren't allowed inside another step")
	}
	h := b.viewerOf(viewer, false)
	if h == nil {
		return ViewerReplay{}, nil
	}
	if r, ok := h.receipts[step]; ok && r.redo == redo {
		return h.answer(r, b), nil
	}
	if step <= h.floor {
		return ViewerReplay{}, Conflict("step %d is older than the %d steps this board keeps for viewer %s", step, viewerSteps, viewer)
	}
	if h.retired(step, redo) {
		return ViewerReplay{Step: &step, Retired: true}, nil
	}
	var stack []viewerStep
	var i int
	if redo {
		stack, i = h.redo, slices.IndexFunc(h.redo, func(s viewerStep) bool { return s.id == step })
	} else {
		var found bool
		stack = h.undo
		if i, found = slices.BinarySearchFunc(h.undo, step, byStepID); !found {
			i--
		}
	}
	if i < 0 {
		return ViewerReplay{}, nil
	}
	t := stack[i]
	plan := guardedInverse(t.changes, b)
	var captured []change
	if len(plan.recreates)+len(plan.patches)+len(plan.removes) > 0 {
		b.replayVerb, b.replayActor = "undo", UserActor
		if redo {
			b.replayVerb = "redo"
		}
		err := b.Atomically(func() error {
			if err := b.applyInverse(plan); err != nil {
				return err
			}
			captured = b.history.openChanges()
			return nil
		})
		b.replayVerb, b.replayActor = "", UserActor
		if err != nil {
			return ViewerReplay{}, err
		}
	}
	if redo {
		h.redo = h.redo[:i]
	} else {
		h.undo = slices.Delete(h.undo, i, i+1)
	}
	pushed := len(captured) > 0
	if pushed {
		back := viewerStep{t.id, captured}
		if redo {
			j, _ := slices.BinarySearchFunc(h.undo, t.id, byStepID)
			h.undo = slices.Insert(h.undo, j, back)
		} else {
			h.redo = append(h.redo, back)
		}
	}
	r := viewerReceipt{redo: redo, step: t.id, kept: plan.kept, touched: touchedBy(captured), pushed: pushed}
	h.forget(t.id)
	h.receipts[t.id] = r
	if step != t.id {
		h.receipts[step] = r
	}
	h.trimReceipts()
	return h.answer(r, b), nil
}

func touchedBy(changes []change) []string {
	var ids []string
	for _, c := range changes {
		if c.kind != changeUnstaged && !slices.Contains(ids, c.object.ID) {
			ids = append(ids, c.object.ID)
		}
	}
	return ids
}

type inversePlan struct {
	recreates []model.Object
	patches   []fieldPatch
	removes   []string
	restage   []placedMention
	kept      []string
}

type fieldPatch struct {
	id    string
	frame *model.Frame
	z     *float64
	props map[string]any
}

func guardedInverse(step []change, b *Board) inversePlan {
	type net struct{ before, after *model.Object }
	var order []string
	nets := map[string]*net{}
	var unstaged []placedMention
	for _, c := range step {
		var before, after *model.Object
		switch c.kind {
		case changeUnstaged:
			unstaged = append(unstaged, c.unstaged...)
			continue
		case changeCreated:
			after = &c.object
		case changeUpdated:
			before, after = &c.before, &c.object
		case changeDeleted:
			before = &c.object
		}
		if n, ok := nets[c.object.ID]; ok {
			n.after = after
		} else {
			order = append(order, c.object.ID)
			nets[c.object.ID] = &net{before, after}
		}
	}
	var plan inversePlan
	keep := func(id string) {
		if !slices.Contains(plan.kept, id) {
			plan.kept = append(plan.kept, id)
		}
	}
	for _, id := range slices.Backward(order) {
		n := nets[id]
		current, exists := b.objects[id]
		switch {
		case n.before == nil && n.after == nil:
		case n.before == nil:
			if !exists {
				break
			}
			if current.Type == model.Group {
				current.Frame = n.after.Frame
			}
			if sameContent(current, *n.after) {
				plan.removes = append(plan.removes, id)
			} else {
				keep(id)
			}
		case n.after == nil:
			if exists || b.keyHeldByAnother(n.before.Props, id) {
				keep(id)
			} else {
				plan.recreates = append(plan.recreates, n.before.Clone())
			}
		case !exists:
			keep(id)
		default:
			patch, changedSince := fieldsBack(*n.before, *n.after, current, b)
			if changedSince {
				keep(id)
			}
			if patch.frame != nil || patch.z != nil || patch.props != nil {
				plan.patches = append(plan.patches, patch)
			}
		}
	}
	slices.SortStableFunc(plan.recreates, func(x, y model.Object) int { return cmp.Compare(x.Z, y.Z) })
	back := map[string]bool{}
	for _, o := range plan.recreates {
		back[o.ID] = true
	}
	for i, o := range plan.recreates {
		if _, here := b.objects[o.Parent]; o.Parent != "" && !here && !back[o.Parent] {
			plan.recreates[i].Parent = ""
		}
	}
	for _, placed := range unstaged {
		if slices.ContainsFunc(model.MentionObjects(placed.mention.Target), func(id string) bool { return back[id] }) {
			plan.restage = append(plan.restage, placed)
		}
	}
	return plan
}

func fieldsBack(before, after, current model.Object, b *Board) (fieldPatch, bool) {
	patch := fieldPatch{id: current.ID}
	changedSince := false
	if current.Type != model.Group {
		frame, framed := current.Frame, false
		for _, side := range []struct {
			before, after, current float64
			into                   *float64
		}{
			{before.Frame.X, after.Frame.X, current.Frame.X, &frame.X},
			{before.Frame.Y, after.Frame.Y, current.Frame.Y, &frame.Y},
			{before.Frame.W, after.Frame.W, current.Frame.W, &frame.W},
			{before.Frame.H, after.Frame.H, current.Frame.H, &frame.H},
		} {
			if side.before == side.after {
				continue
			}
			if side.current != side.after {
				changedSince = true
				continue
			}
			*side.into, framed = side.before, true
		}
		if framed {
			patch.frame = &frame
		}
	}
	if before.Z != after.Z {
		if current.Z != after.Z {
			changedSince = true
		} else {
			z := before.Z
			patch.z = &z
		}
	}
	was, now, is := contentProps(before), contentProps(after), contentProps(current)
	keys := slices.Collect(maps.Keys(was))
	for k := range now {
		if _, ok := was[k]; !ok {
			keys = append(keys, k)
		}
	}
	for _, k := range keys {
		wasValue, wasSet := was[k]
		nowValue, nowSet := now[k]
		if wasSet == nowSet && model.Equal(wasValue, nowValue) {
			continue
		}
		if isValue, isSet := is[k]; isSet != nowSet || !model.Equal(isValue, nowValue) {
			changedSince = true
			continue
		}
		if patch.props == nil {
			patch.props = map[string]any{}
		}
		patch.props[k] = wasValue
	}
	if b.keyHeldByAnother(patch.props, current.ID) {
		delete(patch.props, "key")
		changedSince = true
		if len(patch.props) == 0 {
			patch.props = nil
		}
	}
	return patch, changedSince
}

func (b *Board) keyHeldByAnother(props map[string]any, id string) bool {
	key, ok := Key(props)
	if !ok {
		return false
	}
	for holder := range b.keyHolders[key] {
		if holder != id {
			return true
		}
	}
	return false
}

func (b *Board) applyInverse(plan inversePlan) error {
	for _, o := range plan.recreates {
		b.recreate(o)
	}
	for _, p := range plan.patches {
		if _, err := b.Update(p.id, nil, p.frame, p.z, p.props, "", ""); err != nil {
			return err
		}
	}
	for _, id := range plan.removes {
		if _, ok := b.objects[id]; !ok {
			continue
		}
		if err := b.Delete(id, ""); err != nil {
			return err
		}
	}
	b.restageMentions(plan.restage)
	return nil
}

func (b *Board) recreate(o model.Object) {
	intentActor := o.CreatedBy
	if o.UpdatedBy != nil {
		intentActor = *o.UpdatedBy
	}
	o.UpdatedAt = time.Now()
	user := model.Actor{Kind: "user"}
	o.UpdatedBy = &user
	b.restore(o, intentActor)
	b.history.record(change{kind: changeCreated, object: b.objects[o.ID]})
	if o.Type == model.Terminal {
		b.createdTerminals = append(b.createdTerminals, o.ID)
	}
	b.refitGroups(o.ID, UserActor, "", nil)
}
