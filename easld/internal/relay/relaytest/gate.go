// Package relaytest provides the authenticated client end of a relay for behavior tests.
package relaytest

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// Gate echoes connections after mutual relay authentication. Names and Wire record
// observations without blocking connections; observations beyond their buffers are dropped.
type Gate struct {
	net.Listener
	Names chan string
	Wire  chan string
}

// New starts a gate holding token and closes its listener when t finishes.
func New(t testing.TB, token string) *Gate {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	gate := &Gate{Listener: listener, Names: make(chan string, 8), Wire: make(chan string, 8)}
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
				fmt.Fprintf(conn, "%s %s\n", mine, proof(token, "gate", name, nonce, mine))
				answer, _ := reader.ReadString('\n')
				select {
				case gate.Wire <- hello + answer:
				default:
				}
				if strings.TrimSuffix(answer, "\n") != proof(token, "easld", name, nonce, mine) {
					return
				}
				select {
				case gate.Names <- name:
				default:
				}
				_, _ = io.Copy(conn, reader)
			}()
		}
	}()
	return gate
}

func (g *Gate) Port() int { return g.Addr().(*net.TCPAddr).Port }

func proof(token, role, name, easld, gate string) string {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("easl-relay " + role + " " + name + " " + easld + " " + gate))
	return hex.EncodeToString(mac.Sum(nil))
}
