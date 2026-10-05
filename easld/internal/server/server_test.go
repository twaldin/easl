package server

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// socketPath is a short path (unix socket paths are limited to ~104 bytes; t.TempDir is long on macOS).
func socketPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "esrv")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "s.sock")
}

func start(t *testing.T, h Handler) *Server {
	t.Helper()
	s, err := Listen(socketPath(t), h)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

type client struct {
	net.Conn
	lines *bufio.Reader
}

func dial(t *testing.T, s *Server) *client {
	t.Helper()
	nc, err := net.Dial("unix", s.Path())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { nc.Close() })
	return &client{nc, bufio.NewReader(nc)}
}

// read returns the next line as decoded JSON; it fails the test after a timeout.
func (c *client) read(t *testing.T) any {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := c.lines.ReadBytes('\n')
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var v any
	if err := json.Unmarshal(line, &v); err != nil {
		t.Fatalf("not JSON: %q", line)
	}
	return v
}

func (c *client) write(t *testing.T, s string) {
	t.Helper()
	if _, err := io.WriteString(c, s); err != nil {
		t.Fatal(err)
	}
}

func echo(req any, c *Conn) any {
	return map[string]any{"ok": true, "result": req}
}

func TestPipelinedRequestsAreAnsweredInArrivalOrder(t *testing.T) {
	// The first request is the slowest: a server that handled requests concurrently would
	// answer it last.
	s := start(t, func(req any, c *Conn) any {
		n := req.(map[string]any)["n"].(float64)
		time.Sleep(time.Duration(5-n) * 20 * time.Millisecond)
		return map[string]any{"n": n}
	})
	c := dial(t, s)
	c.write(t, `{"n":1}`+"\n"+`{"n":2}`+"\n"+`{"n":3}`+"\n")
	for want := 1.0; want <= 3; want++ {
		if got := c.read(t).(map[string]any)["n"]; got != want {
			t.Fatalf("answer %v where %v was next", got, want)
		}
	}
}

func TestMalformedLineIsAnsweredInOrderAndEmptyLinesAreSkipped(t *testing.T) {
	s := start(t, func(req any, c *Conn) any {
		time.Sleep(50 * time.Millisecond)
		return req
	})
	c := dial(t, s)
	c.write(t, "\n"+`{"id":"a"}`+"\n\n"+`{"id": nope`+"\n"+`{"id":"b"}`+"\n")
	if got := c.read(t); fmt.Sprint(got) != "map[id:a]" {
		t.Fatalf("first reply %v", got)
	}
	want := `map[error:map[code:invalid_params message:malformed JSON line] ok:false]`
	if got := c.read(t); fmt.Sprint(got) != want {
		t.Fatalf("malformed reply %v, want %s", got, want)
	}
	if got := c.read(t); fmt.Sprint(got) != "map[id:b]" {
		t.Fatalf("request after a malformed line was not answered: %v", got)
	}
}

func TestDeferredReplyAndLaterEvents(t *testing.T) {
	conns := make(chan *Conn, 1)
	s := start(t, func(req any, c *Conn) any {
		if req.(map[string]any)["method"] == "wait" {
			conns <- c
			return nil // answered later, like agent.wait
		}
		return map[string]any{"id": req.(map[string]any)["id"]}
	})
	c := dial(t, s)
	c.write(t, `{"id":"1","method":"wait"}`+"\n")
	held := <-conns
	// The deferred request doesn't hold up the connection's later requests...
	c.write(t, `{"id":"2","method":"ping"}`+"\n")
	if got := c.read(t).(map[string]any)["id"]; got != "2" {
		t.Fatalf("got %v", got)
	}
	// ...and its answer, and later pushes, go out when the owner sends them.
	if !held.Send(map[string]any{"id": "1", "ok": true}) || !held.Send(map[string]any{"event": "x"}) {
		t.Fatal("Send on an open connection failed")
	}
	if got := c.read(t).(map[string]any)["id"]; got != "1" {
		t.Fatalf("deferred reply: %v", got)
	}
	if got := c.read(t).(map[string]any)["event"]; got != "x" {
		t.Fatalf("event: %v", got)
	}
}

func TestSendKeepsOrderUnderConcurrentSenders(t *testing.T) {
	conns := make(chan *Conn, 1)
	s := start(t, func(req any, c *Conn) any { conns <- c; return nil })
	c := dial(t, s)
	c.write(t, "{}\n")
	held := <-conns
	const senders, each = 8, 200
	var wg sync.WaitGroup
	for g := range senders {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range each {
				held.Send(map[string]any{"g": g, "i": i})
			}
		}()
	}
	wg.Wait()
	next := make([]float64, senders)
	for n := 0; n < senders*each; n++ {
		m := c.read(t).(map[string]any)
		g := int(m["g"].(float64))
		if m["i"].(float64) != next[g] {
			t.Fatalf("sender %d: line %v arrived where %v was due", g, m["i"], next[g])
		}
		next[g]++
	}
}

func TestSendNeverBlocksOnAClientThatStopsReading(t *testing.T) {
	conns := make(chan *Conn, 1)
	s, err := listen(socketPath(t), func(req any, c *Conn) any { conns <- c; return nil }, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	c := dial(t, s) // never reads
	c.write(t, "{}\n")
	held := <-conns

	payload := map[string]any{"text": strings.Repeat("x", 64<<10)}
	finished := make(chan int)
	go func() {
		sent := 0
		for held.Send(payload) {
			sent++
			if sent > 1000 {
				break // would be 64 MiB: the cut-off never fired
			}
		}
		finished <- sent
	}()
	select {
	case sent := <-finished:
		if sent > 1000 {
			t.Fatal("a client 64 MiB behind was never dropped")
		}
		if sent < 8 {
			t.Fatalf("dropped after only %d lines of 64 KiB, below the 1 MiB limit", sent)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Send blocked on a client that stopped reading")
	}
	if held.IsOpen() {
		t.Fatal("a dropped client still reports open")
	}
	select {
	case <-held.Done():
	case <-time.After(time.Second):
		t.Fatal("Done not closed for a dropped client")
	}
	if held.Send(payload) {
		t.Fatal("Send succeeded on a dropped client")
	}
	// The peer sees its socket shut: reading drains what was buffered, then fails.
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.Copy(io.Discard, c); err != nil && !isReset(err) {
		t.Fatalf("expected the connection to end, got %v", err)
	}
}

func isReset(err error) bool {
	return strings.Contains(err.Error(), "reset") || strings.Contains(err.Error(), "broken pipe")
}

func TestSlowReaderStillReceivesEverythingInOrder(t *testing.T) {
	conns := make(chan *Conn, 1)
	s := start(t, func(req any, c *Conn) any { conns <- c; return nil })
	c := dial(t, s)
	c.write(t, "{}\n")
	held := <-conns
	// Well past the socket buffer but under the limit: all lines queue, none are lost.
	const lines = 40
	for i := range lines {
		if !held.Send(map[string]any{"i": i, "pad": strings.Repeat("y", 100<<10)}) {
			t.Fatalf("Send %d refused", i)
		}
	}
	for i := range lines {
		if got := c.read(t).(map[string]any)["i"]; got != float64(i) {
			t.Fatalf("line %d was %v", i, got)
		}
	}
}

func TestPeerDisconnectClosesTheConnectionButHandlesWhatWasSent(t *testing.T) {
	handled := make(chan any, 1)
	conns := make(chan *Conn, 1)
	s := start(t, func(req any, c *Conn) any {
		conns <- c
		handled <- req
		return nil
	})
	c := dial(t, s)
	// A request written just before the client leaves still runs (a mutation isn't lost)...
	c.write(t, `{"id":"last"}`+"\n")
	c.Close()
	if got := <-handled; fmt.Sprint(got) != "map[id:last]" {
		t.Fatalf("handled %v", got)
	}
	held := <-conns
	// ...but nothing can be sent to the gone client.
	select {
	case <-held.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("Done not closed after the peer left")
	}
	if held.IsOpen() || held.Send(map[string]any{"a": 1}) {
		t.Fatal("connection to a gone peer still accepts sends")
	}
}

func TestUnterminatedFinalLineIsNotARequest(t *testing.T) {
	var mu sync.Mutex
	var seen []any
	s := start(t, func(req any, c *Conn) any {
		mu.Lock()
		defer mu.Unlock()
		seen = append(seen, req)
		return echo(req, c)
	})
	c := dial(t, s)
	c.write(t, `{"id":"a"}`+"\n"+`{"id":"b"}`)
	c.read(t)
	c.Close()
	time.Sleep(100 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 1 {
		t.Fatalf("handled %v", seen)
	}
}

func TestSocketMode(t *testing.T) {
	s := start(t, echo)
	info, err := os.Stat(s.Path())
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v", info.Mode().Perm())
	}
}

func TestListenReplacesStaleSocketAndCreatesItsDirectory(t *testing.T) {
	path := filepath.Join(filepath.Dir(socketPath(t)), "sub", "dir", "s.sock")
	// A dead server's socket file.
	first, err := Listen(path, echo)
	if err != nil {
		t.Fatal(err)
	}
	first.listener.SetUnlinkOnClose(false)
	first.listener.Close() // leaves the file behind, like a crashed process
	second, err := Listen(path, echo)
	if err != nil {
		t.Fatalf("Listen over a stale socket: %v", err)
	}
	defer second.Close()
	c := dial(t, second)
	c.write(t, `{"id":"x"}`+"\n")
	c.read(t)
	first.Close()
}

func TestCloseRemovesOnlyItsOwnSocketFile(t *testing.T) {
	path := socketPath(t)
	a, err := Listen(path, echo)
	if err != nil {
		t.Fatal(err)
	}
	// Another instance takes over the path (unlinking a's file); a closing later must leave it.
	b, err := Listen(path, echo)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	a.Close()
	c := dial(t, b)
	c.write(t, `{"id":"still here"}`+"\n")
	c.read(t)

	b.Close()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("the socket file remains after its own server closed: %v", err)
	}
}

func TestCloseEndsConnectionsAfterFlushingWhatWasQueued(t *testing.T) {
	conns := make(chan *Conn, 1)
	s := start(t, func(req any, c *Conn) any { conns <- c; return nil })
	c := dial(t, s)
	c.write(t, "{}\n")
	held := <-conns
	held.Send(map[string]any{"last": true})
	s.Close()
	if got := c.read(t).(map[string]any)["last"]; got != true {
		t.Fatalf("queued line lost on Close: %v", got)
	}
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.lines.ReadByte(); err != io.EOF {
		t.Fatalf("expected EOF after Close, got %v", err)
	}
	if held.IsOpen() || held.Send(1) {
		t.Fatal("connection still open after server Close")
	}
	if _, err := net.Dial("unix", s.Path()); err == nil {
		t.Fatal("server still accepts after Close")
	}
	s.Close() // idempotent
}

func TestListenRejectsTooLongPath(t *testing.T) {
	_, err := Listen("/tmp/"+strings.Repeat("a", 120)+".sock", echo)
	if err == nil || !strings.Contains(err.Error(), "file name too long") {
		t.Fatalf("got %v", err)
	}
}

func TestCloseWaitsForHandlersOfRequestsAlreadyReceived(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var mu sync.Mutex
	var finished []string
	s := start(t, func(req any, c *Conn) any {
		id := req.(map[string]any)["id"].(string)
		if id == "a" {
			close(started)
			<-release
		}
		mu.Lock()
		finished = append(finished, id)
		mu.Unlock()
		return map[string]any{"id": id}
	})
	c := dial(t, s)
	// b is received while a is still running: it is queued behind it and must be handled too.
	c.write(t, `{"id":"a"}`+"\n"+`{"id":"b"}`+"\n")
	<-started
	time.Sleep(50 * time.Millisecond) // let the reader pick b up

	closed := make(chan struct{})
	go func() { s.Close(); close(closed) }()
	select {
	case <-closed:
		t.Fatal("Close returned while a handler was still running")
	case <-time.After(150 * time.Millisecond):
	}
	close(release)
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not return after the handlers finished")
	}
	mu.Lock()
	got := append([]string(nil), finished...)
	mu.Unlock()
	if fmt.Sprint(got) != "[a b]" {
		t.Fatalf("handlers finished %v before Close returned, want [a b]", got)
	}
	// Their replies were still delivered before the connection ended.
	for _, want := range []string{"a", "b"} {
		if got := c.read(t).(map[string]any)["id"]; got != want {
			t.Fatalf("reply %v, want %s", got, want)
		}
	}
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.lines.ReadByte(); err != io.EOF {
		t.Fatalf("expected EOF after the replies, got %v", err)
	}
}

func TestCloseDoesNotReadNewRequestsFromOpenConnections(t *testing.T) {
	var mu sync.Mutex
	handled := 0
	s := start(t, func(req any, c *Conn) any {
		mu.Lock()
		handled++
		mu.Unlock()
		return map[string]any{"ok": true}
	})
	c := dial(t, s)
	c.write(t, "{}\n")
	c.read(t)
	s.Close()
	io.WriteString(c, "{}\n") // fails with a broken pipe once the socket is gone: either way nothing handles it
	time.Sleep(100 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if handled != 1 {
		t.Fatalf("%d requests handled, want 1", handled)
	}
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func explodingHandler(req any, c *Conn) any {
	if req.(map[string]any)["method"] == "boom" {
		panic("kaboom")
	}
	return map[string]any{"id": req.(map[string]any)["id"], "ok": true}
}

func TestPanickingHandlerIsAnsweredAsInternalErrorAndTheConnectionKeepsServing(t *testing.T) {
	var logged lockedBuffer
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	s := start(t, explodingHandler)
	c := dial(t, s)
	c.write(t, `{"id":"1","method":"boom"}`+"\n"+`{"id":"2","method":"ping"}`+"\n"+`{"method":"boom"}`+"\n"+`{"id":"4","method":"ping"}`+"\n")

	reply := c.read(t).(map[string]any)
	errObj, _ := reply["error"].(map[string]any)
	if reply["id"] != "1" || reply["ok"] != false || errObj["code"] != "internal" || !strings.Contains(fmt.Sprint(errObj["message"]), "kaboom") {
		t.Fatalf("panic reply %v", reply)
	}
	if got := c.read(t).(map[string]any); got["id"] != "2" || got["ok"] != true {
		t.Fatalf("request after the panic: %v", got)
	}
	// A request without an id still gets an answer (without one), and the connection lives on.
	reply = c.read(t).(map[string]any)
	if _, has := reply["id"]; has || reply["ok"] != false || reply["error"].(map[string]any)["code"] != "internal" {
		t.Fatalf("panic reply to an id-less request: %v", reply)
	}
	if got := c.read(t).(map[string]any); got["id"] != "4" {
		t.Fatalf("request after the second panic: %v", got)
	}
	// Other connections are unaffected, and the log names the panic with its stack.
	other := dial(t, s)
	other.write(t, `{"id":"x","method":"ping"}`+"\n")
	if got := other.read(t).(map[string]any); got["id"] != "x" {
		t.Fatalf("second connection: %v", got)
	}
	out := logged.String()
	if !strings.Contains(out, "kaboom") || !strings.Contains(out, "explodingHandler") {
		t.Fatalf("panic not logged with its stack:\n%s", out)
	}
}
