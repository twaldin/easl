package relay

import (
	"bufio"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func relayDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "easld-relay-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "run")
}

func TestRestoreKeepsTheLatestRegistrationAndRequestsSpoolReplayOnce(t *testing.T) {
	dir := relayDir(t)
	r := New(dir)
	first, _, _ := gate(t, token)
	paths, _, err := r.Open("mac-1", first, token)
	if err != nil {
		t.Fatal(err)
	}
	rotated := strings.Repeat("7", 32)
	if _, _, err := r.Open("mac-1", first, rotated); err != nil {
		t.Fatal(err)
	}
	latest, _, _ := gate(t, rotated)
	if _, _, err := r.Open("mac-1", latest, rotated); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(filepath.Join(dir, "mac-1", "relay.json")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("registration must be readable only by its owner: %v %v", info, err)
	}
	r.Close()
	r = New(dir)
	defer r.Close()
	if failures := r.Restore(); len(failures) != 0 {
		t.Fatal(failures)
	}
	for _, name := range Sockets {
		if got := roundTrip(t, paths[name], "latest\n"); got != "latest\n" {
			t.Fatalf("%s did not reach the latest port and token: %q", name, got)
		}
	}
	before := inode(t, paths["easl"])
	for _, want := range []bool{true, false} {
		if _, opened, err := r.Open("mac-1", latest, rotated); err != nil || opened != want {
			t.Fatalf("keepalive opened=%v, want %v: %v", opened, want, err)
		}
		if inode(t, paths["easl"]) != before {
			t.Fatal("a restored relay's keepalive rebound its socket")
		}
	}
}

func silentTarget(t *testing.T) (int, chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	wire := make(chan string, 8)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
				data, _ := io.ReadAll(conn)
				wire <- string(data)
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port, wire
}

func TestRestoredRelayRejectsImpostorsAndBoundsSilentTargets(t *testing.T) {
	for _, target := range []string{"impostor", "silent"} {
		t.Run(target, func(t *testing.T) {
			dir := relayDir(t)
			r := New(dir)
			var port int
			var wire chan string
			if target == "impostor" {
				port, wire = impostor(t)
			} else {
				port, wire = silentTarget(t)
			}
			paths, _, err := r.Open("mac-1", port, token)
			if err != nil {
				t.Fatal(err)
			}
			r.Close()
			r = New(dir)
			r.HandshakeTimeout = 100 * time.Millisecond
			defer r.Close()
			if failures := r.Restore(); len(failures) != 0 {
				t.Fatal(failures)
			}
			for _, name := range Sockets {
				conn, err := net.Dial("unix", paths[name])
				if err != nil {
					t.Fatal(err)
				}
				_ = conn.SetDeadline(time.Now().Add(time.Second))
				_, err = io.WriteString(conn, "secret report\n")
				if err != nil && !errors.Is(err, syscall.EPIPE) && !errors.Is(err, syscall.ECONNRESET) {
					conn.Close()
					t.Fatal(err)
				}
				reply, err := bufio.NewReader(conn).ReadBytes('\n')
				conn.Close()
				if len(reply) != 0 || !(errors.Is(err, io.EOF) || errors.Is(err, syscall.ECONNRESET)) {
					t.Fatalf("%s must close without a reply or a client timeout: %q %v", name, reply, err)
				}
			}
			select {
			case sent := <-wire:
				if strings.Contains(sent, token) || strings.Contains(sent, "secret") || strings.Count(sent, "\n") != 1 {
					t.Fatalf("stale target received more than a challenge: %q", sent)
				}
			case <-time.After(time.Second):
				t.Fatal("the stale connection did not close")
			}
			select {
			case sent := <-wire:
				t.Fatalf("the disarmed restored relay dialed again: %q", sent)
			case <-time.After(200 * time.Millisecond):
			}
		})
	}
}
