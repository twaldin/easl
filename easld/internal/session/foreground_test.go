package session

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A process table as /proc has it: each process's stat (its command name in parentheses, which
// may hold spaces and parentheses) and cmdline.
type process struct {
	pid, ppid, pgrp, tpgid int
	start                  uint64
	argv                   []string
}

func proc(t *testing.T, processes ...process) string {
	t.Helper()
	dir := t.TempDir()
	for _, p := range processes {
		pdir := filepath.Join(dir, fmt.Sprint(p.pid))
		if err := os.MkdirAll(pdir, 0o755); err != nil {
			t.Fatal(err)
		}
		// pid (comm) state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime
		// stime cutime cstime priority nice num_threads itrealvalue starttime …
		stat := fmt.Sprintf("%d (odd) name) S %d %d %d 34816 %d 4194560 1 0 0 0 0 0 0 0 20 0 1 0 %d 0\n", p.pid, p.ppid, p.pgrp, p.pgrp, p.tpgid, p.start)
		files := map[string]string{"stat": stat, "cmdline": strings.Join(p.argv, "\x00") + "\x00"}
		for name, data := range files {
			if err := os.WriteFile(filepath.Join(pdir, name), []byte(data), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "uptime"), []byte("1 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// The session's foreground process is the agent wherever the shell runs it: a job with its own
// group (an interactive shell's), the newest child of a shell running its command (`sh -l -c
// 'omp; exec sh -l'`, as an owned terminal starts), or the program the shell exec'd; none at the
// prompt or once the shell is gone.
func TestTheForegroundProcessIsTheAgentWhereverTheShellRunsIt(t *testing.T) {
	login := []string{"/bin/sh", "-l"}
	command := []string{"/bin/sh", "-l", "-c", "'omp'; exec '/bin/sh' -l"}
	for name, c := range map[string]struct {
		table []process
		want  int
	}{
		"a job":      {[]process{{pid: 10, ppid: 1, pgrp: 10, tpgid: 20, argv: login}, {pid: 20, ppid: 10, pgrp: 20, tpgid: 20, argv: []string{"omp"}}}, 20},
		"the prompt": {[]process{{pid: 10, ppid: 1, pgrp: 10, tpgid: 10, argv: []string{"-zsh"}}}, 0},
		"its command": {[]process{
			{pid: 10, ppid: 1, pgrp: 10, tpgid: 10, argv: command},
			{pid: 11, ppid: 10, pgrp: 10, tpgid: 10, start: 5, argv: []string{"git", "status"}},
			{pid: 12, ppid: 10, pgrp: 10, tpgid: 10, start: 9, argv: []string{"omp"}},
			{pid: 13, ppid: 12, pgrp: 10, tpgid: 10, start: 12, argv: []string{"node"}},
			{pid: 14, ppid: 10, pgrp: 14, tpgid: 10, start: 20, argv: []string{"sleep"}},
		}, 12},
		"its command, done":   {[]process{{pid: 10, ppid: 1, pgrp: 10, tpgid: 10, argv: command}}, 0},
		"a program it exec'd": {[]process{{pid: 10, ppid: 1, pgrp: 10, tpgid: 10, argv: []string{"/usr/bin/omp", "--resume=s1"}}}, 10},
		"no terminal":         {[]process{{pid: 10, ppid: 1, pgrp: 10, tpgid: -1, argv: login}}, 0},
		"gone":                {nil, 0},
	} {
		if got := foreground(proc(t, c.table...), 10); got != c.want {
			t.Errorf("%s: %d, want %d", name, got, c.want)
		}
	}
	if ForegroundPID(999999999) != 0 {
		t.Error("a pid no process has has a foreground process")
	}
}
