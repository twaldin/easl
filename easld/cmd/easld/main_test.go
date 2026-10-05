package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// shortDir is a directory for sockets (their paths are short; TMPDIR on macOS is long).
func shortDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "easld-main-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// start runs easld in-process; the channel receives its exit status.
func start(t *testing.T, args ...string) (<-chan int, *syncBuffer) {
	t.Helper()
	done, stderr := make(chan int, 1), &syncBuffer{}
	go func() { done <- run(args, stderr) }()
	return done, stderr
}

// stop signals easld (this process) and waits for it to exit.
func stop(t *testing.T, done <-chan int, sig syscall.Signal) int {
	t.Helper()
	if err := syscall.Kill(os.Getpid(), sig); err != nil {
		t.Fatal(err)
	}
	select {
	case code := <-done:
		return code
	case <-time.After(10 * time.Second):
		t.Fatalf("easld still running after %v", sig)
		return -1
	}
}

type client struct {
	net.Conn
	lines *bufio.Reader
	seq   int
}

// connect dials path once easld serves it.
func connect(t *testing.T, path string, stderr *syncBuffer) *client {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		nc, err := net.Dial("unix", path)
		if err == nil {
			t.Cleanup(func() { nc.Close() })
			return &client{Conn: nc, lines: bufio.NewReader(nc)}
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s never served: %v (easld said %q)", path, err, stderr.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (c *client) call(t *testing.T, method string, params map[string]any) map[string]any {
	t.Helper()
	c.seq++
	line, _ := json.Marshal(map[string]any{"id": c.seq, "method": method, "params": params})
	if _, err := c.Write(append(line, '\n')); err != nil {
		t.Fatal(err)
	}
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	reply, err := c.lines.ReadBytes('\n')
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(reply, &m); err != nil || m["ok"] != true {
		t.Fatalf("%s: %s", method, reply)
	}
	return m["result"].(map[string]any)
}

// The app holds its home's instance lock and serves its socket there: easld on that home
// exits naming the app's pid, and the app's socket stays the app's.
func TestAHomeInUseIsRefused(t *testing.T) {
	home := filepath.Join(shortDir(t), "home")
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}
	app, err := acquireInstanceLock(filepath.Join(home, "instance.lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer app.release()
	appSocket, err := net.Listen("unix", filepath.Join(home, "easl.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer appSocket.Close()

	var stderr bytes.Buffer
	if code := run([]string{"--home", home}, &stderr); code != 1 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	if want := fmt.Sprintf("pid %d", os.Getpid()); !strings.Contains(stderr.String(), want) {
		t.Fatalf("the message doesn't name the holder (%s): %s", want, stderr.String())
	}
	accepted := make(chan error, 1)
	go func() {
		nc, err := appSocket.Accept()
		if err == nil {
			nc.Close()
		}
		accepted <- err
	}()
	nc, err := net.Dial("unix", filepath.Join(home, "easl.sock"))
	if err != nil {
		t.Fatalf("the app's socket is gone: %v", err)
	}
	nc.Close()
	if err := <-accepted; err != nil {
		t.Fatal(err)
	}
}

// A terminal tile of the app exports EASL_SOCKET (the app's socket); easld started there serves
// its own home's socket and leaves the app's alone.
func TestInheritedEaslSocketIsNotServed(t *testing.T) {
	dir := shortDir(t)
	appPath := filepath.Join(dir, "app.sock")
	appSocket, err := net.Listen("unix", appPath)
	if err != nil {
		t.Fatal(err)
	}
	defer appSocket.Close()
	t.Setenv("EASL_SOCKET", appPath)
	home := filepath.Join(dir, "home")

	done, stderr := start(t, "--home", home)
	c := connect(t, filepath.Join(home, "easl.sock"), stderr)
	if pong := c.call(t, "system.ping", nil); pong == nil {
		t.Fatal("no ping reply")
	}
	if info, err := os.Lstat(appPath); err != nil || info.Mode().Type() != os.ModeSocket {
		t.Fatalf("the app's socket: %v %v", info, err)
	}
	if code := stop(t, done, syscall.SIGTERM); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
}

// SIGHUP (the terminal easld runs in closing) saves the changes still waiting for the debounce,
// as SIGINT and SIGTERM do.
func TestHangupSavesPendingChanges(t *testing.T) {
	dir := shortDir(t)
	home, root := filepath.Join(dir, "home"), filepath.Join(dir, "root")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	done, stderr := start(t, "--home", home, "--socket", filepath.Join(dir, "s.sock"))
	c := connect(t, filepath.Join(dir, "s.sock"), stderr)
	board := c.call(t, "board.open", map[string]any{"root": root})["board"].(string)
	created := c.call(t, "object.create", map[string]any{"board": board, "type": "shape", "props": map[string]any{"kind": "rect"}, "frame": map[string]any{"x": 0, "y": 0, "w": 100, "h": 60}})
	id := created["object"].(map[string]any)["id"].(string)
	if code := stop(t, done, syscall.SIGHUP); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	data, err := os.ReadFile(filepath.Join(home, "boards", board+".json"))
	if err != nil || !strings.Contains(string(data), id) {
		t.Fatalf("the new shape isn't in the board file: %v\n%s", err, data)
	}
}
