package router

import (
	"encoding/json"
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
	var fixture struct {
		Tile  string
		Board string
		Home  string
		Cases []struct {
			Name     string
			Labels   map[string]string
			Merged   []string
			Accepted bool
		}
	}
	data, err := os.ReadFile("../../../Tests/Fixtures/hosted-ownership.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	f.router.Sessions = &session.Manager{Zmx: zmx, Dir: filepath.Join(home, "zmx-dir"), Shell: "/bin/sh", Home: home, Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin"}}
	call := func(merged any) map[string]any {
		return f.router.HandleConn(map[string]any{"id": 1, "method": "session.spawn", "params": map[string]any{
			"tile": fixture.Tile, "merged": merged, "labels": map[string]any{"canvas.home": fixture.Home, "canvas.board": fixture.Board, "canvas.tile": fixture.Tile},
		}}, f.conn).(map[string]any)
	}
	for _, ownership := range fixture.Cases {
		t.Run(ownership.Name, func(t *testing.T) {
			var labels []string
			for key, value := range ownership.Labels {
				labels = append(labels, key+"="+value)
			}
			list := "  name=canvas-" + fixture.Tile + "\tpid=7\tclients=0\t" + strings.Join(labels, "\t") + "\n"
			if err := os.WriteFile(filepath.Join(home, "list-last"), []byte(list), 0o600); err != nil {
				t.Fatal(err)
			}
			merged := make([]any, len(ownership.Merged))
			for i, id := range ownership.Merged {
				merged[i] = id
			}
			reply := call(merged)
			if !ownership.Accepted {
				failure, _ := reply["error"].(map[string]any)
				if reply["ok"] != false || failure["code"] != "conflict" {
					t.Fatalf("re-check: %v, want conflict", reply)
				}
				return
			}
			result, _ := reply["result"].(map[string]any)
			if reply["ok"] != true || result["session"] != "canvas-"+fixture.Tile || result["created"] != false {
				t.Fatalf("re-check: %v", reply)
			}
		})
	}
	for _, c := range []struct {
		name   string
		merged any
	}{
		{"not an array", "brd_old"},
		{"not all strings", []any{"brd_old", float64(1)}},
		{"null", nil},
		{"newline", []any{"brd_other\ncanvas.board=brd_old"}},
		{"trailing newline", []any{"brd_old\n"}},
		{"empty", []any{""}},
		{"uppercase prefix", []any{"BRD_old"}},
		{"extra separator", []any{"brd_old_extra"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			reply := call(c.merged)
			failure, _ := reply["error"].(map[string]any)
			if reply["ok"] != false || failure["code"] != "invalid_params" {
				t.Fatalf("re-check: %v, want invalid_params", reply)
			}
		})
	}
}
