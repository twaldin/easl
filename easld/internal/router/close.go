package router

import (
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

type closeDisposition uint8

const (
	keepSessions closeDisposition = iota
	endOwnedSessions
)

type boardClose struct {
	board       *board.Board
	disposition closeDisposition
	terminals   []model.Object
	ended       []any
}

func (r *Router) availableBoard(b *board.Board) (*board.Board, error) {
	if r.closing[b.ID()] != nil {
		return nil, fail(api.CodeConflict, "board %s is closing", b.ID())
	}
	return b, nil
}

func (r *Router) boardClose(p map[string]any) (any, error) {
	disposition := keepSessions
	if value, present := p["endSessions"]; present {
		end, ok := value.(bool)
		if !ok {
			return nil, invalid("endSessions must be a boolean")
		}
		if end {
			disposition = endOwnedSessions
		}
	}
	if value, present := p["board"]; present {
		if id, ok := value.(string); !ok || id == "" {
			return nil, invalid("board must be a board id")
		}
	}
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	if disposition == endOwnedSessions && r.Owns == nil {
		return nil, fail(api.CodeUnsupported, "this easld does not own terminal sessions; omit endSessions")
	}
	closing := &boardClose{board: b, disposition: disposition, terminals: sortedTerminals(b), ended: []any{}}
	for _, terminal := range closing.terminals {
		if _, restarting := r.restarts[terminal.ID]; restarting {
			return nil, fail(api.CodeConflict, "terminal %s is restarting (agent.restart); wait before closing board %s", terminal.ID, b.ID())
		}
	}
	if closing.disposition == endOwnedSessions {
		r.closing[b.ID()] = closing
		defer delete(r.closing, b.ID())
		var endErr error
		r.queueSession(func() { endErr = r.endClosingSessions(closing) })
		queued := r.queuedSessions()
		r.reg.Mu.Unlock()
		r.waitSessions(queued)
		r.reg.Mu.Lock()
		if endErr != nil {
			return nil, closing.failure(endErr)
		}
	}
	if err := r.reg.Close(b.ID(), func() error { return r.forgetClosed(b) }); err != nil {
		return nil, closing.failure(err)
	}
	for _, terminal := range closing.terminals {
		delete(r.startedSessions, terminal.ID)
	}
	r.dropOwnedSockets(closing.terminals)
	r.closedBoard(closing)
	kept := []any{}
	for _, terminal := range sortedTerminals(b) {
		kept = append(kept, closedTerminal(terminal))
	}
	return map[string]any{"board": b.ID(), "root": b.Root(), "kept": kept, "ended": closing.ended}, nil
}

func closedTerminal(terminal model.Object) map[string]any {
	name, _ := terminal.Props["name"].(string)
	if name == "" {
		name, _ = terminal.Props["title"].(string)
	}
	if name == "" {
		name = "Terminal"
	}
	return map[string]any{"id": terminal.ID, "name": name}
}

func (closing *boardClose) failure(err error) error {
	ended := make([]string, len(closing.ended))
	for i, terminal := range closing.ended {
		ended[i] = terminal.(map[string]any)["id"].(string)
	}
	return fail(api.CodeUnavailable, "couldn't close board %s; board remains open; ended terminals [%s]: %s", closing.board.ID(), strings.Join(ended, ", "), err)
}

func (r *Router) endClosingSessions(closing *boardClose) error {
	b := closing.board
	r.reg.Mu.Lock()
	merged := mergedInto(b)
	r.reg.Mu.Unlock()
	for _, terminal := range closing.terminals {
		if board.TerminalHost(terminal) != "" {
			continue
		}
		if _, err := r.Sessions.End(terminal.ID, r.Owns.Labels(b.ID(), terminal.ID), merged...); err != nil {
			r.sessionFailed(b, terminal, "easld couldn't end its session: "+err.Error())
			return fmt.Errorf("terminal %s: %w", terminal.ID, err)
		}
		if err := r.confirmSessionEnded(terminal.ID); err != nil {
			r.sessionFailed(b, terminal, "easld couldn't confirm its session ended: "+err.Error())
			return err
		}
		if spool := r.spoolOf(terminal.ID); spool != "" {
			_ = os.RemoveAll(spool)
		}
		r.reg.Mu.Lock()
		// The session is already ended. Do not queue a second kill that could catch a new one.
		onTerminals := b.OnTerminals
		b.OnTerminals = nil
		err := b.Delete(terminal.ID, "")
		b.OnTerminals = onTerminals
		if err == nil {
			closing.ended = append(closing.ended, closedTerminal(terminal))
		}
		r.reg.Mu.Unlock()
		if err != nil {
			return fmt.Errorf("terminal %s ended but couldn't be removed: %w", terminal.ID, err)
		}
	}
	return nil
}

func (r *Router) confirmSessionEnded(tile string) error {
	deadline := time.Now().Add(unlistedWithin)
	for {
		left := time.Until(deadline)
		if left <= 0 {
			return fmt.Errorf("terminal %s: zmx didn't confirm within %s that its session ended", tile, unlistedWithin)
		}
		if sessions, err := r.Sessions.ListWithin(left); err == nil && !listed(sessions, tile) {
			return nil
		}
		time.Sleep(min(100*time.Millisecond, time.Until(deadline)))
	}
}

func (r *Router) forgetClosed(b *board.Board) error {
	if r.Owns == nil || r.Reopens == "" {
		return nil
	}
	listed, err := store.ReadReopened(r.Reopens)
	if err != nil {
		return fmt.Errorf("can't read the boards to reopen: %w", err)
	}
	kept := slices.DeleteFunc(listed, func(entry store.Reopened) bool {
		return entry.Board == b.ID() || (b.Repo != nil && slices.Contains(b.Repo.Merged, entry.Board))
	})
	if err := store.WriteReopened(r.Reopens, kept); err != nil {
		return fmt.Errorf("can't record the boards to reopen: %w", err)
	}
	return nil
}

func (r *Router) dropOwnedSockets(terminals []model.Object) {
	if r.Owns == nil {
		return
	}
	var tiles []string
	for _, terminal := range terminals {
		if board.TerminalHost(terminal) == "" {
			tiles = append(tiles, terminal.ID)
		}
	}
	if len(tiles) == 0 {
		return
	}
	r.queueSession(func() {
		for _, tile := range tiles {
			r.removeCmux(tile)
		}
	})
}

func (r *Router) closedBoard(closing *boardClose) {
	r.announceClients(r.clients.RemoveBoard(closing.board.ID()))
	r.surfaces.Recheck(closing.board.ID())
	terminals := map[string]bool{}
	for _, terminal := range closing.terminals {
		terminals[terminal.ID] = true
		delete(r.pendingPrompts, terminal.ID)
	}
	waiters := r.waiters[:0]
	for _, w := range r.waiters {
		if terminals[w.tile] {
			w.conn.Send(errorReply(w.id, &Failure{api.CodeNotFound, "board " + closing.board.ID() + " was closed"}))
			r.finish(w)
		} else {
			waiters = append(waiters, w)
		}
	}
	clear(r.waiters[len(waiters):])
	r.waiters = waiters
	inbox := r.inboxWaiters[:0]
	for _, w := range r.inboxWaiters {
		if terminals[w.tile] {
			w.timer.Stop()
			w.conn.Send(errorReply(w.id, &Failure{api.CodeNotFound, "board " + closing.board.ID() + " was closed"}))
		} else {
			inbox = append(inbox, w)
		}
	}
	clear(r.inboxWaiters[len(inbox):])
	r.inboxWaiters = inbox
	for hold := range r.messageHolds {
		if terminals[hold.tile] {
			delete(r.messageHolds, hold)
		}
	}
}
