package metrics

import "testing"

func TestWindowsKeepOnlyTheirRecentBuckets(t *testing.T) {
	s := newSeries()
	s.add(Tally{N: 1, Ms: 4, MaxMs: 4, Bytes: 10}, 5)  // over 10 min before 745
	s.add(Tally{N: 1, Ms: 2, MaxMs: 2}, 650)           // within 10 min of 745, not its last 60 s
	s.add(Tally{N: 2, Ms: 3, MaxMs: 3, Bytes: 5}, 745) // the last 60 s
	if got := s.window(60, 745); got != (Tally{N: 2, Ms: 3, MaxMs: 3, Bytes: 5}) {
		t.Errorf("last 60 s at 745: %+v", got)
	}
	if got := s.window(600, 760); got != (Tally{N: 3, Ms: 5, MaxMs: 3, Bytes: 5}) {
		t.Errorf("last 10 min at 760: %+v", got)
	}
	// 600 s later the same per-second and per-10-second slots come round again: the stale
	// tallies in them are dropped, not added to.
	s.add(Tally{N: 1, Ms: 1, MaxMs: 1}, 1345)
	if got := s.window(60, 1345); got != (Tally{N: 1, Ms: 1, MaxMs: 1}) {
		t.Errorf("last 60 s at 1345: %+v", got)
	}
	if got := s.window(600, 1345); got != (Tally{N: 1, Ms: 1, MaxMs: 1}) {
		t.Errorf("last 10 min at 1345: %+v", got)
	}
	if s.total != (Tally{N: 5, Ms: 10, MaxMs: 4, Bytes: 15}) {
		t.Errorf("total %+v", s.total)
	}
}

func TestResetClearsCountersButKeepsLevels(t *testing.T) {
	m := New()
	m.Record("api.x", 2, 7)
	m.Offender("writers", "user", 0)
	m.Gauge("events.subscribers", 3)
	m.Reset()
	snap := m.Snapshot()
	if c := snap["counters"].(map[string]any); len(c) != 0 {
		t.Errorf("counters after reset: %v", c)
	}
	if top := snap["top"].(map[string]any); len(top) != 0 {
		t.Errorf("top after reset: %v", top)
	}
	if g := snap["gauges"].(map[string]any)["events.subscribers"]; g != 3.0 {
		t.Errorf("events.subscribers after reset: %v", g)
	}
}
