// Command easld serves easl's boards and API over a unix socket.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/relay"
	"github.com/twaldin/easl/easld/internal/router"
	"github.com/twaldin/easl/easld/internal/server"
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/store"
)

// orphanGrace is how long a session of easld's home must have been without its terminal (on a
// board that is open) before easld ends it (Router.SweepOrphans).
const orphanGrace = time.Minute

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
	os.Exit(run(os.Args[1:], os.Stderr))
}

// run is easld: it serves until SIGINT, SIGTERM or SIGHUP, then saves the boards and returns
// the exit status.
func run(args []string, stderr io.Writer) int {
	flags := flag.NewFlagSet("easld", flag.ContinueOnError)
	flags.SetOutput(stderr)
	home := flags.String("home", defaultHome(), "state directory; boards live in <home>/boards")
	// Not $EASL_SOCKET: every terminal tile of the app exports it, pointing at the app's socket.
	socket := flags.String("socket", "", "unix socket to serve (default <home>/easl.sock)")
	zmx := flags.String("zmx", "", "zmx binary for hosted terminals' sessions (default: zmx on PATH, else ~/.local/bin/zmx)")
	// Off by default: on a Mac the app runs its terminals, and an easld there must not compete.
	own := flags.Bool("own-terminals", false, "start and end the sessions of the terminals on its boards that have no props.host (a machine whose boards run wholly here)")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	path := *socket
	if path == "" {
		path = filepath.Join(*home, "easl.sock")
	}
	fail := func(err error) int {
		fmt.Fprintln(stderr, "easld:", err)
		return 1
	}
	// Taken before anything else: a signal from here on stops easld cleanly.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)

	if err := os.MkdirAll(*home, 0o700); err != nil {
		return fail(err)
	}
	lock, err := acquireInstanceLock(filepath.Join(*home, "instance.lock"))
	if err != nil {
		return fail(err)
	}
	defer lock.release()
	// Integrations spool undelivered reports in `agent-reports/` beside the socket.
	reg := board.NewRegistry(filepath.Join(*home, "boards"), store.DefaultDebounce, filepath.Join(filepath.Dir(path), "agent-reports"))
	r := router.New(reg)
	// Hosted and owned terminals' sessions keep their zmx sockets and logs in `<home>/zmx`, the
	// user's own.
	r.Sessions = session.New(session.Locate(*zmx), filepath.Join(*home, "zmx"))
	if r.Sessions.Zmx != "" {
		if err := r.Sessions.Secure(); err != nil {
			fmt.Fprintln(stderr, "easld: terminal sessions can't start:", err)
		}
	}
	// Owned terminals' sessions reach easld at its own socket, as absolute paths.
	if *own {
		socketPath, err := filepath.Abs(path)
		if err != nil {
			return fail(err)
		}
		homePath, err := filepath.Abs(*home)
		if err != nil {
			return fail(err)
		}
		r.Owns = &session.Owner{Socket: socketPath, Home: homePath, Resources: session.Resources(r.Sessions.Home)}
		r.Reopens = filepath.Join(*home, "open-boards.json")
	}
	// Hosted terminals reach their board through `<home>/run/<instance>/` (relay.open).
	r.Relays = relay.New(filepath.Join(*home, "run"))
	defer r.Relays.Close()
	// The boards it owned reopen before it serves, their missing sessions starting again (after a
	// reboot) meanwhile.
	for _, err := range r.Restore() {
		fmt.Fprintln(stderr, "easld:", err)
	}
	srv, err := server.Listen(path, r.Handle, r.Answer)
	if err != nil {
		return fail(err)
	}
	owns := ""
	if r.Owns != nil {
		owns = "; it starts and ends their terminals"
		// A session of easld's home left without its terminal ends after orphanGrace.
		stopped := make(chan struct{})
		defer close(stopped)
		go func() {
			for {
				r.SweepOrphans()
				select {
				case <-stopped:
					return
				case <-time.After(orphanGrace):
				}
			}
		}()
	}
	fmt.Fprintf(stderr, "easld: serving %s (boards in %s%s)\n", path, filepath.Join(*home, "boards"), owns)
	<-signals
	// Close stops accepting, lets the requests already read finish and unlinks the socket (only
	// if it is still ours); the boards are saved after that, with nothing left changing them.
	srv.Close()
	reg.Flush()
	return 0
}
