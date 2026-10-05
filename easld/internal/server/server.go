// Package server is easld's Unix socket transport: newline-delimited JSON, one request per
// line, answered in arrival order on each connection. It ports Sources/CanvasCore/SocketServer.swift.
//
// The server knows nothing of the API: a Handler turns a decoded request into a response.
package server

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sync"
	"syscall"
	"time"
)

// maxPending is how many bytes may be queued for one client before it counts as stuck: a
// client this far behind is dropped rather than buffered without bound.
const maxPending = 32 << 20

// drainTimeout bounds how long a closing connection spends flushing what was already queued
// to it.
const drainTimeout = 2 * time.Second

// Handler answers one decoded request line. It returns the response to send, or nil when the
// reply is deferred (a later Conn.Send) or the connection became an event stream. A
// connection's requests reach its handler one at a time, in arrival order; connections run
// concurrently.
type Handler func(req any, c *Conn) any

// malformedLine is the reply to a line that isn't JSON.
var malformedLine = map[string]any{
	"ok":    false,
	"error": map[string]any{"code": "invalid_params", "message": "malformed JSON line"},
}

// Conn is one client connection.
type Conn struct {
	nc    net.Conn
	limit int

	// mu guards everything below.
	mu      sync.Mutex
	wake    *sync.Cond // the writer waits here for queued lines or for the close
	queue   [][]byte   // lines not yet handed to the writer, in Send order
	pending int        // bytes queued or being written
	open    bool
	// stopping: the server is closing and no longer reads requests (see stopReading).
	stopping bool

	done    chan struct{} // closed once the connection is closed (see Done)
	written chan struct{} // closed when the writer has finished and the socket is closed

	inbox inbox
}

func newConn(nc net.Conn, limit int) *Conn {
	c := &Conn{nc: nc, limit: limit, open: true, done: make(chan struct{}), written: make(chan struct{})}
	c.wake = sync.NewCond(&c.mu)
	c.inbox.cond = sync.NewCond(&c.inbox.mu)
	return c
}

// IsOpen reports whether the peer is still connected and Send still queues.
func (c *Conn) IsOpen() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.open
}

// Done is closed when the connection closes (the peer left, it fell too far behind, or the
// server closed), so holders of a Conn (event subscribers, waiters) can let go of it.
func (c *Conn) Done() <-chan struct{} { return c.done }

// Send queues one JSON line. It never blocks on the peer: lines go out in Send order from a
// goroutine of the connection's own, so a client that stops reading can't stall the caller
// (event broadcasts, waiter replies). It returns false once the connection is closed, or when
// this line pushed the client more than 32 MiB behind, which drops it.
func (c *Conn) Send(v any) bool {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if enc.Encode(v) != nil {
		return false
	}
	return c.write(buf.Bytes()) // Encode ends the value with the newline
}

func (c *Conn) write(line []byte) bool {
	c.mu.Lock()
	if !c.open {
		c.mu.Unlock()
		return false
	}
	c.pending += len(line)
	if c.pending > c.limit {
		c.queue = nil
		c.mu.Unlock()
		c.close(true)
		return false
	}
	c.queue = append(c.queue, line)
	c.mu.Unlock()
	c.wake.Signal()
	return true
}

// close stops further sends and reads. Lines already queued are still written (within
// drainTimeout) unless hard, which is for a client that is stuck; then the socket closes.
func (c *Conn) close(hard bool) {
	c.mu.Lock()
	first := c.open
	c.open = false
	c.mu.Unlock()
	if first {
		close(c.done)
		if uc, ok := c.nc.(interface{ CloseRead() error }); ok {
			uc.CloseRead()
		}
		c.inbox.finish()
	}
	if hard {
		c.nc.Close()
	} else if first {
		c.nc.SetWriteDeadline(time.Now().Add(drainTimeout))
	}
	c.wake.Broadcast()
}

// writeLoop is the connection's single writer: lines leave in the order Send queued them.
func (c *Conn) writeLoop() {
	defer close(c.written)
	defer c.nc.Close()
	for {
		c.mu.Lock()
		for len(c.queue) == 0 && c.open {
			c.wake.Wait()
		}
		batch := c.queue
		c.queue = nil
		c.mu.Unlock()
		if len(batch) == 0 {
			return
		}
		size := 0
		for _, line := range batch {
			size += len(line)
		}
		buffers := net.Buffers(batch)
		_, err := buffers.WriteTo(c.nc)
		c.mu.Lock()
		c.pending -= size
		c.mu.Unlock()
		if err != nil {
			// The peer is gone; the reader sees EOF too.
			c.close(true)
			return
		}
	}
}

// inbox holds a connection's requests in arrival order; the reader never waits on the handler.
type inbox struct {
	mu       sync.Mutex
	cond     *sync.Cond
	items    []request
	finished bool
}

type request struct {
	value     any
	malformed bool
}

func (b *inbox) push(r request) {
	b.mu.Lock()
	if !b.finished {
		b.items = append(b.items, r)
	}
	b.mu.Unlock()
	b.cond.Signal()
}

func (b *inbox) finish() {
	b.mu.Lock()
	b.finished = true
	b.mu.Unlock()
	b.cond.Broadcast()
}

// next blocks for the next request; false once the connection closed and the queue emptied
// (requests received before the close are still handled).
func (b *inbox) next() (request, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for len(b.items) == 0 && !b.finished {
		b.cond.Wait()
	}
	if len(b.items) == 0 {
		return request{}, false
	}
	r := b.items[0]
	b.items[0] = request{}
	b.items = b.items[1:]
	return r, true
}

// serve runs the connection: a reader splitting lines into requests, and this goroutine
// answering them one by one.
func (c *Conn) serve(h Handler) {
	go c.writeLoop()
	go c.readLoop()
	for {
		r, ok := c.inbox.next()
		if !ok {
			return
		}
		if r.malformed {
			c.Send(malformedLine)
			continue
		}
		if response := c.handle(h, r.value); response != nil {
			c.Send(response)
		}
	}
}

// handle runs the handler on one request. A panic is logged with its stack and answered with
// an `internal` error (carrying the request's id), so one bad request costs neither the
// connection nor the process.
func (c *Conn) handle(h Handler, req any) (response any) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("easld: handler panic: %v\n%s", p, debug.Stack())
			failure := map[string]any{
				"ok":    false,
				"error": map[string]any{"code": "internal", "message": fmt.Sprintf("internal error: %v", p)},
			}
			if m, ok := req.(map[string]any); ok {
				if id, ok := m["id"]; ok {
					failure["id"] = id
				}
			}
			response = failure
		}
	}()
	return h(req, c)
}

// stopReading ends the intake without closing: no new requests are read, those already
// received are still handled and answered (Send keeps working until close).
func (c *Conn) stopReading() {
	c.mu.Lock()
	c.stopping = true
	c.mu.Unlock()
	if uc, ok := c.nc.(interface{ CloseRead() error }); ok {
		uc.CloseRead()
	}
	c.inbox.finish()
}

func (c *Conn) readLoop() {
	r := bufio.NewReaderSize(c.nc, 64<<10)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			// EOF (or a closed socket): an unfinished last line is dropped, as it waits for its newline.
			c.mu.Lock()
			stopping := c.stopping
			c.mu.Unlock()
			if !stopping { // the server's Close closes the connection itself, after the handlers
				c.close(false)
			}
			return
		}
		line = line[:len(line)-1]
		if len(line) == 0 {
			continue
		}
		var value any
		if json.Unmarshal(line, &value) != nil {
			c.inbox.push(request{malformed: true})
			continue
		}
		c.inbox.push(request{value: value})
	}
}

// Server accepts connections on a Unix socket.
type Server struct {
	path     string
	listener *net.UnixListener
	handler  Handler
	limit    int // per-connection pending-byte cut-off (maxPending; tests lower it)
	// bound is the socket file Listen created: instances sharing a directory bind the same
	// path in turn, so Close removes the path only while it is still this file.
	bound os.FileInfo

	mu     sync.Mutex
	conns  map[*Conn]struct{}
	closed bool
	wg     sync.WaitGroup // the accept loop
	// serving counts the connections' request-handling goroutines (Close waits for them).
	serving sync.WaitGroup
}

// sunPathMax is how long a socket path may be (sockaddr_un.sun_path, with its NUL).
func sunPathMax() int {
	if runtime.GOOS == "linux" {
		return 108
	}
	return 104
}

// Listen binds path (mode 0600, creating its directory and replacing a stale socket file)
// and serves h on every connection until Close.
func Listen(path string, h Handler) (*Server, error) { return listen(path, h, maxPending) }

func listen(path string, h Handler, limit int) (*Server, error) {
	if len(path) >= sunPathMax() {
		return nil, &net.OpError{Op: "listen", Net: "unix", Addr: &net.UnixAddr{Name: path, Net: "unix"}, Err: syscall.ENAMETOOLONG}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	os.Remove(path)
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, err
	}
	l.SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		l.Close()
		os.Remove(path)
		return nil, err
	}
	s := &Server{path: path, listener: l, handler: h, limit: limit, conns: map[*Conn]struct{}{}}
	if info, err := os.Lstat(path); err == nil {
		s.bound = info
	}
	s.wg.Add(1)
	go s.acceptLoop()
	return s, nil
}

// Path is the socket path.
func (s *Server) Path() string { return s.path }

func (s *Server) acceptLoop() {
	defer s.wg.Done()
	for {
		nc, err := s.listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(10 * time.Millisecond) // e.g. out of descriptors: don't spin
			continue
		}
		c := newConn(nc, s.limit)
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			nc.Close()
			return
		}
		s.conns[c] = struct{}{}
		s.mu.Unlock()
		s.serving.Add(1)
		go func() {
			defer s.serving.Done()
			c.serve(s.handler)
			s.mu.Lock()
			delete(s.conns, c)
			s.mu.Unlock()
		}()
	}
}

// Close stops accepting, stops reading new requests, waits (up to 2 s) for the handlers to
// finish the requests already received and for their replies to flush, then closes every
// connection and removes the socket file if it is still the one Listen bound. When it
// returns no handler it waited for is running, so the caller can persist state without
// racing one; a handler still running past the bound (hung) is abandoned.
func (s *Server) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	conns := make([]*Conn, 0, len(s.conns))
	for c := range s.conns {
		conns = append(conns, c)
	}
	s.mu.Unlock()
	s.listener.Close()
	s.wg.Wait()
	for _, c := range conns {
		c.stopReading()
	}
	deadline := time.Now().Add(drainTimeout)
	handlersDone := make(chan struct{})
	go func() { s.serving.Wait(); close(handlersDone) }()
	select {
	case <-handlersDone:
	case <-time.After(time.Until(deadline)):
	}
	for _, c := range conns {
		c.close(false)
	}
	for _, c := range conns {
		select {
		case <-c.written:
		case <-time.After(max(time.Until(deadline), 0)):
		}
	}
	if s.bound != nil {
		if info, err := os.Lstat(s.path); err == nil && os.SameFile(info, s.bound) {
			os.Remove(s.path)
		}
	}
}
