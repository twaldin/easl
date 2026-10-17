package measure

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAnchorRefusalUsesPolicyNotSourceAvailability(t *testing.T) {
	root := t.TempDir()
	write(t, root, "inside.rs", "inside anchor")
	if err := os.WriteFile(filepath.Join(root, "binary.rs"), []byte{0xff}, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "directory.rs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../outside.rs", filepath.Join(root, "escape.rs")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("inside.rs", filepath.Join(root, "alias.rs")); err != nil {
		t.Fatal(err)
	}
	reading := LinkReading{Root: root, Board: root}
	for _, test := range []struct {
		info string
		want bool
	}{
		{"rs file=../outside.rs#L1 anchor=legacy", true},
		{"rs file=escape.rs#L1 anchor=legacy", true},
		{"rs file=../outside.rs commit=-invalid anchor=legacy", true},
		{"rs file=inside.rs commit=-invalid anchor=legacy", false},
		{"rs file=inside.rs#L99 anchor=stale", false},
		{"rs file=missing.rs#L1 anchor=missing", false},
		{"rs file=directory.rs#L1 anchor=unreadable", false},
		{"rs file=binary.rs#L1 anchor=unreadable", false},
		{"rs file=alias.rs#L1 anchor=allowed", false},
		{"rs file=inside.rs@-invalid#L1 anchor=invalid", false},
	} {
		if got := reading.RefusesFence(ParseFenceInfo(test.info)); got != test.want {
			t.Errorf("%q refusal = %v, want %v", test.info, got, test.want)
		}
	}
}

func TestAnchorRefusalKeepsPinsWorktreesAndOverrides(t *testing.T) {
	parent, repo, board := gitBoard(t)
	write(t, board, "inside.rs", "board anchor")
	write(t, repo, "outside.rs", "outside anchor")
	if err := os.Symlink("../outside.rs", filepath.Join(board, "blob-link.rs")); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-q", "-m", "sources")
	git(t, repo, "branch", "objects")
	wt := filepath.Join(parent, "wt")
	git(t, repo, "worktree", "add", "-q", "-b", "feature", wt)
	for _, ref := range []string{"feature", "objects"} {
		for _, test := range []struct {
			path string
			want bool
		}{
			{"inside.rs", false},
			{"missing.rs", false},
			{"../outside.rs", true},
			{"blob-link.rs", true},
		} {
			reading := ReadingFor(map[string]any{"ref": ref}, board)
			if got := reading.RefusesFence(ParseFenceInfo("rs file=" + test.path + "#L1 anchor=legacy")); got != test.want {
				t.Errorf("ref %s path %s refusal = %v, want %v", ref, test.path, got, test.want)
			}
		}
	}
	if err := os.Remove(filepath.Join(board, "inside.rs")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../outside.rs", filepath.Join(board, "inside.rs")); err != nil {
		t.Fatal(err)
	}
	reading := LinkReading{Root: board, Board: board}
	if reading.RefusesFence(ParseFenceInfo("rs file=inside.rs@HEAD#L1 anchor=allowed")) {
		t.Fatal("a live symlink overrode an allowed pinned regular blob")
	}
	if !reading.RefusesFence(ParseFenceInfo("rs file=blob-link.rs@HEAD#L1 anchor=legacy")) {
		t.Fatal("a pinned symlink was not refused")
	}
	for _, props := range []map[string]any{{"root": repo}, {"root": ".."}} {
		if !ReadingFor(props, board).RefusesFence(ParseFenceInfo("rs file=outside.rs#L1 anchor=legacy")) {
			t.Fatalf("outside source override was authorized: %v", props)
		}
	}
	escape := filepath.Join(parent, "escape")
	write(t, escape, "inside.rs", "outside anchor")
	if err := os.RemoveAll(filepath.Join(wt, "board")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(escape, filepath.Join(wt, "board")); err != nil {
		t.Fatal(err)
	}
	if !ReadingFor(map[string]any{"ref": "feature"}, board).RefusesFence(ParseFenceInfo("rs file=inside.rs#L1 anchor=legacy")) {
		t.Fatal("an escaped worktree source root was authorized")
	}
}
