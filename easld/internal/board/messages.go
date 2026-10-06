package board

import (
	"path/filepath"
	"sort"
	"time"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/mention"
	"github.com/twaldin/easl/easld/internal/model"
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

// Address is where a message to terminal goes from any board: `name@board` for a named
// terminal, else its tile id.
func Address(terminal model.Object, b *Board) string {
	if name, ok := AgentName(terminal); ok {
		return name + "@" + BoardName(b.root)
	}
	return terminal.ID
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
// agent.inbox. In memory only.
type Message struct {
	ID   string
	Text string
	// From is the sending terminal; "" for a script.
	From string
	// Label is a script's sender label (`from`); set, the message is the user's even with a
	// caller.
	Label string
	// When is "now" or "next-turn".
	When string
	// Mentions are the board objects the sender attached, as a hand-off's.
	Mentions []model.Mention
	QueuedAt time.Time
}

// ScriptName is what a script with no label is called.
const ScriptName = "script"

// NewMessage is a message queued now; a label makes it a script's, whoever the caller.
func NewMessage(text, from, label, when string, mentions []model.Mention) Message {
	if label != "" {
		from = ""
	}
	return Message{ID: model.NewID("msg"), Text: text, From: from, Label: label, When: when, Mentions: mentions, QueuedAt: time.Now()}
}

// Attribution is `agent` when a terminal sent the message, `user` for a script.
func (m Message) Attribution() string {
	if m.From == "" {
		return "user"
	}
	return "agent"
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
	if len(left) == 0 {
		delete(b.messages, terminal)
	} else {
		b.messages[terminal] = left
	}
	return acked
}

// forgetMessages: a deleted terminal takes its undelivered messages along; a deleted object
// leaves the messages that mentioned it, without that mention.
func (b *Board) forgetMessages(id string) {
	delete(b.messages, id)
	for terminal, waiting := range b.messages {
		kept := make([]Message, len(waiting))
		for i, m := range waiting {
			var mentions []model.Mention
			for _, men := range m.Mentions {
				if !contains(model.MentionObjects(men.Target), id) {
					mentions = append(mentions, men)
				}
			}
			m.Mentions = mentions
			kept[i] = m
		}
		b.messages[terminal] = kept
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
			from["name"], from["address"], from["board"] = senderName, Address(tile, sender), sender.id
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
