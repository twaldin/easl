package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func pasteFile(t *testing.T, home, instance, session, name string, modified time.Time) string {
	t.Helper()
	path := filepath.Join(home, fmt.Sprintf("easl-paste-%d", os.Getuid()), instance, session, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(name), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
	return path
}

func expectPasteFile(t *testing.T, path, content string) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil || string(got) != content {
		t.Fatalf("%s = %q, %v; want %q", path, got, err, content)
	}
}

func expectPasteGone(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("%s still exists: %v", path, err)
	}
}

func TestPasteSweepExpiresOnlySevenDayFilesInItsHome(t *testing.T) {
	home, other := t.TempDir(), t.TempDir()
	now := time.Now()
	cutoff := now.Add(-7 * 24 * time.Hour)
	expired := pasteFile(t, home, "mac-a", "canvas-old", "expired.png", cutoff)
	older := pasteFile(t, home, "mac-b", "canvas-old", "older.png", cutoff.Add(-time.Hour))
	kept := pasteFile(t, home, "mac-b", "canvas-live", "kept.png", cutoff.Add(time.Second))
	fresh := pasteFile(t, home, "mac-a", "canvas-live", "fresh.png", now)
	foreign := pasteFile(t, other, "mac-a", "canvas-old", "foreign.png", cutoff.Add(-time.Hour))
	if err := sweepPasteImages(home, now); err != nil {
		t.Fatal(err)
	}
	expectPasteGone(t, expired)
	expectPasteGone(t, older)
	expectPasteFile(t, kept, "kept.png")
	expectPasteFile(t, fresh, "fresh.png")
	expectPasteFile(t, foreign, "foreign.png")
	if err := sweepPasteImages(home, now); err != nil {
		t.Fatal(err)
	}
	expectPasteFile(t, kept, "kept.png")
}

func TestPasteSweepDoesNotFollowRootInstanceSessionOrFileSymlinks(t *testing.T) {
	for level := range 4 {
		t.Run(fmt.Sprint(level), func(t *testing.T) {
			home, outside := t.TempDir(), t.TempDir()
			now := time.Now()
			suffix := []string{"mac-a/canvas-link/private.png", "canvas-link/private.png", "private.png", "private.png"}[level]
			kept := filepath.Join(outside, suffix)
			if err := os.MkdirAll(filepath.Dir(kept), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(kept, []byte("outside"), 0o600); err != nil {
				t.Fatal(err)
			}
			old := now.Add(-8 * 24 * time.Hour)
			if err := os.Chtimes(kept, old, old); err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(home, fmt.Sprintf("easl-paste-%d", os.Getuid()))
			instance := filepath.Join(root, "mac-a")
			session := filepath.Join(instance, "canvas-link")
			link := []string{root, instance, session, filepath.Join(session, "linked.png")}[level]
			if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
				t.Fatal(err)
			}
			target := outside
			if level == 3 {
				target = kept
			}
			if err := os.Symlink(target, link); err != nil {
				t.Fatal(err)
			}
			err := sweepPasteImages(home, now)
			if (level == 0) != (err != nil) {
				t.Fatalf("root symlink must be refused, other symlinks skipped: %v", err)
			}
			expectPasteFile(t, kept, "outside")
			if got, err := os.Readlink(link); err != nil || got != target {
				t.Fatalf("symlink changed to %q: %v", got, err)
			}
		})
	}
}

func TestPasteOwnerSweepsAtStartupWhileUnattendedAndAfterRestart(t *testing.T) {
	home := t.TempDir()
	old := time.Now().Add(-8 * 24 * time.Hour)
	startup := pasteFile(t, home, "mac-a", "canvas-old", "startup.png", old)
	fresh := pasteFile(t, home, "mac-b", "canvas-live", "fresh.png", time.Now())
	stop := startPasteMaintenance(home, 10*time.Millisecond, io.Discard)
	defer stop()
	expectPasteGone(t, startup)
	periodic := pasteFile(t, home, "mac-a", "canvas-unwatched", "periodic.png", old)
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Lstat(periodic); os.IsNotExist(err) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("unattended owner did not expire the image")
		}
		time.Sleep(10 * time.Millisecond)
	}
	expectPasteGone(t, periodic)
	stop()
	stopped := pasteFile(t, home, "mac-a", "canvas-stopped", "stopped.png", old)
	time.Sleep(50 * time.Millisecond)
	expectPasteFile(t, stopped, "stopped.png")
	restarted := startPasteMaintenance(home, time.Hour, io.Discard)
	defer restarted()
	expectPasteGone(t, stopped)
	expectPasteFile(t, fresh, "fresh.png")
}

func TestDaemonPurgesExpiredImagesBeforeServingWithoutViewer(t *testing.T) {
	home := shortDir(t)
	old := time.Now().Add(-8 * 24 * time.Hour)
	expired := pasteFile(t, home, "mac-a", "canvas-unwatched", "expired.png", old)
	fresh := pasteFile(t, home, "mac-b", "canvas-live", "fresh.png", time.Now())
	done, stderr := start(t, "--home", home)
	connect(t, filepath.Join(home, "easl.sock"), stderr)
	expectPasteGone(t, expired)
	expectPasteFile(t, fresh, "fresh.png")
	if code := stop(t, done, syscall.SIGTERM); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
}

func TestPasteMaintenanceDoesNotRunWithoutTheHomeLock(t *testing.T) {
	home := shortDir(t)
	lock, err := acquireInstanceLock(filepath.Join(home, "instance.lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer lock.release()
	expired := pasteFile(t, home, "mac-a", "canvas-unwatched", "expired.png", time.Now().Add(-8*24*time.Hour))
	var log bytes.Buffer
	if code := run([]string{"--home", home}, &log); code != 1 {
		t.Fatalf("exit %d: %s", code, log.String())
	}
	expectPasteFile(t, expired, "expired.png")
}
