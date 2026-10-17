package measure

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestReanchorRefusesOutsideSourcesButKeepsDisplay(t *testing.T) {
	parent := t.TempDir()
	board := filepath.Join(parent, "board")
	if err := os.MkdirAll(board, 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, parent, "outside.rs", outsideMarker)
	write(t, board, "inside.rs", "", "  inside anchor", "body")
	outside := filepath.Join(parent, "outside.rs")
	if err := os.Symlink(outside, filepath.Join(board, "escape.rs")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("inside.rs", filepath.Join(board, "alias.rs")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{outside, "../outside.rs", "escape.rs"} {
		for _, authored := range []string{"", outsideMarker} {
			props := map[string]any{"path": path, "range": model.LineRange{Start: 1, End: 1}.JSON()}
			if authored != "" {
				props["anchor"] = authored
			}
			if r, anchor, changed := Reanchor(props, board); changed || anchor != nil || r != (model.LineRange{}) {
				t.Errorf("refused %s authored %q produced %v %v %v", path, authored, r, anchor, changed)
			}
			if got, err := CodeExcerpt(props, board); err != nil || !reflect.DeepEqual(got.Lines, []string{outsideMarker}) {
				t.Errorf("display %s = %+v, %v", path, got, err)
			}
			if props["anchor"] != nil && props["anchor"] != authored {
				t.Errorf("authored anchor changed in %v", props)
			}
		}
	}
	for _, path := range []string{"inside.rs", "alias.rs", filepath.Join(board, "inside.rs")} {
		props := map[string]any{"path": path, "range": model.LineRange{Start: 1, End: 2}.JSON(), "anchor": "inside anchor"}
		assertReanchor(t, props, board, model.LineRange{Start: 2, End: 3}, "inside anchor")
	}
	for _, exclusion := range []map[string]any{{"pinnedCommit": "HEAD"}, {"followOf": "obj_source"}} {
		props := map[string]any{"path": "inside.rs", "range": model.LineRange{Start: 2, End: 3}.JSON()}
		for k, v := range exclusion {
			props[k] = v
		}
		if _, anchor, changed := Reanchor(props, board); changed || anchor != nil {
			t.Errorf("excluded tile %v produced %v %v", props, anchor, changed)
		}
	}
}

func TestReanchorKeepsCanonicalBoardAreasAcrossRefs(t *testing.T) {
	parent, repo, board := gitBoard(t)
	write(t, board, "inside.rs", "board anchor")
	write(t, repo, "outside.rs", outsideMarker)
	if err := os.Symlink(outsideMarker, filepath.Join(board, "blob-link.rs")); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-q", "-m", "sources")
	sha := git(t, repo, "rev-parse", "HEAD")
	git(t, repo, "branch", "objects")
	wt := filepath.Join(parent, "wt")
	git(t, repo, "worktree", "add", "-q", "-b", "feature", wt)
	write(t, wt, "board/inside.rs", "", "worktree anchor", "body")
	for _, props := range []map[string]any{
		{"path": filepath.Join(wt, "board", "inside.rs")},
		{"path": "inside.rs", "ref": "feature"},
		{"path": filepath.Join(board, "inside.rs"), "ref": "feature"},
	} {
		props["range"] = model.LineRange{Start: 1, End: 2}.JSON()
		props["anchor"] = "worktree anchor"
		assertReanchor(t, props, board, model.LineRange{Start: 2, End: 3}, "worktree anchor")
	}
	for _, ref := range []string{"objects", "gone"} {
		props := map[string]any{"path": "inside.rs", "ref": ref, "refSha": sha, "range": model.LineRange{Start: 1, End: 1}.JSON()}
		assertReanchor(t, props, board, model.LineRange{Start: 1, End: 1}, "board anchor")
	}
	for _, ref := range []string{"feature", "objects", "gone"} {
		for _, path := range []string{"../outside.rs", filepath.Join(repo, "outside.rs"), "blob-link.rs"} {
			props := map[string]any{"path": path, "ref": ref, "refSha": sha, "range": model.LineRange{Start: 1, End: 1}.JSON()}
			if r, anchor, changed := Reanchor(props, board); changed || anchor != nil || r != (model.LineRange{}) {
				t.Errorf("ref %s path %s produced %v %v %v", ref, path, r, anchor, changed)
			}
		}
	}
	if err := os.RemoveAll(filepath.Join(wt, "board")); err != nil {
		t.Fatal(err)
	}
	escape := filepath.Join(parent, "escape")
	write(t, escape, "inside.rs", outsideMarker)
	if err := os.Symlink(escape, filepath.Join(wt, "board")); err != nil {
		t.Fatal(err)
	}
	props := map[string]any{"path": "inside.rs", "ref": "feature", "range": model.LineRange{Start: 1, End: 1}.JSON()}
	if r, anchor, changed := Reanchor(props, board); changed || anchor != nil || r != (model.LineRange{}) {
		t.Fatalf("escaped ref root produced %v %v %v", r, anchor, changed)
	}
}

func assertReanchor(t *testing.T, props map[string]any, root string, want model.LineRange, wantAnchor string) {
	t.Helper()
	r, anchor, changed := Reanchor(props, root)
	if !changed || r != want || anchor == nil || *anchor != wantAnchor {
		t.Fatalf("reanchor %v = %v %v %v, want %v %q true", props, r, anchor, changed, want, wantAnchor)
	}
}
