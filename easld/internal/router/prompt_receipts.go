package router

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"regexp"
	"time"
	"unicode/utf8"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/model"
)

const promptReceiptLimit = 4096
const promptReceiptLifetime = 24 * time.Hour

var submissionIDPattern = regexp.MustCompile(`^sub_[A-Za-z0-9_-]{4,76}$`)
var submissionDatePattern = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)

type promptReceiptState uint8

const (
	promptInFlight promptReceiptState = iota
	promptFinished
	promptCancelled
)

type promptReceipt struct {
	payload   []byte
	createdAt time.Time
	state     promptReceiptState
	result    any
	failure   *Failure
}

func newPromptEpoch() string {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		panic(err)
	}
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
}

func promptDelivery(delivery string) map[string]any {
	return map[string]any{"delivery": delivery}
}

// prompt owns receipts under the registry lock, including the reservation before await unlocks it.
func (r *Router) prompt(p map[string]any) (any, error) {
	reconcile := false
	if value, present := p["reconcile"]; present {
		var ok bool
		reconcile, ok = value.(bool)
		if !ok {
			return nil, invalid("reconcile must be a boolean")
		}
		if p["submission"] == nil {
			return nil, invalid("reconcile requires submission")
		}
	}
	if p["submission"] == nil {
		if err := checkParams("agent.prompt", p); err != nil {
			return nil, err
		}
		return r.executePrompt(p)
	}
	submission, ok := p["submission"].(map[string]any)
	if !ok || len(submission) != 3 {
		return nil, invalid("submission must contain id, epoch and createdAt")
	}
	id, _ := submission["id"].(string)
	if !submissionIDPattern.MatchString(id) {
		return nil, invalid("submission.id must match ^sub_[A-Za-z0-9_-]{4,76}$")
	}
	epoch, _ := submission["epoch"].(string)
	if epoch == "" || utf8.RuneCountInString(epoch) > 80 {
		return nil, invalid("submission.epoch must be a nonempty string of at most 80 characters")
	}
	stamp, _ := submission["createdAt"].(string)
	createdAt, err := time.Parse(time.RFC3339Nano, stamp)
	if err != nil || !submissionDatePattern.MatchString(stamp) {
		return nil, invalid("submission.createdAt must be an RFC3339 date")
	}
	payload := copyParams(p)
	delete(payload, "reconcile")
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, invalid("submission payload must be JSON: %s", err)
	}
	if receipt := r.promptReceipts[id]; receipt != nil {
		if !bytes.Equal(receipt.payload, encoded) {
			return nil, invalid("submission.id was already used with different prompt parameters")
		}
		switch receipt.state {
		case promptInFlight:
			return promptDelivery("pending"), nil
		case promptCancelled:
			return promptDelivery("not-delivered"), nil
		default:
			if receipt.failure != nil {
				if reconcile {
					return map[string]any{"delivery": "not-delivered", "error": map[string]any{"code": receipt.failure.Code, "message": receipt.failure.Message}}, nil
				}
				return nil, receipt.failure
			}
			return model.Clone(receipt.result), nil
		}
	}
	now := time.Now()
	if epoch != r.promptEpoch || now.Sub(createdAt) > promptReceiptLifetime || createdAt.Sub(now) > 5*time.Minute {
		return promptDelivery("unknown"), nil
	}
	if len(r.promptReceipts) >= promptReceiptLimit {
		for key, receipt := range r.promptReceipts {
			if receipt.state != promptInFlight && now.Sub(receipt.createdAt) > promptReceiptLifetime {
				delete(r.promptReceipts, key)
			}
		}
		if len(r.promptReceipts) >= promptReceiptLimit {
			if reconcile {
				return promptDelivery("unknown"), nil
			}
			return nil, fail(api.CodeUnavailable, "prompt receipt registry is full; no prompt was sent")
		}
	}
	receipt := &promptReceipt{payload: encoded, createdAt: createdAt, state: promptInFlight}
	r.promptReceipts[id] = receipt
	if reconcile {
		receipt.state = promptCancelled
		return promptDelivery("not-delivered"), nil
	}
	var result any
	if err = checkParams("agent.prompt", p); err == nil {
		result, err = r.executePrompt(p)
	}
	if err == nil {
		if nf, bad := nonFinite(result); bad {
			err = invalid("%s", nf.Debug())
		}
	}
	if err != nil {
		failure := *asFailure(err)
		receipt.failure = &failure
	} else {
		receipt.result = model.Clone(result)
	}
	receipt.state = promptFinished
	return result, err
}
