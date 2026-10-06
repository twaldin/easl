package board

import (
	"sort"
	"time"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/question"
)

// maxExpiryWait is the longest the expiry timer sleeps; it checks again after.
const maxExpiryWait = 24 * time.Hour

// QuestionToCreate is Board.questionToCreate: `object.create` props for a question:
// question.Creating, then validated.
func (b *Board) QuestionToCreate(props map[string]any, caller string) (map[string]any, error) {
	props = question.Creating(props, caller)
	if problem, bad := question.Problem(props, nil); bad {
		return nil, InvalidParams("%s", problem)
	}
	return props, nil
}

// QuestionUpdate is Board.questionUpdate: what an update of object id writes: the patch (the
// call's `props` as received, has saying whether it gave one) validated, `answer.at` and
// `answer.by` stamped when it answers the question, and, when it closes the question and the
// call gave no frame, the frame shrunk to the closed tile (closedFrame). Anything else passes
// through: the props are the patch when it is an object, else nil.
func (b *Board) QuestionUpdate(id string, patch any, has bool, frame *model.Frame, caller string, now time.Time) (map[string]any, *model.Frame, error) {
	before, err := b.Object(id)
	if err != nil {
		return nil, nil, err
	}
	fields, _ := patch.(map[string]any)
	if before.Type != model.Question || !has {
		return fields, frame, nil
	}
	if problem, bad := question.Problem(patch, &before); bad {
		return nil, nil, InvalidParams("%s", problem)
	}
	if question.StatusOf(before.Props) != question.Open {
		return fields, frame, nil
	}
	merged, _ := model.Merge(before.Props, fields).(map[string]any)
	status := question.StatusOf(merged)
	if answer, ok := merged["answer"].(map[string]any); ok && status == question.Answered {
		answer["at"] = question.Stamp(now)
		answer["by"] = model.ActorFor(caller).JSON()
		fields, _ = model.Merge(fields, map[string]any{"answer": answer}).(map[string]any)
		merged, _ = model.Merge(before.Props, fields).(map[string]any)
	}
	if status == question.Open || frame != nil {
		return fields, frame, nil
	}
	return fields, b.closedFrame(before, merged), nil
}

// closedFrame is Board.closedFrame: a closing question's frame: no taller than the closed tile
// (at its zoom), where it was. Nil when it already is.
func (b *Board) closedFrame(before model.Object, props map[string]any) *model.Frame {
	w, h := question.Size(props)
	_, height := measure.Zoomed(w, h, measure.ZoomOf(props))
	if !(height < before.Frame.H) {
		return nil
	}
	return &model.Frame{X: before.Frame.X, Y: before.Frame.Y, W: before.Frame.W, H: height}
}

// answeredHeader is Board.answeredHeader: the block header over an answered question's hand-off
// to its asker.
func answeredHeader(id string) string { return "Your question " + id + " was answered (easl ask):" }

// questionWritten is Board.questionWritten: after a write or a restore of a question (Board.write,
// restore): the hand-off of its answer waits for the asker only while the question is answered.
// One just answered is handed to its asker's terminal, when that is a terminal on this board, as a
// mention of the question delivered with its next prompt (HandOff), never typed into what the
// agent is writing. One no longer answered (reverted with a failed batch) takes back a hand-off
// not yet drained.
func (b *Board) questionWritten(before, after model.Object) {
	was, now := question.StatusOf(before.Props), question.StatusOf(after.Props)
	if was == question.Answered && now != question.Answered {
		b.withdrawAnswer(after.ID)
		return
	}
	if was != question.Open || now != question.Answered {
		return
	}
	asker, _ := after.Props["asker"].(map[string]any)
	tile, ok := asker["tile"].(string)
	if !ok || b.objects[tile].Type != model.Terminal {
		return
	}
	target := map[string]any{"kind": "object", "object": after.ID}
	_, _ = b.HandOff([]map[string]any{target}, tile, "", "", false, answeredHeader(after.ID))
}

// withdrawAnswer drops the waiting hand-off of question id's answer, from whichever terminal it
// waits for.
func (b *Board) withdrawAnswer(id string) {
	for terminal, waiting := range b.handoffs {
		var left []Handoff
		for _, h := range waiting {
			if answerOf(h) != id {
				left = append(left, h)
			}
		}
		switch {
		case len(left) == len(waiting):
		case len(left) == 0:
			delete(b.handoffs, terminal)
		default:
			b.handoffs[terminal] = left
		}
	}
}

// answerOf is the question whose answer h hands off, "" for any other hand-off.
func answerOf(h Handoff) string {
	id, _ := h.Mention.Target["object"].(string)
	if h.From != "" || h.Mention.Target["kind"] != "object" || id == "" || h.Header != answeredHeader(id) {
		return ""
	}
	return id
}

// handoffStands is Board.handoffStands: still to be delivered: anything but a question's answer
// hand-off, and that one only while its question is there and answered (the drain's guard;
// questionWritten keeps it so).
func (b *Board) handoffStands(h Handoff) bool {
	id := answerOf(h)
	if id == "" {
		return true
	}
	q, ok := b.objects[id]
	return ok && q.Type == model.Question && question.StatusOf(q.Props) == question.Answered
}

// ExpireQuestions is Board.expireQuestions: open questions whose `expiresAt` is at or before now
// become `expired`, frames shrunk as a closing question's are, written by the app itself (no undo
// step). Returns their ids.
func (b *Board) ExpireQuestions(now time.Time) []string {
	var due []string
	for id, o := range b.objects {
		if o.Type != model.Question {
			continue
		}
		spec := question.Read(o.Props)
		if spec.Status == question.Open && spec.ExpiresAt != nil && !spec.ExpiresAt.After(now) {
			due = append(due, id)
		}
	}
	sort.Strings(due)
	for _, id := range due {
		before, ok := b.objects[id]
		if !ok {
			continue
		}
		patch := map[string]any{"status": string(question.Expired)}
		merged, _ := model.Merge(before.Props, patch).(map[string]any)
		_, _ = b.Update(id, nil, b.closedFrame(before, merged), nil, patch, "", SystemActor)
	}
	return due
}

// ScheduleQuestionExpiry is Board.scheduleQuestionExpiry: sets the board's expiry timer for its
// earliest open `expiresAt` (at most a day out, then again); a question already past it expires
// on the next turn (the timer takes the board's Lock, so after the request that made it due).
// Called when the board opens and whenever a question is stored.
func (b *Board) ScheduleQuestionExpiry() { b.scheduleQuestionExpiry(time.Now()) }

func (b *Board) scheduleQuestionExpiry(now time.Time) {
	b.StopQuestionExpiry()
	var next time.Time
	found := false
	for _, o := range b.objects {
		if o.Type != model.Question {
			continue
		}
		spec := question.Read(o.Props)
		if spec.Status == question.Open && spec.ExpiresAt != nil && (!found || spec.ExpiresAt.Before(next)) {
			next, found = *spec.ExpiresAt, true
		}
	}
	if !found || b.Lock == nil {
		return
	}
	b.expirySeq++
	seq := b.expirySeq
	b.questionExpiry = time.AfterFunc(min(max(0, next.Sub(now)), maxExpiryWait), func() {
		b.Lock.Lock()
		defer b.Lock.Unlock()
		if b.expirySeq != seq {
			return
		}
		b.questionExpiry = nil
		b.ExpireQuestions(time.Now())
		b.ScheduleQuestionExpiry()
	})
}

// StopQuestionExpiry cancels the pending expiry check (the board closed, or is about to be
// rescheduled).
func (b *Board) StopQuestionExpiry() {
	b.expirySeq++
	if b.questionExpiry != nil {
		b.questionExpiry.Stop()
		b.questionExpiry = nil
	}
}
