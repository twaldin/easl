// Package session runs terminal tiles' zmx sessions on easld's machine (session.spawn, .list,
// .kill): a hosted terminal's session is easld's own child, so it and everything it runs stay
// in easld's cgroup (on Linux, the systemd unit's slice and its CPU and memory caps), however
// the client that shows it attaches (docs/contracts.md "Hosted terminals").
package session

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Prefix names every terminal tile's session: `canvas-<tile>`.
const Prefix = "canvas-"

// HomeLabel is the label naming the instance a session belongs to (TerminalTile.homeLabel).
const HomeLabel = "canvas.home"

// OwnerLabels say whose a session is: the instance (a board copied into another home has the
// same board and tile ids), the board and the tile. A session whose labels aren't the caller's is
// never taken over or ended.
var OwnerLabels = []string{HomeLabel, "canvas.board", "canvas.tile"}

// Error is a failure with its API code.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Message }

func failure(code, format string, args ...any) error {
	return &Error{code, fmt.Sprintf(format, args...)}
}

// Session is one `canvas-…` session as zmx lists it.
type Session struct {
	Name        string
	Tile        string
	PID         int
	Clients     int
	Labels      map[string]string
	Unreachable bool
}

// Manager runs zmx. The zero Zmx means zmx isn't installed: every call is `unavailable`.
type Manager struct {
	Zmx string
	// Dir is the sessions' zmx directory (`ZMX_DIR`: their sockets, and zmx's logs in `logs/`),
	// the user's own (`Secure`): never a shared one such as zmx's default /tmp/zmx-<uid>, which
	// another user of the machine could make first and plant a symlink in that zmx would write
	// through.
	Dir string
	// Shell is the user's login shell (`$SHELL`, else /bin/sh); Home the default directory.
	Shell string
	Home  string
	// Env is the environment sessions start from (easld's own); Spawn's `env` goes over it.
	Env []string
	// Timeout bounds each zmx call.
	Timeout time.Duration

	// mu serializes spawn and kill, so two spawns of one tile can't both create its session.
	mu sync.Mutex
}

// New is a manager for the zmx at `zmx` ("" when there is none) with easld's environment, its
// sessions in `dir` (easld's `<home>/zmx`, which the tiles' ssh commands name too:
// HostedTerminal.zmxDir).
func New(zmx, dir string) *Manager {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	home, _ := os.UserHomeDir()
	return &Manager{Zmx: zmx, Dir: dir, Shell: shell, Home: home, Env: os.Environ(), Timeout: 15 * time.Second}
}

// Secure makes Dir ready for zmx: created for the user only when it is missing. A symlink, a
// directory another user owns, or one others can write to is refused (`unavailable`): what
// they could have put in it (a `logs/zmx.log` symlink to one of the user's files) zmx would
// follow. One that others can only read is closed to them (0700).
func (m *Manager) Secure() error {
	if err := os.MkdirAll(m.Dir, 0o700); err != nil {
		return failure("unavailable", "can't make zmx's directory %s: %v", m.Dir, err)
	}
	return secure(m.Dir, os.Getuid())
}

// secure checks that `dir` is a directory of user `uid`'s that nobody else can write to, and
// closes it to them.
func secure(dir string, uid int) error {
	info, err := os.Lstat(dir)
	if err != nil {
		return failure("unavailable", "zmx's directory %s: %v", dir, err)
	}
	if !info.IsDir() {
		return failure("unavailable", "zmx's directory %s is not a directory (%v): easld runs no session there", dir, info.Mode().Type())
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != uid {
		owner := "unknown"
		if ok {
			owner = strconv.Itoa(int(stat.Uid))
		}
		return failure("unavailable", "zmx's directory %s belongs to uid %s, not this user (%d): easld runs no session there", dir, owner, uid)
	}
	if perm := info.Mode().Perm(); perm&0o022 != 0 {
		return failure("unavailable", "others can write to zmx's directory %s (%04o): easld runs no session there; check what is in it, then chmod 700 it", dir, perm)
	} else if perm&0o077 != 0 {
		if err := os.Chmod(dir, 0o700); err != nil {
			return failure("unavailable", "can't close zmx's directory %s to others: %v", dir, err)
		}
	}
	return nil
}

// Locate finds zmx: `explicit` when given, else on PATH, else ~/.local/bin/zmx (where
// scripts/offload-setup.sh installs it); "" when there is none.
func Locate(explicit string) string {
	if explicit != "" {
		return explicit
	}
	if path, err := exec.LookPath("zmx"); err == nil {
		return path
	}
	if home, err := os.UserHomeDir(); err == nil {
		local := filepath.Join(home, ".local", "bin", "zmx")
		if info, err := os.Stat(local); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return local
		}
	}
	return ""
}

var (
	tilePattern  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	labelPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	envPattern   = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
)

// ready says why zmx can't run: it isn't installed, or its directory isn't safe.
func (m *Manager) ready() error {
	if m == nil || m.Zmx == "" {
		return failure("unavailable", "zmx isn't installed on this machine (scripts/offload-setup.sh installs it in ~/.local/bin; or start easld with --zmx <path>)")
	}
	return m.Secure()
}

func checkTile(tile string) error {
	if !tilePattern.MatchString(tile) {
		return failure("invalid_params", "tile must be an object id ([A-Za-z0-9_-], at most 64 characters), got %q", tile)
	}
	return nil
}

// SpawnRequest is session.spawn's params.
type SpawnRequest struct {
	Tile    string
	Command []string
	Cwd     string
	Env     map[string]string
	Labels  map[string]string
	// Unset are name prefixes of easld's own environment (Manager.Env) the session doesn't
	// inherit: an owned terminal's (Owner.Request). session.spawn sets none.
	Unset []string
}

// Spawn starts the tile's session unless it runs already (created false). A session whose
// owner labels (OwnerLabels) aren't those of `Labels` is `conflict`; one that doesn't answer is
// left to come back (created false: its daemon may be busy), and the client's attach checks its
// owner once it does.
func (m *Manager) Spawn(req SpawnRequest) (session string, created bool, err error) {
	if err := m.ready(); err != nil {
		return "", false, err
	}
	if err := checkTile(req.Tile); err != nil {
		return "", false, err
	}
	labels, err := labelArg(req.Labels)
	if err != nil {
		return "", false, err
	}
	for key, value := range req.Env {
		if !envPattern.MatchString(key) || strings.ContainsRune(value, 0) {
			return "", false, failure("invalid_params", "env %q: names are [A-Za-z_][A-Za-z0-9_]* and values hold no NUL", key)
		}
	}
	cwd := req.Cwd
	if cwd == "" {
		cwd = m.Home
	}
	if info, err := os.Stat(cwd); err != nil || !info.IsDir() {
		host, _ := os.Hostname()
		return "", false, failure("invalid_params", "cwd %s is not a directory on %s", cwd, host)
	}
	name := Prefix + req.Tile
	m.mu.Lock()
	defer m.mu.Unlock()
	existing, err := m.find(name)
	if err != nil {
		return "", false, err
	}
	if existing != nil {
		if !existing.Unreachable {
			if err := owned(existing, req.Labels); err != nil {
				return "", false, err
			}
		}
		return name, false, nil
	}
	// `zmx attach` with no terminal on stdin creates the session (its daemon detaches from
	// easld, staying in its cgroup) and returns at once.
	args := []string{"attach"}
	if labels != "" {
		args = append(args, "--labels", labels)
	}
	args = append(append(args, name), m.loginCommand(req.Command)...)
	if out, err := m.run(cwd, environ(m.Env, req.Env, req.Unset), args...); err != nil {
		return "", false, failure("unavailable", "zmx couldn't start %s: %s", name, describe(err, out))
	}
	// The daemon lists the session once its socket is up.
	deadline := time.Now().Add(2 * time.Second)
	for {
		if found, err := m.find(name); err == nil && found != nil {
			return name, true, nil
		}
		if time.Now().After(deadline) {
			return "", false, failure("unavailable", "zmx started %s but doesn't list it", name)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// loginCommand is what the session runs: `command` in the login shell, then the login shell,
// as a terminal tile on the Mac does (TerminalTile.command).
func (m *Manager) loginCommand(command []string) []string {
	if len(command) == 0 {
		return []string{m.Shell, "-l"}
	}
	return []string{m.Shell, "-l", "-c", Quote(command) + "; exec " + Quote([]string{m.Shell}) + " -l"}
}

// List is every `canvas-…` session zmx has.
func (m *Manager) List() ([]Session, error) {
	if err := m.ready(); err != nil {
		return nil, err
	}
	out, err := m.run("", m.Env, "list")
	if err != nil {
		return nil, failure("unavailable", "zmx list failed: %s", describe(err, out))
	}
	return Parse(string(out)), nil
}

// Kill ends the tile's session and deletes zmx's log of it; false when there was none. When
// `home` is given, a session not labelled with it is `conflict` (one that doesn't answer can't
// say whose it is: `unavailable`).
func (m *Manager) Kill(tile, home string) (bool, error) {
	var want map[string]string
	if home != "" {
		want = map[string]string{HomeLabel: home}
	}
	return m.kill(tile, want, false)
}

// End is Kill for a terminal gone for good (an owned terminal's delete), of the session that
// carries every owner label `labels` names (OwnerLabels: in one home, a board copied to another
// root keeps its tile ids, so the home alone doesn't say whose it is). When its session is no
// longer there (it exited, or zmx found its daemon dead), zmx's log of it goes too.
func (m *Manager) End(tile string, labels map[string]string) (bool, error) {
	return m.kill(tile, labels, true)
}

func (m *Manager) kill(tile string, want map[string]string, gone bool) (bool, error) {
	if err := m.ready(); err != nil {
		return false, err
	}
	if err := checkTile(tile); err != nil {
		return false, err
	}
	name := Prefix + tile
	m.mu.Lock()
	defer m.mu.Unlock()
	existing, err := m.find(name)
	if err != nil {
		return false, err
	}
	if existing == nil {
		if gone {
			m.removeLog(name)
		}
		return false, nil
	}
	if len(want) > 0 {
		if existing.Unreachable {
			return false, failure("unavailable", "session %s doesn't answer, so whose it is can't be told; not ending it", name)
		}
		if err := owned(existing, want); err != nil {
			return false, err
		}
	}
	if out, err := m.run("", m.Env, "kill", name); err != nil {
		return false, failure("unavailable", "zmx couldn't end %s: %s", name, describe(err, out))
	}
	m.removeLog(name)
	return true, nil
}

// removeLog deletes zmx's log of session `name`, which zmx keeps forever.
func (m *Manager) removeLog(name string) {
	if dir := m.logDir(); dir != "" {
		_ = os.Remove(filepath.Join(dir, name+".log"))
	}
}

func (m *Manager) find(name string) (*Session, error) {
	list, err := m.List()
	if err != nil {
		return nil, err
	}
	for i := range list {
		if list[i].Name == name {
			return &list[i], nil
		}
	}
	return nil, nil
}

// owned is nil when `s` carries every owner label `want` names, with the same value.
func owned(s *Session, want map[string]string) error {
	for _, key := range OwnerLabels {
		expected, given := want[key]
		if !given || s.Labels[key] == expected {
			continue
		}
		have := s.Labels[key]
		if have == "" {
			have = "none"
		}
		return failure("conflict", "session %s belongs to another easl instance or board (its %s is %s, not %s)", s.Name, key, have, expected)
	}
	return nil
}

// logDir is zmx's log directory (`zmx version`'s `log_dir`); "" when it doesn't say.
func (m *Manager) logDir() string {
	out, err := m.run("", m.Env, "version")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		if key, value, ok := strings.Cut(line, "\t"); ok && key == "log_dir" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// run runs zmx with `env`, its directory always Dir, whatever `env` says (a spawn's `env` must
// not point zmx elsewhere).
func (m *Manager) run(dir string, env []string, args ...string) ([]byte, error) {
	timeout := m.Timeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, m.Zmx, args...)
	cmd.Dir = dir
	// The last of a duplicated variable wins (exec.Cmd.Env).
	cmd.Env = append(env[:len(env):len(env)], "ZMX_DIR="+m.Dir)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	// The session's daemon inherits zmx's stdout and stderr: waiting for EOF on them would wait
	// for the session to end.
	cmd.WaitDelay = time.Second
	err := cmd.Run()
	if errors.Is(err, exec.ErrWaitDelay) {
		err = nil
	}
	return out.Bytes(), err
}

func describe(err error, out []byte) string {
	if text := strings.TrimSpace(string(out)); text != "" {
		return text
	}
	return err.Error()
}

// builtin are the fields `zmx list` prints of every session; the rest are its labels.
var builtin = map[string]bool{"name": true, "pid": true, "clients": true, "created": true, "cwd": true, "cmd": true, "ended": true, "exit_code": true, "err": true, "status": true, "start_dir": true}

// Parse reads `zmx list` (a line per session, tab-separated `key=value` fields, the current one
// marked `→`), keeping the `canvas-…` sessions, by name. A session zmx found dead (its socket
// refused) is gone: zmx deleted its socket while listing it (`status=cleaning up`). One that
// didn't answer in time stays, unreachable: its daemon may only be busy.
func Parse(output string) []Session {
	var sessions []Session
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Split(strings.TrimLeft(line, " *→"), "\t")
		name, ok := strings.CutPrefix(fields[0], "name=")
		if !ok || !strings.HasPrefix(name, Prefix) {
			continue
		}
		s := Session{Name: name, Tile: strings.TrimPrefix(name, Prefix), Labels: map[string]string{}}
		gone := false
		for _, field := range fields[1:] {
			key, value, _ := strings.Cut(field, "=")
			switch {
			case key == "pid":
				s.PID, _ = strconv.Atoi(value)
			case key == "clients":
				s.Clients, _ = strconv.Atoi(value)
			case key == "status" && value == "cleaning up":
				gone = true
			case key == "err" || (key == "status" && value == "unreachable"):
				s.Unreachable = true
			case !builtin[key] && key != "":
				s.Labels[key] = value
			}
		}
		if !gone {
			sessions = append(sessions, s)
		}
	}
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].Name < sessions[j].Name })
	return sessions
}

// labelArg is `zmx attach --labels`'s value: `k=v` pairs by key.
func labelArg(labels map[string]string) (string, error) {
	keys := make([]string, 0, len(labels))
	for key, value := range labels {
		if !labelPattern.MatchString(key) || !labelPattern.MatchString(value) {
			return "", failure("invalid_params", "label %s=%s: keys and values are [A-Za-z0-9._-]", key, value)
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([]string, len(keys))
	for i, key := range keys {
		pairs[i] = key + "=" + labels[key]
	}
	return strings.Join(pairs, " "), nil
}

// environ is `base` without the names starting with an `unset` prefix, with `extra` set over it,
// except that `extra`'s PATH goes before base's: a hosted tile puts easl's bin first, as the
// Mac's tiles do before the app's PATH.
func environ(base []string, extra map[string]string, unset []string) []string {
	out := make([]string, 0, len(base)+len(extra))
	basePath := ""
	for _, kv := range base {
		key, value, _ := strings.Cut(kv, "=")
		if key == "PATH" {
			basePath = value
		}
		if _, replaced := extra[key]; !replaced && !slices.ContainsFunc(unset, func(prefix string) bool { return strings.HasPrefix(key, prefix) }) {
			out = append(out, kv)
		}
	}
	keys := make([]string, 0, len(extra))
	for key := range extra {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		value := extra[key]
		if key == "PATH" && basePath != "" && value != "" {
			value += ":" + basePath
		}
		out = append(out, key+"="+value)
	}
	return out
}

// Quote is argv as one POSIX shell word list (ShellWords.quote).
func Quote(argv []string) string {
	words := make([]string, len(argv))
	for i, arg := range argv {
		words[i] = "'" + strings.ReplaceAll(arg, "'", `'"'"'`) + "'"
	}
	return strings.Join(words, " ")
}
