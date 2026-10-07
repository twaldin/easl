package router

import (
	"fmt"
	"os"
	"slices"
	"sort"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/store"
)

// Restore reopens the boards easld owned when it stopped (Reopens), oldest first, replaying what
// their agents spooled meanwhile (Registry.Open), and has each reconciled (opened): after a
// reboot their terminals' sessions start again, resuming their agents; after an easld restart,
// with its sessions still running, nothing starts. A root that is no longer a directory is
// dropped from the list; a board file easld can't read is kept on it, and so are its sessions.
// It returns what went wrong; the sessions start once it has returned (the lifecycle's queue).
func (r *Router) Restore() []error {
	if r.Owns == nil || r.Reopens == "" {
		return nil
	}
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	roots, err := store.ReadRoots(r.Reopens)
	if err != nil {
		return []error{fmt.Errorf("can't read the boards to reopen (%s): %w", r.Reopens, err)}
	}
	var errs []error
	var kept []string
	for _, root := range roots {
		if !store.IsDirectory(root) {
			errs = append(errs, fmt.Errorf("board root %s is gone; its board is no longer reopened", root))
			continue
		}
		b, err := r.reg.Open(root)
		if err != nil {
			errs = append(errs, fmt.Errorf("can't reopen the board at %s: %w", root, err))
			kept = append(kept, root)
			continue
		}
		kept = append(kept, b.Root())
	}
	if kept = unique(kept); !slices.Equal(kept, roots) {
		if err := store.WriteRoots(r.Reopens, kept); err != nil {
			errs = append(errs, fmt.Errorf("can't record the boards to reopen (%s): %w", r.Reopens, err))
		}
	}
	return errs
}

func unique(list []string) []string {
	var out []string
	for _, s := range list {
		if !slices.Contains(out, s) {
			out = append(out, s)
		}
	}
	return out
}

// opened is the registry's Opened, under its lock. A board opened on an easld that owns its
// terminals is recorded to reopen at its next start (Restore), and its owned terminals' sessions
// are reconciled: each without a session of its own gets one, resuming its recorded agent
// (ownedSpawn); one that runs is left alone, and so is one that doesn't answer (its daemon may
// only be busy). A session of the tile's name that is another home's or board's is not taken
// over: the board's history says so.
func (r *Router) opened(b *board.Board) {
	if r.Owns == nil {
		return
	}
	r.remember(b)
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
			if s, ok := running[session.Prefix+t.o.ID]; ok && (s.Unreachable || s.Carries(t.labels)) {
				continue
			}
			r.startSession(b, t.o, t.spawn)
		}
	})
}

// remember adds b's root to the boards easld reopens at start; a failure is logged in its
// history (the board won't come back after a reboot).
func (r *Router) remember(b *board.Board) {
	if r.Reopens == "" {
		return
	}
	roots, err := store.ReadRoots(r.Reopens)
	if err == nil {
		if slices.Contains(roots, b.Root()) {
			return
		}
		err = store.WriteRoots(r.Reopens, append(roots, b.Root()))
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
// ended only after a grace as an orphan. Another home's session is never ended, nor one labelled
// with a board that isn't open, nor one that doesn't answer. Each one ended is logged in its
// board's history; its spooled reports go with it unless a terminal of that id is on an open
// board. It returns once the sweep is done.
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
		if s.Unreachable || s.Labels[session.HomeLabel] != home || s.Labels["canvas.tile"] != s.Tile || !open || owned[id][s.Tile] {
			continue
		}
		found[s.Name] = s.PID
		if pid, seen := r.lifecycle.orphans[s.Name]; !seen || pid != s.PID {
			continue
		}
		r.reap(b, s, !onBoard[s.Tile])
	}
	r.lifecycle.orphans = found
}

// reap ends orphan session s of board b (and with `spool`, the reports spooled for its tile) and
// logs it in b's history.
func (r *Router) reap(b *board.Board, s session.Session, spool bool) {
	_, err := r.Sessions.End(s.Tile, r.Owns.Labels(b.ID(), s.Tile))
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
