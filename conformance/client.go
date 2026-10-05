package conformance

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"
)

// conn is one client connection speaking the socket protocol (schema "transport"):
// newline-delimited JSON, requests answered by id, event lines once subscribed. A connection
// that attached as a client (client.attach) also gets requests from the server, which it answers
// from its script (Step.Replies) and records.
type conn struct {
	c       net.Conn
	mu      sync.Mutex
	next    int
	waiting map[string]chan map[string]any
	// Responses that arrived before anyone waited for them (an async step's reply).
	early map[string]map[string]any
	// Lines that carry no id: event lines, and replies to lines that weren't JSON.
	events []map[string]any
	loose  []map[string]any
	// The scripted answers left, by method, and the requests the server sent, in order.
	replies  map[string][]Reply
	received []map[string]any
	// When the last event or server request arrived; settling waits for a quiet stretch.
	lastEvent time.Time
	closed    bool
	done      chan struct{}
}

func dial(socket string) (*conn, error) {
	c, err := net.DialTimeout("unix", socket, 5*time.Second)
	if err != nil {
		return nil, err
	}
	k := &conn{c: c, waiting: map[string]chan map[string]any{}, early: map[string]map[string]any{}, done: make(chan struct{})}
	go k.read()
	return k, nil
}

func (k *conn) read() {
	defer close(k.done)
	scanner := bufio.NewScanner(k.c)
	scanner.Buffer(make([]byte, 0, 1<<20), 256<<20)
	for scanner.Scan() {
		var line map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &line); err != nil {
			line = map[string]any{"unparsed": scanner.Text()}
		}
		k.mu.Lock()
		switch {
		case line["method"] != nil:
			k.received = append(k.received, map[string]any{"method": line["method"], "params": line["params"]})
			k.lastEvent = time.Now()
			k.answer(line)
		case line["event"] != nil:
			k.events = append(k.events, line)
			k.lastEvent = time.Now()
		case line["id"] != nil:
			id := fmt.Sprint(line["id"])
			if ch, ok := k.waiting[id]; ok {
				delete(k.waiting, id)
				ch <- line
			} else {
				k.early[id] = line
			}
		default:
			k.loose = append(k.loose, line)
		}
		k.mu.Unlock()
	}
	k.mu.Lock()
	k.closed = true
	for id, ch := range k.waiting {
		close(ch)
		delete(k.waiting, id)
	}
	k.mu.Unlock()
}

// answer replies to a request the server sent with the next scripted answer for its method (an
// `internal` error when the script has none left). Called with k.mu held.
func (k *conn) answer(request map[string]any) {
	method := fmt.Sprint(request["method"])
	script := k.replies[method]
	reply := Reply{Error: map[string]any{"code": "internal", "message": "the scripted client has no reply left for " + method}}
	if len(script) > 0 {
		reply, k.replies[method] = script[0], script[1:]
	}
	switch {
	case reply.Silent:
		return
	case reply.HangUp:
		k.c.Close()
		return
	}
	line := map[string]any{"id": request["id"], "ok": reply.Error == nil}
	if reply.Error != nil {
		line["error"] = reply.Error
	} else {
		result := reply.Result
		if result == nil {
			result = map[string]any{}
		}
		line["result"] = result
	}
	data, err := json.Marshal(line)
	if err == nil {
		k.writeLine(data)
	}
}

// script adds scripted answers.
func (k *conn) script(replies map[string][]Reply) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.replies == nil {
		k.replies = map[string][]Reply{}
	}
	for method, list := range replies {
		k.replies[method] = append(k.replies[method], list...)
	}
}

// takeReceived returns and clears the requests the server sent so far.
func (k *conn) takeReceived() []map[string]any {
	k.mu.Lock()
	defer k.mu.Unlock()
	received := k.received
	k.received = nil
	return received
}

func (k *conn) isClosed() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.closed
}

// send writes one request and returns its id.
func (k *conn) send(method string, params any) (string, error) {
	k.mu.Lock()
	k.next++
	id := "r" + strconv.Itoa(k.next)
	k.mu.Unlock()
	line, err := json.Marshal(map[string]any{"id": id, "method": method, "params": params})
	if err != nil {
		return "", err
	}
	return id, k.writeLine(line)
}

func (k *conn) writeLine(line []byte) error {
	_, err := k.c.Write(append(line, '\n'))
	return err
}

// await returns the reply to request id, or an error after timeout.
func (k *conn) await(id string, timeout time.Duration) (map[string]any, error) {
	k.mu.Lock()
	if line, ok := k.early[id]; ok {
		delete(k.early, id)
		k.mu.Unlock()
		return line, nil
	}
	if k.closed {
		k.mu.Unlock()
		return nil, fmt.Errorf("connection closed before the reply to %s", id)
	}
	ch := make(chan map[string]any, 1)
	k.waiting[id] = ch
	k.mu.Unlock()
	select {
	case line, ok := <-ch:
		if !ok {
			return nil, fmt.Errorf("connection closed before the reply to %s", id)
		}
		return line, nil
	case <-time.After(timeout):
		k.mu.Lock()
		delete(k.waiting, id)
		k.mu.Unlock()
		return nil, fmt.Errorf("no reply to %s within %s", id, timeout)
	}
}

// awaitLoose returns the next line without an id (the reply to a line that wasn't JSON).
func (k *conn) awaitLoose(timeout time.Duration) (map[string]any, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		k.mu.Lock()
		if len(k.loose) > 0 {
			line := k.loose[0]
			k.loose = k.loose[1:]
			k.mu.Unlock()
			return line, nil
		}
		k.mu.Unlock()
		time.Sleep(5 * time.Millisecond)
	}
	return nil, fmt.Errorf("no reply within %s", timeout)
}

// takeEvents returns and clears the event lines received so far.
func (k *conn) takeEvents() []map[string]any {
	k.mu.Lock()
	defer k.mu.Unlock()
	events := k.events
	k.events = nil
	return events
}

func (k *conn) quietSince() time.Time {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.lastEvent
}

func (k *conn) close() {
	k.c.Close()
	<-k.done
}
