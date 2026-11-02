package router

import (
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestDispatchedRequestOutcomesPersistUntilSuccess(t *testing.T) {
	f := newFixture(t)
	tile := f.agentTerminal("", map[string]any{})
	report := func(seq int, state, outcome, failure string) {
		t.Helper()
		p := map[string]any{"tile": tile, "kind": "omp", "state": state, "protocol": 4.0, "seq": float64(seq)}
		if outcome != "" {
			p["turnOutcome"] = outcome
		}
		if failure != "" {
			p["error"] = failure
		}
		f.result("agent.report", p)
	}
	lifecycle := func() map[string]any {
		t.Helper()
		listed := f.listed(tile)["lifecycle"].(map[string]any)
		props := f.result("object.get", map[string]any{"id": tile})["object"].(map[string]any)["props"].(map[string]any)
		if !reflect.DeepEqual(listed, props["lifecycle"]) {
			t.Fatalf("agent.list and props.lifecycle disagree: %v, %v", listed, props["lifecycle"])
		}
		return listed
	}
	report(1, "working", "", "")
	before := time.Now().UTC()
	report(2, "working", "error", "400 compaction_block_misplaced")
	first := lifecycle()
	since, ok := first["errorSince"].(string)
	stamp, err := time.Parse(time.RFC3339Nano, since)
	if !ok || err != nil || !strings.HasSuffix(since, "Z") || stamp.Before(before) || stamp.After(time.Now().UTC()) {
		t.Fatalf("errorSince must be the UTC receipt time: %v (%v)", first, err)
	}
	assertRun := func(state, failure string, count float64) {
		t.Helper()
		lc := lifecycle()
		if lc["state"] != state || lc["error"] != failure || lc["errorCount"] != count || lc["errorSince"] != since {
			t.Fatalf("failure run: %v", lc)
		}
	}
	assertRun("working", "400 compaction_block_misplaced", 1)
	report(3, "working", "", "")
	assertRun("working", "400 compaction_block_misplaced", 1)
	report(4, "idle", "", "")
	assertRun("idle", "400 compaction_block_misplaced", 1)
	if lc := lifecycle(); lc["message"] != "400 compaction_block_misplaced" {
		t.Fatalf("idle settle lost default failure message: %v", lc)
	}
	object := f.result("object.get", map[string]any{"id": tile})["object"].(map[string]any)
	if seen := f.result("view.seen", map[string]any{"id": tile, "rev": object["rev"]}); seen["seen"] != true {
		t.Fatalf("failed idle tile was not seen: %v", seen)
	}
	assertRun("idle", "400 compaction_block_misplaced", 1)
	report(5, "working", "", "")
	assertRun("working", "400 compaction_block_misplaced", 1)
	report(6, "working", "aborted", "")
	assertRun("working", "400 compaction_block_misplaced", 1)
	if cutoff, _ := f.board.TurnError(tile); cutoff != "interrupted" {
		t.Fatalf("aborted request lost read cutoff: %q", cutoff)
	}
	report(7, "blocked", "", "")
	assertRun("blocked", "400 compaction_block_misplaced", 1)
	report(8, "blocked", "error", "overloaded_error")
	assertRun("blocked", "overloaded_error", 2)
	report(8, "working", "error", "duplicate")
	report(7, "working", "success", "")
	assertRun("blocked", "overloaded_error", 2)
	report(9, "working", "success", "")
	for _, key := range []string{"error", "errorCount", "errorSince"} {
		if value, present := lifecycle()[key]; present {
			t.Fatalf("success retained %s: %v", key, value)
		}
	}
	if cutoff, present := f.board.TurnError(tile); present {
		t.Fatalf("success retained read cutoff: %q", cutoff)
	}
	report(10, "idle", "", "")
	if lc := lifecycle(); lc["state"] != "done" {
		t.Fatalf("successful response lost normal done settle: %v", lc)
	}
	before = time.Now().UTC()
	report(11, "idle", "error", "new failure")
	lc := lifecycle()
	stamp, err = time.Parse(time.RFC3339Nano, lc["errorSince"].(string))
	if lc["state"] != "idle" || lc["errorCount"] != 1.0 || lc["error"] != "new failure" || err != nil || stamp.Before(before) {
		t.Fatalf("failure after success did not start a fresh run: %v", lc)
	}
}

func TestOutcomeCapabilityAndFailureSurviveAgentAndDaemonRestarts(t *testing.T) {
	for _, state := range []string{"working", "blocked", "idle"} {
		t.Run(state, func(t *testing.T) {
			f, _ := restorable(t)
			tile := f.agentTerminal("", map[string]any{"command": []any{"omp"}})
			endedAt := "2026-10-27T12:34:56.123456789Z"
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": state, "protocol": 4.0, "seq": 10.0, "turnOutcome": "error", "turnEndedAt": endedAt, "error": "provider refused"})
			if lc := f.listed(tile)["lifecycle"].(map[string]any); lc["errorSince"] != endedAt || lc["errorCount"] != 1.0 {
				t.Fatalf("delayed error did not use its response ending time: %v", lc)
			}
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": state, "protocol": 4.0, "seq": 11.0, "turnOutcome": "error", "turnEndedAt": "2026-10-28T12:34:56.987654321Z", "error": "provider refused again"})
			failed := f.listed(tile)["lifecycle"].(map[string]any)
			if failed["errorSince"] != endedAt || failed["errorCount"] != 2.0 {
				t.Fatalf("later failure changed the first response ending time: %v", failed)
			}
			f.result("agent.restart", map[string]any{"target": tile, "mode": "fresh", "force": true})
			if got := f.listed(tile)["lifecycle"]; !reflect.DeepEqual(got, failed) {
				t.Fatalf("agent.restart changed failure run: %v, want %v", got, failed)
			}
			if props := f.agentProps(tile).(map[string]any); props["turnOutcomes"] != true {
				t.Fatalf("agent.restart lost outcome capability: %v", props)
			}
			again, errs := restart(t, f)
			if len(errs) != 0 {
				t.Fatal(errs)
			}
			lc := again.listed(tile)["lifecycle"].(map[string]any)
			for _, key := range []string{"state", "error", "errorCount", "errorSince"} {
				if lc[key] != failed[key] {
					t.Fatalf("daemon restore changed %s: %v, want %v", key, lc, failed)
				}
			}
			again.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "protocol": 4.0, "seq": 11.0, "turnOutcome": "error", "turnEndedAt": "2026-10-29T12:34:56Z", "error": "replayed"})
			for _, p := range []map[string]any{
				{"state": "working"},
				{"state": "idle", "protocol": 1.0, "error": "legacy health must not replace explicit health"},
				{"state": "blocked", "protocol": 4.0},
				{"state": "idle", "turnOutcome": "aborted"},
			} {
				p["tile"], p["kind"] = tile, "codex"
				again.result("agent.report", p)
				lc = again.listed(tile)["lifecycle"].(map[string]any)
				for _, key := range []string{"error", "errorCount", "errorSince"} {
					if lc[key] != failed[key] {
						t.Fatalf("report %v changed persisted %s: %v", p, key, lc)
					}
				}
				if props := again.agentProps(tile).(map[string]any); props["turnOutcomes"] != true {
					t.Fatalf("report forgot outcome capability: %v", props)
				}
			}
			again.result("agent.report", map[string]any{"tile": tile, "kind": "codex", "state": "working", "turnOutcome": "success"})
			for _, key := range []string{"error", "errorCount", "errorSince"} {
				if _, present := again.listed(tile)["lifecycle"].(map[string]any)[key]; present {
					t.Fatalf("success retained %s after restore", key)
				}
			}
		})
	}
}

func TestOutcomeCapabilityIgnoresLegacyHealthWithoutAFailureRun(t *testing.T) {
	for _, capability := range []map[string]any{{"protocol": 4.0}, {"turnOutcome": "success"}} {
		f := newFixture(t)
		tile := f.agentTerminal("", map[string]any{})
		capability["tile"], capability["kind"], capability["state"] = tile, "omp", "working"
		f.result("agent.report", capability)
		f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "protocol": 1.0, "error": "legacy cutoff"})
		for _, key := range []string{"error", "errorCount", "errorSince"} {
			if value, present := f.listed(tile)["lifecycle"].(map[string]any)[key]; present {
				t.Fatalf("non-outcome report created %s: %v", key, value)
			}
		}
	}
}

func TestAbortedResponseRetainsCutoffWithoutCreatingFailureHealth(t *testing.T) {
	f := newFixture(t)
	tile := f.agentTerminal("", map[string]any{})
	f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working", "protocol": 4.0})
	f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working", "protocol": 4.0, "turnOutcome": "aborted"})
	f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "protocol": 4.0, "final": "Partial response"})
	if lc := f.listed(tile)["lifecycle"].(map[string]any); lc["state"] != "idle" || lc["error"] != nil || lc["errorCount"] != nil || lc["errorSince"] != nil {
		t.Fatalf("abort created failure health or done: %v", lc)
	}
	if answer := f.result("agent.read", map[string]any{"target": tile, "final": true}); answer["text"] != "Partial response" || answer["cutOff"] != "interrupted" {
		t.Fatalf("abort lost partial answer cutoff: %v", answer)
	}
}

func TestTurnOutcomeValidationDoesNotMutateLifecycleOrSequence(t *testing.T) {
	for _, invalid := range []map[string]any{
		{"turnOutcome": ""}, {"turnOutcome": "length"}, {"turnOutcome": nil}, {"turnOutcome": true},
		{"turnOutcome": "error"}, {"turnOutcome": "error", "error": " \n\t"}, {"turnOutcome": "error", "error": 1.0},
		{"turnOutcome": "success", "error": "failure"}, {"turnOutcome": "aborted", "error": ""}, {"turnOutcome": "success", "error": nil},
		{"error": "legacy working error"},
		{"turnEndedAt": "2026-10-27T12:34:56Z"},
		{"turnOutcome": "success", "turnEndedAt": nil},
		{"turnOutcome": "success", "turnEndedAt": 1.0},
		{"turnOutcome": "success", "turnEndedAt": ""},
		{"turnOutcome": "success", "turnEndedAt": "2026-10-27T12:34:56+01:00"},
		{"turnOutcome": "success", "turnEndedAt": "2026-10-27T12:34:56+00:00"},
		{"turnOutcome": "success", "turnEndedAt": "2026-10-27T12:34:56-00:00"},
		{"turnOutcome": "success", "turnEndedAt": "2026-02-30T12:34:56Z"},
		{"turnOutcome": "success", "turnEndedAt": "2026-10-27T1:34:56Z"},
		{"turnOutcome": "success", "turnEndedAt": "2026-10-27T12:34:56,123Z"},
		{"turnOutcome": "success", "turnEndedAt": "2026-10-27T12:34:56.1234567890Z"},
	} {
		f := newFixture(t)
		tile := f.agentTerminal("", map[string]any{})
		before := f.result("object.get", map[string]any{"id": tile})
		invalid["tile"], invalid["kind"], invalid["state"], invalid["seq"] = tile, "omp", "working", 10.0
		if code, _ := errorOf(f.call("agent.report", invalid)); code != "invalid_params" {
			t.Fatalf("accepted invalid outcome %v: %s", invalid, code)
		}
		if after := f.result("object.get", map[string]any{"id": tile}); !reflect.DeepEqual(before, after) {
			t.Fatalf("invalid report mutated object: %v", after)
		}
		f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working", "seq": 10.0, "turnOutcome": "error", "error": "valid failure"})
		if lc := f.listed(tile)["lifecycle"].(map[string]any); lc["error"] != "valid failure" || lc["errorCount"] != 1.0 {
			t.Fatalf("invalid report consumed sequence: %v", lc)
		}
	}
}

func TestReportedErrorsAreBoundedByUnicodeCharacters(t *testing.T) {
	for _, sample := range []struct{ input, want string }{
		{strings.Repeat("a", 500), strings.Repeat("a", 500)},
		{strings.Repeat("界", 499), strings.Repeat("界", 499)},
		{strings.Repeat("🙂", 500), strings.Repeat("🙂", 500)},
		{strings.Repeat("界", 501), strings.Repeat("界", 499) + "…"},
		{strings.Repeat("e\u0301", 251), strings.Repeat("e\u0301", 249) + "e…"},
	} {
		for _, outcome := range []bool{false, true} {
			f := newFixture(t)
			tile := f.agentTerminal("", map[string]any{})
			p := map[string]any{"tile": tile, "kind": "omp", "state": "idle", "error": " \n" + sample.input + "\t "}
			if outcome {
				p["turnOutcome"] = "error"
				p["state"] = "working"
			}
			f.result("agent.report", p)
			lc := f.listed(tile)["lifecycle"].(map[string]any)
			if lc["error"] != sample.want || !utf8.ValidString(lc["error"].(string)) || utf8.RuneCountInString(lc["error"].(string)) > 500 {
				t.Fatalf("bounded Unicode error: %v, want %q", lc, sample.want)
			}
			if outcome && lc["message"] != nil || !outcome && lc["message"] != sample.want {
				t.Fatalf("only idle errors supply a default lifecycle message: %v", lc)
			}
		}
	}
}

func TestLegacyIdleErrorsKeepReceiptTimeAndClearOnWorking(t *testing.T) {
	f := newFixture(t)
	tile := f.agentTerminal("", map[string]any{})
	before := time.Now().UTC()
	f.result("agent.report", map[string]any{"tile": tile, "kind": "codex", "state": "idle", "protocol": 1.0, "error": "legacy failure"})
	first := f.listed(tile)["lifecycle"].(map[string]any)
	since, ok := first["errorSince"].(string)
	stamp, err := time.Parse(time.RFC3339Nano, since)
	if first["state"] != "idle" || first["error"] != "legacy failure" || first["errorCount"] != 1.0 || !ok || err != nil || !strings.HasSuffix(since, "Z") || stamp.Before(before) || stamp.After(time.Now().UTC()) {
		t.Fatalf("legacy failure run: %v", first)
	}
	f.result("agent.report", map[string]any{"tile": tile, "kind": "codex", "state": "idle"})
	if got := f.listed(tile)["lifecycle"]; !reflect.DeepEqual(got, first) {
		t.Fatalf("legacy idle heartbeat changed failure run: %v", got)
	}
	before = time.Now().UTC()
	f.result("agent.report", map[string]any{"tile": tile, "kind": "codex", "state": "idle", "error": "another legacy failure"})
	next := f.listed(tile)["lifecycle"].(map[string]any)
	stamp, err = time.Parse(time.RFC3339Nano, next["errorSince"].(string))
	if next["error"] != "another legacy failure" || next["errorCount"] != 1.0 || err != nil || stamp.Before(before) {
		t.Fatalf("legacy repeated failure did not reset receipt time/count: %v", next)
	}
	f.result("agent.report", map[string]any{"tile": tile, "kind": "codex", "state": "working"})
	if got := f.listed(tile)["lifecycle"]; !reflect.DeepEqual(got, map[string]any{"state": "working", "seen": false}) {
		t.Fatalf("legacy working did not clear run: %v", got)
	}
}

func TestClosedBoardListsLegacySavedFailureWithRunFields(t *testing.T) {
	f := newFixture(t)
	tile := f.agentTerminal("", map[string]any{
		"agent":     map[string]any{"kind": "codex"},
		"lifecycle": map[string]any{"state": "idle", "error": "saved legacy error", "seen": false},
	})
	f.closeBoard(f.board.ID())
	listed := f.listed(tile)
	lc := listed["lifecycle"].(map[string]any)
	if listed["open"] != false || lc["error"] != "saved legacy error" || lc["errorCount"] != 1.0 {
		t.Fatalf("closed saved failure lacks run fields: %v", listed)
	}
	if since, ok := lc["errorSince"].(string); !ok || !strings.HasSuffix(since, "Z") {
		t.Fatalf("closed saved failure lacks UTC errorSince: %v", lc)
	} else if _, err := time.Parse(time.RFC3339Nano, since); err != nil {
		t.Fatal(err)
	}
}

func TestTurnOutcomeTimestampsPreserveNanosecondsAndNormalizeUTC(t *testing.T) {
	for _, sample := range []struct{ input, want string }{
		{"2026-10-27T12:34:56Z", "2026-10-27T12:34:56Z"},
		{"2026-10-27T12:34:56.120000000Z", "2026-10-27T12:34:56.12Z"},
		{"2026-10-27T12:34:56.000000000Z", "2026-10-27T12:34:56Z"},
		{"2026-10-27T12:34:56.123456789Z", "2026-10-27T12:34:56.123456789Z"},
	} {
		f := newFixture(t)
		tile := f.agentTerminal("", map[string]any{})
		f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working", "turnOutcome": "error", "turnEndedAt": sample.input, "error": "delayed response"})
		if lc := f.listed(tile)["lifecycle"].(map[string]any); lc["errorSince"] != sample.want {
			t.Fatalf("response ending timestamp: %v, want %s", lc, sample.want)
		}
		f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working", "turnOutcome": "aborted", "turnEndedAt": "2026-10-28T12:34:56Z"})
		if lc := f.listed(tile)["lifecycle"].(map[string]any); lc["errorSince"] != sample.want || lc["errorCount"] != 1.0 {
			t.Fatalf("abort timestamp changed failure run: %v", lc)
		}
		f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working", "turnOutcome": "success", "turnEndedAt": "2026-10-29T12:34:56Z"})
		if lc := f.listed(tile)["lifecycle"].(map[string]any); lc["errorSince"] != nil || lc["errorCount"] != nil || lc["error"] != nil {
			t.Fatalf("timestamped success retained failure run: %v", lc)
		}
	}
}
