package router

import (
	"errors"
	"math"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/store"
)

type waiter struct {
	id                  any
	conn                Conn
	tile                string
	until               map[string]bool
	firstReportDeadline time.Time
	done                bool
	timers              []*time.Timer // its timeout and grace rechecks, stopped when it is done
	finished            chan struct{} // closed when it is done
}

// finish ends a waiter that was answered, timed out or lost its connection: its timers are
// stopped so nothing keeps it alive.
func (r *Router) finish(w *waiter) {
	if w.done {
		return
	}
	w.done = true
	for _, t := range w.timers {
		t.Stop()
	}
	w.timers = nil
	close(w.finished)
}

// after runs f for w under the registry's lock in d.
func (r *Router) after(w *waiter, d time.Duration, f func()) {
	w.timers = append(w.timers, time.AfterFunc(d, func() {
		r.reg.Mu.Lock()
		defer r.reg.Mu.Unlock()
		f()
	}))
}

func stateOf(terminal model.Object) string {
	if s := board.LifecycleState(terminal); s != "" {
		return s
	}
	return "unknown"
}

// agentTile is the terminal target addresses (AgentAddress.resolve: a tile id, `name` or
// `name@board`) on the open boards; a bare name on caller's board first, when caller is a
// terminal on one ("" for none). Fails not_found and ambiguous.
func (r *Router) agentTile(target, caller string) (*board.Board, model.Object, error) {
	boards := r.reg.SortedBoards()
	for _, b := range boards {
		if o, ok := b.Objects()[target]; ok && o.Type == model.Terminal {
			return b, o, nil
		}
	}
	if at := strings.LastIndex(target, "@"); at >= 0 {
		name, part := target[:at], target[at+1:]
		// Only a board whose root folder still exists is found by name; any by its id.
		var live, named []*board.Board
		for _, b := range boards {
			exists := store.IsDirectory(b.Root())
			if exists {
				live = append(live, b)
			}
			if b.ID() == part || (exists && board.BoardName(b.Root()) == part) {
				named = append(named, b)
			}
		}
		if len(named) == 0 {
			open := make([]string, len(live))
			for i, b := range live {
				open[i] = board.BoardName(b.Root())
			}
			sort.Strings(open)
			list := strings.Join(open, ", ")
			if list == "" {
				list = "none"
			}
			return nil, model.Object{}, fail(api.CodeNotFound, "no open board named %s (open boards: %s)", part, list)
		}
		if len(named) > 1 {
			listed := make([]string, len(named))
			for i, b := range named {
				listed[i] = board.BoardName(b.Root()) + " (" + b.ID() + ", " + b.Root() + ")"
			}
			return nil, model.Object{}, fail(api.CodeAmbiguous, "%s names %d open boards: %s; address the board by its id, %s@%s", part, len(named), strings.Join(listed, ", "), name, named[0].ID())
		}
		b, o, err := lookUpAgent(name, target, named, boards)
		if err != nil || b != nil {
			return b, o, err
		}
		return nil, model.Object{}, fail(api.CodeNotFound, "no terminal tile named %s on board %s", name, part)
	}
	if caller != "" {
		for _, own := range boards {
			if o, ok := own.Objects()[caller]; ok && o.Type == model.Terminal {
				if b, o, err := lookUpAgent(target, target, []*board.Board{own}, boards); err != nil || b != nil {
					return b, o, err
				}
				break
			}
		}
	}
	if b, o, err := lookUpAgent(target, target, boards, boards); err != nil || b != nil {
		return b, o, err
	}
	return nil, model.Object{}, fail(api.CodeNotFound, "no terminal tile named or with id %s", target)
}

// lookUpAgent is the terminal named name on boards: on each board its current name first, else
// an alias; nil board for none, ambiguous for more than one across them, each listed by its
// address among all.
func lookUpAgent(name, target string, boards, all []*board.Board) (*board.Board, model.Object, error) {
	type match struct {
		board    *board.Board
		terminal model.Object
	}
	var named []match
	for _, b := range boards {
		current := false
		for _, o := range sortedTerminals(b) {
			if n, ok := board.AgentName(o); ok && n == name {
				named, current = append(named, match{b, o}), true
			}
		}
		if id, ok := b.Alias(name); ok && !current {
			if o, ok := b.Objects()[id]; ok && o.Type == model.Terminal {
				named = append(named, match{b, o})
			}
		}
	}
	switch len(named) {
	case 0:
		return nil, model.Object{}, nil
	case 1:
		return named[0].board, named[0].terminal, nil
	}
	listed := make([]string, len(named))
	for i, m := range named {
		reach := board.Address(m.terminal, m.board, all)
		if reach == m.terminal.ID {
			reach = name
		}
		listed[i] = reach + " (" + m.terminal.ID + ")"
	}
	sort.Strings(listed)
	return nil, model.Object{}, fail(api.CodeAmbiguous, "%s matches %d terminals: %s; address one as name@board, or by its tile id", target, len(named), strings.Join(listed, ", "))
}

// sortedTerminals are b's terminal tiles by id.
func sortedTerminals(b *board.Board) []model.Object {
	var out []model.Object
	for _, o := range b.Objects() {
		if o.Type == model.Terminal {
			out = append(out, o)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// agentEntry is a terminal as agent.list reports it; title, program and last command come from
// the app's terminal surface, which easld doesn't have.
func (r *Router) agentEntry(terminal model.Object, b *board.Board) map[string]any {
	entry := terminalEntry(terminal, b.ID(), b.Root())
	entry["address"] = board.Address(terminal, b, r.reg.SortedBoards())
	if aliases := b.Aliases(terminal.ID); len(aliases) > 0 {
		list := make([]any, len(aliases))
		for i, a := range aliases {
			list[i] = a
		}
		entry["aliases"] = list
	}
	return entry
}

// terminalEntry is what an agent.list entry says of a terminal on any board, open or stored:
// everything but its address and aliases.
func terminalEntry(terminal model.Object, boardID, root string) map[string]any {
	agent := asMap(terminal.Props["agent"])
	entry := map[string]any{"tile": terminal.ID, "board": boardID, "root": root, "kind": "unknown"}
	if agent != nil {
		if k, present := agent["kind"]; present {
			entry["kind"] = k
		}
		if s, present := agent["sessionId"]; present {
			entry["sessionId"] = s
		}
		if v, present := agent["protocol"]; present {
			entry["protocol"] = v
		}
	}
	if name, present := terminal.Props["name"]; present {
		entry["name"] = name
	}
	if lc, present := terminal.Props["lifecycle"]; present {
		entry["lifecycle"] = lc
	} else {
		entry["lifecycle"] = map[string]any{"state": "unknown"}
	}
	addAgentControl(entry, agent, board.TerminalHost(terminal) != "")
	for k, v := range entry {
		if v == nil {
			delete(entry, k)
		}
	}
	return entry
}

// addAgentControl adds to an agent.list entry what agent control reads: its board is open and,
// with no window, nothing has keyboard focus; the draft, model and thinking level its
// integration reported, and the pid it reported while that process lives (withSession adds
// what an owned terminal's session says). A hosted terminal's processes are its host's
// (props.host): it has no pid, and its reported one is never probed on this machine, where
// another process may have that number.
func addAgentControl(entry, agent map[string]any, hosted bool) {
	entry["open"] = true
	entry["focused"] = false
	for _, key := range []string{"draft", "model", "thinking"} {
		if v, present := agent[key]; present && v != nil {
			entry[key] = v
		}
	}
	if pid, ok := board.TruncInt(agent["pid"]); ok && !hosted && processLives(pid) {
		entry["pid"] = float64(pid)
	}
}

// processLives: a process with this pid runs (signal 0 reaches it, or it runs as another user).
func processLives(pid int) bool {
	if pid < 1 || pid > math.MaxInt32 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// agentList is agent.list: every terminal of the open boards, by board id then tile id, then of
// the closed ones (closedBoardAgents). On an easld that owns its terminals, each not hosted
// says whether its session runs (live) and stands in its foreground process for a pid no
// integration reported (withSession), from easld's zmx, listed with the registry's lock let go
// (zmx takes up to a second), as the app reads its own.
func (r *Router) agentList() map[string]any {
	sessions := r.ownSessions()
	agents := []any{}
	for _, b := range r.reg.SortedBoards() {
		for _, terminal := range sortedTerminals(b) {
			agents = append(agents, r.withSession(r.agentEntry(terminal, b), b.ID(), mergedInto(b), terminal, sessions))
		}
	}
	return map[string]any{"agents": append(agents, r.closedBoardAgents(sessions)...)}
}

// ownSessions are the sessions zmx lists by their tile: nil when easld doesn't own its
// terminals or zmx can't list them. The caller holds the registry's lock, which this lets go
// meanwhile.
func (r *Router) ownSessions() map[string]session.Session {
	if r.Owns == nil || r.Sessions == nil {
		return nil
	}
	r.reg.Mu.Unlock()
	defer r.reg.Mu.Lock()
	list, err := r.Sessions.List()
	if err != nil {
		return nil
	}
	sessions := map[string]session.Session{}
	for _, s := range list {
		sessions[s.Tile] = s
	}
	return sessions
}

// withSession is the agent.list entry of `terminal` on board `boardID` with what its session
// says, when sessions are known (non-nil; ApiRouter.withSession): `live`, a session carrying its
// labels (Owner.Labels: not another home's or board's of its name, but for one of `merged`, the
// boards boardID took in); without one no process of it runs (a pid reported before is stale,
// or another process's by now); with one, its foreground process (session.ForegroundPID) stands
// in for a pid no integration reported. A hosted terminal's session is its host's.
func (r *Router) withSession(entry map[string]any, boardID string, merged []string, terminal model.Object, sessions map[string]session.Session) map[string]any {
	if sessions == nil || board.TerminalHost(terminal) != "" {
		return entry
	}
	s, listed := sessions[terminal.ID]
	live := listed && s.Carries(r.Owns.Labels(boardID, terminal.ID), merged...)
	entry["live"] = live
	if !live {
		delete(entry, "pid")
	} else if _, reported := entry["pid"]; !reported {
		if pid := session.ForegroundPID(s.PID); pid > 0 {
			entry["pid"] = float64(pid)
		}
	}
	return entry
}

// closedBoardAgents is agent.list's terminals on the boards easld has stored but not open, by
// board id then tile id, as their saved board files have them: a lifecycle saved `working` or
// `blocked` is `restored` (as opening the board marks it), and each carries the address that
// reaches it once its board opens: `<name>@<its root's directory name>`, else its tile id. A
// terminal an open board lists already isn't listed again. `sessions` are as withSession takes
// them.
func (r *Router) closedBoardAgents(sessions map[string]session.Session) []any {
	var agents []any
	for _, snap := range r.reg.Store.Snapshots() {
		if _, open := r.reg.Board(snap.ID); open {
			continue
		}
		var terminals []model.Object
		for _, o := range snap.Objects {
			if o.Type == model.Terminal && !r.openTerminal(o.ID) {
				terminals = append(terminals, o)
			}
		}
		sort.SliceStable(terminals, func(i, j int) bool { return terminals[i].ID < terminals[j].ID })
		for _, terminal := range terminals {
			board.MarkRestored(terminal)
			entry := terminalEntry(terminal, snap.ID, snap.Root)
			entry["open"] = false
			entry["address"] = terminal.ID
			delete(entry, "name")
			if name, ok := terminal.Props["name"].(string); ok && name != "" {
				entry["name"] = name
				entry["address"] = name + "@" + filepath.Base(snap.Root)
			}
			var merged []string
			if snap.Repo != nil {
				merged = snap.Repo.Merged
			}
			agents = append(agents, r.withSession(entry, snap.ID, merged, terminal, sessions))
		}
	}
	return agents
}

// openTerminal: a terminal tile with this id is on an open board.
func (r *Router) openTerminal(id string) bool {
	for _, b := range r.reg.Boards() {
		if o, ok := b.Objects()[id]; ok && o.Type == model.Terminal {
			return true
		}
	}
	return false
}

var waitableStates = []string{"blocked", "done", "idle", "unknown", "working"}

func waitStates(value any) (map[string]bool, error) {
	if value == nil {
		return map[string]bool{"idle": true, "done": true, "blocked": true}, nil
	}
	items, ok := value.([]any)
	if !ok {
		return nil, invalid("until must be an array of states, e.g. [\"working\"]")
	}
	set := map[string]bool{}
	for _, item := range items {
		s, ok := item.(string)
		if !ok || !contains(waitableStates, s) {
			return nil, invalid("unknown state %s in until; one of %s", describe(item), strings.Join(waitableStates, ", "))
		}
		set[s] = true
	}
	return set, nil
}

func sortedSet(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// wait is agent.wait: answered now when the terminal is in one of `until`, else when it gets
// there, times out, or can never get there.
func (r *Router) wait(id any, p map[string]any, c Conn) (any, error) {
	target, err := str(p, "target")
	if err != nil {
		return nil, err
	}
	caller, _ := optStr(p, "caller")
	b, terminal, err := r.agentTile(target, caller)
	if err != nil {
		return nil, err
	}
	until, err := waitStates(p["until"])
	if err != nil {
		return nil, err
	}
	w := &waiter{id: id, conn: c, tile: terminal.ID, until: until, firstReportDeadline: time.Now().Add(r.FirstReportGrace), finished: make(chan struct{})}
	if reply := r.reply(w, b, false); reply != nil {
		c.Send(reply)
		return nil, nil
	}
	r.waiters = append(r.waiters, w)
	if timeout, ok := intParam(p, "timeoutMs"); ok {
		r.after(w, time.Duration(max(0, timeout))*time.Millisecond, func() { r.expire(w) })
	}
	r.after(w, r.FirstReportGrace, func() { r.recheck(w) })
	if prompted, ok := r.pendingPrompts[terminal.ID]; ok {
		r.recheckAt(w, prompted.Add(r.PromptStartGrace))
	}
	go func() {
		select {
		case <-c.Done():
			r.reg.Mu.Lock()
			defer r.reg.Mu.Unlock()
			if !w.done {
				r.remove(w)
				r.finish(w)
			}
		case <-w.finished:
		}
	}()
	return nil, nil
}

func lifecycleUnknown(terminal model.Object) *Failure {
	return &Failure{api.CodeUnavailable, "terminal " + terminal.ID + " reports no agent lifecycle (nothing in it has an easl integration, or its agent exited), " +
		"so agent.wait can't tell when it is done; poll agent.read with since: \"prompt\" instead"}
}

// reply is the response for a satisfied waiter, nil while it must keep waiting.
func (r *Router) reply(w *waiter, b *board.Board, exited bool) map[string]any {
	terminal, ok := b.Objects()[w.tile]
	if !ok {
		return errorReply(w.id, &Failure{api.CodeNotFound, "terminal " + w.tile + " was closed"})
	}
	state := stateOf(terminal)
	if state == "unknown" && !w.until[state] {
		if !exited && board.NotifyingReports(terminal) {
			return nil
		}
		if !exited && time.Now().Before(w.firstReportDeadline) {
			return nil
		}
		return errorReply(w.id, lifecycleUnknown(terminal))
	}
	// A message the terminal's integration hasn't delivered yet: its turn hasn't started.
	if len(b.Messages(w.tile)) > 0 {
		return nil
	}
	if prompted, ok := r.pendingPrompts[w.tile]; ok {
		if time.Since(prompted) < r.PromptStartGrace {
			return nil
		}
		return errorReply(w.id, &Failure{api.CodeUnavailable, w.tile + "'s last agent.prompt started no turn within " + formatSeconds(r.PromptStartGrace) + " s " +
			"(its agent reported neither working nor blocked: a / command or ! escape is no turn, or the agent didn't take the text as a prompt), " +
			"so agent.wait can't tell when it is done; read what followed with agent.read since: \"prompt\""})
	}
	if !w.until[state] {
		return nil
	}
	return okReply(w.id, map[string]any{"agent": r.agentEntry(terminal, b)})
}

// formatSeconds is Double.formatted(): `60`, `1.5`.
func formatSeconds(d time.Duration) string {
	return strconv.FormatFloat(d.Seconds(), 'f', -1, 64)
}

func (r *Router) observe(b *board.Board, e model.Event) {
	var tile string
	exited := false
	data := asMap(e.Data)
	switch e.Name {
	case board.EventAgentLifecycle:
		tile, _ = data["tile"].(string)
		lifecycle := data["lifecycle"]
		exited = lifecycle == nil
		state := asMap(lifecycle)["state"]
		if exited || state == "working" || state == "blocked" {
			delete(r.pendingPrompts, tile)
		}
	case board.EventObjectDeleted:
		tile, _ = data["id"].(string)
		delete(r.pendingPrompts, tile)
	default:
		return
	}
	kept := r.waiters[:0]
	for _, w := range r.waiters {
		if !w.conn.IsOpen() {
			r.finish(w)
			continue
		}
		if w.tile == tile {
			if reply := r.reply(w, b, exited); reply != nil {
				w.conn.Send(reply)
				r.finish(w)
				continue
			}
		}
		kept = append(kept, w)
	}
	clear(r.waiters[len(kept):])
	r.waiters = kept
}

func (r *Router) remove(w *waiter) bool {
	for i, x := range r.waiters {
		if x == w {
			r.waiters = slices.Delete(r.waiters, i, i+1)
			return true
		}
	}
	return false
}

func (r *Router) recheck(w *waiter) {
	if w.done {
		return
	}
	b, _, err := r.agentTile(w.tile, "")
	if err != nil {
		return
	}
	reply := r.reply(w, b, false)
	if reply == nil {
		if prompted, ok := r.pendingPrompts[w.tile]; ok {
			r.recheckAt(w, prompted.Add(r.PromptStartGrace))
		}
		return
	}
	r.remove(w)
	r.finish(w)
	w.conn.Send(reply)
}

func (r *Router) recheckAt(w *waiter, at time.Time) {
	r.after(w, max(0, time.Until(at)), func() { r.recheck(w) })
}

func (r *Router) expire(w *waiter) {
	if w.done || !r.remove(w) {
		return
	}
	r.finish(w)
	w.conn.Send(errorReply(w.id, &Failure{api.CodeTimeout, w.tile + " did not reach " + strings.Join(sortedSet(w.until), "|") + " in time"}))
}

// --- terminals (app surfaces) ---

const terminalCommandLogCapacity = 50

// read is agent.read: `final` answers from the board; the screen, `since` and `block` are a
// client's to read from its terminal surface.
func (r *Router) read(p map[string]any) (any, error) {
	target, err := str(p, "target")
	if err != nil {
		return nil, err
	}
	caller, _ := optStr(p, "caller")
	b, terminal, err := r.agentTile(target, caller)
	if err != nil {
		return nil, err
	}
	if boolParam(p, "final") {
		return r.finalAnswer(terminal, b, p)
	}
	since, hasSince := p["since"]
	if hasSince && since != nil && since != "prompt" {
		return nil, invalid("since must be \"prompt\"")
	}
	if !hasSince || since == nil {
		hasSince = false
	}
	hasBlock := false
	if value, present := p["block"]; present && value != nil {
		n, isNum := value.(float64)
		if value != "last" && !(isNum && n <= -1 && n == float64(int64(n)) && n >= -terminalCommandLogCapacity) {
			return nil, invalid("block must be \"last\" or a whole number from -1 (the last command) to -%d: -2 is the one before the last", terminalCommandLogCapacity)
		}
		hasBlock = true
	}
	if hasBlock && hasSince {
		return nil, invalid("since and block don't combine: block reads a command's output, since the reply to the last agent.prompt")
	}
	requested := 100
	if !hasSince && !hasBlock {
		requested = 100
	} else {
		requested = 2000
	}
	if n, ok := intParam(p, "lines"); ok {
		requested = n
	}
	if requested < 1 {
		return nil, invalid("lines must be at least 1")
	}
	params := copyParams(p)
	params["target"] = terminal.ID
	return r.forward("agent.read", b.ID(), params, clients.TerminalDeadline, "agent.read reads the terminal's screen through its live surface (final: true needs none)")
}

func (r *Router) finalAnswer(terminal model.Object, b *board.Board, p map[string]any) (any, error) {
	_, hasLines := p["lines"]
	_, hasSince := p["since"]
	if hasLines || hasSince {
		return nil, invalid("final takes no lines or since: it returns the whole last answer")
	}
	state := stateOf(terminal)
	_, prompted := r.pendingPrompts[terminal.ID]
	prompted = prompted || len(b.Messages(terminal.ID)) > 0
	if prompted || state == "working" || state == "blocked" {
		why := state
		if prompted {
			why = "prompted"
		}
		return nil, fail(api.CodeUnavailable, "%s is still in its turn (%s): agent.wait for it, then read final", terminal.ID, why)
	}
	cutOff, hasCutOff := b.TurnError(terminal.ID)
	answer, ok := b.FinalAnswer(terminal.ID)
	if !ok {
		if hasCutOff {
			return nil, fail(api.CodeUnavailable, "%s's last turn ended on an error before any answer: %s", terminal.ID, cutOff)
		}
		kind, ok := asMap(terminal.Props["agent"])["kind"].(string)
		if !ok {
			kind = "none reporting"
		}
		return nil, fail(api.CodeUnavailable, "no final answer is known for %s's last turn: its agent (%s) reported none, or the turn was interrupted. Read the screen with since: \"prompt\" instead", terminal.ID, kind)
	}
	result := map[string]any{
		"agent": r.agentEntry(terminal, b), "text": answer,
		"lines": float64(strings.Count(answer, "\n") + 1),
	}
	if hasCutOff {
		result["cutOff"] = cutOff
	}
	return result, nil
}

// prompt is agent.prompt: to a terminal whose integration takes messages it queues one
// (queueMessage); into any other, and a composer's prompt into any terminal, a client types it,
// after the board's refusals, with the mentions the board hands over.
func (r *Router) prompt(p map[string]any) (any, error) {
	if err := checkComposer(p); err != nil {
		return nil, err
	}
	target, err := str(p, "target")
	if err != nil {
		return nil, err
	}
	caller, _ := optStr(p, "caller")
	b, terminal, err := r.agentTile(target, caller)
	if err != nil {
		return nil, err
	}
	text, err := str(p, "text")
	if err != nil {
		return nil, err
	}
	mentions, _ := p["mentions"].([]any)
	when := "now"
	if value, present := p["when"]; present && value != nil {
		s, _ := value.(string)
		if s != "now" && s != "next-turn" {
			return nil, invalid("when is \"now\" (the default) or \"next-turn\"")
		}
		when = s
	}
	label := ""
	if value, present := p["from"]; present && value != nil {
		s, ok := value.(string)
		if !ok || measure.TrimWS(s) == "" {
			return nil, invalid("from is a sender label such as \"machine-watch\"")
		}
		label = s
	}
	if _, restarting := r.restarts[terminal.ID]; restarting {
		return nil, restartingFailure(terminal.ID)
	}
	composer := boolParam(p, "composer")
	if !composer && board.TakesMessages(terminal) {
		return r.queueMessage(text, terminal, b, mentions, caller, label, when)
	}
	if when == "next-turn" && stateOf(terminal) == "working" {
		return nil, fail(api.CodeConflict, "%s is in its turn and its integration takes no messages, so typed text would join that turn; agent.wait for it and send again, or send with when: \"now\"", terminal.ID)
	}
	force := boolParam(p, "force")
	// The user's answer from a composer (a remote board's viewer) passes the blocked check alone.
	answering := composer && boolParam(p, "answer")
	lifecycle := asMap(terminal.Props["lifecycle"])
	if stateOf(terminal) == "blocked" && !force && !answering {
		blocker := ""
		if m, ok := lifecycle["message"].(string); ok {
			blocker = " (“" + m + "”)"
		}
		return nil, fail(api.CodeConflict, "%s is blocked, waiting on its user%s: the prompt would go into that dialog. Leave it to the user. force: true types into the dialog and presses Return, which in an approval menu picks the highlighted option (usually allow), so never force an answer to an approval", terminal.ID, blocker)
	}
	if stateOf(terminal) == "working" && lifecycle["restored"] == true && !force {
		return nil, fail(api.CodeConflict, "%s was working when easl last closed and its agent hasn't reported since, so it may now wait on a question or approval that the prompt would answer. Read its screen (agent.read) first; force: true sends anyway", terminal.ID)
	}
	c, err := r.client("agent.prompt", b.ID(), "agent.prompt types through the terminal's live surface")
	if err != nil {
		return nil, err
	}
	var targets []map[string]any
	if list, present := p["mentions"]; present && list != nil {
		items, ok := list.([]any)
		if !ok {
			return nil, invalid("mentions must be a list of {object, lines?, point?}")
		}
		for _, item := range items {
			t, err := promptMention(item, b)
			if err != nil {
				return nil, err
			}
			targets = append(targets, t)
		}
	}
	if len(targets) > 0 && !board.Drains(terminal) {
		return nil, fail(api.CodeUnavailable, "%s runs no agent with an easl integration, so nothing there would take the mentions; name the objects in the text instead", terminal.ID)
	}
	// Queued before the text goes in: the target's integration drains them with this prompt.
	name, named := "", false
	if caller != "" {
		if _, tile, err := r.agentTile(caller, ""); err == nil {
			name, named = board.PromptLabel(tile), true
		}
	}
	handed, err := b.HandOff(targets, terminal.ID, caller, name, named, "")
	if err != nil {
		return nil, err
	}
	ids := make([]string, len(handed))
	for i, m := range handed {
		ids[i] = m.ID
	}
	params := copyParams(p)
	delete(params, "mentions")
	params["target"] = terminal.ID
	// From here until its turn reports, agent.restart counts the prompt as work (promptPending).
	r.typing[terminal.ID]++
	result, err := r.await(c, "agent.prompt", params, clients.TerminalDeadline)
	if r.typing[terminal.ID]--; r.typing[terminal.ID] <= 0 {
		delete(r.typing, terminal.ID)
	}
	if err != nil {
		b.Commit(ids)
		return nil, err
	}
	current, ok := b.Objects()[terminal.ID]
	if !ok {
		b.Commit(ids)
		return nil, fail(api.CodeNotFound, "terminal %s was closed", terminal.ID)
	}
	// Only a reporting agent's next report can end the pre-prompt state; one still in its turn
	// takes the prompt into that turn, whose end answers agent.wait.
	notifying := board.NotifyingReports(current)
	if notifying {
		b.NotifyingAgentSubmitted(terminal.ID)
	} else if stateOf(current) != "unknown" && stateOf(current) != "working" {
		r.pendingPrompts[terminal.ID] = time.Now()
	}
	if len(handed) > 0 {
		list := make([]any, len(handed))
		for i, m := range handed {
			list[i] = m.APIJSON()
		}
		result["mentions"] = list
	}
	return result, nil
}

// checkComposer checks agent.prompt's `composer` and `answer` before the target, as
// ApiRouter.checkComposer does: only the user answers, and the composer's prompt is the user's,
// typed (no caller, from, when or force).
func checkComposer(p map[string]any) error {
	composer := boolParam(p, "composer")
	if boolParam(p, "answer") && !composer {
		return invalid("answer is the user's answer from a composer: it needs composer: true (an agent or script sends force: true instead)")
	}
	if !composer {
		return nil
	}
	if caller, ok := p["caller"]; ok && caller != nil {
		return invalid("a composer's prompt is the user's: it takes no caller")
	}
	if from, ok := p["from"]; ok && from != nil {
		return invalid("a composer's prompt is the user's: it takes no from")
	}
	if when, ok := p["when"]; ok && when != nil {
		return invalid("a composer's prompt is typed as the user sends it: it takes no when")
	}
	if boolParam(p, "force") {
		return invalid("a composer's prompt never forces: answer: true answers a blocked target")
	}
	return nil
}

// restartKinds are the agents agent.restart relaunches by kind (AgentResume's grammars).
var restartKinds = []string{"omp", "claude", "codex", "gemini", "opencode"}

// restart is agent.restart: its refusals are the board's (ApiRouter.restart's but focus, which
// needs a window), and one restart of a terminal at a time; then a terminal easld owns is
// restarted by easld itself (restartOwned), and any other's by a client, which kills the tile's
// zmx session and relaunches it through its terminal tile, checking again just before the kill.
// While the client does, the terminal is held (restarts, owned by this restart): agent.prompt to
// it is refused and no inbox poll takes what is queued for it. Once the client has relaunched
// it, the killed agent's session is over and what was queued bounces (Board.EndAgentSession; the
// app ends the session between the kill and the relaunch), so none of it reaches the relaunched
// agent. Refused or failed, the session goes on and its messages are offered again.
func (r *Router) restart(p map[string]any) (any, error) {
	target, err := str(p, "target")
	if err != nil {
		return nil, err
	}
	caller, _ := optStr(p, "caller")
	b, terminal, err := r.agentTile(target, caller)
	if err != nil {
		return nil, err
	}
	mode, err := str(p, "mode")
	if err != nil {
		return nil, err
	}
	if mode != "resume" && mode != "fresh" {
		return nil, invalid("mode is resume or fresh, not %s", mode)
	}
	if args, present := p["args"]; present && args != nil {
		items, ok := args.([]any)
		for _, item := range items {
			if _, isString := item.(string); !isString {
				ok = false
			}
		}
		if !ok {
			return nil, invalid("args is an array of strings")
		}
	}
	if _, busy := r.restarts[terminal.ID]; busy {
		return nil, fail(api.CodeConflict, "%s is already restarting (another agent.restart): wait for that one to finish", terminal.ID)
	}
	// Even forced: the client would type the prompt into the relaunched agent (ApiRouter.typingFailure).
	if r.typing[terminal.ID] > 0 {
		return nil, typingFailure(terminal.ID)
	}
	agent := asMap(terminal.Props["agent"])
	if !boolParam(p, "force") {
		if err := r.restartRefusal(b, terminal, agent); err != nil {
			return nil, err
		}
	}
	kind, _ := agent["kind"].(string)
	known := slices.Contains(restartKinds, kind)
	if mode == "resume" {
		if !known || resumedSession(agent) == "" {
			return nil, fail(api.CodeUnavailable, "%s has no recorded agent session to resume (its agent never reported one, or it exited); mode fresh starts it anew", terminal.ID)
		}
	} else if !known && len(strings_(terminal.Props["command"])) == 0 {
		return nil, fail(api.CodeUnavailable, "%s runs no known agent and has no command to relaunch", terminal.ID)
	}
	// A terminal easld owns runs in easld's own session: easld restarts it, no client needed.
	if r.Owns != nil && board.TerminalHost(terminal) == "" {
		return r.restartOwned(b, terminal, mode, strings_(p["args"]), boolParam(p, "force"))
	}
	params := copyParams(p)
	params["target"] = terminal.ID
	c, err := r.client("agent.restart", b.ID(), "agent.restart kills and relaunches the terminal's session through its live surface")
	if err != nil {
		return nil, err
	}
	r.restartSeq++
	op := r.restartSeq
	r.restarts[terminal.ID] = op
	result, err := r.await(c, "agent.restart", params, clients.TerminalDeadline)
	if r.restarts[terminal.ID] == op {
		delete(r.restarts, terminal.ID)
	}
	if err != nil {
		r.serveInbox(terminal.ID, b)
		return nil, err
	}
	delete(r.pendingPrompts, terminal.ID)
	b.EndAgentSession(terminal.ID)
	r.serveInbox(terminal.ID, b)
	return result, nil
}

// restartingFailure is agent.prompt's answer for a terminal agent.restart holds.
func restartingFailure(tile string) error {
	return fail(api.CodeConflict, "%s is restarting (agent.restart): nothing reaches it until its agent is relaunched; send again once it reports", tile)
}

// typingFailure is agent.restart's answer for a terminal a client is typing an agent.prompt into.
func typingFailure(tile string) error {
	return fail(api.CodeConflict, "%s is being prompted right now (agent.prompt is typing into it): restarting would cut that prompt off; try again in a moment", tile)
}

// resumedSession is the session agent.restart resumes (AgentResume.session): omp's session file
// when it reported one (its `--resume` takes a path), else the session id; "" for none.
func resumedSession(agent map[string]any) string {
	session, isPath := "", false
	if agent["kind"] == "omp" {
		session, isPath = agent["sessionPath"].(string)
	}
	if !isPath {
		session, _ = agent["sessionId"].(string)
	}
	return session
}

// restartRefusal is why agent.restart leaves a terminal alone without force: the dialog, turn,
// prompt, queued message or draft a restart would lose, in that order; a draft no integration
// reports is one the user may have. (The app also refuses while the user may be typing in it:
// easld has no window to have keyboard focus.)
func (r *Router) restartRefusal(b *board.Board, terminal model.Object, agent map[string]any) error {
	switch stateOf(terminal) {
	case "blocked":
		blocker := ""
		if m, ok := asMap(terminal.Props["lifecycle"])["message"].(string); ok {
			blocker = " (“" + m + "”)"
		}
		return fail(api.CodeConflict, "%s is blocked, waiting on its user%s: restarting would drop that dialog; force: true restarts anyway", terminal.ID, blocker)
	case "working":
		return fail(api.CodeConflict, "%s is working: restarting would kill its turn. Wait for it (agent.wait), or force: true restarts anyway", terminal.ID)
	}
	if r.promptPending(terminal.ID) {
		return fail(api.CodeConflict, "%s was just prompted and hasn't started that turn: restarting would lose the prompt. Wait for it (agent.wait), or force: true restarts anyway", terminal.ID)
	}
	// A message its integration hasn't taken yet: its turn hasn't started, as agent.wait counts it.
	// A restart would bounce it (EndAgentSession).
	if len(b.Messages(terminal.ID)) > 0 {
		return fail(api.CodeConflict, "%s has a message queued that its agent hasn't taken yet: restarting would bounce it. Wait for it (agent.wait), or force: true restarts anyway (the message bounces)", terminal.ID)
	}
	switch draft, reported := agent["draft"].(bool); {
	case !reported:
		return fail(api.CodeConflict, "nothing in %s reports whether its input holds a draft the user hasn't sent (omp's easl extension does), so restarting could lose one; force: true restarts anyway", terminal.ID)
	case draft:
		return fail(api.CodeConflict, "%s's input editor holds a draft the user hasn't sent: restarting would lose it; force: true restarts anyway", terminal.ID)
	}
	return nil
}

// promptPending: a prompt to tile whose turn hasn't started, one a client is typing or one
// submitted (or a message its integration delivered as a new turn) that its agent hasn't
// reported working on within PromptStartGrace, the interval agent.wait waits out
// (ApiRouter.promptPending).
func (r *Router) promptPending(tile string) bool {
	if r.typing[tile] > 0 {
		return true
	}
	prompted, ok := r.pendingPrompts[tile]
	return ok && time.Since(prompted) < r.PromptStartGrace
}

// drain is tray.drain. Without a window there is no prompt target, so anyone drains the tray.
func (r *Router) drain(p map[string]any) (any, error) {
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	caller, _ := optStr(p, "caller")
	resolved, context := b.Drain(boolParam(p, "peek"), caller, true)
	mentions := make([]any, len(resolved))
	for i, m := range resolved {
		mentions[i] = m.JSON()
	}
	return map[string]any{"mentions": mentions, "context": context}, nil
}
