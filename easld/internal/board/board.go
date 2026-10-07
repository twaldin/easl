// Package board is one canvas: its objects, revisions, the selection tray, agent lifecycle,
// attention markers, follow tiles and the activity log, with the events every change announces.
// It ports Sources/CanvasCore/Board.swift and its extensions. A Board is not safe for concurrent
// use: the router serialises all board work behind one lock, as Swift runs it on the main actor.
package board

import (
	"fmt"
	"maps"
	"math"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/mention"
	"github.com/twaldin/easl/easld/internal/metrics"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/question"
	"github.com/twaldin/easl/easld/internal/route"
	"github.com/twaldin/easl/easld/internal/store"
)

// Error is a board failure with its API error code (BoardError: not_found, conflict,
// invalid_params).
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Message }

func NotFound(format string, args ...any) error {
	return &Error{"not_found", fmt.Sprintf(format, args...)}
}

func Conflict(format string, args ...any) error {
	return &Error{"conflict", fmt.Sprintf(format, args...)}
}

func InvalidParams(format string, args ...any) error {
	return &Error{"invalid_params", fmt.Sprintf(format, args...)}
}

// Event names (BoardEvent.name).
const (
	EventObjectCreated    = "object.created"
	EventObjectUpdated    = "object.updated"
	EventObjectDeleted    = "object.deleted"
	EventTrayChanged      = "tray.changed"
	EventAgentLifecycle   = "agent.lifecycle"
	EventFollowUpdated    = "follow.updated"
	EventAttentionChanged = "attention.changed"
)

type approval struct {
	call    string
	message *string
}

type cascade struct {
	seq    int
	actor  Actor
	before model.Object
}

type refit struct {
	member string
	actor  Actor
	caller string
}

// Board is one canvas for one root directory.
type Board struct {
	id   string
	root string

	objects  map[string]model.Object
	revision int
	tray     []model.Mention
	// Delivered counts mentions that left the tray with a prompt or a commit since the board opened.
	Delivered int
	attention map[string]store.Attention
	// Repo is the repository this board is for; nil outside git.
	Repo            *store.RepoRecord
	workingWorktree *store.Worktree
	promptTarget    store.PromptTargetState
	handoffs        map[string][]Handoff
	finalAnswers    map[string]string
	turnErrors      map[string]string
	// aliases are names terminals had before a rename, each still addressing its terminal
	// (AgentAddress) until another terminal on this board takes it; saved with the board.
	aliases map[string]string
	// messages are the out-of-band messages queued for each terminal, oldest first, until its
	// integration acks them (messages.go); saved with the board.
	messages map[string][]Message
	// bouncing are messages bounced in the open step, handed on when it closes (flushBounces).
	bouncing []Bounce
	// createdTerminals and removedTerminals are the terminals created and deleted in the open
	// step, checked against objects when it closes (flushTerminals).
	createdTerminals []string
	removedTerminals []model.Object

	changedAt        map[string]int
	keyHolders       map[string]map[string]bool
	seenSinceWorking map[string]bool
	lifecycleSeq     map[string]int
	pendingApprovals map[string][]approval
	revHighWater     map[string]int
	pinnedRevision   *int

	history       *history
	Activity      *ActivityLog
	activityMuted bool
	replayVerb    string
	replayActor   Actor
	cascades      map[string]cascade
	cascadeRev    int
	refitDeferral int
	pendingRefits []refit

	workingDirectories map[string]string
	// unknown is the board file's top-level keys easld doesn't know, written back as they were.
	unknown map[string]any

	// OnEvent receives every event, in order (the registry broadcasts them).
	OnEvent func(model.Event)
	// OnMessagesBounced receives messages whose receiver's agent session ended before its
	// integration took them (the registry's router sends them back or logs them).
	OnMessagesBounced func(Bounce)
	// OnTerminals receives, once the outermost step closes, the terminals it created that are
	// still there (as they are then) and those it deleted that are still gone (as they last
	// were): a failed batch reverts both, so it reports neither (Board.onTerminalsEnded, plus the
	// created). The registry's router starts and ends the sessions of those easld owns.
	OnTerminals func(created, ended []model.Object)
	// OnChange is called after any persisted change (the store debounces saves).
	OnChange func()
	// Viewport is the canvas rect a window shows; easld has none (nil), so placement ignores it.
	Viewport func() *model.Frame
	// Texts measures arrow captions for routing (DrawingStyle.arrowLabel); nil: arrows route
	// without their labels.
	Texts measure.Texts
	// settled is the drawing layer's last routing (Board.settledRouting).
	settled *route.Result

	// Lock is what serialises this board's work with everyone else's (the registry's Mu); the
	// question expiry timer takes it to expire questions as a request would. A board without
	// one (outside a registry) sets no timer: ExpireQuestions is the caller's.
	Lock sync.Locker
	// questionExpiry is the pending check for the earliest open question's expiresAt
	// (Board.questionExpiry); expirySeq tells a timer that was replaced.
	questionExpiry *time.Timer
	expirySeq      int
}

// New is an empty board.
func New(id, root string) *Board {
	return &Board{
		id: id, root: root,
		objects: map[string]model.Object{}, attention: map[string]store.Attention{}, handoffs: map[string][]Handoff{},
		finalAnswers: map[string]string{}, turnErrors: map[string]string{}, changedAt: map[string]int{},
		keyHolders: map[string]map[string]bool{}, seenSinceWorking: map[string]bool{}, lifecycleSeq: map[string]int{},
		aliases: map[string]string{}, messages: map[string][]Message{},
		pendingApprovals: map[string][]approval{}, revHighWater: map[string]int{}, history: newHistory(),
		Activity: NewActivityLog(DefaultActivityCapacity, nil), replayActor: UserActor, cascades: map[string]cascade{}, cascadeRev: -1,
		workingDirectories: map[string]string{}, promptTarget: store.PromptTargetState{FocusOrder: []string{}},
	}
}

// TileTitleHeight is a tile's title bar (RenderMath.tileTitleHeight).
const TileTitleHeight = 26.0

// FromSnapshot is a board as saved (Board.init(snapshot:)): `props.scale` migrated, legacy
// group `name` → `title`, format-1 tile frames grown by the title bar, terminals saved working or
// blocked marked `restored`, group frames refit, and what refers to missing objects dropped.
func FromSnapshot(s *store.Snapshot) *Board {
	b := New(s.ID, s.Root)
	b.revision = s.Revision
	format := 1
	if s.Format != nil {
		format = *s.Format
	}
	for _, o := range s.Objects {
		o = MigratedZoom(o.Clone())
		if o.Type == model.Group {
			if name, ok := o.Props["name"]; ok {
				delete(o.Props, "name")
				if _, has := o.Props["title"]; !has {
					o.Props["title"] = name
				}
			}
		}
		if format < 2 && o.Type.IsTile() {
			o.Frame.H += TileTitleHeight
		}
		MarkRestored(o)
		b.objects[o.ID] = o
		b.changedAt[o.ID] = s.Revision
		if key, ok := Key(o.Props); ok {
			b.holders(key)[o.ID] = true
		}
	}
	for range 8 {
		changed := false
		for _, id := range b.sortedIDs() {
			g := b.objects[id]
			if g.Type != model.Group {
				continue
			}
			if f, ok := b.fittedFrame(g); ok && f != g.Frame {
				g.Frame = f
				b.objects[id] = g
				changed = true
			}
		}
		if !changed {
			break
		}
	}
	b.tray = []model.Mention{}
	for _, m := range s.Tray {
		if b.allExist(model.MentionObjects(m.Target)) {
			b.tray = append(b.tray, m)
		}
	}
	for _, a := range s.Attention {
		if _, ok := b.objects[a.Object]; ok {
			b.attention[a.Object] = a
		}
	}
	if s.PromptTarget != nil {
		b.promptTarget = store.PromptTargetState{FocusOrder: append([]string{}, s.PromptTarget.FocusOrder...), Chosen: s.PromptTarget.Chosen}
		b.prunePromptTarget()
	}
	for k, v := range s.FinalAnswers {
		if _, ok := b.objects[k]; ok {
			b.finalAnswers[k] = v
		}
	}
	for k, v := range s.TurnErrors {
		if _, ok := b.objects[k]; ok {
			b.turnErrors[k] = v
		}
	}
	for k, v := range s.LifecycleSeq {
		tile, _, _ := strings.Cut(k, "|")
		if _, ok := b.objects[tile]; ok {
			b.lifecycleSeq[k] = v
		}
	}
	for alias, tile := range s.Aliases {
		if o, ok := b.objects[tile]; ok && o.Type == model.Terminal {
			b.aliases[alias] = tile
		}
	}
	for tile, waiting := range s.Messages {
		if o, ok := b.objects[tile]; ok && o.Type == model.Terminal && len(waiting) > 0 {
			b.messages[tile] = append([]Message{}, waiting...)
		}
	}
	if s.Repo != nil {
		r := *s.Repo
		r.Worktrees = append([]store.WorktreeRecord{}, s.Repo.Worktrees...)
		b.Repo = &r
	}
	b.unknown = s.Unknown
	return b
}

// MarkRestored marks a terminal's lifecycle saved `working` or `blocked` as `restored` (in place):
// what it was when its board was saved, which its agent hasn't confirmed since.
func MarkRestored(o model.Object) {
	if o.Type != model.Terminal {
		return
	}
	if lc, ok := o.Props["lifecycle"].(map[string]any); ok {
		if st, _ := lc["state"].(string); st == "working" || st == "blocked" {
			lc["restored"] = true
		}
	}
}

func (b *Board) prunePromptTarget() {
	order := b.promptTarget.FocusOrder[:0]
	for _, id := range b.promptTarget.FocusOrder {
		if _, ok := b.objects[id]; ok {
			order = append(order, id)
		}
	}
	b.promptTarget.FocusOrder = order
	if _, ok := b.objects[b.promptTarget.Chosen]; !ok {
		b.promptTarget.Chosen = ""
	}
}

// MigratedZoom is ObjectZoom.migrated: a `props.scale` saved before `zoom` becomes a tile's
// content zoom, a text shape's textSize, or nothing (images); a zoom/textSize already there wins.
func MigratedZoom(o model.Object) model.Object {
	scale, ok := o.Props["scale"]
	if !ok {
		return o
	}
	delete(o.Props, "scale")
	key := ""
	if o.Type.IsTile() && o.Type != model.Image {
		key = "zoom"
	} else if o.Type == model.Shape && o.Props["kind"] == "text" {
		key = "textSize"
	}
	if key != "" {
		if _, has := o.Props[key]; !has {
			if v, ok := scale.(float64); ok && !math.IsInf(v, 0) && !math.IsNaN(v) && v > 0 && math.Abs(v-1) >= 0.001 {
				o.Props[key] = v
			}
		}
	}
	return o
}

// Snapshot is the board as saved (Board.snapshot).
func (b *Board) Snapshot() *store.Snapshot {
	format := store.Format
	s := &store.Snapshot{Format: &format, ID: b.id, Root: b.root, Revision: b.revision, HasTray: true}
	for _, o := range b.objects {
		s.Objects = append(s.Objects, o.Clone())
	}
	store.SortObjects(s.Objects)
	s.Tray = append([]model.Mention{}, b.tray...)
	if len(b.attention) > 0 {
		for _, a := range b.attention {
			s.Attention = append(s.Attention, a)
		}
		sort.Slice(s.Attention, func(i, j int) bool { return s.Attention[i].Object < s.Attention[j].Object })
	}
	if len(b.promptTarget.FocusOrder) > 0 || b.promptTarget.Chosen != "" {
		p := store.PromptTargetState{FocusOrder: append([]string{}, b.promptTarget.FocusOrder...), Chosen: b.promptTarget.Chosen}
		s.PromptTarget = &p
	}
	if len(b.finalAnswers) > 0 {
		s.FinalAnswers = copyMap(b.finalAnswers)
	}
	if len(b.turnErrors) > 0 {
		s.TurnErrors = copyMap(b.turnErrors)
	}
	if len(b.lifecycleSeq) > 0 {
		s.LifecycleSeq = copyMap(b.lifecycleSeq)
	}
	if len(b.aliases) > 0 {
		s.Aliases = copyMap(b.aliases)
	}
	if len(b.messages) > 0 {
		s.Messages = map[string][]Message{}
		for tile, waiting := range b.messages {
			s.Messages[tile] = append([]Message{}, waiting...)
		}
	}
	if b.Repo != nil {
		r := *b.Repo
		r.Worktrees = append([]store.WorktreeRecord{}, b.Repo.Worktrees...)
		s.Repo = &r
	}
	s.Unknown = b.unknown // never changed after load, so the snapshot may share it
	return s
}

func copyMap[V any](m map[string]V) map[string]V {
	out := make(map[string]V, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// --- reading ---

// Objects is the board's objects by id; callers must not change it.
func (b *Board) Objects() map[string]model.Object { return b.objects }

// ID is the board's id.
func (b *Board) ID() string { return b.id }

// Root is the directory the board is for (a repository board's canonical root).
func (b *Board) Root() string { return b.root }

// SetRoot follows a moved root (a renamed checkout keeps its board).
func (b *Board) SetRoot(root string) { b.root = root }

func (b *Board) Revision() int         { return b.revision }
func (b *Board) Tray() []model.Mention { return b.tray }
func (b *Board) FinalAnswer(tile string) (string, bool) {
	s, ok := b.finalAnswers[tile]
	return s, ok
}
func (b *Board) TurnError(tile string) (string, bool) {
	s, ok := b.turnErrors[tile]
	return s, ok
}

// Object is the object id, or not_found "object <id>".
func (b *Board) Object(id string) (model.Object, error) {
	o, ok := b.objects[id]
	if !ok {
		return o, NotFound("object %s", id)
	}
	return o, nil
}

// Changed is the objects changed after board revision cursor (board.get since), sorted.
func (b *Board) Changed(since int) []string {
	var out []string
	for id, rev := range b.changedAt {
		if rev > since {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out
}

func (b *Board) sortedIDs() []string {
	ids := make([]string, 0, len(b.objects))
	for id := range b.objects {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func (b *Board) allExist(ids []string) bool {
	for _, id := range ids {
		if _, ok := b.objects[id]; !ok {
			return false
		}
	}
	return true
}

func (b *Board) emit(name string, data any) {
	if b.OnEvent != nil {
		b.OnEvent(model.Event{Name: name, Data: data})
	}
}

func (b *Board) changed() {
	if b.OnChange != nil {
		b.OnChange()
	}
}

// DefaultSize is the frame size a new object gets without one (Board.defaultSize).
func DefaultSize(t model.ObjectType) (float64, float64) { return model.DefaultSize(t) }

// --- objects ---

// Create adds an object (Board.create). Without a frame it is placed beside the caller, or at
// the viewport's center (the origin without one); a group's frame follows its members.
func (b *Board) Create(typ model.ObjectType, props map[string]any, frame *model.Frame, parent, caller string) model.Object {
	z := 0.0
	first := true
	for _, o := range b.objects {
		if first || o.Z > z {
			z = o.Z
		}
		first = false
	}
	z++
	if props == nil {
		props = map[string]any{}
	}
	props, _ = model.Clone(props).(map[string]any)
	w, h := DefaultSize(typ)
	if typ == model.Question {
		w, h = question.Size(props)
	}
	// A code tile without a frame is as wide as its file's lines need.
	if typ == model.Code && frame == nil {
		w, h = b.NewCodeSize(props)
	}
	if typ == model.Terminal {
		props = b.stampingWorktree(props)
	}
	now := time.Now()
	o := model.Object{ID: model.NewID("obj"), Type: typ, Z: z, Rev: 1, Parent: parent, CreatedBy: model.ActorFor(caller), CreatedAt: now, UpdatedAt: now, Props: props}
	if frame != nil {
		o.Frame = *frame
	} else {
		o.Frame = model.Frame{W: w, H: h}
	}
	if fitted, ok := b.fittedFrame(o); ok {
		o.Frame = fitted
	} else if frame == nil {
		o.Frame = b.Place(w, h, caller, nil, true)
	}
	b.commit(o)
	b.countWrite(caller, "")
	b.history.record(change{kind: changeCreated, object: o})
	if typ == model.Terminal {
		b.createdTerminals = append(b.createdTerminals, o.ID)
	}
	b.log(KindCreated, o, ActorFor(caller), "created "+Describe(o)+" at "+Position(b.ReportedOne(o).Frame), "", nil)
	b.emit(EventObjectCreated, o.APIJSON())
	// A create opens no step of its own: outside one it is reported now.
	b.flushTerminals()
	return o
}

// Update patches an object (Board.update); a group's frame is never taken from frame. actor
// credits the activity log entry to someone other than the caller ("" for the caller); the
// system's writes are never recorded.
func (b *Board) Update(id string, rev *int, frame *model.Frame, z *float64, props map[string]any, caller string, actor Actor) (model.Object, error) {
	if actor == SystemActor {
		var out model.Object
		err := b.unrecorded(func() error {
			var err error
			out, err = b.write(id, rev, frame, z, props, caller, actor, "", nil)
			return err
		})
		return out, err
	}
	return b.write(id, rev, frame, z, props, caller, actor, "", nil)
}

// WriteBookkeeping writes props the app keeps about an object rather than its content: stored,
// announced, but no rev, undo step or log.
func (b *Board) WriteBookkeeping(id string, props map[string]any) error {
	before, err := b.Object(id)
	if err != nil {
		return err
	}
	allowed := bookkeeping(before)
	var keys []string
	ok := true
	for k := range props {
		keys = append(keys, k)
		if !allowed[k] {
			ok = false
		}
	}
	if !ok {
		var names []string
		for k := range allowed {
			names = append(names, k)
		}
		sort.Strings(names)
		sort.Strings(keys)
		return InvalidParams("%s bookkeeping is %s, not %s", before.Type, swiftList(names), swiftList(keys))
	}
	b.commitBookkeeping(before, props)
	return nil
}

// swiftList prints a [String] as Swift's string interpolation does: ["a", "b"].
func swiftList(items []string) string {
	quoted := make([]string, len(items))
	for i, s := range items {
		quoted[i] = fmt.Sprintf("%q", s)
	}
	return "[" + strings.Join(quoted, ", ") + "]"
}

func (b *Board) commitBookkeeping(before model.Object, props map[string]any) {
	o := before.Clone()
	o.Props, _ = model.Merge(o.Props, props).(map[string]any)
	if model.Equal(anyMap(o.Props), anyMap(before.Props)) && o.Frame == before.Frame {
		return
	}
	b.commit(o)
	metrics.Shared.Record("board.bookkeeping", 0, 0)
	b.emit(EventObjectUpdated, o.APIJSON())
}

// write is update, re-bounding the groups that contain the object in the same step. refitting
// holds the groups already being re-bounded; cause marks a cascade of another change.
func (b *Board) write(id string, rev *int, frame *model.Frame, z *float64, props map[string]any, caller string, actor Actor, cause string, refitting map[string]bool) (model.Object, error) {
	before, err := b.Object(id)
	if err != nil {
		return before, err
	}
	if rev != nil && *rev != before.Rev {
		return before, Conflict("object %s is at rev %d, not %d", id, before.Rev, *rev)
	}
	if err := b.CheckKey(props, id); err != nil {
		return before, err
	}
	o := before.Clone()
	if frame != nil {
		o.Frame = *frame
	}
	if z != nil {
		o.Z = *z
	}
	if props != nil {
		o.Props, _ = model.Merge(o.Props, props).(map[string]any)
		if o.Type == model.Code {
			if _, given := props["anchor"]; !given {
				if !jsonEqualKey(o.Props, before.Props, "range") || !jsonEqualKey(o.Props, before.Props, "path") {
					delete(o.Props, "anchor")
				}
			}
		}
	}
	if o.Type == model.Terminal {
		if was, now := TerminalHost(before), TerminalHost(o); was != now {
			return before, InvalidParams("terminal %s runs on %s: a terminal's host can't change (create a terminal on %s instead)", id, hostName(was), hostName(now))
		}
	}
	if fitted, ok := b.fittedFrame(o); ok {
		o.Frame = fitted
	}
	o.Rev++
	o.UpdatedAt = time.Now()
	updatedBy := model.ActorFor(caller)
	o.UpdatedBy = &updatedBy
	credited := actor
	if credited == "" {
		credited = ActorFor(caller)
	}
	b.history.begin()
	defer b.endStep()
	b.commit(o)
	b.countWrite(caller, cause)
	b.history.record(change{kind: changeUpdated, before: before, object: o})
	if changes, ok := Changes(before, o); ok {
		b.log(KindUpdated, o, credited, Describe(o)+": "+changes, cause, &before)
	}
	b.markMentionsEdited(before, o)
	data := o.APIJSON()
	b.reanchorShown(before, o)
	b.emit(EventObjectUpdated, data)
	if o.Type == model.Question {
		b.questionWritten(before, o)
	}
	if before.Frame != o.Frame {
		b.refitGroups(id, credited, caller, refitting)
	}
	return o, nil
}

// TerminalHost is the machine terminal `o`'s session runs on (`props.host`, an ssh target); ""
// for the local one (HostedTerminal.host). It is fixed for the terminal's life: the live terminal
// stays attached where its session started, so a board naming another host (or none) would read
// its history from, and end, a session elsewhere.
func TerminalHost(o model.Object) string {
	host, _ := o.Props["host"].(string)
	return strings.Trim(host, " \t")
}

func hostName(host string) string {
	if host == "" {
		return "the local machine"
	}
	return host
}

func jsonEqualKey(a, b map[string]any, key string) bool {
	x, ok1 := a[key]
	y, ok2 := b[key]
	return ok1 == ok2 && model.Equal(x, y)
}

// Delete removes an object (Board.delete). In the same step arrows bound to it detach; a
// deleted terminal takes its follow tile; a closed follow tile stops its terminal following.
func (b *Board) Delete(id, caller string) error {
	if _, ok := b.objects[id]; !ok {
		return NotFound("object %s", id)
	}
	actor := ActorFor(caller)
	b.history.begin()
	defer b.endStep()
	b.detachArrows(id, actor, caller)
	removed, ok := b.objects[id]
	if !ok {
		return NotFound("object %s", id)
	}
	delete(b.objects, id)
	delete(b.changedAt, id)
	b.reindexKey(id, removed.Props, nil)
	b.forgetAliases(id)
	b.bumpRevision()
	b.countWrite(caller, "")
	var unstaged []placedMention
	for i, m := range b.tray {
		if contains(model.MentionObjects(m.Target), id) {
			unstaged = append(unstaged, placedMention{index: i, mention: m})
		}
	}
	if len(unstaged) > 0 {
		b.history.record(change{kind: changeUnstaged, unstaged: unstaged})
	}
	b.history.record(change{kind: changeDeleted, object: removed})
	if removed.Type == model.Terminal {
		b.removedTerminals = append(b.removedTerminals, removed)
	}
	b.log(KindDeleted, removed, actor, "deleted "+Describe(removed), "", nil)
	before := len(b.tray)
	kept := b.tray[:0:0]
	for _, m := range b.tray {
		if !contains(model.MentionObjects(m.Target), id) {
			kept = append(kept, m)
		}
	}
	b.tray = kept
	b.forgetHandoffs(id)
	b.forgetMessages(removed)
	_, marked := b.attention[id]
	delete(b.attention, id)
	b.changed()
	b.emit(EventObjectDeleted, map[string]any{"id": id})
	if len(b.tray) != before {
		b.trayChanged()
	}
	if marked {
		b.emit(EventAttentionChanged, map[string]any{"id": id, "active": false})
	}
	b.refitGroups(id, actor, caller, nil)
	if b.history.replaying {
		return nil
	}
	if removed.Type == model.Terminal {
		for _, f := range b.FollowTiles(id) {
			if err := b.Delete(f.ID, caller); err != nil {
				return err
			}
		}
	} else if of, ok := removed.Props["followOf"].(string); ok {
		if terminal, ok := b.objects[of]; ok && terminal.Props["follow"] != false {
			_, _ = b.write(terminal.ID, nil, nil, nil, map[string]any{"follow": false}, caller, actor, "its follow tile was closed", nil)
		}
	}
	return nil
}

func contains(list []string, id string) bool {
	for _, x := range list {
		if x == id {
			return true
		}
	}
	return false
}

// log records a change. A cascade (cause set, with the object's state before it) hitting an
// object already cascaded in this revision by the same actor amends that entry to the net
// change, or drops it when the changes cancel out.
func (b *Board) log(kind string, o model.Object, actor Actor, summary, cause string, before *model.Object) {
	if b.activityMuted {
		return
	}
	if b.replayVerb != "" {
		b.Activity.Record(kind, b.replayActor, b.revision, o.ID, o.Type, b.replayVerb+": "+summary, "")
		return
	}
	if cause == "" || before == nil || kind != KindUpdated {
		b.Activity.Record(kind, actor, b.revision, o.ID, o.Type, summary, "")
		return
	}
	if b.cascadeRev != b.revision {
		b.cascades = map[string]cascade{}
		b.cascadeRev = b.revision
	}
	first := *before
	if earlier, ok := b.cascades[o.ID]; ok && earlier.actor == actor {
		changes, ok := Changes(earlier.before, o)
		if !ok {
			b.Activity.Remove(earlier.seq)
			delete(b.cascades, o.ID)
			return
		}
		if b.Activity.Amend(earlier.seq, Describe(o)+": "+changes) {
			return
		}
		first = earlier.before
	}
	b.Activity.Record(kind, actor, b.revision, o.ID, o.Type, summary, cause)
	b.cascades[o.ID] = cascade{seq: b.Activity.Cursor(), actor: actor, before: first}
}

// restore puts an object state back verbatim (same id and z), with a revision newer than any it
// has had, announced as a normal change.
func (b *Board) restore(o model.Object) {
	previous, existed := b.objects[o.ID]
	high := b.revHighWater[o.ID]
	if existed && previous.Rev > high {
		high = previous.Rev
	}
	if o.Rev > high {
		high = o.Rev
	}
	o.Rev = high + 1
	b.commit(o)
	metrics.Shared.Record("board.undo", 0, 0)
	if existed {
		if changes, ok := Changes(previous, o); ok {
			b.log(KindUpdated, o, b.replayActor, Describe(o)+": "+changes, "", nil)
		}
		b.markMentionsEdited(previous, o)
		b.emit(EventObjectUpdated, o.APIJSON())
		if o.Type == model.Question {
			b.questionWritten(previous, o)
		}
	} else {
		b.log(KindCreated, o, b.replayActor, "restored "+Describe(o)+" at "+Position(b.ReportedOne(o).Frame), "", nil)
		b.emit(EventObjectCreated, o.APIJSON())
	}
}

func (b *Board) commit(o model.Object) {
	b.bumpRevision()
	var old map[string]any
	if prev, ok := b.objects[o.ID]; ok {
		old = prev.Props
	}
	b.reindexKey(o.ID, old, o.Props)
	b.renamed(o.ID, old, o.Props, o.Type)
	b.objects[o.ID] = o
	b.changedAt[o.ID] = b.revision
	if o.Rev > b.revHighWater[o.ID] {
		b.revHighWater[o.ID] = o.Rev
	}
	b.changed()
	if o.Type == model.Question {
		b.ScheduleQuestionExpiry()
	}
}

// countWrite counts a change to the board's objects for `app.metrics`: `board.write` (and the
// caller among `writers`) for a create, update or delete; `board.refit` for a group re-fit
// around its members; `board.undo` for undo and redo.
func (b *Board) countWrite(caller, cause string) {
	switch {
	case b.history.replaying:
		metrics.Shared.Record("board.undo", 0, 0)
	case cause == GroupRefitCause:
		metrics.Shared.Record("board.refit", 0, 0)
	default:
		metrics.Shared.Record("board.write", 0, 0)
		writer := "user"
		if caller != "" {
			writer = "agent:" + caller
		}
		metrics.Shared.Offender("writers", writer, 0)
	}
}

func (b *Board) bumpRevision() {
	if b.pinnedRevision != nil {
		b.revision = *b.pinnedRevision
	} else {
		b.revision++
	}
}

// endStep closes a step opened with history.begin; when the outermost one closes, the messages
// it bounced are handed on (flushBounces) and its terminals reported (flushTerminals).
func (b *Board) endStep() {
	b.history.end()
	b.flushBounces()
	b.flushTerminals()
}

// flushTerminals hands OnTerminals, once no step is open, the terminals created since that are
// still there and those deleted since that are still gone, each once, in the order it happened.
// A terminal created and deleted in the same step is neither: nothing started it.
func (b *Board) flushTerminals() {
	if b.history.isOpen() || (len(b.createdTerminals) == 0 && len(b.removedTerminals) == 0) {
		return
	}
	createdIDs, removed := b.createdTerminals, b.removedTerminals
	b.createdTerminals, b.removedTerminals = nil, nil
	seen := map[string]bool{}
	var created, ended []model.Object
	for _, id := range createdIDs {
		seen[id] = true
		if o, ok := b.objects[id]; ok {
			created = append(created, o)
		}
	}
	for _, o := range removed {
		if _, back := b.objects[o.ID]; !back && !seen[o.ID] {
			ended = append(ended, o)
		}
		seen[o.ID] = true
	}
	if (len(created) > 0 || len(ended) > 0) && b.OnTerminals != nil {
		b.OnTerminals(created, ended)
	}
}

// Atomically runs body as one step and one board revision; when it fails, every change it made
// is reverted (announced as normal changes, logged as "reverted (batch failed)"), the hand-offs,
// messages and aliases of terminals are put back as they were (an answer it handed off
// withdrawn, the queue, mentions and old names a delete took restored), and the error returned.
func (b *Board) Atomically(body func() error) error {
	outermost := b.pinnedRevision == nil
	if outermost {
		pinned := b.revision + 1
		b.pinnedRevision = &pinned
	}
	b.history.begin()
	mark := b.history.mark()
	handed, queued, named := maps.Clone(b.handoffs), maps.Clone(b.messages), maps.Clone(b.aliases)
	defer func() {
		b.endStep()
		if outermost {
			b.pinnedRevision = nil
		}
	}()
	if err := body(); err != nil {
		b.replayVerb, b.replayActor = "reverted (batch failed)", SystemActor
		b.revert(b.history.discard(mark))
		b.replayVerb, b.replayActor = "", UserActor
		b.handoffs, b.messages, b.aliases = handed, queued, named
		return err
	}
	return nil
}

// InStep: a step is open (a batch reports its arrows once it closes).
func (b *Board) InStep() bool { return b.history.isOpen() }

// --- arrows as reported ---

// ArrowPaths is each arrow's routed line as the app's drawing layer has it (Board.arrowPath:
// ShapeLayer's settled routing, through document coordinates), else routed from object frames
// (BoardGeometry, from the settled routing). Arrows whose ends are gone have none. Outside a
// step the drawing layer's routing settles first (settleArrows), so it reflects every change.
func (b *Board) ArrowPaths(ids []string) map[string][]route.Point {
	paths := map[string][]route.Point{}
	if len(ids) == 0 {
		return paths
	}
	labels, _ := b.LabelSizes()
	drawn := route.Geometry{Objects: b.objects, LabelSizes: labels, Settled: b.settled}.DrawnRouting(nil)
	if !b.history.isOpen() {
		b.settled = drawn
	}
	var missing []string
	for _, id := range ids {
		if path, ok := drawn.DrawnPath(id); ok && len(path) >= 2 {
			paths[id] = path
		} else {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		for id, path := range (route.Geometry{Objects: b.objects, Settled: b.settled}).Routes(nil, missing) {
			if _, ok := paths[id]; !ok {
				paths[id] = path
			}
		}
	}
	return paths
}

// Reported is objects as the API reports them: an arrow's frame is the bounds of its routed
// line, everything else as stored.
func (b *Board) Reported(list []model.Object) []model.Object {
	var arrows []string
	for _, o := range list {
		if o.Type == model.Arrow {
			arrows = append(arrows, o.ID)
		}
	}
	if len(arrows) == 0 {
		return list
	}
	paths := b.ArrowPaths(arrows)
	out := make([]model.Object, len(list))
	for i, o := range list {
		if path, ok := paths[o.ID]; ok && len(path) > 0 {
			o.Frame = route.Bounds(path)
		}
		out[i] = o
	}
	return out
}

func (b *Board) ReportedOne(o model.Object) model.Object { return b.Reported([]model.Object{o})[0] }

// detachArrows gives every arrow bound to id a free end where it last attached, as a cascade of
// the delete.
func (b *Board) detachArrows(id string, actor Actor, caller string) {
	type bound struct {
		arrow model.Object
		spec  route.ArrowSpec
	}
	var list []bound
	for _, aid := range b.sortedIDs() {
		a := b.objects[aid]
		if a.Type != model.Arrow || a.ID == id {
			continue
		}
		spec, ok := route.ParseArrow(a.Props)
		if !ok || (spec.From.Object != id && spec.To.Object != id) {
			continue
		}
		list = append(list, bound{a, spec})
	}
	if len(list) == 0 {
		return
	}
	ids := make([]string, len(list))
	for i, x := range list {
		ids[i] = x.arrow.ID
	}
	paths := b.ArrowPaths(ids)
	for _, x := range list {
		path, ok := paths[x.arrow.ID]
		if !ok || len(path) == 0 {
			continue
		}
		spec := x.spec
		if spec.From.Object == id {
			spec.From = route.Binding{Point: path[0]}
		}
		if spec.To.Object == id {
			spec.To = route.Binding{Point: path[len(path)-1]}
		}
		_, _ = b.write(x.arrow.ID, nil, nil, nil, map[string]any{"from": spec.From.JSON(), "to": spec.To.JSON()}, caller, actor, "bound object "+id+" deleted", nil)
	}
}

// Overlaps is the objects id overlaps by accident, by layout.check's overlaps rule.
func (b *Board) Overlaps(id string) []string {
	var out []string
	for _, pair := range route.Overlaps(b.objects, []string{id}) {
		for _, x := range pair {
			if x != id {
				out = append(out, x)
			}
		}
	}
	return out
}

// mentionView adapts the board for the mention package.
var _ mention.BoardView = (*Board)(nil)

// Settled is the drawing layer's routing of the board as it is now (Board.settledRouting after
// settleArrows), which layout math routes on from.
func (b *Board) Settled() *route.Result {
	labels, _ := b.LabelSizes()
	b.settled = route.Geometry{Objects: b.objects, LabelSizes: labels, Settled: b.settled}.DrawnRouting(nil)
	return b.settled
}

// LabelSizes is the chip of every arrow with a caption (DrawingStyle.arrowLabel: its label, else
// its relation), measured by Texts in one batch, and which of them the glyph table approximated.
// Nil without Texts.
func (b *Board) LabelSizes() (sizes map[string]route.Size, approximate map[string]bool) {
	if b.Texts == nil {
		return nil, nil
	}
	var ids []string
	var items []measure.TextItem
	for _, id := range b.sortedIDs() {
		o := b.objects[id]
		if o.Type != model.Arrow {
			continue
		}
		if spec, ok := route.ParseArrow(o.Props); ok && spec.Caption() != "" {
			ids = append(ids, id)
			items = append(items, measure.TextItem{Kind: "arrowLabel", Text: spec.Caption()})
		}
	}
	if len(items) == 0 {
		return nil, nil
	}
	sizes, approximate = map[string]route.Size{}, map[string]bool{}
	for i, size := range b.Texts.MeasureText(items) {
		sizes[ids[i]] = route.Size{W: size.W, H: size.H}
		if size.Approximate {
			approximate[ids[i]] = true
		}
	}
	return sizes, approximate
}
