package session

import (
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// ForegroundPID is the leader of the foreground job of the session whose shell is `shell` (zmx
// list's pid; ForegroundProgram.foregroundPid): the agent when one runs in it; 0 at the shell's
// prompt, when the shell is gone, and where there is no /proc (macOS, where the app reads its
// own sessions).
func ForegroundPID(shell int) int { return foreground("/proc", shell) }

// foreground is ForegroundPID over the process table at `proc`. The terminal's foreground
// process group is the shell's own while it waits at its prompt, runs a command it was given
// with -c (without job control, its children stay in its group: the newest is the command), or
// exec'd a program (no longer a shell); else it is a job's, whose leader it names.
func foreground(proc string, shell int) int {
	st, ok := readStat(proc, shell)
	if !ok || st.tpgid <= 0 {
		return 0
	}
	if st.tpgid != shell {
		return st.tpgid
	}
	argv := readCmdline(proc, shell)
	if len(argv) > 0 && !isShell(argv[0]) {
		return shell
	}
	if !slices.Contains(argv, "-c") {
		return 0
	}
	entries, err := os.ReadDir(proc)
	if err != nil {
		return 0
	}
	newest, started := 0, uint64(0)
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == shell {
			continue
		}
		if child, ok := readStat(proc, pid); ok && child.ppid == shell && child.pgrp == shell && (newest == 0 || child.start > started) {
			newest, started = pid, child.start
		}
	}
	return newest
}

// stat is what foreground reads of /proc/<pid>/stat.
type stat struct {
	ppid, pgrp, tpgid int
	start             uint64
}

// readStat reads /proc/<pid>/stat: its fields after the command name (in parentheses, which
// may hold spaces and parentheses itself) are state, ppid, pgrp, session, tty_nr, tpgid, …,
// with starttime the 22nd field of the line.
func readStat(proc string, pid int) (stat, bool) {
	data, err := os.ReadFile(filepath.Join(proc, strconv.Itoa(pid), "stat"))
	if err != nil {
		return stat{}, false
	}
	end := strings.LastIndexByte(string(data), ')')
	if end < 0 {
		return stat{}, false
	}
	fields := strings.Fields(string(data[end+1:]))
	if len(fields) < 20 {
		return stat{}, false
	}
	ppid, err1 := strconv.Atoi(fields[1])
	pgrp, err2 := strconv.Atoi(fields[2])
	tpgid, err3 := strconv.Atoi(fields[5])
	start, err4 := strconv.ParseUint(fields[19], 10, 64)
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
		return stat{}, false
	}
	return stat{ppid: ppid, pgrp: pgrp, tpgid: tpgid, start: start}, true
}

// readCmdline is /proc/<pid>/cmdline's arguments.
func readCmdline(proc string, pid int) []string {
	data, err := os.ReadFile(filepath.Join(proc, strconv.Itoa(pid), "cmdline"))
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
}

// shells are the programs a terminal's shell can be (SessionProcesses.shells).
var shells = words("sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "login")

// isShell is whether argv0 runs a shell (SessionProcesses.isShell): by its last path component,
// a login shell's leading `-` dropped.
func isShell(argv0 string) bool {
	return shells[strings.TrimPrefix(filepath.Base(argv0), "-")]
}
