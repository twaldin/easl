package board

import (
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/mention"
	"github.com/twaldin/easl/easld/internal/model"
)

// Handoff is a mention an agent attached to its agent.prompt for another terminal (Handoff.swift).
type Handoff struct {
	Mention  model.Mention
	From     string // "" for a script
	FromName string // "" for none
	HasName  bool
}

func mentionsJSON(list []model.Mention) []any {
	out := make([]any, len(list))
	for i, m := range list {
		out[i] = m.APIJSON()
	}
	return out
}

// MentionsJSON encodes mentions as the API returns them.
func MentionsJSON(list []model.Mention) []any { return mentionsJSON(list) }

func (b *Board) trayChanged() {
	b.changed()
	b.emit(EventTrayChanged, map[string]any{"mentions": mentionsJSON(b.tray)})
}

// Stage puts target (a canonical MentionTarget) in the tray; one already there is returned.
func (b *Board) Stage(target map[string]any) (model.Mention, error) {
	for _, id := range model.MentionObjects(target) {
		if _, ok := b.objects[id]; !ok {
			return model.Mention{}, NotFound("object %s", id)
		}
	}
	for _, m := range b.tray {
		if model.Equal(m.Target, target) {
			return m, nil
		}
	}
	m := model.Mention{ID: model.NewID("men"), Target: target, Label: mention.Label(target, b), StagedAt: time.Now()}
	b.tray = append(b.tray, m)
	b.trayChanged()
	return m, nil
}

// Unstage takes a mention out of the tray.
func (b *Board) Unstage(id string) error {
	found := false
	kept := b.tray[:0:0]
	for _, m := range b.tray {
		if m.ID == id {
			found = true
		} else {
			kept = append(kept, m)
		}
	}
	if !found {
		return NotFound("mention %s", id)
	}
	b.tray = kept
	b.trayChanged()
	return nil
}

// Drain resolves every staged mention (includeTray) and what agents handed to caller, returning
// the prompt context; without peek they leave the tray.
func (b *Board) Drain(peek bool, caller string, includeTray bool) ([]mention.Resolved, string) {
	var resolved []mention.Resolved
	var staged []model.Mention
	if includeTray {
		staged = b.tray
	}
	for i, m := range staged {
		resolved = append(resolved, mention.Resolve(m, i+1, b, caller))
	}
	var blocks []string
	if len(resolved) > 0 {
		targets := make([]map[string]any, len(staged))
		for i, m := range staged {
			targets[i] = m.Target
		}
		blocks = append(blocks, mention.Render(resolved, b, targets, "", ""))
	}
	if caller != "" {
		handed, handedBlocks := b.resolveHandoffs(caller, len(resolved)+1)
		resolved = append(resolved, handed...)
		blocks = append(blocks, handedBlocks...)
	}
	if !peek {
		ids := make([]string, len(resolved))
		for i, r := range resolved {
			ids[i] = r.ID
		}
		b.Commit(ids)
	}
	return resolved, strings.Join(blocks, "\n")
}

// Commit removes exactly these mentions, from the tray and from what agents handed to
// terminals; unknown ids are ignored.
func (b *Board) Commit(ids []string) {
	b.commitHandoffs(ids)
	kept := b.tray[:0:0]
	removed := 0
	for _, m := range b.tray {
		if contains(ids, m.ID) {
			removed++
		} else {
			kept = append(kept, m)
		}
	}
	if removed == 0 {
		return
	}
	b.tray = kept
	b.Delivered += removed
	b.trayChanged()
}

func (b *Board) restageMentions(placed []placedMention) {
	sorted := append([]placedMention(nil), placed...)
	for i := 1; i < len(sorted); i++ {
		for j := i; j > 0 && sorted[j].index < sorted[j-1].index; j-- {
			sorted[j], sorted[j-1] = sorted[j-1], sorted[j]
		}
	}
	changed := false
	for _, entry := range sorted {
		dup := false
		for _, m := range b.tray {
			if m.ID == entry.mention.ID || model.Equal(m.Target, entry.mention.Target) {
				dup = true
			}
		}
		if dup || !b.allExist(model.MentionObjects(entry.mention.Target)) {
			continue
		}
		at := min(entry.index, len(b.tray))
		b.tray = append(b.tray[:at], append([]model.Mention{entry.mention}, b.tray[at:]...)...)
		changed = true
	}
	if changed {
		b.trayChanged()
	}
}

// markMentionsEdited turns staged mentions of the object "edited" when the update changed what
// they hold.
func (b *Board) markMentionsEdited(before, after model.Object) {
	changed := false
	for i := range b.tray {
		m := &b.tray[i]
		if !m.Edited && contains(model.MentionObjects(m.Target), after.ID) && mention.IsEdited(m.Target, before, after) {
			m.Edited = true
			changed = true
		}
	}
	if changed {
		b.trayChanged()
	}
}

// HandOff queues mentions for terminal's next drained prompt, after any already waiting there.
func (b *Board) HandOff(targets []map[string]any, terminal, from, fromName string, hasName bool) ([]model.Mention, error) {
	tile, err := b.Object(terminal)
	if err != nil {
		return nil, err
	}
	if tile.Type != model.Terminal {
		return nil, InvalidParams("%s is not a terminal tile", terminal)
	}
	var queued []model.Mention
	for _, target := range targets {
		for _, id := range model.MentionObjects(target) {
			if _, ok := b.objects[id]; !ok {
				return nil, NotFound("object %s", id)
			}
		}
		waiting := false
		for _, h := range b.handoffs[terminal] {
			if model.Equal(h.Mention.Target, target) {
				waiting = true
			}
		}
		for _, q := range queued {
			if model.Equal(q.Target, target) {
				waiting = true
			}
		}
		if waiting {
			continue
		}
		queued = append(queued, model.Mention{ID: model.NewID("men"), Target: target, Label: mention.Label(target, b), StagedAt: time.Now()})
	}
	for _, m := range queued {
		b.handoffs[terminal] = append(b.handoffs[terminal], Handoff{Mention: m, From: from, FromName: fromName, HasName: hasName})
	}
	return queued, nil
}

func (b *Board) resolveHandoffs(caller string, index int) ([]mention.Resolved, []string) {
	waiting := b.handoffs[caller]
	var senders []string
	seen := map[string]bool{}
	for _, h := range waiting {
		if !seen[h.From] {
			seen[h.From] = true
			senders = append(senders, h.From)
		}
	}
	var resolved []mention.Resolved
	var blocks []string
	for _, sender := range senders {
		var group []Handoff
		for _, h := range waiting {
			if h.From == sender {
				group = append(group, h)
			}
		}
		var part []mention.Resolved
		targets := make([]map[string]any, len(group))
		for i, h := range group {
			part = append(part, mention.Resolve(h.Mention, index+len(resolved)+len(part), b, caller))
			targets[i] = h.Mention.Target
		}
		resolved = append(resolved, part...)
		name := ""
		if group[0].HasName {
			name = " \"" + group[0].FromName + "\""
		}
		header := "Attached by a script to its prompt to you (agent.prompt):"
		if sender != "" {
			header = "Attached by terminal " + sender + name + " to its prompt to you (agent.prompt):"
		}
		blocks = append(blocks, mention.Render(part, b, targets, sender, header))
	}
	return resolved, blocks
}

func (b *Board) commitHandoffs(ids []string) {
	for terminal, waiting := range b.handoffs {
		var left []Handoff
		for _, h := range waiting {
			if !contains(ids, h.Mention.ID) {
				left = append(left, h)
			}
		}
		if len(left) == 0 {
			delete(b.handoffs, terminal)
		} else {
			b.handoffs[terminal] = left
		}
	}
}

// forgetHandoffs: a deleted object takes the mentions of it along; a deleted terminal its queue
// and its last answer.
func (b *Board) forgetHandoffs(id string) {
	delete(b.handoffs, id)
	delete(b.finalAnswers, id)
	delete(b.turnErrors, id)
	for terminal, waiting := range b.handoffs {
		var left []Handoff
		for _, h := range waiting {
			if !contains(model.MentionObjects(h.Mention.Target), id) {
				left = append(left, h)
			}
		}
		if len(left) == 0 {
			delete(b.handoffs, terminal)
		} else {
			b.handoffs[terminal] = left
		}
	}
}
