// Package relay serves an easl client's sockets to the programs on easld's machine
// (relay.open): a hosted terminal's integration and the `easl` CLI reach the board that shows
// the terminal through `<run>/<instance>/easl.sock` and `cmux.sock`, which easld passes on to
// the client's ssh forward of a loopback TCP port (docs/contracts.md "Hosted terminals").
//
// Why not ssh's own forward of a unix socket: Tailscale SSH creates it owned by root and
// readable by root only, so the user's programs can't connect. A loopback port can be reached
// by every user of the machine, and once the client's forward is gone anyone can listen on it.
// So neither end sends the token the client gave: each connection starts with both proving
// they hold it (Proof), and nothing passes to an end that can't.
package relay

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Error is a failure with its API code.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Message }

// Sockets are the names of an instance's sockets, each named to the client as a connection to it
// starts.
var Sockets = []string{"easl", "cmux"}

// Relays are the open relays of easld's machine, by client instance.
type Relays struct {
	// Dir holds an instance's sockets in `<Dir>/<instance>/`.
	Dir string
	// DialTimeout bounds connecting to the client's port; HandshakeTimeout the client's proof.
	DialTimeout      time.Duration
	HandshakeTimeout time.Duration

	mu   sync.Mutex
	open map[string]*relay
}

type registration struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
}

type relay struct {
	// port and token are where the client's forward is and the secret it proves; port is 0 once
	// a connection there failed (the forward is gone, or what listens can't prove the token),
	// until the client opens the relay again.
	port        int
	token       string
	needsReplay bool
	listeners   []net.Listener
}

// New is the relays of `dir` (easld's `<home>/run`).
func New(dir string) *Relays {
	return &Relays{Dir: dir, DialTimeout: 5 * time.Second, HandshakeTimeout: 5 * time.Second, open: map[string]*relay{}}
}

var (
	instancePattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
	tokenPattern    = regexp.MustCompile(`^[A-Za-z0-9]{16,128}$`)
	noncePattern    = regexp.MustCompile(`^[0-9a-f]{32}$`)
	proofPattern    = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// Open serves `instance`'s sockets through the client's forward at `port`, whose end holds
// `token`: their paths, by name, and whether integrations may have spooled reports the client
// should fetch (opened). Opening again with the same token (the client's keepalive) takes the
// port and reports a restart or re-arms a relay a failed connection disarmed (opened then).
// A new token is a new connection of the client's (its app restarted, or it reconnected):
// the sockets are bound anew at the same paths, so integrations watching their socket's
// identity see the board come back and report again.
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
	existing := r.open[instance]
	if existing != nil && existing.token == token {
		if existing.port != port {
			if err := saveRegistration(dir, port, token); err != nil {
				return nil, false, &Error{"unavailable", err.Error()}
			}
		}
		replay := existing.port == 0 || existing.needsReplay
		existing.port = port
		existing.needsReplay = false
		return paths, replay, nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, false, &Error{"unavailable", err.Error()}
	}
	_ = os.Chmod(r.Dir, 0o700)
	_ = os.Chmod(dir, 0o700)
	opened := &relay{port: port, token: token}
	var err error
	for _, name := range Sockets {
		var listener net.Listener
		listener, err = bind(paths[name])
		if err != nil {
			break
		}
		opened.listeners = append(opened.listeners, listener)
	}
	if err == nil {
		err = saveRegistration(dir, port, token)
	}
	if err != nil {
		for i, listener := range opened.listeners {
			listener.Close()
			_ = os.Remove(paths[Sockets[i]])
		}
		if existing != nil {
			for _, listener := range existing.listeners {
				listener.Close()
			}
			delete(r.open, instance)
		}
		return nil, false, &Error{"unavailable", fmt.Sprintf("can't serve %s: %v", instance, err)}
	}
	if existing != nil {
		// Its paths are the new listeners' now.
		for _, listener := range existing.listeners {
			listener.Close()
		}
	}
	r.open[instance] = opened
	for i, name := range Sockets {
		go r.serve(instance, name, opened.listeners[i])
	}
	return paths, true, nil
}

func saveRegistration(dir string, port int, token string) error {
	data, err := json.Marshal(registration{Port: port, Token: token})
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(dir, ".relay.json.tmp-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(file.Name(), filepath.Join(dir, "relay.json"))
	}
	return err
}

// Restore rebinds registered sockets before easld serves. It does not dial the targets:
// a Mac that went away must not delay startup, and pass still requires its proof.
func (r *Relays) Restore() []error {
	entries, err := os.ReadDir(r.Dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return []error{err}
	}
	var failures []error
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		path := filepath.Join(r.Dir, entry.Name(), "relay.json")
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		var saved registration
		if err == nil {
			err = json.Unmarshal(data, &saved)
		}
		if err == nil {
			_, _, err = r.Open(entry.Name(), saved.Port, saved.Token)
		}
		if err != nil {
			failures = append(failures, fmt.Errorf("can't restore relay %s: %w", entry.Name(), err))
			continue
		}
		r.mu.Lock()
		// The next keepalive must still fetch reports spooled while easld was down.
		r.open[entry.Name()].needsReplay = true
		r.mu.Unlock()
	}
	return failures
}

// bind serves `path` for the user only. The socket is bound beside it and renamed over it, so a
// socket already there (the relay's previous one, or one a previous easld left) is replaced in
// one step and a client never finds the path missing; a file that isn't a socket is left alone.
func bind(path string) (net.Listener, error) {
	if info, err := os.Lstat(path); err == nil && info.Mode()&os.ModeSocket == 0 {
		return nil, errors.New("a file that isn't a socket is in the way")
	}
	fresh := filepath.Join(filepath.Dir(path), "."+filepath.Base(path))
	_ = os.Remove(fresh)
	listener, err := net.Listen("unix", fresh)
	if err != nil {
		return nil, err
	}
	// Once renamed, the path is no longer this listener's to unlink (Close).
	listener.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := os.Chmod(fresh, 0o600); err == nil {
		err = os.Rename(fresh, path)
	}
	if err != nil {
		listener.Close()
		_ = os.Remove(fresh)
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

// pass connects `client` to the instance's port, proves the token there and has the other end
// prove it (`handshake`), then copies both ways until both sides are done. A connection the
// client's end doesn't take (nothing listens, or what does can't prove the token) closes at once
// (the integration spools its report: `unavailable`) and disarms the relay until the client opens
// it again: whatever has the port now gets no more connections.
func (r *Relays) pass(instance, name string, client net.Conn) {
	defer client.Close()
	r.mu.Lock()
	var port int
	var token string
	if current := r.open[instance]; current != nil {
		port, token = current.port, current.token
	}
	r.mu.Unlock()
	if port == 0 {
		return
	}
	remote, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), r.DialTimeout)
	if err != nil {
		r.disarm(instance, port, token)
		return
	}
	defer remote.Close()
	if err := handshake(remote, token, name, r.HandshakeTimeout); err != nil {
		r.disarm(instance, port, token)
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

// disarm stops passing `instance`'s connections on, unless the client opened the relay again
// since `port` and `token` were read.
func (r *Relays) disarm(instance string, port int, token string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if current := r.open[instance]; current != nil && current.port == port && current.token == token {
		current.port = 0
	}
}

// handshake starts a connection to the client's end for socket `name`: easld sends
// `<name> <nonce>`, the end answers `<its nonce> <Proof(token, "gate", …)>`, and easld, once
// that proves the token, sends `<Proof(token, "easld", …)>`, which the end checks before it
// splices. Neither sends the token: what listens on the port after the client's forward is gone
// learns nothing from a connection, and gets no report.
func handshake(conn net.Conn, token, name string, timeout time.Duration) error {
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return err
	}
	ours := make([]byte, 16)
	if _, err := rand.Read(ours); err != nil {
		return err
	}
	nonce := hex.EncodeToString(ours)
	if _, err := io.WriteString(conn, name+" "+nonce+"\n"); err != nil {
		return err
	}
	// Small enough that a listener sending without end can't fill memory; the gate sends nothing
	// after its line until it has easld's proof.
	reader := bufio.NewReaderSize(conn, 256)
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return err
	}
	theirs, proof, _ := strings.Cut(strings.TrimSuffix(string(line), "\n"), " ")
	if !noncePattern.MatchString(theirs) || !proofPattern.MatchString(proof) || reader.Buffered() > 0 ||
		!hmac.Equal([]byte(proof), []byte(Proof(token, "gate", name, nonce, theirs))) {
		return errors.New("the client's end didn't prove the token")
	}
	if _, err := io.WriteString(conn, Proof(token, "easld", name, nonce, theirs)+"\n"); err != nil {
		return err
	}
	return conn.SetDeadline(time.Time{})
}

// Proof is `role`'s proof ("easld" or "gate") that it holds `token`, for a connection to socket
// `name` that easld started with nonce `easld` and the client's end answered with nonce `gate`:
// HMAC-SHA256 keyed by the token, in hex (RelayGate.proof).
func Proof(token, role, name, easld, gate string) string {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("easl-relay " + role + " " + name + " " + easld + " " + gate))
	return hex.EncodeToString(mac.Sum(nil))
}

// Close stops every relay and removes its sockets, leaving registrations for the next start.
func (r *Relays) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for instance, open := range r.open {
		for i, listener := range open.listeners {
			listener.Close()
			_ = os.Remove(filepath.Join(r.Dir, instance, Sockets[i]+".sock"))
		}
		delete(r.open, instance)
	}
}
