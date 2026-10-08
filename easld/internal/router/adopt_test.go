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

func TestAnAdoptedPathWorktreeOpensAndListsItsRegionAcrossRestarts(t *testing.T) {
	for _, name := range []string{"attached", "detached", "previously branchless"} {
		t.Run(name, func(t *testing.T) {
			f, _ := restorable(t)
			repo := filepath.Join(t.TempDir(), "repo")
			worktree := filepath.Join(repo, ".worktrees", "topic")
			if err := os.MkdirAll(worktree, 0o755); err != nil {
				t.Fatal(err)
			}
			oldID := f.result("board.open", map[string]any{"root": worktree})["board"].(string)
			codeFrame := map[string]any{"x": 20.0, "y": 40.0, "w": 400.0, "h": 300.0}
			noteFrame := map[string]any{"x": 500.0, "y": 40.0, "w": 200.0, "h": 100.0}
			terminalFrame := map[string]any{"x": 500.0, "y": 200.0, "w": 300.0, "h": 200.0}
			code := idOf(f.result("object.create", map[string]any{"board": oldID, "type": "code", "props": map[string]any{"path": "src/a.go"}, "frame": codeFrame}))
			note := idOf(f.result("object.create", map[string]any{"board": oldID, "type": "note", "props": map[string]any{"markdown": "src/a.go:1"}, "frame": noteFrame}))
			terminal := idOf(f.result("object.create", map[string]any{"board": oldID, "type": "terminal", "props": map[string]any{"cwd": worktree}, "frame": terminalFrame}))
			git(t, repo, "init", "-q", "-b", "main")
			git(t, repo, "commit", "-q", "--allow-empty", "-m", "init")
			git(t, repo, "worktree", "add", "-q", "-b", "topic", worktree)
			if name == "detached" {
				git(t, worktree, "checkout", "-q", "--detach")
			}
			var region string
			var ledger []byte
			for load := range 3 {
				again, errs := restart(t, f)
				if (load == 0 && (len(errs) != 1 || !strings.Contains(errs[0].Error(), "reopened as board"))) || (load > 0 && len(errs) != 0) {
					t.Fatalf("restart %d: %v", load, errs)
				}
				f = again
				opened := f.result("board.open", map[string]any{"root": worktree})
				repoID := opened["board"].(string)
				b := f.router.reg.Boards()[repoID]
				if len(b.Objects()) != 4 || !slices.Equal(b.Repo.Merged, []string{oldID}) {
					t.Fatalf("objects %v, merged %v", b.Objects(), b.Repo.Merged)
				}
				for _, o := range b.Objects() {
					if o.Props["key"] == "worktree:topic" {
						if region != "" && region != o.ID {
							t.Fatalf("region changed from %s to %s", region, o.ID)
						}
						region = o.ID
					}
				}
				if region == "" {
					t.Fatal("missing worktree:topic group")
				}
				info := opened["worktree"].(map[string]any)
				if info["region"] != region || (name == "detached" && info["branch"] != nil) || (name != "detached" && info["branch"] != "topic") {
					t.Fatalf("opened worktree %v", info)
				}
				var rows []map[string]any
				for _, raw := range f.result("board.list", map[string]any{})["boards"].([]any) {
					entry := raw.(map[string]any)
					if entry["board"] != repoID {
						continue
					}
					for _, raw := range entry["worktrees"].([]any) {
						row := raw.(map[string]any)
						if row["path"] == store.Normalized(worktree) {
							rows = append(rows, row)
						}
					}
				}
				if len(rows) != 1 || rows[0]["live"] != true || rows[0]["region"] != region || !reflect.DeepEqual(rows[0]["branch"], info["branch"]) {
					t.Fatalf("listed worktree %v, opened %v", rows, info)
				}
				objects := map[string]map[string]any{}
				for _, raw := range f.result("board.get", map[string]any{"board": oldID})["objects"].([]any) {
					o := raw.(map[string]any)
					objects[o["id"].(string)] = o
				}
				codeProps, noteProps := objects[code]["props"].(map[string]any), objects[note]["props"].(map[string]any)
				if !reflect.DeepEqual(objects[code]["frame"], codeFrame) || !reflect.DeepEqual(objects[note]["frame"], noteFrame) ||
					codeProps["path"] != filepath.Join(worktree, "src", "a.go") || codeProps["ref"] != nil || noteProps["root"] != worktree || noteProps["ref"] != nil {
					t.Fatalf("changed frames/anchors: %v %v", objects[code], objects[note])
				}
				terminalProps := objects[terminal]["props"].(map[string]any)
				if !reflect.DeepEqual(objects[terminal]["frame"], terminalFrame) || terminalProps["cwd"] != worktree ||
					terminalProps["worktree"] != store.Normalized(worktree) || terminalProps["branch"] != nil {
					t.Fatalf("changed folder terminal frame/affinity: %v", objects[terminal])
				}
				if part := f.result("board.get", map[string]any{"board": repoID, "branch": "topic"})["objects"].([]any); len(part) != 0 {
					t.Fatalf("live HEAD incorrectly branch-anchored folder objects: %v", part)
				}
				current, err := os.ReadFile(filepath.Join(f.router.reg.Store.Dir, store.BackupFolder, store.LedgerFile))
				if err != nil {
					t.Fatal(err)
				}
				if ledger != nil && !slices.Equal(ledger, current) {
					t.Fatal("a restart appended another migration run")
				}
				ledger = current
				if load == 0 {
					if len(b.Repo.Worktrees) != 1 || b.Repo.Worktrees[0].Region != region || !reflect.DeepEqual(b.Repo.Worktrees[0].Branch, store.BranchOf(*store.Containing(worktree))) {
						t.Fatalf("adopted records %v", b.Repo.Worktrees)
					}
					if name == "previously branchless" {
						// The exact split persisted by the older adoption: region on nil HEAD,
						// followed by an attached entry without a region.
						b.Repo.Worktrees[0].Branch = nil
						b.Repo.Worktrees = append(b.Repo.Worktrees, store.WorktreeRecord{Path: store.Normalized(worktree), Branch: store.BranchOf(*store.Containing(worktree))})
						f.router.reg.Mu.Lock()
						err := f.router.reg.Store.Write(b.Snapshot())
						f.router.reg.Mu.Unlock()
						if err != nil {
							t.Fatal(err)
						}
					}
				}
			}
		})
	}
}
