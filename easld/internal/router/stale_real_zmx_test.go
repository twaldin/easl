package router

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/session"
)

func TestBoardStaleRealZmxTaskCompletionIsNotShellExit(t *testing.T) {
	zmx := session.Locate("")
	if zmx == "" {
		t.Skip("real zmx is not installed")
	}
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	home, err := os.MkdirTemp("/tmp", "easl-stale-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(home); err != nil {
			t.Errorf("remove real zmx scratch: %v", err)
		}
	})
	m := &session.Manager{Zmx: zmx, Dir: filepath.Join(home, "zmx"), Shell: "/bin/sh", Home: home,
		Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin", "TERM=xterm-256color", "ZMX_TRACK_ENV="}}
	f.router.Sessions = m
	f.router.Owns = &session.Owner{Socket: filepath.Join(home, "easl.sock"), Home: home, Resources: session.Resources(home)}
	t.Cleanup(f.router.CloseOwnedSockets)
	tile := idOf(f.result("object.create", terminal(map[string]any{"name": "task-finished"})))
	name := session.Prefix + tile
	t.Cleanup(func() {
		if _, err := m.End(tile, f.router.Owns.Labels(f.board.ID(), tile)); err != nil {
			t.Errorf("clean up real zmx session: %v", err)
		}
	})
	run := func(args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, zmx, args...)
		cmd.Dir = home
		cmd.Env = append(append([]string{}, m.Env...), "ZMX_DIR="+m.Dir)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("zmx %v: %v: %s", args, err, out)
		}
		return string(out)
	}
	run("run", name, "true")
	listed := run("list")
	fields := map[string]string{}
	for _, field := range strings.Fields(listed) {
		key, value, found := strings.Cut(field, "=")
		if found {
			fields[key] = value
		}
	}
	if fields["name"] != name || fields["ended"] == "" || fields["ended"] == "0" || fields["exit_code"] != "0" {
		t.Fatalf("zmx did not list the completed task in its live session: %s", listed)
	}
	pid, err := strconv.Atoi(fields["pid"])
	if err != nil || pid <= 0 {
		t.Fatalf("zmx listed no shell PID: %s", listed)
	}
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("shell %d did not survive task completion: %v", pid, err)
	}
	if got := f.result("board.stale", map[string]any{})["objects"]; !reflect.DeepEqual(got, []any{}) {
		t.Fatalf("completed task made a running shell stale: %v", got)
	}
	if ended, err := m.End(tile, f.router.Owns.Labels(f.board.ID(), tile)); err != nil || !ended {
		t.Fatalf("end owned session: ended %v, error %v", ended, err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		list, err := m.List()
		if err != nil {
			t.Fatal(err)
		}
		if len(list) == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("ended session is still listed: %+v", list)
		}
		time.Sleep(10 * time.Millisecond)
	}
	got := f.result("board.stale", map[string]any{})["objects"].([]any)
	if len(got) != 1 {
		t.Fatalf("ended shell missing from stale listing: %v", got)
	}
	entry := got[0].(map[string]any)
	if entry["id"] != tile || !reflect.DeepEqual(entry["reasons"], []any{"exited"}) {
		t.Fatalf("ended shell stale entry = %v", entry)
	}
}
