package router

import (
	"fmt"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
)

// restartOwned is agent.restart of a terminal easld owns, served by easld itself as a Mac's
// TerminalHost.restart serves a hosted one's: one lifecycle job (so no start, end, reconcile or
// sweep of its sessions comes between) checks the terminal again, ends its session, waits until
// zmx no longer lists it, ends the killed agent's session (its queued messages bounce) and
// records the relaunch (Board.RestartedAgent), then starts the relaunch in a new session. The
// terminal is held meanwhile (restarts), with the registry's lock let go, as a client's restart
// does. The caller holds the lock and has made the restart's first checks.
func (r *Router) restartOwned(b *board.Board, terminal model.Object, mode string, args []string, force bool) (any, error) {
	agent := asMap(terminal.Props["agent"])
	kind, _ := agent["kind"].(string)
	resumed := ""
	if mode == "resume" {
		resumed = session.ResumedSession(agent)
	}
	agentModel, _ := agent["model"].(string)
	thinking, _ := agent["thinking"].(string)
	launch, ok := session.RelaunchOf(kind, strings_(terminal.Props["command"]), resumed, agentModel, thinking, args)
	if !ok {
		return nil, fail(api.CodeUnavailable, "%s runs no known agent and has no command to relaunch", terminal.ID)
	}
	// What the relaunched agent is until it reports: the same agent, model and thinking (and
	// session, resumed), without what only the killed process knew. Taken now: the old agent's
	// release as it exits clears props.agent.
	var relaunched any
	if agent != nil {
		kept := map[string]any{}
		for k, v := range agent {
			kept[k] = v
		}
		delete(kept, "draft")
		delete(kept, "pid")
		if mode == "fresh" {
			delete(kept, "sessionId")
			delete(kept, "sessionPath")
		}
		relaunched = kept
	}
	tile := terminal.ID
	r.restartSeq++
	op := r.restartSeq
	r.restarts[tile] = op
	var failure error
	r.queueSession(func() { failure = r.relaunch(b, tile, launch, relaunched, force) })
	queued := r.queuedSessions()
	r.reg.Mu.Unlock()
	r.waitSessions(queued)
	r.reg.Mu.Lock()
	if r.restarts[tile] == op {
		delete(r.restarts, tile)
	}
	b.AgentRestartEnded(tile)
	r.serveInbox(tile, b)
	if failure != nil {
		return nil, failure
	}
	current, ok := b.Objects()[tile]
	if !ok {
		return nil, fail(api.CodeNotFound, "terminal %s was closed while it restarted", tile)
	}
	argv := make([]any, len(launch.Argv))
	for i, word := range launch.Argv {
		argv[i] = word
	}
	return map[string]any{"agent": r.agentEntry(current, b), "command": argv}, nil
}

// relaunch is restartOwned's job, off the registry's lock (TerminalHost.restart): the kill,
// then, once zmx no longer lists the session (within unlistedWithin, each listing given what is
// left of it: the job holds every queued start and end meanwhile), the relaunch. A failure
// before the kill leaves the session as it was; one after it leaves the terminal without a
// session, logged in its board's history as a failed start is.
func (r *Router) relaunch(b *board.Board, tile string, launch session.Relaunch, agent any, force bool) error {
	// Checked again at the kill: a turn, prompt or draft that came since would be lost too.
	r.reg.Mu.Lock()
	err := r.restartable(b, tile, force)
	if err == nil {
		// From the kill until the relaunch is recorded, the killed agent's release waits for that
		// record, which replaces it, so the tile keeps showing its lifecycle (an unseen done
		// stays: Board.RestartedAgent). A restart ending without it applies it (restartOwned).
		b.AgentRestartBegan(tile)
	}
	r.reg.Mu.Unlock()
	if err != nil {
		return err
	}
	if _, err := r.Sessions.End(tile, r.Owns.Labels(b.ID(), tile)); err != nil {
		return asFailure(err)
	}
	deadline := time.Now().Add(unlistedWithin)
	for {
		left := time.Until(deadline)
		if left <= 0 {
			why := fmt.Sprintf("zmx didn't confirm within %s that its session ended: nothing was relaunched", unlistedWithin)
			r.reg.Mu.Lock()
			terminal, ok := b.Objects()[tile]
			r.reg.Mu.Unlock()
			if ok {
				r.sessionFailed(b, terminal, "easld couldn't relaunch it: "+why)
			}
			return fail(api.CodeUnavailable, "terminal %s: %s", tile, why)
		}
		if list, err := r.Sessions.ListWithin(left); err == nil && !listed(list, tile) {
			break
		}
		time.Sleep(min(100*time.Millisecond, time.Until(deadline)))
	}
	r.reg.Mu.Lock()
	terminal, ok := b.Objects()[tile]
	if !ok {
		r.reg.Mu.Unlock()
		// Closed while its session was killed: its delete ended the agent session and bounced
		// the queue; there is nothing to relaunch into.
		return fail(api.CodeNotFound, "terminal %s was closed while it restarted: nothing was relaunched", tile)
	}
	b.EndAgentSession(tile)
	delete(r.pendingPrompts, tile)
	err = b.RestartedAgent(tile, launch.Command, agent)
	cwd, _ := terminal.Props["cwd"].(string)
	spawn := r.Owns.Request(b.ID(), tile, b.Root(), cwd, launch.Argv)
	r.reg.Mu.Unlock()
	if err != nil {
		return err
	}
	_, created, err := r.Sessions.Spawn(spawn)
	switch {
	case err != nil:
		r.sessionFailed(b, terminal, "easld couldn't start its relaunch: "+err.Error())
		return asFailure(err)
	case !created:
		return fail(api.CodeUnavailable, "terminal %s's session was started again before the relaunch could", tile)
	}
	return nil
}

// unlistedWithin is how long a restart waits for zmx to stop listing the session it ended
// (TerminalHost.restart's 3 s).
var unlistedWithin = 3 * time.Second

// restartable is why agent.restart can no longer restart `tile` on b as it kills its session:
// it was closed, a prompt is being typed into it, or (unless forced) a restart would lose
// something now (restartRefusal). The caller holds the registry's lock.
func (r *Router) restartable(b *board.Board, tile string, force bool) error {
	terminal, ok := b.Objects()[tile]
	if !ok {
		return fail(api.CodeNotFound, "terminal %s was closed", tile)
	}
	if r.typing[tile] > 0 {
		return typingFailure(tile)
	}
	if force {
		return nil
	}
	return r.restartRefusal(b, terminal, asMap(terminal.Props["agent"]))
}

// listed is whether zmx lists terminal tile's session.
func listed(sessions []session.Session, tile string) bool {
	for _, s := range sessions {
		if s.Tile == tile {
			return true
		}
	}
	return false
}
