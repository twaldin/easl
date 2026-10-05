package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// instanceLock is InstanceLock.swift: an exclusive flock on `<home>/instance.lock`, held for
// the life of the process (the kernel drops it when the process ends, even after a crash), with
// the holder's pid written in the file. The app takes the same lock on its support directory,
// so easld and the app, or two easlds, never run on one home: the second would take over the
// first's socket, and both would write the same board files.
type instanceLock struct{ file *os.File }

// lockHeld is the error when another process holds the lock.
type lockHeld struct {
	path string
	pid  int // 0 when the holder hasn't written it
}

func (e *lockHeld) Error() string {
	holder := "another process"
	if e.pid > 0 {
		holder = "pid " + strconv.Itoa(e.pid)
	}
	return fmt.Sprintf("%s is in use: %s (easl or easld) holds %s; stop it, or give easld its own --home", filepath.Dir(e.path), holder, e.path)
}

// acquireInstanceLock takes the lock at path (opened 0600, close-on-exec, as the app opens it)
// and records this process's pid in it; a *lockHeld error names the holder when it is taken.
func acquireInstanceLock(path string) (*instanceLock, error) {
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600) // Go opens every file O_CLOEXEC
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, &lockHeld{path: path, pid: lockHolder(path)}
		}
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := file.Truncate(0); err == nil {
		file.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0)
	}
	return &instanceLock{file}, nil
}

// lockHolder is the pid the holder recorded (InstanceLock.holder), 0 if none yet.
func lockHolder(path string) int {
	data, _ := os.ReadFile(path)
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return pid
}

func (l *instanceLock) release() {
	syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	l.file.Close()
}
