package router

import "testing"

func TestInboxRefusesNoticeAckBeforeOrdinaryAckOrHoldMutation(t *testing.T) {
	for _, tc := range []struct {
		name      string
		protocol  float64
		wakeOnly  bool
		noticeAck any
	}{
		{"legacy_protocol", 1, false, []any{"msg_notice_unsupported"}},
		{"protocol2_wake_only", 2, true, []any{"msg_notice_unsupported"}},
		{"protocol3_without_wake_only", 3, false, []any{"msg_notice_unsupported"}},
		{"protocol3_wake_only", 3, true, []any{"msg_notice_unsupported"}},
		{"empty_notice_ack", 3, true, []any{}},
		{"null_notice_ack", 3, true, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			tile := f.namedTerminal("worker", "")
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "protocol": 1.0})
			id := f.result("agent.prompt", map[string]any{"target": tile, "text": "Keep this ordinary message."})["message"]
			holder, other := &conn{}, &conn{}
			defer holder.close()
			defer other.close()
			if got := messagesOf(t, f.on(holder, "agent.inbox", map[string]any{"tile": tile})); len(got) != 1 || got[0]["id"] != id {
				t.Fatalf("initial ordinary offer: %v", got)
			}

			code, _ := errorOf(f.on(other, "agent.inbox", map[string]any{
				"tile": tile, "ack": []any{id}, "started": true,
				"protocol": tc.protocol, "wakeOnly": tc.wakeOnly, "noticeAck": tc.noticeAck,
			}))
			if code != "invalid_params" {
				t.Fatalf("unsupported notice acknowledgement code: %s", code)
			}
			if got := messagesOf(t, f.on(other, "agent.inbox", map[string]any{"tile": tile, "protocol": 3.0, "wakeOnly": true})); len(got) != 0 {
				t.Fatalf("refusal released the ordinary hold: %v", got)
			}

			holder.close()
			got := messagesOf(t, f.on(other, "agent.inbox", map[string]any{"tile": tile, "protocol": 3.0, "wakeOnly": true}))
			if len(got) != 1 || got[0]["id"] != id || got[0]["text"] != "Keep this ordinary message." {
				t.Fatalf("refusal consumed the ordinary message: %v", got)
			}
			if got := messagesOf(t, f.on(other, "agent.inbox", map[string]any{"tile": tile, "ack": []any{id}})); len(got) != 0 {
				t.Fatalf("ordinary ACK failed: %v", got)
			}
			other.close()
			reader := &conn{}
			defer reader.close()
			if got := messagesOf(t, f.on(reader, "agent.inbox", map[string]any{"tile": tile})); len(got) != 0 {
				t.Fatalf("ordinary ACK left a queued message: %v", got)
			}
		})
	}
}
