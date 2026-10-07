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

	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/session/zmxtest"
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

// With --own-terminals easld starts a new terminal's session pointed at its own socket, beside
// which the agent's integration spools what easld isn't there to take (the directory easld
// replays), labelled with its home; deleting the terminal ends the session and that spool.
func TestOwnTerminalsStartsAndEndsTheirSessions(t *testing.T) {
	dir := shortDir(t)
	home, root, socket := filepath.Join(dir, "home"), filepath.Join(dir, "root"), filepath.Join(dir, "s.sock")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	zmx, err := zmxtest.Install(dir)
	if err != nil {
		t.Fatal(err)
	}
	done, stderr := start(t, "--home", home, "--socket", socket, "--zmx", zmx, "--own-terminals")
	c := connect(t, socket, stderr)
	board := c.call(t, "board.open", map[string]any{"root": root})["board"].(string)
	created := c.call(t, "object.create", map[string]any{"board": board, "type": "terminal", "props": map[string]any{"command": []any{"omp"}}})
	tile := created["object"].(map[string]any)["id"].(string)
	sessions := filepath.Join(home, "zmx")
	got, err := zmxtest.Read(sessions, "canvas-"+tile)
	if err != nil {
		t.Fatalf("no session for %s: %v (easld said %q)", tile, err, stderr.String())
	}
	if got.Env["EASL_SOCKET"] != socket || got.Env["EASL_TILE_ID"] != tile || got.Env["EASL_BOARD_ID"] != board {
		t.Errorf("env %v", got.Env)
	}
	if want := "canvas.home=" + session.Label(home); !strings.Contains(got.Labels, want) {
		t.Errorf("labels %q, want %s", got.Labels, want)
	}
	spooled := filepath.Join(filepath.Dir(got.Env["EASL_SOCKET"]), "agent-reports", tile)
	if err := os.MkdirAll(spooled, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(spooled, "1-1-r.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	c.call(t, "object.delete", map[string]any{"id": tile})
	for _, path := range []string{filepath.Join(sessions, "canvas-"+tile), spooled} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("%s is still there after the delete: %v", path, err)
		}
	}
	if code := stop(t, done, syscall.SIGTERM); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
}

// With --own-terminals easld reopens at start the boards it had open. Restarted with their
// sessions still running it starts none; after a reboot (no session left) each terminal's starts
// again, resuming the agent session it recorded, or running its command once its agent released.
func TestOwnedBoardsComeBackAfterARestartAndAReboot(t *testing.T) {
	dir := shortDir(t)
	home, root, socket := filepath.Join(dir, "home"), filepath.Join(dir, "root"), filepath.Join(dir, "s.sock")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	zmx, err := zmxtest.Install(dir)
	if err != nil {
		t.Fatal(err)
	}
	args := []string{"--home", home, "--socket", socket, "--zmx", zmx, "--own-terminals"}
	terminal := func(c *client, board string, command ...any) string {
		props := map[string]any{}
		if len(command) > 0 {
			props["command"] = command
		}
		created := c.call(t, "object.create", map[string]any{"board": board, "type": "terminal", "props": props})
		return created["object"].(map[string]any)["id"].(string)
	}
	done, stderr := start(t, args...)
	c := connect(t, socket, stderr)
	board := c.call(t, "board.open", map[string]any{"root": root})["board"].(string)
	agent := terminal(c, board, "omp", "--model", "opus")
	c.call(t, "agent.report_session", map[string]any{"tile": agent, "kind": "omp", "sessionId": "s1"})
	released := terminal(c, board, "claude")
	c.call(t, "agent.report_session", map[string]any{"tile": released, "kind": "claude", "sessionId": "u-1"})
	c.call(t, "agent.release", map[string]any{"tile": released, "kind": "claude"})
	if code := stop(t, done, syscall.SIGTERM); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	sessions := filepath.Join(home, "zmx")
	mark := func(tile string) string {
		path := filepath.Join(sessions, "canvas-"+tile)
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("no session for %s: %v", tile, err)
		}
		marked := string(data) + "mark=before the restart\n"
		if err := os.WriteFile(path, []byte(marked), 0o600); err != nil {
			t.Fatal(err)
		}
		return marked
	}
	before := map[string]string{agent: mark(agent), released: mark(released)}

	done, stderr = start(t, args...)
	c = connect(t, socket, stderr)
	// Answered once the sessions queued before its own have started.
	terminal(c, board)
	for tile, want := range before {
		if data, _ := os.ReadFile(filepath.Join(sessions, "canvas-"+tile)); string(data) != want {
			t.Errorf("%s's session was started again by a restart: %q", tile, data)
		}
	}
	if code := stop(t, done, syscall.SIGTERM); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}

	entries, err := os.ReadDir(sessions)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "canvas-") {
			os.Remove(filepath.Join(sessions, e.Name()))
		}
	}
	done, stderr = start(t, args...)
	c = connect(t, socket, stderr)
	terminal(c, board)
	for tile, want := range map[string]string{agent: `'omp' '--model' 'opus' '--resume=s1'; exec`, released: `'claude'; exec`} {
		got, err := zmxtest.Read(sessions, "canvas-"+tile)
		if err != nil || len(got.Args) != 4 || !strings.HasPrefix(got.Args[3], want) {
			t.Errorf("%s after a reboot: %q (%v), want %s…; easld said %q", tile, got.Args, err, want, stderr.String())
		}
	}
	if code := stop(t, done, syscall.SIGTERM); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
}
