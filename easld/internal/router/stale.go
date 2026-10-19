package router

import (
	"time"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
)

func (r *Router) boardStale(p map[string]any) (any, error) {
	olderThan := 7 * 24 * time.Hour
	if value, present := p["olderThan"]; present {
		var err error
		olderThan, err = parseCleanupDuration(value, "olderThan")
		if err != nil {
			return nil, err
		}
	}
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	observed := map[string]model.Object{}
	for id, o := range b.Objects() {
		if o.Type == model.Terminal && board.TerminalHost(o) == "" {
			observed[id] = o
		}
	}
	sessions := r.ownSessions()
	current, open := r.reg.Board(b.ID())
	if !open || current != b {
		return nil, board.NotFound("board %s", b.ID())
	}
	if _, err := r.availableBoard(b); err != nil {
		return nil, err
	}
	exited := map[string]bool{}
	if sessions != nil {
		for id, before := range observed {
			o, exists := b.Objects()[id]
			if !exists || o.Rev != before.Rev || !o.CreatedAt.Equal(before.CreatedAt) || b.AwaitsRelaunchedAgent(id) {
				continue
			}
			if _, restarting := r.restarts[id]; restarting {
				continue
			}
			s, listed := sessions[id]
			if !listed {
				exited[id] = true
			} else if !s.Unreachable && s.Carries(r.Owns.Labels(b.ID(), id), mergedInto(b)...) && s.Ended {
				exited[id] = true
			}
		}
	}
	return map[string]any{"objects": b.Stale(time.Now(), olderThan, exited)}, nil
}
