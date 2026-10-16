package session

import (
	"bytes"
	"context"
	"io"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestSpawnFirstAttachRestoresBracketedPaste(t *testing.T) {
	zmx := Locate("")
	if zmx == "" {
		t.Skip("real zmx is not installed; the file-backed zmxtest fixture cannot retain terminal modes")
	}
	home := t.TempDir()
	m := &Manager{Zmx: zmx, Dir: filepath.Join(home, "zmx"), Shell: "/bin/sh", Home: home,
		Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin", "TERM=xterm-256color", "ZMX_TRACK_ENV="}}
	const tile = "first_view"
	t.Cleanup(func() {
		if _, err := m.run("", m.Env, "kill", Prefix+tile, "--force"); err != nil {
			t.Errorf("clean up real zmx session: %v", err)
		}
	})
	name, created, err := m.Spawn(SpawnRequest{Tile: tile,
		Command: []string{"/bin/sh", "-c", "printf '\033[?2004h'; exec sleep 60"}})
	if err != nil || !created {
		t.Fatalf("spawn: created %v, error %v", created, err)
	}
	mode := []byte("\x1b[?2004h")
	deadline := time.Now().Add(5 * time.Second)
	for {
		out, err := m.run("", m.Env, "history", name, "--vt")
		if err != nil {
			t.Fatalf("read retained screen: %v: %s", err, out)
		}
		if bytes.Contains(out, mode) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("program did not enable bracketed paste before first attach: %q", out)
		}
		time.Sleep(10 * time.Millisecond)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, zmx, "attach", name)
	cmd.Env = append(m.Env, "ZMX_DIR="+m.Dir)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = stdin.Close()
		cancel()
		_ = cmd.Wait()
	}()
	var output bytes.Buffer
	buf := make([]byte, 4096)
	for !bytes.Contains(output.Bytes(), mode) {
		n, err := stdout.Read(buf)
		output.Write(buf[:n])
		if err != nil {
			if err != io.EOF {
				t.Logf("attach read: %v", err)
			}
			t.Fatalf("first attach did not restore bracketed paste: output %q, stderr %q", output.Bytes(), stderr.String())
		}
	}
	t.Logf("first attach restored bracketed paste: %q", output.Bytes())
}
