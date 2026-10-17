package router

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/session/zmxtest"
)

func owningHome(t *testing.T) (*fixture, string, string) {
	t.Helper()
	f := newFixture(t)
	home, err := os.MkdirTemp("/tmp", "easlcmux")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(home) })
	zmx, err := zmxtest.Install(home)
	if err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(home, "sessions")
	if err := os.MkdirAll(filepath.Join(state, "logs"), 0o700); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions = &session.Manager{Zmx: zmx, Dir: state, Shell: "/bin/sh", Home: home, Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin", "CMUX_SOCKET_PATH=/old/cmux.sock", "CMUX_SOCKET_PASSWORD=secret"}}
	f.router.Owns = &session.Owner{Socket: filepath.Join(home, "easl.sock"), Home: home, Resources: session.Resources(home)}
	return f, home, state
}

func TestOwnedSessionGetsABoundCmuxSocketAndNotTheInheritedOne(t *testing.T) {
	f, home, state := owningHome(t)
	defer f.router.CloseOwnedSockets()
	tile := idOf(f.result("object.create", map[string]any{
		"type": "terminal", "props": map[string]any{"command": []any{"omp"}}, "frame": browserFrame(),
	}))
	got, err := zmxtest.Read(state, session.Prefix+tile)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(home, "cmux", tile+".sock")
	if got.Env["CMUX_SOCKET_PATH"] != path || got.Env["CMUX_SURFACE_ID"] != tile || got.Env["CMUX_WORKSPACE_ID"] != f.board.ID() {
		t.Fatalf("cmux env %v", got.Env)
	}
	if got.Env["CMUX_SOCKET_PASSWORD"] != "" || strings.Contains(got.Env["CMUX_SOCKET_PATH"], "/old/") {
		t.Fatalf("inherited cmux leaked: %v", got.Env)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v %v", info, err)
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("auth anything\n")); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil || line != "OK: No password required\n" {
		t.Fatalf("auth reply %q %v", line, err)
	}
	body, _ := json.Marshal(map[string]any{"id": "1", "method": "browser.open_split", "params": map[string]any{"url": "https://example.com/from-cmux"}})
	if _, err := conn.Write(append(body, '\n')); err != nil {
		t.Fatal(err)
	}
	line, err = reader.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	var reply map[string]any
	if err := json.Unmarshal([]byte(line), &reply); err != nil || reply["ok"] != true {
		t.Fatalf("open_split %s %v", line, err)
	}
	result := reply["result"].(map[string]any)
	if result["created_split"] != true || result["workspace_id"] != f.board.ID() {
		t.Fatalf("open_split result %v", result)
	}
	page := result["surface_id"].(string)
	object := f.result("object.get", map[string]any{"id": page})["object"].(map[string]any)
	if object["props"].(map[string]any)["url"] != "https://example.com/from-cmux" {
		t.Fatalf("created page %v", object["props"])
	}
	if object["createdBy"].(map[string]any)["tile"] != tile {
		t.Fatalf("open_split credit %v", object["createdBy"])
	}
}

func TestCmuxPageCommandReachesTheDrawingMacAndCloseDropsTheSocket(t *testing.T) {
	f, home, state := owningHome(t)
	defer f.router.CloseOwnedSockets()
	homeClient := &scriptedClient{router: f.router, replies: []map[string]any{
		{"ok": true, "result": map[string]any{"url": "https://example.com/drawn"}},
	}}
	attachDrawing(f, homeClient, "mch_home", "home", true, "browser.call")
	tile := idOf(f.result("object.create", map[string]any{
		"type": "terminal", "props": map[string]any{}, "frame": browserFrame(),
	}))
	path := filepath.Join(home, "cmux", tile+".sock")
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	body, _ := json.Marshal(map[string]any{"id": "open", "method": "browser.open_split", "params": map[string]any{"url": "example.com"}})
	if _, err := conn.Write(append(body, '\n')); err != nil {
		t.Fatal(err)
	}
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	var opened map[string]any
	if err := json.Unmarshal([]byte(line), &opened); err != nil || opened["ok"] != true {
		t.Fatalf("open %s", line)
	}
	page := opened["result"].(map[string]any)["surface_id"].(string)
	props := f.result("object.get", map[string]any{"id": page})["object"].(map[string]any)["props"].(map[string]any)
	machine := props["drawingMachine"].(map[string]any)
	if machine["id"] != "mch_home" || props["url"] != "https://example.com" {
		t.Fatalf("split props %v", props)
	}
	nav, _ := json.Marshal(map[string]any{"id": "nav", "method": "browser.navigate", "params": map[string]any{"surface_id": page, "url": "https://example.com/drawn"}})
	if _, err := conn.Write(append(nav, '\n')); err != nil {
		t.Fatal(err)
	}
	line, err = reader.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	var navigated map[string]any
	if err := json.Unmarshal([]byte(line), &navigated); err != nil || navigated["ok"] != true {
		t.Fatalf("navigate %s", line)
	}
	result := navigated["result"].(map[string]any)
	if result["url"] != "https://example.com/drawn" || result["surface_id"] != page {
		t.Fatalf("navigate result %v", result)
	}
	if len(homeClient.asked) != 1 || homeClient.asked[0]["method"] != "browser.call" {
		t.Fatalf("drawing Mac was not asked: %v", homeClient.asked)
	}
	forwarded := homeClient.asked[0]["params"].(map[string]any)
	if forwarded["caller"] != tile || forwarded["params"].(map[string]any)["surface_id"] != nil {
		t.Fatalf("forwarded %v", forwarded)
	}
	conn.Close()
	f.result("object.delete", map[string]any{"id": tile})
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("deleted terminal left its socket: %v", err)
	}
	if _, err := zmxtest.Read(state, session.Prefix+tile); err == nil {
		t.Fatal("deleted terminal left its session")
	}
}

func TestFailedBatchStartsNoCmuxSocket(t *testing.T) {
	f, home, _ := owningHome(t)
	defer f.router.CloseOwnedSockets()
	code, _ := errorOf(f.call("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": map[string]any{"type": "terminal", "props": map[string]any{}, "frame": browserFrame()}},
		map[string]any{"method": "object.create", "params": map[string]any{"type": "nope", "props": map[string]any{}}},
	}}))
	if code == "" {
		t.Fatal("batch succeeded")
	}
	entries, err := os.ReadDir(filepath.Join(home, "cmux"))
	if err == nil && len(entries) != 0 {
		t.Fatalf("failed batch left sockets %v", entries)
	}
}

func TestRestartKeepsTheOwnedCmuxSocket(t *testing.T) {
	f, home, _ := owningHome(t)
	defer f.router.CloseOwnedSockets()
	tile := idOf(f.result("object.create", map[string]any{
		"type": "terminal", "props": map[string]any{"command": []any{"omp"}}, "frame": browserFrame(),
	}))
	path := filepath.Join(home, "cmux", tile+".sock")
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	restarted := f.result("agent.restart", map[string]any{"target": tile, "mode": "fresh", "force": true})
	if restarted["command"] == nil {
		t.Fatalf("restart %v", restarted)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("restart removed the cmux socket: %v", err)
	}
}

func TestCmuxCloseCreditsItsCrossBoardDriverBeforeThePageCreator(t *testing.T) {
	f, home, _ := owningHome(t)
	defer f.router.CloseOwnedSockets()
	driver := idOf(f.result("object.create", map[string]any{
		"type": "terminal", "props": map[string]any{}, "frame": browserFrame(),
	}))
	other, _ := f.openBoard("other")
	creator := idOf(f.result("object.create", map[string]any{
		"board": other, "type": "terminal", "props": map[string]any{}, "frame": browserFrame(),
	}))
	page := idOf(f.result("object.create", map[string]any{
		"board": other, "type": "browser", "caller": creator, "props": map[string]any{}, "frame": browserFrame(),
	}))
	conn, err := net.Dial("unix", filepath.Join(home, "cmux", driver+".sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]any{
		"id": "close", "method": "surface.close", "params": map[string]any{"surface_id": page},
	})
	if _, err := conn.Write(append(body, '\n')); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	var closed map[string]any
	if err := json.Unmarshal([]byte(line), &closed); err != nil || closed["ok"] != true {
		t.Fatalf("close %s", line)
	}
	entries := f.result("board.history", map[string]any{"board": other, "kinds": []any{"deleted"}})["entries"].([]any)
	if len(entries) != 1 {
		t.Fatalf("deletion history %v", entries)
	}
	entry := entries[0].(map[string]any)
	if entry["id"] != page || entry["actor"] != "agent:"+driver {
		t.Fatalf("cross-board close lost its driver to the creator: %v", entry)
	}
}
