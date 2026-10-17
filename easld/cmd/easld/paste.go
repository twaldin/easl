package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// TerminalPaste.script uses this same root and seven-day modification-time policy.
const pasteRetention = 7 * 24 * time.Hour
const pasteSweepInterval = time.Hour

func startPasteMaintenance(home string, interval time.Duration, log io.Writer) func() {
	sweep := func() {
		if err := sweepPasteImages(home, time.Now()); err != nil {
			fmt.Fprintln(log, "easld: terminal image expiration:", err)
		}
	}
	sweep()
	ticker := time.NewTicker(interval)
	stopped, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-stopped:
				return
			case <-ticker.C:
				sweep()
			}
		}
	}()
	var once sync.Once
	return func() {
		once.Do(func() {
			ticker.Stop()
			close(stopped)
			<-done
		})
	}
}

func sweepPasteImages(home string, now time.Time) error {
	path := filepath.Join(home, "easl-paste-"+strconv.Itoa(os.Getuid()))
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !privatePasteDirectory(info) {
		return fmt.Errorf("unsafe staging root %s", path)
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return err
	}
	defer root.Close()
	opened, err := root.Stat(".")
	if err != nil {
		return err
	}
	if !os.SameFile(info, opened) {
		return fmt.Errorf("staging root changed while opening %s", path)
	}
	return sweepPasteDirectory(root, root.FS(), ".", 0, now.Add(-pasteRetention))
}

func privatePasteDirectory(info fs.FileInfo) bool {
	owner, ok := info.Sys().(*syscall.Stat_t)
	return info.IsDir() && info.Mode().Perm()&0o077 == 0 && ok && int(owner.Uid) == os.Getuid()
}

func sweepPasteDirectory(root *os.Root, tree fs.FS, path string, depth int, cutoff time.Time) error {
	entries, err := fs.ReadDir(tree, path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var failures error
	for _, entry := range entries {
		name := filepath.Join(path, entry.Name())
		info, err := root.Lstat(name)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			failures = errors.Join(failures, err)
			continue
		}
		if depth < 2 && privatePasteDirectory(info) {
			failures = errors.Join(failures, sweepPasteDirectory(root, tree, name, depth+1, cutoff))
		} else if depth == 2 && info.Mode().IsRegular() && !info.ModTime().After(cutoff) {
			if err := root.Remove(name); err != nil && !errors.Is(err, fs.ErrNotExist) {
				failures = errors.Join(failures, err)
			}
		}
	}
	return failures
}
