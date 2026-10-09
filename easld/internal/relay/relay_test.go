package relay

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/relay/relaytest"
)

const token = "0123456789abcdef0123456789abcdef"

// impostor listens on a port the client's forward let go of, as another user of the machine
// could: it answers a connection's challenge with a made-up proof and records everything the
// connection sends it until easld closes it.
func impostor(t *testing.T) (port int, wire chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	wire = make(chan string, 8)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
				reader := bufio.NewReader(conn)
				hello, _ := reader.ReadString('\n')
				fmt.Fprintf(conn, "%s %s\n", strings.Repeat("a", 32), strings.Repeat("0", 64))
				rest, _ := io.ReadAll(reader)
				wire <- hello + string(rest)
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port, wire
}

func roundTrip(t *testing.T, path, text string) string {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.WriteString(conn, text); err != nil {
		// The relay closes a connection it won't pass on, and that close can land before the
		// write: a broken pipe, reset or ENOTCONN is that close, so there is no reply.
		if errors.Is(err, syscall.EPIPE) || errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ENOTCONN) {
			return ""
		}
		t.Fatal(err)
	}
	_ = conn.(*net.UnixConn).CloseWrite()
	reply, _ := io.ReadAll(conn)
	return string(reply)
}

func inode(t *testing.T, path string) uint64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Sys().(*syscall.Stat_t).Ino
}

// Each socket's connections reach the client's end once both have proved the token, without
// either sending it, and the replies come back; the sockets are the user's only.
func TestRelayPassesConnectionsOnceBothEndsProveTheToken(t *testing.T) {
	r := New(filepath.Join(t.TempDir(), "run"))
	defer r.Close()
	gate := relaytest.New(t, token)
	port, names, wire := gate.Port(), gate.Names, gate.Wire
	paths, opened, err := r.Open("mac-1", port, token)
	if err != nil || !opened {
		t.Fatalf("open: %v %v", opened, err)
	}
	for _, name := range Sockets {
		if got := roundTrip(t, paths[name], "{\"id\":\"1\"}\n"); got != "{\"id\":\"1\"}\n" {
			t.Errorf("%s: reply %q", name, got)
		}
		if got := <-names; got != name {
			t.Errorf("connection for %s announced as %q", name, got)
		}
		if sent := <-wire; strings.Contains(sent, token) || !strings.HasPrefix(sent, name+" ") {
			t.Errorf("%s: the handshake %q", name, sent)
		}
		info, err := os.Stat(paths[name])
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Errorf("%s: mode %v %v", name, info.Mode(), err)
		}
	}
	if info, _ := os.Stat(filepath.Dir(paths["easl"])); info.Mode().Perm() != 0o700 {
		t.Errorf("instance directory mode %v", info.Mode())
	}
}

// Whatever listens on the port once the client's forward is gone (another user's listener, or the
// client's end under a newer token) learns neither the token nor anything the integration sends;
// the relay then stops dialing it until the client opens it again, with its new port and token
// or (its keepalive) the same ones, which re-arms it and says so (opened: replay the spool).
func TestNothingPassesToAnEndThatCantProveTheToken(t *testing.T) {
	r := New(filepath.Join(t.TempDir(), "run"))
	defer r.Close()
	stolen, wire := impostor(t)
	paths, _, err := r.Open("mac-1", stolen, token)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if got := roundTrip(t, paths["easl"], `{"method":"agent.report","params":{"final":"secret"}}`+"\n"); got != "" {
		t.Errorf("reply %q from an impostor", got)
	}
	if time.Since(start) > 2*time.Second {
		t.Errorf("the connection took %v to close", time.Since(start))
	}
	sent := <-wire
	if strings.Contains(sent, token) || strings.Contains(sent, "secret") || strings.Count(sent, "\n") != 1 {
		t.Errorf("the impostor got %q", sent)
	}
	_ = roundTrip(t, paths["easl"], "again\n")
	select {
	case sent := <-wire:
		t.Errorf("a disarmed relay dialed the port again: %q", sent)
	case <-time.After(200 * time.Millisecond):
	}

	// The client's end under a newer token than easld holds: the same.
	rotatedGate := relaytest.New(t, strings.Repeat("9", 32))
	rotated, rotatedWire := rotatedGate.Port(), rotatedGate.Wire
	if _, opened, err := r.Open("mac-1", rotated, token); err != nil || !opened {
		t.Fatalf("re-arming open: %v %v", opened, err)
	}
	if got := roundTrip(t, paths["easl"], "secret\n"); got != "" {
		t.Errorf("reply %q through an end holding another token", got)
	}
	if sent := <-rotatedWire; strings.Contains(sent, "secret") {
		t.Errorf("the other end got %q", sent)
	}

	freshGate := relaytest.New(t, strings.Repeat("7", 32))
	fresh, names := freshGate.Port(), freshGate.Names
	if _, opened, err := r.Open("mac-1", fresh, strings.Repeat("7", 32)); err != nil || !opened {
		t.Fatalf("open with the new forward: %v %v", opened, err)
	}
	if got := roundTrip(t, paths["easl"], "x\n"); got != "x\n" || <-names != "easl" {
		t.Errorf("reply %q through the new forward", got)
	}
}

// The client's keepalive (same port and token) changes nothing. A new token (the client's app
// restarted, or it reconnected) binds the sockets anew at the same paths, so an integration
// watching its socket's identity reports again. A socket a previous easld left is replaced, a
// file that isn't a socket is not.
func TestANewTokenRebindsTheSockets(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "run")
	stale := filepath.Join(dir, "mac-1", "easl.sock")
	if err := os.MkdirAll(filepath.Dir(stale), 0o700); err != nil {
		t.Fatal(err)
	}
	old, err := net.Listen("unix", stale)
	if err != nil {
		t.Fatal(err)
	}
	old.(*net.UnixListener).SetUnlinkOnClose(false)
	old.Close()

	r := New(dir)
	defer r.Close()
	first := relaytest.New(t, token).Port()
	paths, opened, err := r.Open("mac-1", first, token)
	if err != nil || !opened {
		t.Fatalf("open over a stale socket: %v %v", opened, err)
	}
	before := inode(t, paths["easl"])
	if _, opened, err := r.Open("mac-1", first, token); err != nil || opened || inode(t, paths["easl"]) != before {
		t.Fatalf("keepalive: opened %v, %v, rebound %v", opened, err, inode(t, paths["easl"]) != before)
	}
	other := strings.Repeat("f", 32)
	secondGate := relaytest.New(t, other)
	second, names := secondGate.Port(), secondGate.Names
	if _, opened, err := r.Open("mac-1", second, other); err != nil || !opened {
		t.Fatalf("reopen: %v %v", opened, err)
	}
	if inode(t, paths["easl"]) == before {
		t.Error("a new token should bind the socket anew")
	}
	if got := roundTrip(t, paths["easl"], "x\n"); got != "x\n" || <-names != "easl" {
		t.Errorf("reply %q through the new socket", got)
	}

	blocked := filepath.Join(dir, "mac-2")
	if err := os.MkdirAll(blocked, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(blocked, "easl.sock"), []byte("mine"), 0o600); err != nil {
		t.Fatal(err)
	}
	var e *Error
	if _, _, err := r.Open("mac-2", second, token); !errors.As(err, &e) || e.Code != "unavailable" {
		t.Errorf("a regular file in the way: %v", err)
	}
	if data, _ := os.ReadFile(filepath.Join(blocked, "easl.sock")); string(data) != "mine" {
		t.Error("the file in the way was touched")
	}
}

// While the client's port doesn't answer, a connection closes at once, so the integration spools
// its report instead of hanging.
func TestUnreachableClientClosesTheConnection(t *testing.T) {
	r := New(filepath.Join(t.TempDir(), "run"))
	defer r.Close()
	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	paths, _, err := r.Open("mac-1", port, token)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if got := roundTrip(t, paths["easl"], "x\n"); got != "" || time.Since(start) > 2*time.Second {
		t.Errorf("reply %q after %v", got, time.Since(start))
	}
}

// The proof both ends compute, pinned (HMAC-SHA256 of the connection, keyed by the token):
// HostedTerminalTests checks RelayGate against the same value.
func TestProofIsHMACOfTheConnection(t *testing.T) {
	got := Proof(token, "gate", "easl", "00112233445566778899aabbccddeeff", "ffeeddccbbaa99887766554433221100")
	if got != "f15a835e2e2f2ab2f5235980e309b1312d70b0dfad121e0f30d011fc406bc9b6" {
		t.Errorf("proof %s", got)
	}
}

func TestOpenChecksItsParams(t *testing.T) {
	r := New(filepath.Join(t.TempDir(), "run"))
	defer r.Close()
	for name, c := range map[string]struct {
		instance, token string
		port            int
	}{
		"instance path": {"../x", token, 1000},
		"instance dot":  {"..", token, 1000},
		"port":          {"mac", token, 70000},
		"short token":   {"mac", "abc", 1000},
		"token space":   {"mac", "0123456789abcdef 0123456789abcdef", 1000},
	} {
		var e *Error
		if _, _, err := r.Open(c.instance, c.port, c.token); !errors.As(err, &e) || e.Code != "invalid_params" {
			t.Errorf("%s: %v", name, err)
		}
	}
}
