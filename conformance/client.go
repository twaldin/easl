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
// newline-delimited JSON, requests answered by id, event lines once subscribed.
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
	// When the last event line arrived; settling waits for a quiet stretch.
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
