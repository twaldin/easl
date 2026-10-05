package conformance

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeServer answers the few methods a scenario below needs. With broadcast it sends every
// event to every connection, subscribed or not.
type fakeServer struct {
	broadcast bool
	mu        sync.Mutex
	conns     map[net.Conn]bool // subscribed
	next      int
}

func startFake(t *testing.T, broadcast bool) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "ecf") // short: a socket path has a length limit
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "s.sock")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	s := &fakeServer{broadcast: broadcast, conns: map[net.Conn]bool{}}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			s.mu.Lock()
			s.conns[c] = false
			s.mu.Unlock()
			go s.serve(c)
		}
	}()
	return socket
}

func (s *fakeServer) serve(c net.Conn) {
	defer c.Close()
	lines := bufio.NewScanner(c)
	for lines.Scan() {
		var req struct {
			ID     string         `json:"id"`
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
		}
		json.Unmarshal(lines.Bytes(), &req)
		var result any = map[string]any{}
		var event map[string]any
		s.mu.Lock()
		switch req.Method {
		case "board.open":
			result = map[string]any{"board": "brd_fake"}
		case "events.subscribe":
			s.conns[c] = true
		case "object.create":
			s.next++
			object := map[string]any{"id": "obj_" + string(rune('a'+s.next)), "type": "note"}
			result = map[string]any{"object": object}
			event = map[string]any{"event": "object.created", "board": "brd_fake", "data": object}
		case "board.get":
			result = map[string]any{"objects": []any{}}
		}
		write(c, map[string]any{"id": req.ID, "ok": true, "result": result})
		if event != nil {
			for other, subscribed := range s.conns {
				if subscribed || s.broadcast {
					write(other, event)
				}
			}
		}
		s.mu.Unlock()
	}
}

func write(c net.Conn, v any) {
	line, _ := json.Marshal(v)
	c.Write(append(line, '\n'))
}

// The transport sends event lines only after events.subscribe: a server that sends them to
// every connection fails the step that set them off, and can't be recorded.
func TestEventsOnUnsubscribedConnectionsFail(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string]string{
		"delegated.json":        `{}`,
		"scenarios/create.json": `{"description":"one note","steps":[{"call":"object.create","params":{"board":"{{board}}","type":"note"}}]}`,
	} {
		path := filepath.Join(dir, name)
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	suite := Suite{Dir: dir}
	all, err := LoadScenarios(filepath.Join(dir, "scenarios"))
	if err != nil {
		t.Fatal(err)
	}
	scenarios, _ := Select(all, []string{"create"})

	if err := suite.RecordAll(scenarios, Options{Socket: startFake(t, false), Settle: 30 * time.Millisecond}, "fake", new(strings.Builder)); err != nil {
		t.Fatal(err)
	}
	report, err := suite.ReplayAll(scenarios, Options{Socket: startFake(t, false), Settle: 30 * time.Millisecond})
	if err != nil || !report.Scenarios[0].Pass {
		t.Fatalf("a server that sends events to subscribers only fails: %v %+v", err, report.Scenarios)
	}

	report, err = suite.ReplayAll(scenarios, Options{Socket: startFake(t, true), Settle: 30 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	create := report.Scenarios[0].Steps[2]
	if report.Scenarios[0].Pass || create.Pass || len(create.Diffs) == 0 || create.Diffs[0] != "events on connections that never subscribed: object.created on main" {
		t.Fatalf("a broadcasting server: %+v", report.Scenarios[0].Steps)
	}

	err = suite.RecordAll(scenarios, Options{Socket: startFake(t, true), Settle: 30 * time.Millisecond}, "fake", new(strings.Builder))
	if err == nil || !strings.Contains(err.Error(), "never subscribed") {
		t.Fatalf("recording a broadcasting server: %v", err)
	}
}
