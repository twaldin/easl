// Package relay serves an easl client's sockets to the programs on easld's machine
// (relay.open): a hosted terminal's integration and the `easl` CLI reach the board that shows
// the terminal through `<run>/<instance>/easl.sock` and `cmux.sock`, which easld passes on to
// the client's ssh forward of a loopback TCP port (docs/contracts.md "Hosted terminals").
//
// Why not ssh's own forward of a unix socket: Tailscale SSH creates it owned by root and
// readable by root only, so the user's programs can't connect. A loopback port can be reached
// by every user of the machine, so each connection starts with a token only easld and the
// client know, and the client's end closes any connection without it.
package relay

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"
)

// Error is a failure with its API code.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Message }

// Sockets are the names of an instance's sockets, each passed on with its name after the token.
var Sockets = []string{"easl", "cmux"}

// Relays are the open relays of easld's machine, by client instance.
type Relays struct {
	// Dir holds an instance's sockets in `<Dir>/<instance>/`.
	Dir string
	// DialTimeout bounds connecting to the client's port.
	DialTimeout time.Duration

	mu   sync.Mutex
	open map[string]*relay
}

type relay struct {
	port      int
	token     string
	listeners []net.Listener
}

// New is the relays of `dir` (easld's `<home>/run`).
func New(dir string) *Relays {
	return &Relays{Dir: dir, DialTimeout: 5 * time.Second, open: map[string]*relay{}}
}

var (
	instancePattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
	tokenPattern    = regexp.MustCompile(`^[A-Za-z0-9]{16,128}$`)
)

// Open starts serving `instance`'s sockets, or points a relay already open at the new port and
// token: their paths, by name, and whether the sockets were made now (false: they were open).
func (r *Relays) Open(instance string, port int, token string) (map[string]string, bool, error) {
	if !instancePattern.MatchString(instance) || instance == "." || instance == ".." {
		return nil, false, &Error{"invalid_params", fmt.Sprintf("instance must be [A-Za-z0-9._-], at most 64 characters, got %q", instance)}
	}
	if port < 1 || port > 65535 {
		return nil, false, &Error{"invalid_params", fmt.Sprintf("port must be 1–65535, got %d", port)}
	}
	if !tokenPattern.MatchString(token) {
		return nil, false, &Error{"invalid_params", "token must be 16–128 letters and digits"}
	}
	dir := filepath.Join(r.Dir, instance)
	paths := map[string]string{}
	for _, name := range Sockets {
		paths[name] = filepath.Join(dir, name+".sock")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if existing := r.open[instance]; existing != nil {
		existing.port, existing.token = port, token
		return paths, false, nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, false, &Error{"unavailable", err.Error()}
	}
	_ = os.Chmod(r.Dir, 0o700)
	_ = os.Chmod(dir, 0o700)
	opened := &relay{port: port, token: token}
	for _, name := range Sockets {
		listener, err := listen(paths[name])
		if err != nil {
			for _, l := range opened.listeners {
				l.Close()
			}
			return nil, false, &Error{"unavailable", fmt.Sprintf("can't serve %s: %v", paths[name], err)}
		}
		opened.listeners = append(opened.listeners, listener)
		go r.serve(instance, name, listener)
	}
	r.open[instance] = opened
	return paths, true, nil
}

// listen binds `path` for the user only, replacing a socket a previous easld left there.
func listen(path string) (net.Listener, error) {
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, errors.New("a file that isn't a socket is in the way")
		}
		_ = os.Remove(path)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	listener.(*net.UnixListener).SetUnlinkOnClose(true)
	if err := os.Chmod(path, 0o600); err != nil {
		listener.Close()
		return nil, err
	}
	return listener, nil
}

func (r *Relays) serve(instance, name string, listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go r.pass(instance, name, conn)
	}
}

// pass connects `client` to the instance's port, announces it with the token and its socket's
// name, and copies both ways until both sides are done. While the client's machine can't be
// reached the connection just closes: the integration spools its report (`unavailable`).
func (r *Relays) pass(instance, name string, client net.Conn) {
	defer client.Close()
	r.mu.Lock()
	current := r.open[instance]
	var port int
	var token string
	if current != nil {
		port, token = current.port, current.token
	}
	r.mu.Unlock()
	if current == nil {
		return
	}
	remote, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), r.DialTimeout)
	if err != nil {
		return
	}
	defer remote.Close()
	if _, err := io.WriteString(remote, token+" "+name+"\n"); err != nil {
		return
	}
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(remote, client)
		if tcp, ok := remote.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
		close(done)
	}()
	_, _ = io.Copy(client, remote)
	if unix, ok := client.(*net.UnixConn); ok {
		_ = unix.CloseWrite()
	}
	<-done
}

// Close stops every relay and removes its sockets.
func (r *Relays) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for instance, open := range r.open {
		for _, listener := range open.listeners {
			listener.Close()
		}
		delete(r.open, instance)
	}
}
