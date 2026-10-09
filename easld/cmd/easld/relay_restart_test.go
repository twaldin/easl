package main

import (
	"bufio"
	"errors"
	"io"
	"net"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/relay"
	"github.com/twaldin/easl/easld/internal/relay/relaytest"
)

const relayToken = "0123456789abcdef0123456789abcdef"

func relayReply(t *testing.T, path string) {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("hosted socket: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(time.Second))
	const report = "{\"method\":\"agent.report\",\"params\":{\"state\":\"idle\"}}\n"
	if _, err := io.WriteString(conn, report); err != nil {
		t.Fatal(err)
	}
	reply, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil || reply != report {
		t.Fatalf("hosted reply %q: %v", reply, err)
	}
}

func TestHostedRelayAnswersAfterEasldRestarts(t *testing.T) {
	dir := shortDir(t)
	home, socket := filepath.Join(dir, "home"), filepath.Join(dir, "easld.sock")
	gate := relaytest.New(t, relayToken)
	params := map[string]any{"instance": "mac-1", "port": gate.Port(), "token": relayToken}
	done, stderr := start(t, "--home", home, "--socket", socket)
	c := connect(t, socket, stderr)
	paths := c.call(t, "relay.open", params)
	for _, name := range relay.Sockets {
		relayReply(t, paths[name].(string))
	}
	if code := stop(t, done, syscall.SIGTERM); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}

	done, stderr = start(t, "--home", home, "--socket", socket)
	defer func() {
		if code := stop(t, done, syscall.SIGTERM); code != 0 {
			t.Errorf("exit %d: %s", code, stderr.String())
		}
	}()
	c = connect(t, socket, stderr)
	c.call(t, "system.ping", nil)
	ready := time.Now()
	for _, name := range relay.Sockets {
		relayReply(t, paths[name].(string))
	}
	if elapsed := time.Since(ready); elapsed > time.Second {
		t.Fatalf("hosted sockets answered %v after easld was ready", elapsed)
	}
	t.Log("both hosted sockets answered within 1 s of easld, without another relay.open")
	if opened := c.call(t, "relay.open", params)["opened"]; opened != true {
		t.Fatalf("first keepalive after restart must fetch spooled reports: opened=%v", opened)
	}
	if opened := c.call(t, "relay.open", params)["opened"]; opened != false {
		t.Fatalf("next keepalive must be a no-op: opened=%v", opened)
	}
}

func TestHostedRelayClosesClientsIfTheMacLeftDuringRestart(t *testing.T) {
	dir := shortDir(t)
	home, socket := filepath.Join(dir, "home"), filepath.Join(dir, "easld.sock")
	gate := relaytest.New(t, relayToken)
	params := map[string]any{"instance": "mac-1", "port": gate.Port(), "token": relayToken}
	done, stderr := start(t, "--home", home, "--socket", socket)
	c := connect(t, socket, stderr)
	paths := c.call(t, "relay.open", params)
	relayReply(t, paths["easl"].(string))
	if code := stop(t, done, syscall.SIGTERM); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	gate.Close()

	done, stderr = start(t, "--home", home, "--socket", socket)
	defer func() {
		if code := stop(t, done, syscall.SIGTERM); code != 0 {
			t.Errorf("exit %d: %s", code, stderr.String())
		}
	}()
	c = connect(t, socket, stderr)
	c.call(t, "system.ping", nil)
	for _, name := range relay.Sockets {
		conn, err := net.Dial("unix", paths[name].(string))
		if err != nil {
			t.Fatalf("restored %s socket: %v", name, err)
		}
		_ = conn.SetDeadline(time.Now().Add(time.Second))
		var reply [1]byte
		n, err := conn.Read(reply[:])
		conn.Close()
		if n != 0 || !(errors.Is(err, io.EOF) || errors.Is(err, syscall.ECONNRESET)) {
			t.Fatalf("%s socket must close instead of blocking: %d bytes, %v", name, n, err)
		}
	}
	t.Log("restored sockets closed clients within 1 s when the Mac's forward was gone")
	fresh := relaytest.New(t, relayToken)
	params["port"] = fresh.Port()
	if opened := c.call(t, "relay.open", params)["opened"]; opened != true {
		t.Fatalf("re-arming must fetch spooled reports: opened=%v", opened)
	}
	relayReply(t, paths["easl"].(string))
}
