package router

import (
	"regexp"
	"time"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
)

// Peer messages (docs/contracts.md, Peer messages): agent.prompt to a terminal whose
// integration takes messages queues out of band (Board.QueueMessage), and that integration
// takes them with agent.inbox. A port of ApiRouter.swift's queueMessage, inbox and their helpers.

// inboxWaiter is an agent.inbox long poll waiting for a message to its terminal.
type inboxWaiter struct {
	id    any
	conn  Conn
	tile  string
	timer *time.Timer
}

// messageHold names a message agent.inbox handed out: by terminal and id, since a sender's own
// id (agent.prompt `message`) may name a message to each of several terminals.
type messageHold struct {
	tile, message string
}

// queueMessage is an out-of-band agent.prompt: queued for terminal, whose integration takes it
// with agent.inbox; nothing is typed, so none of typing's refusals apply. From a terminal
// (caller, honoured when it is a terminal on an open board) the message is the agent's; with a
// label (`from`) or none, the user's. It is queued under the registry's lock with nothing
// awaited, so always for the agent session the call resolved (ApiRouter.swift reads the
// terminal first and checks Board.agentSession again). With an id (`message`) already queued
// for the terminal it answers with that message and queues nothing: a sender whose call timed
// out sends the same id again.
func (r *Router) queueMessage(text string, terminal model.Object, b *board.Board, mentions []any, caller, label, when, id string) (any, error) {
	if id != "" {
		for _, queued := range b.Messages(terminal.ID) {
			if queued.ID == id {
				return r.messageResult(queued, terminal, b, true), nil
			}
		}
	}
	targets := make([]map[string]any, len(mentions))
	for i, m := range mentions {
		target, err := promptMention(m, b)
		if err != nil {
			return nil, err
		}
		targets[i] = target
	}
	attached, err := b.MessageMentions(targets)
	if err != nil {
		return nil, err
	}
	sender := ""
	if caller != "" {
		if owner, ok := r.reg.Containing(caller); ok && owner.Objects()[caller].Type == model.Terminal {
			sender = caller
		}
	}
	message := board.NewMessage(text, sender, label, when, attached)
	if id != "" {
		message.ID = id
	}
	if err := b.QueueMessage(message, terminal.ID); err != nil {
		return nil, err
	}
	r.serveInbox(terminal.ID, b)
	return r.messageResult(message, terminal, b, false), nil
}

// messageResult is agent.prompt's result for message, queued for terminal: now, or by an
// earlier attempt with its id (duplicate).
func (r *Router) messageResult(message board.Message, terminal model.Object, b *board.Board, duplicate bool) map[string]any {
	result := map[string]any{
		"agent":       r.agentEntry(terminal, b),
		"submittedAt": model.FileTime(message.QueuedAt),
		"waitable":    true,
		"delivery":    "message",
		"message":     message.ID,
	}
	if len(message.Mentions) > 0 {
		result["mentions"] = board.MentionsJSON(message.Mentions)
	}
	if duplicate {
		result["duplicate"] = true
	}
	return result
}

// messageID is agent.prompt's `message`: an id of the sender's own, the same on every attempt
// at one message ("" when absent).
func messageID(p map[string]any) (string, error) {
	value, present := p["message"]
	if !present || value == nil {
		return "", nil
	}
	id, _ := value.(string)
	if !messageIDPattern.MatchString(id) {
		return "", invalid("message is the id the message gets, the same on every attempt to send it: msg_ and 8 to 64 letters, digits, _ or -")
	}
	return id, nil
}

var messageIDPattern = regexp.MustCompile(`^msg_[A-Za-z0-9_-]{8,64}$`)

// inbox is agent.inbox: a terminal's integration acks what it delivered, then takes what waits
// for it (held by this connection until acked, offered again once it closes), or waits up to
// waitMs for a message.
func (r *Router) inbox(id any, p map[string]any, c Conn) (any, error) {
	tile, err := str(p, "tile")
	if err != nil {
		return nil, err
	}
	b, err := r.boardForObject(tile)
	if err != nil {
		return nil, err
	}
	if b.Objects()[tile].Type != model.Terminal {
		return nil, invalid("%s is not a terminal tile", tile)
	}
	waitMs, _ := intParam(p, "waitMs")
	if waitMs < 0 || waitMs > 60_000 {
		return nil, invalid("waitMs is from 0 to 60000")
	}
	for hold, holder := range r.messageHolds {
		if !holder.IsOpen() {
			delete(r.messageHolds, hold)
		}
	}
	if ack := strings_(p["ack"]); len(ack) > 0 {
		for _, message := range ack {
			delete(r.messageHolds, messageHold{tile, message})
		}
		if len(b.AckMessages(ack, tile)) > 0 {
			r.messagesDelivered(tile, b, boolParam(p, "started"))
		}
	}
	offered := r.offer(tile, b, c)
	if len(offered) > 0 || waitMs == 0 {
		return r.inboxResult(offered, tile, b), nil
	}
	w := &inboxWaiter{id: id, conn: c, tile: tile}
	r.inboxWaiters = append(r.inboxWaiters, w)
	w.timer = time.AfterFunc(time.Duration(waitMs)*time.Millisecond, func() {
		r.reg.Mu.Lock()
		defer r.reg.Mu.Unlock()
		for i, x := range r.inboxWaiters {
			if x == w {
				r.inboxWaiters = append(r.inboxWaiters[:i:i], r.inboxWaiters[i+1:]...)
				w.conn.Send(okReply(w.id, map[string]any{"messages": []any{}}))
				return
			}
		}
	})
	return nil, nil
}

// offer is the messages for tile no open connection holds, now held by c; none while
// agent.restart has a client kill and relaunch it (restarts).
func (r *Router) offer(tile string, b *board.Board, c Conn) []board.Message {
	if _, restarting := r.restarts[tile]; restarting {
		return nil
	}
	var free []board.Message
	for _, m := range b.Messages(tile) {
		if holder, held := r.messageHolds[messageHold{tile, m.ID}]; held && holder.IsOpen() {
			continue
		}
		free = append(free, m)
		r.messageHolds[messageHold{tile, m.ID}] = c
	}
	return free
}

func (r *Router) inboxResult(messages []board.Message, tile string, b *board.Board) map[string]any {
	boards := r.reg.SortedBoards()
	rendered := make([]any, len(messages))
	for i, m := range messages {
		rendered[i] = b.InboxMessage(m, tile, boards)
	}
	return map[string]any{"messages": rendered}
}

// serveInbox: a message reached tile's queue (or agent.restart let it go again), and the oldest
// open long poll for it takes it.
func (r *Router) serveInbox(tile string, b *board.Board) {
	kept := r.inboxWaiters[:0]
	for _, w := range r.inboxWaiters {
		if w.conn.IsOpen() {
			kept = append(kept, w)
		} else {
			w.timer.Stop()
		}
	}
	clear(r.inboxWaiters[len(kept):])
	r.inboxWaiters = kept
	if _, restarting := r.restarts[tile]; restarting {
		return
	}
	for i, w := range r.inboxWaiters {
		if w.tile != tile {
			continue
		}
		r.inboxWaiters = append(r.inboxWaiters[:i:i], r.inboxWaiters[i+1:]...)
		w.timer.Stop()
		w.conn.Send(okReply(w.id, r.inboxResult(r.offer(tile, b, w.conn), tile, b)))
		return
	}
}

// messagesDelivered: tile's integration delivered messages. One that started a new turn
// (started) is waited on as a prompt to an idle agent is, unless that turn already reported;
// one that joined the running turn ends with it.
func (r *Router) messagesDelivered(tile string, b *board.Board, started bool) {
	terminal, ok := b.Objects()[tile]
	if !ok {
		return
	}
	if state := stateOf(terminal); started && state != "working" && state != "blocked" && state != "unknown" {
		r.pendingPrompts[tile] = time.Now()
	}
	for _, w := range append([]*waiter(nil), r.waiters...) {
		if w.tile == tile {
			r.recheck(w)
		}
	}
}

// bounce: messages whose receiver's agent session ended before its integration took them
// (Board.endAgentSession), never dropped silently. Each goes back to a sending terminal whose
// integration takes messages, as a message from easl ("undelivered to bob@canvas: its first
// line…"); a script's, or one whose sender takes no messages or has closed, is logged in the
// receiver's board.history (`message`). Waits on the receiver look again.
func (r *Router) bounce(b *board.Board, bounce board.Bounce) {
	boards := r.reg.SortedBoards()
	receiver := bounce.Tile
	if terminal, ok := b.Objects()[bounce.Tile]; ok {
		receiver = board.Address(terminal, b, boards)
	} else if bounce.Name != "" {
		receiver = bounce.Name + "@" + board.BoardName(b.Root())
	}
	for _, m := range bounce.Messages {
		delete(r.messageHolds, messageHold{bounce.Tile, m.ID})
		notice := "undelivered to " + receiver + ": " + board.Gist(m)
		home, sent := r.reg.Containing(m.From)
		if m.From != "" && sent {
			if tile := home.Objects()[m.From]; board.TakesMessages(tile) {
				if err := home.QueueMessage(board.NewMessage(notice, "", board.BounceSender, "now", nil), m.From); err == nil {
					r.serveInbox(m.From, home)
					continue
				}
			}
		}
		from := m.Label
		switch {
		case from != "":
		case m.From != "" && sent:
			from = board.Address(home.Objects()[m.From], home, boards)
		case m.From != "":
			from = m.From
		default:
			from = board.ScriptName
		}
		b.Activity.Record(board.KindMessage, board.SystemActor, b.Revision(), bounce.Tile, model.Terminal, notice+" (from "+from+")", "")
	}
	for _, w := range append([]*waiter(nil), r.waiters...) {
		if w.tile == bounce.Tile {
			r.recheck(w)
		}
	}
}
