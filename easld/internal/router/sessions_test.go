package router

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/session"
)

// session.* over the socket: env and labels reach zmx, a spawn's reply says whether it created
// the session, list shows it with its labels, and bad params and a missing zmx keep their codes.
func TestSessionMethods(t *testing.T) {
	f := newFixture(t)
	dir := t.TempDir()
	zmx := filepath.Join(dir, "zmx")
	script := `#!/bin/sh
case "$1" in
attach) [ "$2" = --labels ] && shift 2; [ -e "` + dir + `/$2" ] || printf '%s %s' "$EASL_SOCKET" "$3" > "` + dir + `/$2" ;;
list) for s in "` + dir + `"/canvas-*; do [ -f "$s" ] && printf '  name=%s\tpid=7\tclients=0\tcanvas.home=mac\n' "$(basename "$s")"; done; true ;;
esac
`
	if err := os.WriteFile(zmx, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions = &session.Manager{Zmx: zmx, Dir: filepath.Join(dir, "zmx-dir"), Shell: "/bin/sh", Home: dir, Env: os.Environ()}
	call := func(method string, params map[string]any) map[string]any {
		f.seq++
		return f.router.HandleConn(map[string]any{"id": f.seq, "method": method, "params": params}, f.conn).(map[string]any)
	}
	spawn := map[string]any{"tile": "obj_x", "env": map[string]any{"EASL_SOCKET": "/r/mac/easl.sock"}, "labels": map[string]any{"canvas.home": "mac"}}
	for i, created := range []bool{true, false} {
		reply := call("session.spawn", spawn)
		result, _ := reply["result"].(map[string]any)
		if reply["ok"] != true || result["session"] != "canvas-obj_x" || result["created"] != created {
			t.Fatalf("spawn %d: %v", i, reply)
		}
	}
	if data, _ := os.ReadFile(filepath.Join(dir, "canvas-obj_x")); string(data) != "/r/mac/easl.sock /bin/sh" {
		t.Errorf("session started with %q", data)
	}
	list := call("session.list", nil)["result"].(map[string]any)["sessions"].([]any)
	if len(list) != 1 {
		t.Fatalf("list %v", list)
	}
	entry := list[0].(map[string]any)
	if entry["tile"] != "obj_x" || entry["pid"] != float64(7) || entry["labels"].(map[string]any)["canvas.home"] != "mac" {
		t.Errorf("list entry %v", entry)
	}
	for _, c := range []struct {
		method string
		params map[string]any
		code   string
	}{
		{"session.spawn", map[string]any{"tile": "obj_x", "env": map[string]any{"A": 1}}, "invalid_params"},
		{"session.spawn", map[string]any{"tile": "obj_x", "shell": "zsh"}, "invalid_params"},
		{"session.kill", map[string]any{}, "invalid_params"},
		{"session.kill", map[string]any{"tile": "obj_x", "home": "other"}, "conflict"},
	} {
		reply := call(c.method, c.params)
		if got, _ := reply["error"].(map[string]any); got["code"] != c.code {
			t.Errorf("%s %v: %v, want %s", c.method, c.params, reply, c.code)
		}
	}
	f.router.Sessions = nil
	if reply := call("session.list", nil); !strings.Contains(stringOf(reply["error"].(map[string]any)["message"]), "zmx isn't installed") {
		t.Errorf("without zmx: %v", reply)
	}
}

func TestSessionSpawnKeepsAMergedBoardsSession(t *testing.T) {
	f := newFixture(t)
	home := t.TempDir()
	zmx, err := filepath.Abs("../../../Tests/Fixtures/hosted-zmx.sh")
	if err != nil {
		t.Fatal(err)
	}
	list := "  name=canvas-obj_x\tpid=7\tclients=0\tcanvas.home=mac\tcanvas.board=brd_old\tcanvas.tile=obj_x\n"
	if err := os.WriteFile(filepath.Join(home, "list-last"), []byte(list), 0o600); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions = &session.Manager{Zmx: zmx, Dir: filepath.Join(home, "zmx-dir"), Shell: "/bin/sh", Home: home, Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin"}}
	reply := f.router.HandleConn(map[string]any{"id": 1, "method": "session.spawn", "params": map[string]any{
		"tile": "obj_x", "labels": map[string]any{"canvas.home": "mac", "canvas.board": "brd_repo", "canvas.tile": "obj_x"},
	}}, f.conn).(map[string]any)
	result, _ := reply["result"].(map[string]any)
	if reply["ok"] != true || result["session"] != "canvas-obj_x" || result["created"] != false {
		t.Fatalf("merged board re-check: %v", reply)
	}
}
