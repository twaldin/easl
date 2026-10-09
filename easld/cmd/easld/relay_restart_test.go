package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/relay"
)

const relayToken = "0123456789abcdef0123456789abcdef"

func relayGate(t *testing.T) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
				reader := bufio.NewReader(conn)
				hello, err := reader.ReadString('\n')
				if err != nil {
					return
				}
				name, nonce, _ := strings.Cut(strings.TrimSuffix(hello, "\n"), " ")
				const mine = "ffeeddccbbaa99887766554433221100"
				fmt.Fprintf(conn, "%s %s\n", mine, relay.Proof(relayToken, "gate", name, nonce, mine))
				proof, _ := reader.ReadString('\n')
				if strings.TrimSuffix(proof, "\n") != relay.Proof(relayToken, "easld", name, nonce, mine) {
					return
				}
				_, _ = io.Copy(conn, reader)
			}()
		}
	}()
	return listener
}

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
	gate := relayGate(t)
	params := map[string]any{"instance": "mac-1", "port": gate.Addr().(*net.TCPAddr).Port, "token": relayToken}
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
}
