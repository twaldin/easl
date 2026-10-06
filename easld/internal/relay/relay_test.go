package relay

import (
	"bufio"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// gate stands in for the client's end of the forward: it records each connection's first line
// and echoes what follows.
func gate(t *testing.T) (port int, headers chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	headers = make(chan string, 8)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				header, _ := reader.ReadString('\n')
				headers <- strings.TrimSuffix(header, "\n")
				_, _ = io.Copy(conn, reader)
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port, headers
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
		t.Fatal(err)
	}
	_ = conn.(*net.UnixConn).CloseWrite()
	reply, _ := io.ReadAll(conn)
	return string(reply)
}

const token = "0123456789abcdef0123456789abcdef"

// Each socket's connections reach the client's port behind the token and the socket's name, and
// the replies come back; the sockets are the user's only.
func TestRelayPassesConnectionsOnWithTheToken(t *testing.T) {
	r := New(filepath.Join(t.TempDir(), "run"))
	defer r.Close()
	port, headers := gate(t)
	paths, opened, err := r.Open("mac-1", port, token)
	if err != nil || !opened {
		t.Fatalf("open: %v %v", opened, err)
	}
	for _, name := range Sockets {
		if got := roundTrip(t, paths[name], "{\"id\":\"1\"}\n"); got != "{\"id\":\"1\"}\n" {
			t.Errorf("%s: reply %q", name, got)
		}
		if got := <-headers; got != token+" "+name {
			t.Errorf("%s: header %q", name, got)
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

// Opening again (the client reconnected) keeps the sockets and moves them to the new port and
// token; a socket a previous easld left is replaced, a file that isn't a socket is not.
func TestReopenMovesToTheNewPort(t *testing.T) {
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
	first, _ := gate(t)
	if _, opened, err := r.Open("mac-1", first, token); err != nil || !opened {
		t.Fatalf("open over a stale socket: %v %v", opened, err)
	}
	second, headers := gate(t)
	other := strings.Repeat("f", 32)
	paths, opened, err := r.Open("mac-1", second, other)
	if err != nil || opened {
		t.Fatalf("reopen: %v %v", opened, err)
	}
	if got := roundTrip(t, paths["easl"], "x\n"); got != "x\n" {
		t.Errorf("reply %q", got)
	}
	if got := <-headers; got != other+" easl" {
		t.Errorf("header %q, want the new token", got)
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
