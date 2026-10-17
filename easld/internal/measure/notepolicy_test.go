package measure

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

const outsideMarker = "DO_NOT_SHOW_OUTSIDE_HOST_68c1"

func TestNoteReadsRefuseOutsidePathsAndKeepCodeReads(t *testing.T) {
	parent := t.TempDir()
	board := filepath.Join(parent, "board")
	if err := os.MkdirAll(board, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside.rs")
	if err := os.WriteFile(outside, []byte(outsideMarker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parent, "outside.rs"), []byte(outsideMarker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	write(t, board, "inside.rs", "visible line")
	write(t, board, "nested/file.rs", "inside target")
	if err := os.Symlink("nested/file.rs", filepath.Join(board, "alias.rs")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(board, "escape.rs")); err != nil {
		t.Fatal(err)
	}
	reading := LinkReading{Root: board, Board: board}
	unbound := LinkReading{Root: board}.NoteExcerpt(ParseFenceInfo("rs file=inside.rs#L1"), nil)
	if unbound.Status.Reason != pathRefused || len(unbound.Lines) != 0 || unbound.Range != nil {
		t.Fatalf("a source root without board authorization read text: %+v", unbound)
	}

	code := ExcerptFor(ParseFenceInfo("rs file="+outside+"#L1"), board, nil, nil)
	if !reflect.DeepEqual(code.Lines, []string{outsideMarker}) || code.Status.Kind != "exact" {
		t.Fatalf("code tile read %+v", code)
	}
	status, ok := CodeRangeStatus(map[string]any{"path": outside, "range": model.LineRange{Start: 1, End: 1}.JSON()}, board)
	if !ok || status["state"] != "live" || status["reason"] != nil {
		t.Fatalf("code range status %v %v", ok, status)
	}

	for _, info := range []string{
		"rs file=" + outside + "#L1",
		"rs file=../outside.rs#L1",
		"rs file=escape.rs#L1",
		"rs file=~/secret.rs#L1",
	} {
		got := reading.NoteExcerpt(ParseFenceInfo(info), nil)
		if got.Status.Reason != pathRefused || len(got.Lines) != 0 || got.Range != nil || strings.Contains(strings.Join(got.Lines, "\n"), outsideMarker) {
			t.Errorf("%s: %+v", info, got)
		}
	}
	alias := reading.NoteExcerpt(ParseFenceInfo("rs file=alias.rs#L1"), nil)
	if alias.Path != "alias.rs" || !reflect.DeepEqual(alias.Lines, []string{"inside target"}) || alias.Status.Kind != "exact" {
		t.Fatalf("inside symlink %+v", alias)
	}
	missing := reading.NoteExcerpt(ParseFenceInfo("rs file=missing.rs#L1"), nil)
	if missing.Status.Reason != "no file missing.rs" || !missing.Missing {
		t.Fatalf("missing inside %+v", missing)
	}
	absent := reading.NoteExcerpt(ParseFenceInfo("rs file="+filepath.Join(t.TempDir(), "absent.rs")+"#L1"), nil)
	if absent.Status.Reason != pathRefused || absent.Missing || len(absent.Lines) != 0 {
		t.Fatalf("missing outside %+v", absent)
	}
}

func TestSwappedDirectoryCannotRedirectANoteRead(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	pkg := filepath.Join(dir, "pkg")
	if err := os.Mkdir(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(pkg, "file.rs")
	if err := os.WriteFile(file, []byte("safe\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	data, err := readRegular(file)
	if err != nil || string(data) != "safe\n" {
		t.Fatalf("before swap %q %v", data, err)
	}
	outside := filepath.Join(dir, "outside")
	if err := os.Mkdir(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "file.rs"), []byte(outsideMarker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(pkg); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, pkg); err != nil {
		t.Fatal(err)
	}
	data, err = readRegular(file)
	var se *SourceError
	if err == nil || !errors.As(err, &se) || se.Kind != "refused" || strings.Contains(string(data), outsideMarker) {
		t.Fatalf("after swap %q %v", data, err)
	}
}

func TestNotePolicyKeepsWorktreesPinsAndOverrides(t *testing.T) {
	parent, repo, board := gitBoard(t)
	write(t, board, "inside.rs", "board line")
	write(t, board, "src/a.rs", "src line")
	write(t, board, "top.rs", "top line")
	secret := filepath.Join(repo, "secret.rs")
	if err := os.WriteFile(secret, []byte(outsideMarker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-q", "-m", "one")
	sha := git(t, repo, "rev-parse", "HEAD")

	if err := os.Remove(filepath.Join(board, "inside.rs")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, filepath.Join(board, "inside.rs")); err != nil {
		t.Fatal(err)
	}
	pinned := LinkReading{Root: board, Board: board}.NoteExcerpt(ParseFenceInfo("rs file=inside.rs@"+sha+"#L1"), nil)
	if !reflect.DeepEqual(pinned.Lines, []string{"board line"}) || pinned.Status.Kind != "exact" || strings.Contains(strings.Join(pinned.Lines, "\n"), outsideMarker) {
		t.Fatalf("pinned blob %+v", pinned)
	}
	if err := os.Symlink(secret, filepath.Join(board, "escape.rs")); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", "board/escape.rs")
	git(t, repo, "commit", "-q", "-m", "link")
	linkSHA := git(t, repo, "rev-parse", "HEAD")
	linked := LinkReading{Root: board, Board: board}.NoteExcerpt(ParseFenceInfo("rs file=escape.rs@"+linkSHA+"#L1"), nil)
	if linked.Status.Reason != pathRefused || len(linked.Lines) != 0 || strings.Contains(strings.Join(linked.Lines, "\n"), outsideMarker) {
		t.Fatalf("pinned symlink %+v", linked)
	}

	wt := filepath.Join(parent, "wt")
	git(t, repo, "worktree", "add", "-q", "-b", "feature", wt)
	if err := os.WriteFile(filepath.Join(wt, "board", "inside.rs"), []byte("worktree line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	live := ReadingFor(map[string]any{"ref": "feature"}, board)
	if live.Board != board {
		t.Fatalf("ref reading board %s", live.Board)
	}
	got := live.NoteExcerpt(ParseFenceInfo("rs file=inside.rs#L1"), nil)
	if !reflect.DeepEqual(got.Lines, []string{"worktree line"}) || got.Status.Kind != "exact" {
		t.Fatalf("worktree counterpart %+v root %s", got, live.Root)
	}
	absolute := LinkReading{Root: board, Board: board}.NoteExcerpt(ParseFenceInfo("rs file="+filepath.Join(wt, "board", "inside.rs")+"#L1"), nil)
	if !reflect.DeepEqual(absolute.Lines, []string{"worktree line"}) {
		t.Fatalf("absolute worktree path %+v", absolute)
	}
	repoFile := LinkReading{Root: board, Board: board}.NoteExcerpt(ParseFenceInfo("rs file="+secret+"#L1"), nil)
	if repoFile.Status.Reason != pathRefused || len(repoFile.Lines) != 0 {
		t.Fatalf("repo file outside the board subdirectory %+v", repoFile)
	}

	if err := os.RemoveAll(filepath.Join(wt, "board")); err != nil {
		t.Fatal(err)
	}
	leaked := filepath.Join(parent, "leaked")
	if err := os.MkdirAll(leaked, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(leaked, "inside.rs"), []byte(outsideMarker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(leaked, filepath.Join(wt, "board")); err != nil {
		t.Fatal(err)
	}
	escaped := LinkReading{Root: filepath.Join(wt, "board"), Board: board}.NoteExcerpt(ParseFenceInfo("rs file=inside.rs#L1"), nil)
	if escaped.Status.Reason != pathRefused || strings.Contains(strings.Join(escaped.Lines, "\n"), outsideMarker) {
		t.Fatalf("worktree symlink area %+v", escaped)
	}

	sub := LinkReading{Root: filepath.Join(board, "src"), Board: board}
	if lines := sub.NoteExcerpt(ParseFenceInfo("rs file=a.rs#L1"), nil).Lines; !reflect.DeepEqual(lines, []string{"src line"}) {
		t.Fatalf("subdir override %v", lines)
	}
	if lines := sub.NoteExcerpt(ParseFenceInfo("rs file=../top.rs#L1"), nil).Lines; !reflect.DeepEqual(lines, []string{"top line"}) {
		t.Fatalf("in-board traversal from override %v", lines)
	}
	out := sub.NoteExcerpt(ParseFenceInfo("rs file=../../secret.rs#L1"), nil)
	if out.Status.Reason != pathRefused || len(out.Lines) != 0 {
		t.Fatalf("override escape %+v", out)
	}
	wide := LinkReading{Root: repo, Board: board}.NoteExcerpt(ParseFenceInfo("rs file=secret.rs#L1"), nil)
	if wide.Status.Reason != pathRefused || strings.Contains(strings.Join(wide.Lines, "\n"), outsideMarker) {
		t.Fatalf("repo root override %+v", wide)
	}
}

func gitBoard(t *testing.T) (parent, repo, board string) {
	t.Helper()
	parent = t.TempDir()
	repo = filepath.Join(parent, "repo")
	board = filepath.Join(repo, "board")
	if err := os.MkdirAll(board, 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "init", "-q", "-b", "main")
	return parent, repo, board
}
