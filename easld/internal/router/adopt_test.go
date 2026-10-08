package router

import (
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/store"
)

func TestAListedFolderBoardReopensAsTheRepositoryBoardThatTookItIn(t *testing.T) {
	f, _ := restorable(t)
	folder := filepath.Join(t.TempDir(), "folder")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	folderID := f.result("board.open", map[string]any{"root": folder})["board"].(string)
	note := idOf(f.result("object.create", map[string]any{"board": folderID, "type": "note", "props": map[string]any{"markdown": "kept"},
		"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0}}))
	if folderID != store.PathID(folder) {
		t.Fatalf("the folder opened %s, want its own board", folderID)
	}

	if err := os.WriteFile(filepath.Join(folder, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, folder, "init", "-q", "-b", "main")
	git(t, folder, "add", ".")
	git(t, folder, "commit", "-q", "-m", "init")
	repoID := store.RepoID(store.Containing(folder).CommonDir)

	again, errs := restart(t, f)
	if len(errs) != 1 || !strings.Contains(errs[0].Error(), "board "+folderID+" reopened as board "+repoID) {
		t.Errorf("errors %v", errs)
	}
	b, ok := again.router.reg.Boards()[repoID]
	if !ok {
		t.Fatalf("the repository board isn't open: %v", again.router.reg.Boards())
	}
	if _, ok := b.Objects()[note]; !ok || !slices.Equal(b.Repo.Merged, []string{folderID}) {
		t.Errorf("the repository board %v (merged %v) didn't take in the folder's", b.Objects(), b.Repo.Merged)
	}
	if _, ok := again.router.reg.Boards()[folderID]; ok {
		t.Errorf("the folder board is open too")
	}
	listed, err := store.ReadReopened(f.router.Reopens)
	want := []store.Reopened{{Root: f.board.Root(), Board: f.board.ID()}, {Root: store.Standardized(folder), Board: repoID}}
	if err != nil || !reflect.DeepEqual(listed, want) {
		t.Errorf("listed %v (%v), want %v", listed, err, want)
	}

	// Listed by its old id again (an older list), it is found in the repository board's merged.
	if err := store.WriteReopened(f.router.Reopens, []store.Reopened{want[0], {Root: store.Standardized(folder), Board: folderID}}); err != nil {
		t.Fatal(err)
	}
	third, errs := restart(t, again)
	if len(errs) != 1 || !strings.Contains(errs[0].Error(), "reopened as board "+repoID) {
		t.Errorf("errors the second time %v", errs)
	}
	if b, ok := third.router.reg.Boards()[repoID]; !ok || len(b.Objects()) != 1 {
		t.Errorf("the second time: %v", third.router.reg.Boards())
	}
	if listed, _ := store.ReadReopened(f.router.Reopens); !reflect.DeepEqual(listed, want) {
		t.Errorf("listed the second time %v, want %v", listed, want)
	}
}
