package board

import (
	"log"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/rivo/uniseg"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"

	"github.com/twaldin/easl/easld/internal/model"
)

const (
	composerLifetime    = 2 * time.Hour
	composerAnswerGrace = 2 * time.Second
	composerShortest    = 3
)

const (
	EventComposerReturned  = "composer.returned"
	EventComposerSubmitted = "composer.submitted"
)

// ComposerPrompt is one composer prompt waiting for its own submission drain
// (Composer.swift). Mentions are per-terminal copies. Origins are the staged ids
// those copies were made from, in the same order, so a commit or return can name
// the originals without broadcasting their targets.
type ComposerPrompt struct {
	ID              string
	Prompt          string
	Folded          string
	Mentions        []model.Mention
	Origins         []string
	Answer          bool
	QueuedAt        time.Time
	AnswerSettledAt *time.Time
	Viewer          string
}

type composerKind int

const (
	composerReturned composerKind = iota
	composerSubmitted
)

type composerNotice struct {
	kind     composerKind
	viewer   string
	terminal string
	ids      []string
}

// Fold is ComposerPrompt.fold: Unicode case fold, then letters and digits.
func Fold(text string) string {
	folded := cases.Fold().String(text)
	var b strings.Builder
	for _, r := range folded {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsMark(r) {
			b.WriteRune(r)
		}
	}
	return norm.NFC.String(b.String())
}

func (p ComposerPrompt) claimedBy(submitted string) bool {
	if uniseg.GraphemeClusterCount(p.Folded) < composerShortest {
		return p.Folded == submitted
	}
	return strings.Contains(submitted, p.Folded)
}

func SkipsDrain(text string, terminal model.Object) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	var first rune
	for _, r := range trimmed {
		first = r
		break
	}
	agent, _ := terminal.Props["agent"].(map[string]any)
	kind, _ := agent["kind"].(string)
	switch kind {
	case "claude", "codex", "gemini":
		return first == '/' || first == '!'
	case "omp":
		return first == '/' || first == '!' || first == '$'
	default:
		return false
	}
}

// AnswersAsPrompt is PromptTarget.answersAsPrompt: only Codex submits an answer as a prompt.
func AnswersAsPrompt(terminal model.Object) bool {
	agent, _ := terminal.Props["agent"].(map[string]any)
	return agent["kind"] == "codex"
}

// QueueComposerPrompt queues text for terminal before it is typed. viewer "" is this
// process's own composer (easld has none). Origins stay parallel to the copies.
func (b *Board) QueueComposerPrompt(text, terminal string, mentions []model.Mention, answer bool, viewer string, now time.Time) string {
	b.ExpireComposerPrompts(now)
	copies := []model.Mention{}
	origins := []string{}
	if !answer {
		copies = make([]model.Mention, len(mentions))
		origins = make([]string, len(mentions))
		for i, m := range mentions {
			target, _ := model.Clone(m.Target).(map[string]any)
			copies[i] = model.Mention{ID: model.NewID("men"), Target: target, Label: m.Label, StagedAt: m.StagedAt, Edited: m.Edited}
			origins[i] = m.ID
		}
	}
	blocked := LifecycleState(b.objects[terminal]) == "blocked"
	prompt := ComposerPrompt{
		ID: model.NewID("cmp"), Prompt: text, Folded: Fold(text), Mentions: copies, Origins: origins,
		Answer: answer, QueuedAt: now, Viewer: viewer,
	}
	if answer && !blocked {
		settled := now
		prompt.AnswerSettledAt = &settled
	}
	if b.composerPrompts == nil {
		b.composerPrompts = map[string][]ComposerPrompt{}
	}
	b.composerPrompts[terminal] = append(b.composerPrompts[terminal], prompt)
	b.scheduleComposerExpiry()
	return prompt.ID
}

// WithdrawComposerPrompt drops the queued prompt id. A failed forward sends no
// return: the error reply covers it.
func (b *Board) WithdrawComposerPrompt(id string) {
	for terminal, queue := range b.composerPrompts {
		kept := make([]ComposerPrompt, 0, len(queue))
		found := false
		for _, prompt := range queue {
			if prompt.ID == id {
				found = true
				continue
			}
			kept = append(kept, prompt)
		}
		if !found {
			continue
		}
		if len(kept) == 0 {
			delete(b.composerPrompts, terminal)
		} else {
			b.composerPrompts[terminal] = kept
		}
		b.scheduleComposerExpiry()
		return
	}
}

func (b *Board) claimComposerPrompt(caller, submitted string, now time.Time) *ComposerPrompt {
	b.ExpireComposerPrompts(now)
	queue := b.composerPrompts[caller]
	if len(queue) == 0 {
		return nil
	}
	folded := Fold(submitted)
	index := -1
	for i, prompt := range queue {
		if prompt.claimedBy(folded) {
			index = i
			break
		}
	}
	if index < 0 {
		lengths := make([]string, len(queue))
		for i, prompt := range queue {
			lengths[i] = strconv.Itoa(len([]rune(prompt.Folded)))
		}
		log.Printf("easl: a submission drain from %s matched none of its %d composer prompts (drained %d letters and digits; waiting %s)", caller, len(queue), len([]rune(folded)), strings.Join(lengths, ", "))
		return nil
	}
	found := queue[index]
	if len(found.Mentions) == 0 {
		queue = append(queue[:index], queue[index+1:]...)
		if len(queue) == 0 {
			delete(b.composerPrompts, caller)
		} else {
			b.composerPrompts[caller] = queue
		}
		if found.Viewer != "" {
			b.noteComposer(composerSubmitted, found.Viewer, caller, nil)
		}
		b.scheduleComposerExpiry()
	}
	return &found
}

// ComposerAgentReported starts the answer grace once the agent is past the question.
func (b *Board) ComposerAgentReported(tile, state string, now time.Time) {
	if state != "working" && state != "idle" {
		return
	}
	queue := b.composerPrompts[tile]
	if len(queue) == 0 {
		return
	}
	changed := false
	for i := range queue {
		if queue[i].Answer && queue[i].AnswerSettledAt == nil {
			settled := now
			queue[i].AnswerSettledAt = &settled
			changed = true
		}
	}
	if changed {
		b.composerPrompts[tile] = queue
		b.scheduleComposerExpiry()
	}
}

// ExpireComposerPrompts drops answers past their grace and returns prompts past the cap.
func (b *Board) ExpireComposerPrompts(now time.Time) {
	if b.composerPrompts == nil {
		return
	}
	for terminal, queue := range b.composerPrompts {
		var left []ComposerPrompt
		var expired []ComposerPrompt
		for _, prompt := range queue {
			settled := prompt.AnswerSettledAt != nil && now.Sub(*prompt.AnswerSettledAt) > composerAnswerGrace
			over := now.Sub(prompt.QueuedAt) > composerLifetime
			if settled || over {
				if over && !settled {
					expired = append(expired, prompt)
				}
				continue
			}
			left = append(left, prompt)
		}
		if len(left) == len(queue) {
			continue
		}
		if len(left) == 0 {
			delete(b.composerPrompts, terminal)
		} else {
			b.composerPrompts[terminal] = left
		}
		b.returnComposer(expired, terminal)
	}
	b.scheduleComposerExpiry()
}

// CommitComposerPrompts removes delivered copies and emits submitted for each
// commit batch's origins, even when the prompt still has mentions left.
func (b *Board) CommitComposerPrompts(ids []string) int {
	if len(ids) == 0 || len(b.composerPrompts) == 0 {
		return 0
	}
	count := 0
	type key struct{ viewer, terminal string }
	batched := map[key][]string{}
	for terminal, queue := range b.composerPrompts {
		var left []ComposerPrompt
		for _, prompt := range queue {
			before := len(prompt.Mentions)
			var keptM []model.Mention
			var keptO []string
			for i, mention := range prompt.Mentions {
				origin := ""
				if i < len(prompt.Origins) {
					origin = prompt.Origins[i]
				}
				if contains(ids, mention.ID) {
					count++
					if prompt.Viewer != "" && origin != "" {
						k := key{prompt.Viewer, terminal}
						batched[k] = append(batched[k], origin)
					}
					continue
				}
				keptM = append(keptM, mention)
				keptO = append(keptO, origin)
			}
			if before == 0 || len(keptM) > 0 {
				prompt.Mentions = keptM
				prompt.Origins = keptO
				left = append(left, prompt)
			}
		}
		if len(left) == 0 {
			delete(b.composerPrompts, terminal)
		} else {
			b.composerPrompts[terminal] = left
		}
	}
	for k, origins := range batched {
		b.noteComposer(composerSubmitted, k.viewer, k.terminal, origins)
	}
	if count > 0 {
		b.scheduleComposerExpiry()
	}
	return count
}

// ComposerQueues identifies each pending terminal queue by its newest prompt.
// A changed token invalidates a foreground observation made before a new prompt.
func (b *Board) ComposerQueues() map[string]string {
	queues := make(map[string]string, len(b.composerPrompts))
	for terminal, prompts := range b.composerPrompts {
		if len(prompts) > 0 {
			queues[terminal] = prompts[len(prompts)-1].ID
		}
	}
	return queues
}

// HasComposerQueue verifies that no new prompt replaced a queue observation.
func (b *Board) HasComposerQueue(terminal, token string) bool {
	queue := b.composerPrompts[terminal]
	return len(queue) > 0 && queue[len(queue)-1].ID == token
}

// DropComposerPrompts returns a terminal's undrained prompts. Its agent will not drain them.
func (b *Board) DropComposerPrompts(terminal string) {
	queue, ok := b.composerPrompts[terminal]
	if !ok {
		return
	}
	delete(b.composerPrompts, terminal)
	b.returnComposer(queue, terminal)
	b.scheduleComposerExpiry()
}

// ForgetComposerPrompts drops mentions of a deleted object (those origins are returned)
// and returns a deleted terminal's own remaining prompts.
func (b *Board) ForgetComposerPrompts(id string) {
	for terminal, queue := range b.composerPrompts {
		left := make([]ComposerPrompt, len(queue))
		for i, prompt := range queue {
			var keptM []model.Mention
			var keptO []string
			var gone []string
			for j, mention := range prompt.Mentions {
				origin := ""
				if j < len(prompt.Origins) {
					origin = prompt.Origins[j]
				}
				if contains(model.MentionObjects(mention.Target), id) {
					if origin != "" {
						gone = append(gone, origin)
					}
					continue
				}
				keptM = append(keptM, mention)
				keptO = append(keptO, origin)
			}
			prompt.Mentions = keptM
			prompt.Origins = keptO
			left[i] = prompt
			if prompt.Viewer != "" && len(gone) > 0 {
				b.noteComposer(composerReturned, prompt.Viewer, terminal, gone)
			}
		}
		b.composerPrompts[terminal] = left
	}
	b.DropComposerPrompts(id)
}

func (b *Board) returnComposer(prompts []ComposerPrompt, terminal string) {
	grouped := map[string][]string{}
	for _, prompt := range prompts {
		if prompt.Viewer == "" || len(prompt.Origins) == 0 {
			continue
		}
		grouped[prompt.Viewer] = append(grouped[prompt.Viewer], prompt.Origins...)
	}
	for viewer, ids := range grouped {
		b.noteComposer(composerReturned, viewer, terminal, ids)
	}
}

func (b *Board) noteComposer(kind composerKind, viewer, terminal string, ids []string) {
	if viewer == "" {
		return
	}
	b.composerNotices = append(b.composerNotices, composerNotice{kind: kind, viewer: viewer, terminal: terminal, ids: append([]string(nil), ids...)})
	b.flushComposerNotices()
}

func (b *Board) flushComposerNotices() {
	if b.history.isOpen() || len(b.composerNotices) == 0 {
		return
	}
	due := b.composerNotices
	b.composerNotices = nil
	for _, notice := range due {
		name := EventComposerReturned
		if notice.kind == composerSubmitted {
			name = EventComposerSubmitted
		}
		ids := make([]any, len(notice.ids))
		for i, id := range notice.ids {
			ids[i] = id
		}
		receipt := map[string]any{"receipt": model.NewID("crp"), "event": name, "viewer": notice.viewer, "terminal": notice.terminal, "ids": ids}
		b.composerReceipts = append(b.composerReceipts, receipt)
		if len(b.composerReceipts) > 2000 {
			copy(b.composerReceipts, b.composerReceipts[len(b.composerReceipts)-2000:])
			clear(b.composerReceipts[2000:])
			b.composerReceipts = b.composerReceipts[:2000]
		}
		b.emit(name, receipt)
	}
}

func (b *Board) ComposerReceipts() []map[string]any {
	return b.composerReceipts
}

func (b *Board) scheduleComposerExpiry() {
	b.StopComposerExpiry()
	if b.closed || b.Lock == nil {
		return
	}
	var next time.Time
	found := false
	for _, queue := range b.composerPrompts {
		for _, prompt := range queue {
			due := prompt.QueuedAt.Add(composerLifetime)
			if prompt.AnswerSettledAt != nil {
				grace := prompt.AnswerSettledAt.Add(composerAnswerGrace)
				if grace.Before(due) {
					due = grace
				}
			}
			if !found || due.Before(next) {
				next, found = due, true
			}
		}
	}
	if !found {
		return
	}
	b.composerExpirySeq++
	seq := b.composerExpirySeq
	wait := next.Sub(time.Now())
	if wait < 0 {
		wait = 0
	}
	if wait > 24*time.Hour {
		wait = 24 * time.Hour
	}
	b.composerExpiry = time.AfterFunc(wait, func() {
		b.Lock.Lock()
		defer b.Lock.Unlock()
		if b.composerExpirySeq != seq {
			return
		}
		b.composerExpiry = nil
		b.ExpireComposerPrompts(time.Now())
	})
}

// StopComposerExpiry cancels the pending composer check (the board closed, or the
// schedule is about to be replaced).
func (b *Board) StopComposerExpiry() {
	b.composerExpirySeq++
	if b.composerExpiry != nil {
		b.composerExpiry.Stop()
		b.composerExpiry = nil
	}
}

func cloneComposerPrompts(in map[string][]ComposerPrompt) map[string][]ComposerPrompt {
	if in == nil {
		return nil
	}
	out := make(map[string][]ComposerPrompt, len(in))
	for terminal, queue := range in {
		copied := make([]ComposerPrompt, len(queue))
		for i, prompt := range queue {
			copied[i] = prompt
			copied[i].Mentions = append([]model.Mention(nil), prompt.Mentions...)
			copied[i].Origins = append([]string(nil), prompt.Origins...)
			if prompt.AnswerSettledAt != nil {
				settled := *prompt.AnswerSettledAt
				copied[i].AnswerSettledAt = &settled
			}
		}
		out[terminal] = copied
	}
	return out
}

func cloneComposerNotices(in []composerNotice) []composerNotice {
	out := make([]composerNotice, len(in))
	for i, notice := range in {
		out[i] = notice
		out[i].ids = append([]string(nil), notice.ids...)
	}
	return out
}
