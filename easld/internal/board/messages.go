package board

import (
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/mention"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

// --- addresses (AgentAddress.swift) ---

// BoardName is a board's name in agent addresses: its root folder's name, as its window title
// shows it.
func BoardName(root string) string { return filepath.Base(root) }

// AgentName is a terminal's name for addressing: its props.name, when it has a non-empty one.
func AgentName(terminal model.Object) (string, bool) {
	name, ok := terminal.Props["name"].(string)
	return name, ok && name != ""
}

// Address is where a message to terminal goes from any board, an address that resolves to it
// alone among boards (the open boards; AgentAddress.address): `name@board` while its name is no
// other terminal's on b and b is found by that name alone (its root folder there, no other open
// board's folder of that name); `name@<board id>` when b's name isn't; its tile id when it has
// no name or shares it on b.
func Address(terminal model.Object, b *Board, boards []*Board) string {
	name, ok := AgentName(terminal)
	if !ok {
		return terminal.ID
	}
	for _, o := range b.objects {
		if other, named := AgentName(o); named && other == name && o.ID != terminal.ID && o.Type == model.Terminal {
			return terminal.ID
		}
	}
	folder := BoardName(b.root)
	found := store.IsDirectory(b.root)
	for _, other := range boards {
		if other != b && BoardName(other.root) == folder && store.IsDirectory(other.root) {
			found = false
		}
	}
	if !found {
		return name + "@" + b.id
	}
	return name + "@" + folder
}

// renamed keeps aliases as a terminal's props.name changes (commit): its old name becomes its
// alias, and the new one is no other terminal's alias any more (it took it).
func (b *Board) renamed(id string, old, new map[string]any, typ model.ObjectType) {
	if typ != model.Terminal {
		return
	}
	before, _ := old["name"].(string)
	after, _ := new["name"].(string)
	if before == after {
		return
	}
	if after != "" {
		delete(b.aliases, after)
	}
	if before != "" {
		b.aliases[before] = id
	}
}

// forgetAliases: a deleted terminal's aliases go with it.
func (b *Board) forgetAliases(id string) {
	for alias, tile := range b.aliases {
		if tile == id {
			delete(b.aliases, alias)
		}
	}
}

// Aliases are the names that still reach terminal besides its own, sorted.
func (b *Board) Aliases(terminal string) []string {
	var out []string
	for alias, tile := range b.aliases {
		if tile == terminal {
			out = append(out, alias)
		}
	}
	sort.Strings(out)
	return out
}

// Alias is the terminal an old name still reaches on this board.
func (b *Board) Alias(name string) (string, bool) {
	tile, ok := b.aliases[name]
	return tile, ok
}

// --- messages (AgentMessages.swift) ---

// Message is an out-of-band agent.prompt (AgentMessage), queued for a terminal whose agent
// integration takes messages (TakesMessages) until that integration acks it through
// agent.inbox; saved with the board. When the agent session it was queued for ends first, it
// bounces (endAgentSession).
type Message = store.Message

// ScriptName is what a script with no label is called.
const ScriptName = "script"

// BounceSender is the sender a bounce names (a script's label): easl itself.
const BounceSender = "easl"

// NewMessage is a message queued now; a label makes it a script's, whoever the caller.
func NewMessage(text, from, label, when string, mentions []model.Mention) Message {
	if label != "" {
		from = ""
	}
	return Message{ID: model.NewID("msg"), Text: text, From: from, Label: label, When: when, Mentions: mentions, QueuedAt: time.Now()}
}

// Gist is what a bounce quotes of m (AgentMessage.gist): its first line, cut at 80 characters,
// with "…" when anything was cut.
func Gist(m Message) string {
	first, _, more := strings.Cut(strings.TrimSpace(m.Text), "\n")
	if runes := []rune(first); len(runes) > 80 {
		first, more = string(runes[:80]), true
	}
	if more {
		return first + "…"
	}
	return first
}

// Bounce is messages whose receiver's agent session ended before its integration took them
// (MessageBounce), handed to OnMessagesBounced once no step is open.
type Bounce struct {
	// Tile is the terminal they were queued for, Name its name then ("" for none).
	Tile, Name string
	Messages   []Message
	// deleted: its terminal was deleted, so it bounces only when the step closes with it
	// still gone (a failed batch puts it back, queue and all).
	deleted bool
}

// TakesMessages: the terminal's integration takes out-of-band messages (agent.report
// `protocol` ≥ 1), so agent.prompt queues for it instead of typing.
func TakesMessages(terminal model.Object) bool {
	agent, _ := terminal.Props["agent"].(map[string]any)
	version, _ := TruncInt(agent["protocol"])
	return Drains(terminal) && version >= 1
}

// PromptLabel is how the tray names a terminal (PromptTarget.label without a shown title): its
// name, else its title, else "Terminal".
func PromptLabel(terminal model.Object) string {
	for _, key := range []string{"name", "title"} {
		if s, ok := terminal.Props[key].(string); ok && measure.TrimWS(s) != "" {
			return s
		}
	}
	return "Terminal"
}

// QueueMessage queues m for terminal, after those already waiting.
func (b *Board) QueueMessage(m Message, terminal string) error {
	tile, err := b.Object(terminal)
	if err != nil {
		return err
	}
	if tile.Type != model.Terminal {
		return InvalidParams("%s is not a terminal tile", terminal)
	}
	b.messages[terminal] = append(b.messages[terminal], m)
	b.changed()
	return nil
}

// MessageMentions are the mentions targets name as a message carries them: one each, in order
// (a target given twice once), every object on this board.
func (b *Board) MessageMentions(targets []map[string]any) ([]model.Mention, error) {
	var mentions []model.Mention
	for _, target := range targets {
		duplicate := false
		for _, m := range mentions {
			if model.Equal(m.Target, target) {
				duplicate = true
			}
		}
		if duplicate {
			continue
		}
		for _, id := range model.MentionObjects(target) {
			if _, ok := b.objects[id]; !ok {
				return nil, NotFound("object %s", id)
			}
		}
		mentions = append(mentions, model.Mention{ID: model.NewID("men"), Target: target, Label: mention.Label(target, b), StagedAt: time.Now()})
	}
	return mentions, nil
}

// Messages are those queued for terminal, oldest first.
func (b *Board) Messages(terminal string) []Message { return b.messages[terminal] }

// AckMessages drops the messages ids names from terminal's queue (its integration delivered
// them) and returns those it dropped.
func (b *Board) AckMessages(ids []string, terminal string) []Message {
	var acked, left []Message
	for _, m := range b.messages[terminal] {
		if contains(ids, m.ID) {
			acked = append(acked, m)
		} else {
			left = append(left, m)
		}
	}
	if len(acked) == 0 {
		return nil
	}
	if len(left) == 0 {
		delete(b.messages, terminal)
	} else {
		b.messages[terminal] = left
	}
	b.changed()
	return acked
}

// endAgentSession: the agent session in terminal ended (released, or another agent or another
// session of it took the tile), and the messages still queued for it bounce. (The app also
// numbers sessions, Board.agentSession, for the terminal read its agent.prompt awaits; easld
// queues under the registry's lock with nothing awaited.)
func (b *Board) endAgentSession(terminal string) {
	waiting, ok := b.messages[terminal]
	if !ok {
		return
	}
	delete(b.messages, terminal)
	name, _ := AgentName(b.objects[terminal])
	b.bouncing = append(b.bouncing, Bounce{Tile: terminal, Name: name, Messages: waiting})
	b.changed()
	b.flushBounces()
}

// EndAgentSession: agent.restart killed the agent in terminal (its client relaunched it), so its
// session is over and what was still queued for it bounces (endAgentSession).
func (b *Board) EndAgentSession(terminal string) { b.endAgentSession(terminal) }

// forgetMessages: a deleted terminal's undelivered messages bounce once the step that deleted it
// closes with it still gone; a deleted object leaves the messages that mentioned it, without
// that mention.
func (b *Board) forgetMessages(removed model.Object) {
	if waiting, ok := b.messages[removed.ID]; ok {
		delete(b.messages, removed.ID)
		name, _ := AgentName(removed)
		b.bouncing = append(b.bouncing, Bounce{Tile: removed.ID, Name: name, Messages: waiting, deleted: true})
	}
	for terminal, waiting := range b.messages {
		kept := make([]Message, len(waiting))
		for i, m := range waiting {
			mentions := []model.Mention{}
			for _, men := range m.Mentions {
				if !contains(model.MentionObjects(men.Target), removed.ID) {
					mentions = append(mentions, men)
				}
			}
			m.Mentions = mentions
			kept[i] = m
		}
		b.messages[terminal] = kept
	}
}

// flushBounces hands the bounces due to OnMessagesBounced once no step is open: a deleted
// terminal's only if it is still gone.
func (b *Board) flushBounces() {
	if b.history.isOpen() || len(b.bouncing) == 0 {
		return
	}
	due := b.bouncing
	b.bouncing = nil
	for _, bounce := range due {
		if _, back := b.objects[bounce.Tile]; bounce.deleted && back {
			continue
		}
		if b.OnMessagesBounced != nil {
			b.OnMessagesBounced(bounce)
		}
	}
}

// InboxMessage is m as agent.inbox hands it to terminal's integration (AgentMessages
// `delivered`): the sender's name and address as they are now (boards are the open boards),
// and its mentions resolved now into the hand-off block a drain gives (handoffBlock).
func (b *Board) InboxMessage(m Message, terminal string, boards []*Board) map[string]any {
	from := map[string]any{}
	senderName, hasName := "", false
	if m.From != "" {
		from["tile"] = m.From
		var sender *Board
		for _, other := range boards {
			if _, ok := other.objects[m.From]; ok {
				sender = other
				break
			}
		}
		if sender != nil {
			tile := sender.objects[m.From]
			senderName, hasName = PromptLabel(tile), true
			from["name"], from["address"], from["board"] = senderName, Address(tile, sender, boards), sender.id
		} else {
			// Closed since it sent: its id still names it.
			from["name"] = m.From
		}
	} else if m.Label != "" {
		from["name"] = m.Label
	} else {
		from["name"] = ScriptName
	}
	result := map[string]any{
		"id": m.ID, "text": m.Text, "from": from, "attribution": m.Attribution(), "when": m.When,
		"queuedAt": model.FileTime(m.QueuedAt),
	}
	if len(m.Mentions) > 0 {
		result["mentions"] = mentionsJSON(m.Mentions)
		_, result["context"] = b.handoffBlock(m.Mentions, m.From, senderName, hasName, "", terminal, 1)
	}
	return result
}
