// Command easld serves easl's boards and API over a unix socket.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/router"
	"github.com/twaldin/easl/easld/internal/server"
	"github.com/twaldin/easl/easld/internal/store"
)

// defaultHome is $EASL_HOME, else the platform's per-user state directory.
func defaultHome() string {
	if home := os.Getenv("EASL_HOME"); home != "" {
		return home
	}
	user, _ := os.UserHomeDir()
	if runtime.GOOS == "darwin" {
		return filepath.Join(user, "Library", "Application Support", "Easl")
	}
	if state := os.Getenv("XDG_STATE_HOME"); state != "" {
		return filepath.Join(state, "easl")
	}
	return filepath.Join(user, ".local", "state", "easl")
}

func main() {
	home := flag.String("home", defaultHome(), "state directory; boards live in <home>/boards")
	socket := flag.String("socket", "", "unix socket to serve (default $EASL_SOCKET, else <home>/easl.sock)")
	flag.Parse()
	path := *socket
	if path == "" {
		path = os.Getenv("EASL_SOCKET")
	}
	if path == "" {
		path = filepath.Join(*home, "easl.sock")
	}
	if err := os.MkdirAll(*home, 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "easld:", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "easld:", err)
		os.Exit(1)
	}
	// Integrations spool undelivered reports in `agent-reports/` beside the socket.
	reg := board.NewRegistry(filepath.Join(*home, "boards"), store.DefaultDebounce, filepath.Join(filepath.Dir(path), "agent-reports"))
	r := router.New(reg)
	srv, err := server.Listen(path, r.Handle)
	if err != nil {
		fmt.Fprintln(os.Stderr, "easld:", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "easld: serving %s (boards in %s)\n", path, filepath.Join(*home, "boards"))
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	<-signals
	// Close stops accepting, lets the requests already read finish and unlinks the socket (only
	// if it is still ours); the boards are saved after that, with nothing left changing them.
	srv.Close()
	reg.Flush()
}
