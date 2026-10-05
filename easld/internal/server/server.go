// Package server is easld's Unix socket transport: newline-delimited JSON, one request per
// line, answered in arrival order on each connection. It ports Sources/CanvasCore/SocketServer.swift.
//
// The server knows nothing of the API: a Handler turns a decoded request into a response.
package server

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"runtime/debug"
	"sync"
	"syscall"
	"time"

	"github.com/twaldin/easl/easld/internal/metrics"
	"github.com/twaldin/easl/easld/internal/swiftjson"
)

// limits bound what one connection may hold of the server's memory.
type limits struct {
	// pending is how many bytes may be queued for one client before it counts as stuck: a
	// client this far behind is dropped rather than buffered without bound.
	pending int
	// line is the longest request line: a longer one is answered `invalid_params` and the
	// connection closed, as the rest of what it sends can't be framed.
	line int
	// inbox is how many requests (and inboxBytes how many of their bytes) are read ahead of
	// the handler; past either the connection isn't read until the handler catches up.
	inbox, inboxBytes int
}

var defaultLimits = limits{pending: 32 << 20, line: 64 << 20, inbox: 256, inboxBytes: 64 << 20}

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

// lineTooLong is the reply to a line longer than the limit; the connection then closes.
func lineTooLong(limit int) map[string]any {
	return map[string]any{
		"ok":    false,
		"error": map[string]any{"code": "invalid_params", "message": fmt.Sprintf("line too long (over %d bytes); closing the connection", limit)},
	}
}

// Conn is one client connection.
type Conn struct {
	nc     net.Conn
	limits limits

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

	// unanswered are the requests handed to the handler whose reply hasn't been sent yet, in
	// arrival order (guarded by mu): a reply from any path (the handler's return, a direct
	// Send, a deferred agent.wait) closes its request's `api.<method>` accounting.
	unanswered []unanswered
}

type unanswered struct {
	id      any
	method  string
	arrived time.Time
}

func newConn(nc net.Conn, l limits) *Conn {
	c := &Conn{nc: nc, limits: l, open: true, done: make(chan struct{}), written: make(chan struct{})}
	c.wake = sync.NewCond(&c.mu)
	c.inbox.ready = sync.NewCond(&c.inbox.mu)
	c.inbox.room = sync.NewCond(&c.inbox.mu)
	c.inbox.max, c.inbox.maxBytes = l.inbox, l.inboxBytes
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

// Send queues one JSON line, encoded as the app's JSONEncoder writes it (numbers as Swift
// formats a Double, `/` escaped). It never blocks on the peer: lines go out in Send order from
// a goroutine of the connection's own, so a client that stops reading can't stall the caller
// (event broadcasts, waiter replies). It returns false once the connection is closed, or when
// this line pushed the client more than 32 MiB behind, which drops it.
func (c *Conn) Send(v any) bool {
	data, err := swiftjson.Encode(v, false, true)
	if err != nil {
		return false
	}
	c.answered(v, len(data)+1)
	return c.write(append(data, '\n'))
}

// expect starts a request's accounting: `api.<method>` counts it when its reply is sent, with
// the time since it arrived (waiting behind earlier requests on the connection included) and
// the reply's bytes.
func (c *Conn) expect(id any, method string, arrived time.Time) {
	c.mu.Lock()
	c.unanswered = append(c.unanswered, unanswered{id, method, arrived})
	c.mu.Unlock()
}

// answered closes the accounting of the oldest unanswered request a reply line answers.
func (c *Conn) answered(v any, bytes int) {
	m, ok := v.(map[string]any)
	if !ok {
		return
	}
	if _, reply := m["ok"]; !reply {
		return
	}
	c.mu.Lock()
	for i, u := range c.unanswered {
		if reflect.DeepEqual(u.id, m["id"]) {
			c.unanswered = append(c.unanswered[:i], c.unanswered[i+1:]...)
			c.mu.Unlock()
			metrics.Shared.Record("api."+u.method, metrics.Since(u.arrived), bytes)
			return
		}
	}
	c.mu.Unlock()
}

func (c *Conn) write(line []byte) bool {
	c.mu.Lock()
	if !c.open {
		c.mu.Unlock()
		return false
	}
	c.pending += len(line)
	if c.pending > c.limits.pending {
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

// inbox holds a connection's requests in arrival order, so the reader seldom waits on the
// handler: only once max requests or maxBytes of them are queued (a client pipelining faster
// than it is answered), and then it stops reading the socket until the handler catches up.
type inbox struct {
	mu            sync.Mutex
	ready         *sync.Cond // the handler waits here for a request
	room          *sync.Cond // the reader waits here for the queue to shrink
	items         []request
	bytes         int // the queued requests' line lengths
	max, maxBytes int
	finished      bool
}

type request struct {
	value     any
	size      int
	malformed bool
	tooLong   bool
	method    string
	arrived   time.Time
}

// push queues r, waiting while the queue is full; a request pushed after finish is dropped.
func (b *inbox) push(r request) {
	b.mu.Lock()
	for len(b.items) > 0 && (len(b.items) >= b.max || b.bytes+r.size > b.maxBytes) && !b.finished {
		b.room.Wait()
	}
	if !b.finished {
		b.items = append(b.items, r)
		b.bytes += r.size
	}
	b.mu.Unlock()
	b.ready.Signal()
}

func (b *inbox) finish() {
	b.mu.Lock()
	b.finished = true
	b.mu.Unlock()
	b.ready.Broadcast()
	b.room.Broadcast()
}

// next blocks for the next request; false once the connection closed and the queue emptied
// (requests received before the close are still handled).
func (b *inbox) next() (request, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for len(b.items) == 0 && !b.finished {
		b.ready.Wait()
	}
	if len(b.items) == 0 {
		return request{}, false
	}
	r := b.items[0]
	b.items[0] = request{}
	b.items = b.items[1:]
	b.bytes -= r.size
	b.room.Signal()
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
		if r.tooLong {
			c.Send(lineTooLong(c.limits.line))
			c.close(false)
			return
		}
		if r.method != "" {
			c.expect(r.value.(map[string]any)["id"], r.method, r.arrived)
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
		line, err := readLine(r, c.limits.line)
		if errors.Is(err, errLineTooLong) {
			c.inbox.push(request{tooLong: true}) // answered in turn; then the connection closes
			return
		}
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
		if len(line) == 0 {
			continue
		}
		var value any
		if json.Unmarshal(line, &value) != nil {
			c.inbox.push(request{malformed: true})
			continue
		}
		m, _ := value.(map[string]any)
		method, _ := m["method"].(string)
		if method != "" {
			metrics.Shared.Record("api.in."+method, 0, len(line)+1)
		}
		c.inbox.push(request{value: value, size: len(line), method: method, arrived: time.Now()})
	}
}

var errLineTooLong = errors.New("line too long")

// readLine reads one line, without its newline, of at most max bytes (errLineTooLong past
// that). The line is valid until the next read.
func readLine(r *bufio.Reader, max int) ([]byte, error) {
	var long []byte // a line longer than the reader's buffer, gathered
	for {
		chunk, err := r.ReadSlice('\n')
		size := len(long) + len(chunk)
		if err == nil {
			size-- // the newline
		}
		if size > max {
			return nil, errLineTooLong
		}
		switch {
		case err == nil && long == nil:
			return chunk[:len(chunk)-1], nil
		case err == nil:
			long = append(long, chunk...)
			return long[:len(long)-1], nil
		case errors.Is(err, bufio.ErrBufferFull):
			long = append(long, chunk...)
		default:
			return nil, err
		}
	}
}

// Server accepts connections on a Unix socket.
type Server struct {
	path     string
	listener *net.UnixListener
	handler  Handler
	limits   limits
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

// Listen binds path (mode 0600, creating its directory 0700) and serves h on every connection
// until Close. It replaces only a stale socket (one nothing listens on, left by a crashed
// server): a path that isn't a socket, or a socket another server answers on, is refused.
func Listen(path string, h Handler) (*Server, error) { return listen(path, h, defaultLimits) }

func listen(path string, h Handler, l limits) (*Server, error) {
	if len(path) >= sunPathMax() {
		return nil, &net.OpError{Op: "listen", Net: "unix", Addr: &net.UnixAddr{Name: path, Net: "unix"}, Err: syscall.ENAMETOOLONG}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := removeStale(path); err != nil {
		return nil, err
	}
	listener, err := listenPrivate(path)
	if err != nil {
		return nil, err
	}
	listener.SetUnlinkOnClose(false)
	s := &Server{path: path, listener: listener, handler: h, limits: l, conns: map[*Conn]struct{}{}}
	if info, err := os.Lstat(path); err == nil {
		s.bound = info
	}
	s.wg.Add(1)
	go s.acceptLoop()
	return s, nil
}

// removeStale clears path for binding. Nothing there is fine, and a socket that refuses
// connections is a crashed server's, which is removed. Anything else is refused: a socket that
// answers is another server's (the app's, or another easld's), and a file that isn't a socket
// is someone's data.
func removeStale(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode().Type() != fs.ModeSocket {
		return fmt.Errorf("%s exists and is not a socket; not replacing it", path)
	}
	nc, err := net.DialTimeout("unix", path, time.Second)
	if err == nil {
		nc.Close()
		return fmt.Errorf("%s is already served by another process (an easl app or easld)", path)
	}
	if !errors.Is(err, syscall.ECONNREFUSED) && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("%s may be in use, not replacing it: %w", path, err)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// umaskMu serialises listenPrivate's umask change (the umask is the process's).
var umaskMu sync.Mutex

// listenPrivate binds path with a umask that leaves the socket 0600 from the start: a chmod
// after bind would leave it open to others (0775 under a 002 umask) in between.
func listenPrivate(path string) (*net.UnixListener, error) {
	umaskMu.Lock()
	defer umaskMu.Unlock()
	old := syscall.Umask(0o177)
	defer syscall.Umask(old)
	return net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
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
		c := newConn(nc, s.limits)
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
