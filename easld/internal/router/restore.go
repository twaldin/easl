package router

import (
	"errors"
	"fmt"
	"os"
	"slices"
	"sort"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/store"
)

// Restore reopens the boards easld owned when it stopped (Reopens), in the order they first
// opened, replaying what their agents spooled meanwhile (Registry.Open), and has each reconciled
// (opened): after a reboot their terminals' sessions start again, resuming their agents; after
// an easld restart, with its sessions still running, nothing starts. Those sessions wait for
// StartSessions, once easld serves: an agent reports its session to easld as it starts, and one
// easld isn't there to take would be lost. A board is its id: it reopens from a directory that
// opens it now (rootOf), and is dropped from the list only when none does; a board file easld
// can't read is kept on it, and so are its sessions. Call it before easld serves; it returns
// what went wrong, and where a board reopened from another directory than the one listed.
func (r *Router) Restore() []error {
	if r.Owns == nil || r.Reopens == "" {
		return nil
	}
	r.holdSessions()
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	listed, err := store.ReadReopened(r.Reopens)
	if err != nil {
		return []error{fmt.Errorf("can't read the boards to reopen (%s): %w", r.Reopens, err)}
	}
	var errs []error
	var kept []store.Reopened
	for _, e := range listed {
		root, err := r.rootOf(e.Board, e.Root)
		if err != nil {
			errs = append(errs, err)
		}
		if root == "" {
			if !errors.Is(err, errNowhere) {
				kept = append(kept, e)
			}
			continue
		}
		b, err := r.reg.Open(root)
		if err != nil {
			errs = append(errs, fmt.Errorf("can't reopen board %s at %s: %w", e.Board, root, err))
			kept = append(kept, store.Reopened{Root: root, Board: e.Board})
			continue
		}
		// The board root opens: e.Board, or the repository board that took it in (adopter).
		kept = append(kept, store.Reopened{Root: root, Board: b.ID()})
	}
	if kept = uniqueBoards(kept); !slices.Equal(kept, listed) {
		if err := store.WriteReopened(r.Reopens, kept); err != nil {
			errs = append(errs, fmt.Errorf("can't record the boards to reopen (%s): %w", r.Reopens, err))
		}
	}
	return errs
}

// errNowhere: no directory opens a listed board any more.
var errNowhere = errors.New("no directory opens it any more")

// rootOf is a directory that opens board `id` now (store.Identify, as Registry.Open does), tried
// in this order: `opener`, the one it is listed with; its own root as its board file has it (a
// repository's main checkout); a live worktree of its repository (listing them reads every one
// the repository names, which can wait on a mount: only when nothing before opens the board).
// Worktrees come and go (one merged and removed, its path reused by another repository) while
// the board stays, and a directory that opens another board never stands for this one, but for
// a folder's board whose folder is in a repository now (adopter). With another directory than
// `opener`, or another board, it also says why; "" when none opens it (errNowhere), or when its
// board file can't be read to tell (it stays listed).
func (r *Router) rootOf(id, opener string) (string, error) {
	opens := func(dir string) bool {
		if dir == "" || !store.IsDirectory(dir) {
			return false
		}
		got, _ := store.Identify(dir)
		return got == id
	}
	if opens(opener) {
		return opener, nil
	}
	snap, err := r.reg.Store.Read(id)
	if err != nil {
		return "", fmt.Errorf("board %s: %s no longer opens it, and its board file can't say what does: %w", id, opener, err)
	}
	moved := func(dir string) (string, error) {
		return dir, fmt.Errorf("board %s reopened from %s: %s no longer opens it", id, dir, opener)
	}
	if snap != nil && opens(snap.Root) {
		return moved(snap.Root)
	}
	if snap != nil && snap.Repo != nil {
		for _, w := range worktreesOf(snap.Repo.CommonDir) {
			if opens(w.Toplevel) {
				return moved(w.Toplevel)
			}
		}
	}
	if dir, ok := r.adopter(id, opener, snap); ok {
		into, _ := store.Identify(dir)
		return dir, fmt.Errorf("board %s reopened as board %s from %s: its folder is in that repository now, whose board takes it in", id, into, dir)
	}
	return "", fmt.Errorf("board %s is no longer reopened: %w (%s is gone or opens another board)", id, errNowhere, opener)
}

// adopter is the directory whose repository's board takes in folder board id as it loads
// (store.Loading: a board made for a folder before the folder was in git), or took it in
// already: the folder as its board file has it, in git now; else, its file gone, `opener` when
// the board it opens lists id in `repo.merged`.
func (r *Router) adopter(id, opener string, snap *store.Snapshot) (string, bool) {
	if snap != nil {
		if snap.Repo == nil && snap.ID == store.PathID(snap.Root) && store.IsDirectory(snap.Root) && store.Containing(snap.Root) != nil {
			return store.Standardized(snap.Root), true
		}
		return "", false
	}
	if opener == "" || !store.IsDirectory(opener) {
		return "", false
	}
	into, w := store.Identify(opener)
	if w == nil {
		return "", false
	}
	repo, err := r.reg.Store.Read(into)
	if err != nil || repo == nil || repo.Repo == nil || !slices.Contains(repo.Repo.Merged, id) {
		return "", false
	}
	return opener, true
}

// worktreesOf lists a repository's worktrees for rootOf (store.Worktrees; tests count calls).
var worktreesOf = store.Worktrees

// uniqueBoards is list with each board once, where it first is.
func uniqueBoards(list []store.Reopened) []store.Reopened {
	var out []store.Reopened
	for _, e := range list {
		if !slices.ContainsFunc(out, func(o store.Reopened) bool { return o.Board == e.Board }) {
			out = append(out, e)
		}
	}
	return out
}

// opened is the registry's Opened, under its lock. A board opened on an easld that owns its
// terminals is recorded to reopen at its next start (Restore), with the root it was opened from,
// and its owned terminals' sessions are reconciled: each without a session of its own gets one,
// resuming its recorded agent (ownedSpawn); one that runs is left alone, and so is one that
// doesn't answer (its daemon may only be busy) and one agent.restart holds (restarts: its
// restart, queued behind, ends its session and starts the relaunch). A session of the tile's
// name that is another home's or board's is not taken over: the board's history says so.
func (r *Router) opened(b *board.Board, root string) {
	if r.Owns == nil {
		return
	}
	r.remember(b, root)
	type owned struct {
		o      model.Object
		spawn  session.SpawnRequest
		labels map[string]string
	}
	var terminals []owned
	for _, o := range ownedTerminals(b) {
		terminals = append(terminals, owned{o, r.ownedSpawn(b, o), r.Owns.Labels(b.ID(), o.ID)})
	}
	if len(terminals) == 0 {
		return
	}
	r.queueSession(func() {
		// One listing for the board; Spawn checks again, under the manager's lock.
		running := map[string]session.Session{}
		if list, err := r.Sessions.List(); err == nil {
			for _, s := range list {
				running[s.Name] = s
			}
		}
		for _, t := range terminals {
			if s, ok := running[session.Prefix+t.o.ID]; ok && (s.Unreachable || s.Carries(t.labels, t.spawn.Merged...)) {
				continue
			}
			if r.restarting(t.o.ID) {
				continue
			}
			r.startSession(b, t.o, t.spawn)
		}
	})
}

// restarting is whether agent.restart holds terminal `tile` now (restarts); called off the
// registry's lock.
func (r *Router) restarting(tile string) bool {
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	_, held := r.restarts[tile]
	return held
}

// remember adds b, opened from root, to the boards easld reopens at start, unless it is there;
// a failure is logged in its history (the board won't come back after a reboot).
func (r *Router) remember(b *board.Board, root string) {
	if r.Reopens == "" {
		return
	}
	listed, err := store.ReadReopened(r.Reopens)
	if err == nil {
		if slices.ContainsFunc(listed, func(e store.Reopened) bool { return e.Board == b.ID() }) {
			return
		}
		err = store.WriteReopened(r.Reopens, append(listed, store.Reopened{Root: root, Board: b.ID()}))
	}
	if err != nil {
		b.Activity.Record(board.KindRestart, board.SystemActor, b.Revision(), "", "", "easld couldn't record this board to reopen it when it starts again: "+err.Error(), "")
	}
}

// ownedTerminals are b's terminals easld owns (no `props.host`), by id.
func ownedTerminals(b *board.Board) []model.Object {
	var out []model.Object
	for _, o := range b.Objects() {
		if o.Type == model.Terminal && board.TerminalHost(o) == "" {
			out = append(out, o)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// SweepOrphans ends the sessions of easld's home whose board is open but has no owned terminal
// for them any more (easld was down when it was deleted, zmx refused to end it), once the sweep
// before found them so too (the same session: the same process). Run a grace apart, a session is
// ended only after a grace as an orphan, and only while it is still that process
// (Manager.EndIf: `session.spawn` and `session.kill` don't wait for the sweep). Another home's
// session is never ended, nor one labelled with a board that isn't open (or taken in by one
// that is: its board label is in that board's `repo.merged`), nor one that doesn't answer or has
// no pid. Each one ended is logged in its board's history; its spooled reports go with it unless
// a terminal of that id is on an open board. It returns once the sweep is done.
func (r *Router) SweepOrphans() {
	if r.Owns == nil {
		return
	}
	r.reg.Mu.Lock()
	// The boards as they are now: the jobs queued before the sweep run before it, those queued
	// after it see the boards after it.
	boards := map[string]*board.Board{}
	owned := map[string]map[string]bool{}
	onBoard := map[string]bool{}
	for _, b := range r.reg.SortedBoards() {
		boards[b.ID()] = b
		owned[b.ID()] = map[string]bool{}
	}
	for _, b := range r.reg.SortedBoards() {
		// A session of a board b took in is b's terminal's (mergedInto).
		for _, id := range mergedInto(b) {
			if _, open := boards[id]; !open {
				boards[id] = b
			}
		}
		for _, o := range ownedTerminals(b) {
			owned[b.ID()][o.ID] = true
		}
		for id, o := range b.Objects() {
			if o.Type == model.Terminal {
				onBoard[id] = true
			}
		}
	}
	r.queueSession(func() { r.sweep(boards, owned, onBoard) })
	queued := r.queuedSessions()
	r.reg.Mu.Unlock()
	r.waitSessions(queued)
}

// sweep is SweepOrphans' job. The orphans it finds are the next one's to end.
func (r *Router) sweep(boards map[string]*board.Board, owned map[string]map[string]bool, onBoard map[string]bool) {
	list, err := r.Sessions.List()
	if err != nil {
		return
	}
	home := session.Label(r.Owns.Home)
	found := map[string]int{}
	for _, s := range list {
		id := s.Labels["canvas.board"]
		b, open := boards[id]
		if s.Unreachable || s.PID <= 0 || s.Labels[session.HomeLabel] != home || s.Labels["canvas.tile"] != s.Tile || !open || owned[b.ID()][s.Tile] {
			continue
		}
		found[s.Name] = s.PID
		if pid, seen := r.lifecycle.orphans[s.Name]; !seen || pid != s.PID {
			continue
		}
		r.reap(b, s, !onBoard[s.Tile])
	}
	r.lifecycle.orphans = found
	for name, pid := range r.lifecycle.unended {
		if found[name] != pid {
			delete(r.lifecycle.unended, name)
		}
	}
}

// reap ends orphan session s of board b, while it is still the process the sweeps found (and
// with `spool`, the reports spooled for its tile), and logs it in b's history. One started
// again under its name since, or gone, is no longer that orphan: it, its log and its spool are
// left as they are. An end that fails is tried again at each sweep, logged only the first time
// for that process.
func (r *Router) reap(b *board.Board, s session.Session, spool bool) {
	// The sweep found b by the session's board label: b's own, or a board b took in.
	var merged []string
	if id := s.Labels["canvas.board"]; id != b.ID() {
		merged = []string{id}
	}
	ended, err := r.Sessions.EndIf(s.Tile, r.Owns.Labels(b.ID(), s.Tile), s.PID, merged...)
	failedBefore := r.lifecycle.unended[s.Name] == s.PID
	if err == nil {
		delete(r.lifecycle.unended, s.Name)
	} else {
		if r.lifecycle.unended == nil {
			r.lifecycle.unended = map[string]int{}
		}
		r.lifecycle.unended[s.Name] = s.PID
	}
	if (err == nil && !ended) || (err != nil && failedBefore) {
		return
	}
	what := "easld ended session " + s.Name + ": no terminal on this board has it any more"
	if err != nil {
		what = "easld couldn't end session " + s.Name + ", which no terminal on this board has any more: " + err.Error()
	} else if dir := r.spoolOf(s.Tile); spool && dir != "" {
		_ = os.RemoveAll(dir)
	}
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	if open, ok := r.reg.Board(b.ID()); ok && open == b {
		b.Activity.Record(board.KindRestart, board.SystemActor, b.Revision(), s.Tile, model.Terminal, what, "")
	}
}
