package router

import (
	"os"
	"path/filepath"
	"sync"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
)

// lifecycle runs the sessions of the terminals easld owns (Router.Owns): it starts each new
// terminal's session and ends each deleted one's, one at a time, in the order their steps closed
// (so a terminal deleted right after its create is spawned, then killed, never left running),
// outside the registry's lock, as hostCall runs session.*: zmx takes up to a second.
type lifecycle struct {
	mu   sync.Mutex
	cond *sync.Cond
	jobs []sessionJob
	// queued counts the jobs ever queued, done those finished; a worker runs while they differ.
	queued, done uint64
}

// sessionJob starts (spawn set) or ends terminal `tile`'s session on `board`: one labelled with
// home `home` only, and its spooled reports in `spool` with it.
type sessionJob struct {
	board *board.Board
	tile  model.Object
	spawn *session.SpawnRequest
	home  string
	spool string
}

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
		cwd, _ := o.Props["cwd"].(string)
		if cwd == "" {
			cwd = b.Root()
		}
		r.queueSession(sessionJob{board: b, tile: o, spawn: &session.SpawnRequest{
			Tile: o.ID, Command: strings_(o.Props["command"]), Cwd: cwd,
			Env: r.Owns.Env(b.ID(), o.ID, b.Root()), Labels: r.Owns.Labels(b.ID(), o.ID),
		}})
	}
	for _, o := range ended {
		if board.TerminalHost(o) != "" {
			continue
		}
		job := sessionJob{board: b, tile: o, home: session.Label(r.Owns.Home)}
		// A board file's ids are whatever it says: one that would leave the spool isn't followed.
		if r.reg.AgentReports != "" && filepath.IsLocal(o.ID) {
			job.spool = filepath.Join(r.reg.AgentReports, o.ID)
		}
		r.queueSession(job)
	}
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
	if l.queued-l.done == 1 {
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
		r.runSession(job)
		l.mu.Lock()
		l.jobs = l.jobs[1:]
		l.done++
		l.cond.Broadcast()
		idle := l.done == l.queued
		l.mu.Unlock()
		if idle {
			return
		}
	}
}

// runSession starts or ends one terminal's session, the way the Mac's tile does
// (TerminalTile.killSession for the end: the session, zmx's log of it and, as the app does for
// every terminal ended, its spooled reports, which nothing would replay). A session labelled
// with another home is left alone. What fails is logged in the board's history.
func (r *Router) runSession(job sessionJob) {
	if job.spawn != nil {
		if _, _, err := r.Sessions.Spawn(*job.spawn); err != nil {
			r.sessionFailed(job, "easld couldn't start its session: "+err.Error())
		}
		return
	}
	if _, err := r.Sessions.Kill(job.tile.ID, job.home); err != nil {
		r.sessionFailed(job, "easld couldn't end its session: "+err.Error())
	}
	if job.spool != "" {
		_ = os.RemoveAll(job.spool)
	}
}

// sessionFailed records why easld couldn't start or end a terminal's session in its board's
// history (a `restart` entry, the system's), while the board is open.
func (r *Router) sessionFailed(job sessionJob, why string) {
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	if b, ok := r.reg.Board(job.board.ID()); !ok || b != job.board {
		return
	}
	job.board.Activity.Record(board.KindRestart, board.SystemActor, job.board.Revision(), job.tile.ID, model.Terminal, board.Describe(job.tile)+": "+why, "")
}
