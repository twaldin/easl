package relay

import (
	"bufio"
	"bytes"
	"errors"
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
	first := relaytest.New(t, token).Port()
	paths, _, err := r.Open("mac-1", first, token)
	if err != nil {
		t.Fatal(err)
	}
	rotated := strings.Repeat("7", 32)
	if _, _, err := r.Open("mac-1", first, rotated); err != nil {
		t.Fatal(err)
	}
	latest := relaytest.New(t, rotated).Port()
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
				_, _ = io.WriteString(conn, "secret report\n")
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

func TestPersistenceFailuresDoNotStopLiveRelays(t *testing.T) {
	dir := relayDir(t)
	r := New(dir)
	defer r.Close()
	var log bytes.Buffer
	r.Log = &log
	first := relaytest.New(t, token)
	paths, _, err := r.Open("mac-1", first.Port(), token)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "mac-1", "relay.json")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "block"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, opened, err := r.Open("mac-1", first.Port(), token); err != nil || opened {
		t.Fatalf("unchanged keepalive: opened=%v, %v", opened, err)
	}
	if log.Len() != 0 {
		t.Fatalf("an unchanged persisted target attempted a save: %s", log.String())
	}
	stolen, _ := impostor(t)
	if _, _, err := r.Open("mac-1", stolen, token); err != nil {
		t.Fatalf("save failure stopped changing the live target: %v", err)
	}
	if got := roundTrip(t, paths["easl"], "secret\n"); got != "" {
		t.Fatalf("an impostor replied %q", got)
	}
	if _, opened, err := r.Open("mac-1", first.Port(), token); err != nil || !opened {
		t.Fatalf("save failure stopped re-arming: opened=%v, %v", opened, err)
	}
	if got := roundTrip(t, paths["easl"], "rearmed\n"); got != "rearmed\n" {
		t.Fatalf("re-armed reply %q", got)
	}
	rotated := strings.Repeat("9", 32)
	fresh := relaytest.New(t, rotated)
	if _, opened, err := r.Open("mac-1", fresh.Port(), rotated); err != nil || !opened {
		t.Fatalf("save failure stopped a new token: opened=%v, %v", opened, err)
	}
	if got := roundTrip(t, paths["easl"], "rotated\n"); got != "rotated\n" {
		t.Fatalf("new-token reply %q", got)
	}
	if !strings.Contains(log.String(), "can't save "+path) || !strings.Contains(log.String(), "can't remove "+path) {
		t.Fatalf("persistence failures did not name the registration path: %s", log.String())
	}
}

func TestDisarmedRegistrationRetiresUntilTheClientRearmsIt(t *testing.T) {
	dir := relayDir(t)
	r := New(dir)
	stolen, wire := impostor(t)
	paths, _, err := r.Open("mac-1", stolen, token)
	if err != nil {
		t.Fatal(err)
	}
	if got := roundTrip(t, paths["easl"], "secret\n"); got != "" {
		t.Fatalf("an impostor replied %q", got)
	}
	<-wire
	path := filepath.Join(dir, "mac-1", "relay.json")
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("disarmed registration was retained: %v", err)
	}
	r.Close()
	r = New(dir)
	defer r.Close()
	if failures := r.Restore(); len(failures) != 0 {
		t.Fatal(failures)
	}
	for _, name := range Sockets {
		conn, err := net.Dial("unix", paths[name])
		if conn != nil {
			conn.Close()
		}
		if !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("known-dead %s socket restored: %v", name, err)
		}
	}
	select {
	case sent := <-wire:
		t.Fatalf("startup dialed a known-dead target: %q", sent)
	case <-time.After(200 * time.Millisecond):
	}
	fresh := relaytest.New(t, token)
	if _, opened, err := r.Open("mac-1", fresh.Port(), token); err != nil || !opened {
		t.Fatalf("re-arm after restart: opened=%v, %v", opened, err)
	}
	if got := roundTrip(t, paths["easl"], "back\n"); got != "back\n" {
		t.Fatalf("reply after re-arm %q", got)
	}
	r.Close()
	r = New(dir)
	defer r.Close()
	if failures := r.Restore(); len(failures) != 0 {
		t.Fatal(failures)
	}
	if got := roundTrip(t, paths["easl"], "persisted again\n"); got != "persisted again\n" {
		t.Fatalf("the re-arm did not persist its registration: %q", got)
	}
}

func TestRestoreLeavesRegistrationFilesUntouched(t *testing.T) {
	dir := relayDir(t)
	r := New(dir)
	gate := relaytest.New(t, token)
	paths, _, err := r.Open("mac-1", gate.Port(), token)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "mac-1", "relay.json")
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	r.Close()
	r = New(dir)
	defer r.Close()
	if failures := r.Restore(); len(failures) != 0 {
		t.Fatal(failures)
	}
	after, err := os.Stat(path)
	if err != nil || !os.SameFile(before, after) || after.Mode().Perm() != 0o400 {
		t.Fatalf("startup rewrote the readable registration: %v %v", after, err)
	}
	if got := roundTrip(t, paths["easl"], "restored\n"); got != "restored\n" {
		t.Fatalf("restored reply %q", got)
	}
	if _, opened, err := r.Open("mac-1", gate.Port(), token); err != nil || !opened {
		t.Fatalf("restored keepalive: opened=%v, %v", opened, err)
	}
	after, err = os.Stat(path)
	if err != nil || !os.SameFile(before, after) || after.Mode().Perm() != 0o400 {
		t.Fatalf("an unchanged keepalive rewrote the registration: %v %v", after, err)
	}
}
