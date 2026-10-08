package router

import (
	"os"
	"path/filepath"
	"slices"
	"sync"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
)

// lifecycle runs the sessions of the terminals easld owns (Router.Owns): it starts each new
// terminal's session and ends each deleted one's, reconciles each board as it opens and sweeps
// for orphans (restore.go), one job at a time, in the order they were queued (so a terminal
// deleted right after its create is spawned, then killed, never left running), outside the
// registry's lock, as hostCall runs session.*: zmx takes up to a second. Jobs are queued under
// the registry's lock.
type lifecycle struct {
	mu   sync.Mutex
	cond *sync.Cond
	jobs []sessionJob
	// queued counts the jobs ever queued, done those finished; a worker runs while they differ,
	// unless held (Restore, until StartSessions).
	queued, done uint64
	held         bool
	// orphans are the sessions the last sweep found orphaned, unended those whose end failed
	// (logged once), with their pids (only sweeps, which run one at a time, touch them).
	orphans, unended map[string]int
}

// sessionJob is one step of an owned terminal's lifecycle: a start, an end, a board's reconcile,
// a sweep for orphans.
type sessionJob func()

// terminals is the registry's Board.OnTerminals, under its lock: the sessions of the owned
// terminals (no `props.host`: a hosted one's is its Mac's to start and end) a step created and
// ended are started and ended once the request that closed it has let go of the lock.
func (r *Router) terminals(b *board.Board, created, ended []model.Object) {
	if r.Owns == nil {
		return
	}
	for _, o := range created {
		if board.TerminalHost(o) != "" {
			continue
		}
		spawn := r.ownedSpawn(b, o)
		r.queueSession(func() { r.startSession(b, o, spawn) })
	}
	for _, o := range ended {
		if board.TerminalHost(o) != "" {
			continue
		}
		labels, merged, spool := r.Owns.Labels(b.ID(), o.ID), mergedInto(b), r.spoolOf(o.ID)
		r.queueSession(func() { r.endSession(b, o, labels, merged, spool) })
	}
}

// ownedSpawn is the session of owned terminal `o` on `b` as it is now: its recorded agent
// session resumed, else its command (session.InitialArgv), in its cwd, else the board's root.
// A session running for it on a board b took in is its own (mergedInto).
func (r *Router) ownedSpawn(b *board.Board, o model.Object) session.SpawnRequest {
	cwd, _ := o.Props["cwd"].(string)
	req := r.Owns.Request(b.ID(), o.ID, b.Root(), cwd, session.InitialArgv(o.Props))
	req.Merged = mergedInto(b)
	return req
}

// mergedInto is the boards b took in (`repo.merged`: a folder's board, made before the folder
// was in git, or a legacy per-branch one): the sessions of their terminals, labelled with their
// ids, are b's terminals' (session.Session.Carries). Called under the registry's lock.
func mergedInto(b *board.Board) []string {
	if b.Repo == nil {
		return nil
	}
	return slices.Clone(b.Repo.Merged)
}

// spoolOf is where terminal `tile`'s integration spools reports easld isn't there to take; ""
// for none. A board file's ids are whatever it says: one that would leave the spool isn't
// followed.
func (r *Router) spoolOf(tile string) string {
	if r.reg.AgentReports == "" || !filepath.IsLocal(tile) {
		return ""
	}
	return filepath.Join(r.reg.AgentReports, tile)
}

func (r *Router) queueSession(job sessionJob) {
	l := &r.lifecycle
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.cond == nil {
		l.cond = sync.NewCond(&l.mu)
	}
	l.jobs = append(l.jobs, job)
	l.queued++
	if l.queued-l.done == 1 && !l.held {
		go r.runSessions()
	}
}

// holdSessions keeps the jobs queued from now on from running until StartSessions.
func (r *Router) holdSessions() {
	r.lifecycle.mu.Lock()
	defer r.lifecycle.mu.Unlock()
	r.lifecycle.held = true
}

// StartSessions runs the session jobs Restore queued, and those queued since: call it once
// easld serves, so that what the agents they start report as they start (agent.report_session)
// reaches it.
func (r *Router) StartSessions() {
	l := &r.lifecycle
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.held {
		return
	}
	l.held = false
	if l.queued > l.done {
		go r.runSessions()
	}
}

// queuedSessions is how many session jobs were ever queued (read under the registry's lock, as
// they are queued).
func (r *Router) queuedSessions() uint64 {
	r.lifecycle.mu.Lock()
	defer r.lifecycle.mu.Unlock()
	return r.lifecycle.queued
}

// waitSessions waits until the first n session jobs are done.
func (r *Router) waitSessions(n uint64) {
	l := &r.lifecycle
	l.mu.Lock()
	defer l.mu.Unlock()
	for l.done < n {
		l.cond.Wait()
	}
}

// runSessions works through the queue until it is empty.
func (r *Router) runSessions() {
	l := &r.lifecycle
	for {
		l.mu.Lock()
		job := l.jobs[0]
		l.mu.Unlock()
		job()
		l.mu.Lock()
		// The finished job (its board, its terminal) isn't kept reachable by the queue's array.
		l.jobs[0] = nil
		l.jobs = l.jobs[1:]
		if len(l.jobs) == 0 {
			l.jobs = nil
		}
		l.done++
		l.cond.Broadcast()
		idle := l.done == l.queued
		l.mu.Unlock()
		if idle {
			return
		}
	}
}

// startSession starts owned terminal `o`'s session; what fails is logged in its board's history.
func (r *Router) startSession(b *board.Board, o model.Object, spawn session.SpawnRequest) {
	if _, _, err := r.Sessions.Spawn(spawn); err != nil {
		r.sessionFailed(b, o, "easld couldn't start its session: "+err.Error())
	}
}

// endSession ends a deleted owned terminal's session the way the Mac's tile does
// (TerminalTile.killSession: the session, zmx's log of it, also when the session is already
// gone, and, as the app does for every terminal ended, its spooled reports in `spool`, which
// nothing would replay). A session not carrying `labels` (another home's or board's, but for
// one of `merged`, the boards b took in) is left alone, and so is its log. What fails is logged
// in the board's history.
func (r *Router) endSession(b *board.Board, o model.Object, labels map[string]string, merged []string, spool string) {
	if _, err := r.Sessions.End(o.ID, labels, merged...); err != nil {
		r.sessionFailed(b, o, "easld couldn't end its session: "+err.Error())
	}
	if spool != "" {
		_ = os.RemoveAll(spool)
	}
}

// sessionFailed records why easld couldn't start or end terminal `o`'s session in board `b`'s
// history (a `restart` entry, the system's), while the board is open.
func (r *Router) sessionFailed(b *board.Board, o model.Object, why string) {
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	if open, ok := r.reg.Board(b.ID()); !ok || open != b {
		return
	}
	b.Activity.Record(board.KindRestart, board.SystemActor, b.Revision(), o.ID, model.Terminal, board.Describe(o)+": "+why, "")
}
