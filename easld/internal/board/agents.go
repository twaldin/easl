package board

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

// NotifyingVia is props.lifecycle.via of a lifecycle that comes from terminal notifications.
const NotifyingVia = "notifications"

func lifecycleOf(o model.Object) map[string]any {
	lc, _ := o.Props["lifecycle"].(map[string]any)
	return lc
}

// LifecycleState is a terminal's lifecycle state, "" when it has none.
func LifecycleState(o model.Object) string {
	s, _ := lifecycleOf(o)["state"].(string)
	return s
}

// NotifyingReports: the terminal's lifecycle comes from its program's notifications.
func NotifyingReports(o model.Object) bool { return lifecycleOf(o)["via"] == NotifyingVia }

// RunsAgent: an agent runs in the terminal (PromptTarget.runsAgent).
func RunsAgent(o model.Object) bool {
	agent, _ := o.Props["agent"].(map[string]any)
	_, hasKind := agent["kind"].(string)
	return LifecycleState(o) != "" && hasKind
}

// Drains: the terminal's agent integration takes staged mentions with its next prompt.
func Drains(o model.Object) bool { return RunsAgent(o) && !NotifyingReports(o) }

func isLifecycleState(s string) bool {
	for _, x := range model.LifecycleStates {
		if x == s {
			return true
		}
	}
	return false
}

// Report is an agent.report's params.
type Report struct {
	Tile, Kind, State string
	Message           *string
	Seq               *int
	Source            string // "" for none
	Call              *string
	Final             *string
	Serial            bool
	Error             *string
	// Protocol is the integration's protocol version (props.agent.protocol; 1 takes out-of-band
	// messages, TakesMessages); nil or 0 says none.
	Protocol *int
}

// ReportLifecycle applies an agent's lifecycle report (Board.reportLifecycle): the staleness rule
// by seq per tile and source, pending approvals by call, final answers and turn errors. A report
// of another agent kind, or of no protocol where it took messages, ends the agent session its
// messages were queued for (endAgentSession).
func (b *Board) ReportLifecycle(r Report) error {
	terminal, err := b.Object(r.Tile)
	if err != nil {
		return err
	}
	if terminal.Type != model.Terminal {
		return InvalidParams("%s is not a terminal tile", r.Tile)
	}
	if r.Final != nil && r.State != "idle" {
		return InvalidParams("final comes only with state idle: the answer of the turn that just ended")
	}
	if r.Error != nil && r.State != "idle" {
		return InvalidParams("error comes only with state idle: what the turn that just ended stopped on")
	}
	source := r.Source
	if source == "" {
		source = r.Kind
	}
	key := r.Tile + "|" + source
	if r.Seq != nil {
		if last, ok := b.lifecycleSeq[key]; ok && *r.Seq <= last {
			if r.State == "working" && r.Call != nil {
				b.resolveApproval(r.Tile, *r.Call)
			}
			return nil
		}
		b.lifecycleSeq[key] = *r.Seq
	}
	state, message := r.State, r.Message
	switch {
	case state == "blocked" && r.Call != nil:
		if r.Serial {
			b.pendingApprovals[r.Tile] = nil
		}
		b.pendingApprovals[r.Tile] = append(b.pendingApprovals[r.Tile], approval{*r.Call, message})
	case state == "working" && r.Call != nil:
		b.resolveApproval(r.Tile, *r.Call)
	case state == "blocked":
	default:
		delete(b.pendingApprovals, r.Tile)
	}
	if waiting := b.pendingApprovals[r.Tile]; len(waiting) > 0 {
		state, message = "blocked", waiting[0].message
	}
	if state == "working" {
		delete(b.seenSinceWorking, r.Tile)
		previous := LifecycleState(terminal)
		if previous != "working" && previous != "blocked" {
			b.agentStartedTurn(r.Tile)
			delete(b.finalAnswers, r.Tile)
			delete(b.turnErrors, r.Tile)
		}
	}
	if state == "idle" && r.Final != nil && strings.TrimSpace(*r.Final) != "" {
		b.finalAnswers[r.Tile] = *r.Final
	}
	failed := ""
	if r.Error != nil {
		failed = strings.TrimSpace(*r.Error)
	}
	if state == "idle" && failed != "" {
		b.turnErrors[r.Tile] = failed
		if message == nil {
			message = &failed
		}
	}
	effective := state
	if state == "idle" && failed == "" && !b.seenSinceWorking[r.Tile] && wasWorking(terminal) {
		effective = "done"
	}
	lifecycle := map[string]any{"state": effective, "seen": b.seenSinceWorking[r.Tile]}
	if message != nil {
		lifecycle["message"] = *message
	}
	if state == "unknown" {
		lifecycle["via"] = NotifyingVia
	}
	var version any
	if r.Protocol != nil && *r.Protocol > 0 {
		version = float64(*r.Protocol)
	}
	before, _ := terminal.Props["agent"].(map[string]any)
	agent, _ := model.Merge(orEmpty(terminal.Props["agent"]), map[string]any{"kind": r.Kind, "protocol": version}).(map[string]any)
	if _, err := b.Update(r.Tile, nil, nil, nil, map[string]any{"lifecycle": lifecycle, "agent": agent}, r.Tile, ""); err != nil {
		return err
	}
	if took, _ := TruncInt(before["protocol"]); took >= 1 && (before["kind"] != r.Kind || version == nil) {
		b.endAgentSession(r.Tile)
	}
	b.emit(EventAgentLifecycle, map[string]any{"tile": r.Tile, "lifecycle": model.Clone(lifecycle)})
	return nil
}

func orEmpty(v any) any {
	if v == nil {
		return map[string]any{}
	}
	return v
}

func (b *Board) resolveApproval(tile, call string) {
	waiting := b.pendingApprovals[tile]
	for i, a := range waiting {
		if a.call == call {
			waiting = append(waiting[:i:i], waiting[i+1:]...)
			if len(waiting) == 0 {
				delete(b.pendingApprovals, tile)
			} else {
				b.pendingApprovals[tile] = waiting
			}
			return
		}
	}
}

func wasWorking(terminal model.Object) bool {
	s := LifecycleState(terminal)
	return s == "working" || s == "done"
}

// ReportParams is agent.report given as its params (also a spooled report).
func (b *Board) ReportParams(p map[string]any) error {
	tile, ok1 := p["tile"].(string)
	kind, ok2 := p["kind"].(string)
	state, ok3 := p["state"].(string)
	if !ok1 || !ok2 || !ok3 {
		return InvalidParams("agent.report needs tile, kind, and state")
	}
	if !isLifecycleState(state) {
		return InvalidParams("unknown state")
	}
	r := Report{Tile: tile, Kind: kind, State: state}
	r.Message = optString(p["message"])
	if n, ok := TruncInt(p["seq"]); ok {
		r.Seq = &n
	}
	if s := optString(p["source"]); s != nil {
		r.Source = *s
	}
	r.Call = optString(p["call"])
	r.Final = optString(p["final"])
	r.Serial, _ = p["serial"].(bool)
	r.Error = optString(p["error"])
	if n, ok := TruncInt(p["protocol"]); ok {
		r.Protocol = &n
	}
	return b.ReportLifecycle(r)
}

func optString(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}

// TruncInt reads a number as JSONValue.int does: Int(number), truncating.
func TruncInt(v any) (int, bool) {
	f, ok := v.(float64)
	if !ok {
		return 0, false
	}
	return int(f), true
}

// jsonInt reads an integral number (Codable Int).
func jsonInt(v any) (int, bool) { return model.Int(v) }

// ReportSession records an agent's session on its terminal. Another session where one was
// recorded (a new conversation, or a replacement agent) ends the agent session its messages
// were queued for (endAgentSession).
func (b *Board) ReportSession(tile, kind string, sessionID, sessionPath *string) error {
	terminal, err := b.Object(tile)
	if err != nil {
		return err
	}
	agent, _ := model.Clone(terminal.Props["agent"]).(map[string]any)
	if agent == nil {
		agent = map[string]any{}
	}
	previous, recorded := agent["sessionId"].(string)
	agent["kind"] = kind
	if sessionID != nil {
		agent["sessionId"] = *sessionID
	}
	if sessionPath != nil {
		agent["sessionPath"] = *sessionPath
	}
	if _, err = b.Update(tile, nil, nil, nil, map[string]any{"agent": agent}, tile, ""); err != nil {
		return err
	}
	if recorded && sessionID != nil && *sessionID != previous {
		b.endAgentSession(tile)
	}
	return nil
}

// ReleaseAgent: the agent exited; the tile is a plain shell again, and the messages its
// integration never took bounce (endAgentSession).
func (b *Board) ReleaseAgent(tile string) error {
	if _, err := b.Object(tile); err != nil {
		return err
	}
	delete(b.pendingApprovals, tile)
	if _, err := b.Update(tile, nil, nil, nil, map[string]any{"lifecycle": nil, "agent": nil}, tile, ""); err != nil {
		return err
	}
	b.endAgentSession(tile)
	b.emit(EventAgentLifecycle, map[string]any{"tile": tile, "lifecycle": nil})
	return nil
}

// NotifyingAgentSubmitted: Return was pressed in a terminal whose agent reports by
// notification; its state is unknown until its next notification.
func (b *Board) NotifyingAgentSubmitted(tile string) bool {
	terminal, ok := b.objects[tile]
	if !ok || !NotifyingReports(terminal) || LifecycleState(terminal) == "unknown" {
		return false
	}
	agent, _ := terminal.Props["agent"].(map[string]any)
	kind, ok := agent["kind"].(string)
	if !ok {
		return false
	}
	lifecycle := map[string]any{"state": "unknown", "via": NotifyingVia}
	if model.Equal(terminal.Props["lifecycle"], lifecycle) && model.Equal(terminal.Props["agent"], map[string]any{"kind": kind}) {
		return true
	}
	_, _ = b.Update(tile, nil, nil, nil, map[string]any{"lifecycle": lifecycle, "agent": map[string]any{"kind": kind}}, tile, "")
	b.emit(EventAgentLifecycle, map[string]any{"tile": tile, "lifecycle": model.Clone(lifecycle)})
	return true
}

// Replay applies spooled agent reports, oldest first (AgentReportSpool / Board.replay).
func (b *Board) Replay(entries []SpoolEntry) {
	for _, e := range entries {
		if o, ok := b.objects[e.Tile]; !ok || o.Type != model.Terminal {
			continue
		}
		params := map[string]any{}
		for k, v := range e.Params {
			params[k] = v
		}
		params["tile"] = e.Tile
		switch e.Method {
		case "agent.report":
			_ = b.ReportParams(params)
		case "agent.release":
			source, ok := params["source"].(string)
			if !ok {
				source, _ = params["kind"].(string)
			}
			key := e.Tile + "|" + source
			if last, ok := b.lifecycleSeq[key]; ok && e.Seq <= last {
				continue
			}
			b.lifecycleSeq[key] = e.Seq
			_ = b.ReleaseAgent(e.Tile)
		}
	}
}

// --- attention (Attention.swift) ---

// AttentionJSON is a marker as the API and events carry it.
func AttentionJSON(a store.Attention) map[string]any {
	m := map[string]any{"id": a.Object, "active": true}
	if a.Message != nil {
		m["message"] = *a.Message
	}
	if a.RaisedBy != nil {
		m["raisedBy"] = *a.RaisedBy
	}
	return m
}

// RaiseAttention raises (or re-raises) the marker on id, clearing the caller's markers from
// earlier turns.
func (b *Board) RaiseAttention(id string, message *string, caller string) (store.Attention, []string, error) {
	if _, ok := b.objects[id]; !ok {
		return store.Attention{}, nil, NotFound("object %s", id)
	}
	var cleared []string
	if caller != "" {
		var ids []string
		for k := range b.attention {
			ids = append(ids, k)
		}
		sort.Strings(ids)
		for _, k := range ids {
			old := b.attention[k]
			if old.RaisedBy != nil && *old.RaisedBy == caller && old.EarlierTurn != nil && *old.EarlierTurn && old.Object != id {
				b.ClearAttention(old.Object)
				cleared = append(cleared, old.Object)
			}
		}
	}
	marker := store.Attention{Object: id, Message: message, RaisedAt: time.Now()}
	if caller != "" {
		c := caller
		marker.RaisedBy = &c
	}
	b.attention[id] = marker
	b.changed()
	b.emit(EventAttentionChanged, AttentionJSON(marker))
	return marker, cleared, nil
}

// ClearAttention removes the marker on id; false when it had none.
func (b *Board) ClearAttention(id string) bool {
	if _, ok := b.attention[id]; !ok {
		return false
	}
	delete(b.attention, id)
	b.changed()
	b.emit(EventAttentionChanged, map[string]any{"id": id, "active": false})
	return true
}

func (b *Board) agentStartedTurn(tile string) {
	changed := false
	for id, m := range b.attention {
		if m.RaisedBy != nil && *m.RaisedBy == tile && (m.EarlierTurn == nil || !*m.EarlierTurn) {
			t := true
			m.EarlierTurn = &t
			b.attention[id] = m
			changed = true
		}
	}
	if changed {
		b.changed()
	}
}

// --- follow mode ---

// FollowHistoryLimit is how many recent locations a follow tile keeps.
const FollowHistoryLimit = 8

// IsEdit: a follow report's action changed the file.
func IsEdit(action string) bool { return action == "edit" || action == "write" }

// FollowAim is where a follow tile aims among an edit's hunks: the one spanning the most lines,
// the last of equals.
func FollowAim(changes []model.LineRange) (model.LineRange, bool) {
	best, found, bestI := model.LineRange{}, false, -1
	for i, c := range changes {
		if !found || c.End-c.Start > best.End-best.Start || (c.End-c.Start == best.End-best.Start && i > bestI) {
			best, found, bestI = c, true, i
		}
	}
	return best, found
}

// Follow re-aims the terminal's follow tile at path/range, creating it on first use
// (Board.follow); ok false when ignored.
func (b *Board) Follow(tile, path string, rng *model.LineRange, changes []model.LineRange, action string) (model.Object, bool, error) {
	terminal, err := b.Object(tile)
	if err != nil {
		return model.Object{}, false, err
	}
	if terminal.Props["follow"] == false {
		return model.Object{}, false, nil
	}
	projects := []string{b.root}
	if cwd, ok := terminal.Props["cwd"].(string); ok {
		projects = append(projects, cwd)
	}
	if !Follows(b.AbsolutePath(path), projects, TempDirectories()) {
		return model.Object{}, false, nil
	}
	relative := b.RelativePath(path)
	var kept []model.LineRange
	for _, c := range changes {
		if c.Start >= 1 {
			kept = append(kept, model.LineRange{Start: c.Start, End: max(c.Start, c.End)})
		}
	}
	if rng == nil {
		if aim, ok := FollowAim(kept); ok {
			rng = &aim
		}
	}
	var rangeValue any
	if rng != nil {
		rangeValue = rng.JSON()
	}
	var lastChanges any
	if len(kept) > 0 {
		list := make([]any, len(kept))
		for i, c := range kept {
			list[i] = c.JSON()
		}
		lastChanges = list
	}
	props := map[string]any{"path": relative, "followOf": tile, "lastAction": action, "range": rangeValue, "lastChanges": lastChanges}
	var existing *model.Object
	if tiles := b.FollowTiles(tile); len(tiles) > 0 {
		existing = &tiles[0]
	}
	entry := map[string]any{"path": relative, "action": action}
	if rng != nil {
		entry["range"] = rangeValue
	}
	var hist []any
	if existing != nil {
		hist, _ = model.Clone(existing.Props["history"]).([]any)
	}
	same := func(other any) bool {
		o, _ := other.(map[string]any)
		return jsonEqualKey(o, entry, "path") && jsonEqualKey(o, entry, "range")
	}
	if !IsEdit(action) {
		for _, h := range hist {
			if same(h) {
				if earlier, ok := asJSONMap(h)["action"].(string); ok && IsEdit(earlier) {
					entry["action"] = earlier
				}
				break
			}
		}
	}
	filtered := []any{entry}
	for _, h := range hist {
		if !same(h) {
			filtered = append(filtered, h)
		}
	}
	hist = filtered
	for len(hist) > FollowHistoryLimit {
		drop := len(hist) - 1
		for i := len(hist) - 1; i >= 1; i-- {
			a, _ := asJSONMap(hist[i])["action"].(string)
			if !IsEdit(a) {
				drop = i
				break
			}
		}
		hist = append(hist[:drop:drop], hist[drop+1:]...)
	}
	props["history"] = hist
	var follow model.Object
	b.activityMuted = true
	err = func() error {
		defer func() { b.activityMuted = false }()
		if existing != nil {
			return b.unrecorded(func() error {
				var err error
				follow, err = b.Update(existing.ID, nil, nil, nil, props, tile, "")
				return err
			})
		}
		props["diffBase"] = "merge-base"
		w, h := DefaultSize(model.Code)
		created := map[string]any{}
		for k, v := range props {
			if v != nil {
				created[k] = v
			}
		}
		return b.unrecorded(func() error {
			frame := b.Place(w, h, tile, &FollowMinimumSize, false)
			follow = b.Create(model.Code, created, &frame, "", tile)
			return nil
		})
	}()
	if err != nil {
		return model.Object{}, false, err
	}
	at := ""
	if rng != nil {
		at = fmt.Sprintf(":%d-%d", rng.Start, rng.End)
	}
	verb := "follow tile re-aimed"
	if existing == nil {
		verb = "follow tile created"
	}
	b.Activity.Record(KindFollow, AgentActor(tile), b.revision, follow.ID, model.Code, fmt.Sprintf("%s at %s%s (%s)", verb, relative, at, action), "")
	b.emit(EventFollowUpdated, map[string]any{"tile": tile, "follow": follow.ID})
	return follow, true, nil
}

// FollowTiles is the code tiles following terminal, by id.
func (b *Board) FollowTiles(terminal string) []model.Object {
	var out []model.Object
	for _, id := range b.sortedIDs() {
		o := b.objects[id]
		if o.Type == model.Code && o.Props["followOf"] == terminal {
			out = append(out, o)
		}
	}
	return out
}

// RelativePath is path (absolute, or relative to the root) relative to the board root when it
// lies under it (also through a symlink), else absolute.
func (b *Board) RelativePath(path string) string { return RelativePath(path, b.root) }

func RelativePath(path, root string) string {
	var abs string
	if strings.HasPrefix(path, "/") {
		abs = store.Standardized(path)
	} else {
		abs = store.Standardized(filepath.Join(root, path))
	}
	rootPath := store.Standardized(root)
	if strings.HasPrefix(abs, rootPath+"/") {
		return abs[len(rootPath)+1:]
	}
	real, realRoot := RealPath(abs), RealPath(root)
	if strings.HasPrefix(real, realRoot+"/") {
		return real[len(realRoot)+1:]
	}
	return abs
}

// RealPath is GitDiffEngine.realPath: realpath(3) of the existing part, the rest appended.
func RealPath(path string) string {
	std := store.Standardized(path)
	existing, missing := std, []string{}
	for existing != "/" {
		if _, err := os.Lstat(existing); err == nil {
			break
		}
		missing = append([]string{filepath.Base(existing)}, missing...)
		existing = filepath.Dir(existing)
	}
	real, err := filepath.EvalSymlinks(existing)
	if err != nil {
		return std
	}
	return filepath.Join(append([]string{real}, missing...)...)
}

// AbsolutePath is path resolved against the board root.
func (b *Board) AbsolutePath(path string) string {
	if strings.HasPrefix(path, "/") {
		return path
	}
	return filepath.Join(b.root, path)
}

var followBinaryExtensions = map[string]bool{}

func init() {
	for _, e := range strings.Fields("png jpg jpeg gif webp bmp tif tiff ico icns svg heic heif avif psd pdf zip tar gz tgz bz2 xz zst 7z rar dmg iso jar war whl o a so dylib dll exe bin class wasm pyc db sqlite sqlite3 mp3 mp4 mov m4a wav webm ogg ttf otf woff woff2") {
		followBinaryExtensions[e] = true
	}
}

// MaxFileSize is the largest file a code tile shows (GitDiffEngine.maxFileSize).
const MaxFileSize = 4 << 20

// TempDirectories are the OS temp directory, /tmp and /var/tmp.
func TempDirectories() []string { return []string{os.TempDir(), "/tmp", "/var/tmp"} }

// Follows is FollowFilter.follows: a text file that exists in one of projects (or another
// worktree of a project's repository), outside temp directories unless the project is too.
func Follows(path string, projects, temps []string) bool {
	file := store.Standardized(path)
	within := func(dir, p string) bool { return dir == "/" || p == dir || strings.HasPrefix(p, dir+"/") }
	var containing []string
	for _, p := range projects {
		if s := store.Standardized(p); within(s, file) {
			containing = append(containing, s)
		}
	}
	if len(containing) == 0 {
		if w := store.Containing(file); w != nil {
			for _, p := range projects {
				if o := store.Containing(p); o != nil && o.CommonDir == w.CommonDir {
					containing = []string{w.Toplevel}
					break
				}
			}
		}
	}
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(file), "."))
	if len(containing) == 0 || followBinaryExtensions[ext] {
		return false
	}
	real := store.Normalized(file)
	info, err := os.Stat(real)
	if err != nil || info.IsDir() || info.Size() > MaxFileSize {
		return false
	}
	var tempsHolding []string
	for _, t := range temps {
		if r := store.Normalized(t); within(r, real) {
			tempsHolding = append(tempsHolding, r)
		}
	}
	ok := false
	for _, project := range containing {
		all := true
		for _, t := range tempsHolding {
			if !within(t, store.Normalized(project)) {
				all = false
			}
		}
		if all {
			ok = true
		}
	}
	if !ok {
		return false
	}
	f, err := os.Open(file)
	if err != nil {
		return false
	}
	defer f.Close()
	head := make([]byte, 8000)
	n, _ := f.Read(head)
	return !bytes.Contains(head[:n], []byte{0})
}

// SpoolEntry is one spooled agent report (AgentReportSpool.Entry).
type SpoolEntry struct {
	Tile   string
	Seq    int
	Method string
	Params map[string]any
	File   string
}
