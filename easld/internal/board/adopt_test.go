package board

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"}, args...)...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// becomeRepository makes dir a git repository with a commit.
func becomeRepository(t *testing.T, dir string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "src", "a.go"), []byte("package a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "init", "-q")
	gitIn(t, dir, "add", ".")
	gitIn(t, dir, "commit", "-q", "-m", "init")
	return store.Containing(dir).CommonDir
}

var folderFrames = map[string]model.Frame{
	"obj_note": {X: 0, Y: 0, W: 200, H: 100},
	"obj_code": {X: 300, Y: 0, W: 400, H: 300},
	"obj_box":  {X: 0, Y: 200, W: 160, H: 100},
}

// writeFolderBoard stores the board of folder dir (outside git): a note, a code tile with a
// relative path, a shape.
func writeFolderBoard(t *testing.T, boards, dir string) string {
	t.Helper()
	at := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	object := func(id string, kind model.ObjectType, z float64, props map[string]any) model.Object {
		return model.Object{ID: id, Type: kind, Frame: folderFrames[id], Z: z, Rev: 1, CreatedBy: model.Actor{Kind: "user"}, CreatedAt: at, UpdatedAt: at, Props: props}
	}
	format := store.Format
	snap := &store.Snapshot{Format: &format, ID: store.PathID(dir), Root: store.Standardized(dir), Revision: 7, Objects: []model.Object{
		object("obj_note", model.Note, 1, map[string]any{"markdown": "kept"}),
		object("obj_code", model.Code, 2, map[string]any{"path": "src/a.go"}),
		object("obj_box", model.Shape, 3, map[string]any{"shape": "rect"}),
	}}
	data, err := snap.Encode()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(boards, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(boards, snap.ID+".json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	return snap.ID
}

// ledgerRuns is the runs of the store's migration ledger.
func ledgerRuns(t *testing.T, boards string) []map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(boards, store.BackupFolder, store.LedgerFile))
	if err != nil {
		t.Fatalf("no ledger: %v", err)
	}
	var ledger struct {
		Runs []map[string]any `json:"runs"`
	}
	if err := json.Unmarshal(data, &ledger); err != nil {
		t.Fatalf("ledger %s: %v", data, err)
	}
	return ledger.Runs
}

// checkAdopted: the repository board holds the folder board's objects as they were, lists it as
// merged; its file is backed up; the ledger's last run says so.
func checkAdopted(t *testing.T, b *Board, boards, folderID, commonDir string, objectsBefore int) {
	t.Helper()
	if b.ID() != store.RepoID(commonDir) {
		t.Fatalf("opened %s, want the repository's board %s", b.ID(), store.RepoID(commonDir))
	}
	for id, frame := range folderFrames {
		o, ok := b.Objects()[id]
		if !ok {
			t.Fatalf("%s isn't on the repository board: %v", id, b.Objects())
		}
		if o.Frame != frame {
			t.Errorf("%s at %v, want %v", id, o.Frame, frame)
		}
	}
	if path := b.Objects()["obj_code"].Props["path"]; path != "src/a.go" {
		t.Errorf("code path %v, want src/a.go", path)
	}
	if len(b.Objects()) != len(folderFrames) {
		t.Errorf("objects %v: the folder board is the main checkout's, placed as it was", b.Objects())
	}
	if b.Repo == nil || !slices.Equal(b.Repo.Merged, []string{folderID}) {
		t.Errorf("repo %+v, want merged [%s]", b.Repo, folderID)
	}
	if _, err := os.Stat(filepath.Join(boards, folderID+".json")); !os.IsNotExist(err) {
		t.Errorf("the folder board's file is still in the store: %v", err)
	}
	if _, err := os.Stat(filepath.Join(boards, store.BackupFolder, folderID+".json")); err != nil {
		t.Errorf("the folder board's file isn't backed up: %v", err)
	}
	runs := ledgerRuns(t, boards)
	if len(runs) != 1 {
		t.Fatalf("ledger runs %v, want one", runs)
	}
	run := runs[0]
	if _, ok := run["ranAt"].(string); !ok || run["dryRun"] != false || len(run["nonGit"].([]any)) != 0 || len(run["unresolved"].([]any)) != 0 {
		t.Errorf("run %v", run)
	}
	repos := run["repos"].([]any)
	repo := repos[0].(map[string]any)
	if len(repos) != 1 || repo["board"] != b.ID() || repo["commonDir"] != commonDir || repo["objectsBefore"] != float64(objectsBefore) ||
		repo["objectsAfter"] != float64(len(folderFrames)) || len(repo["keyRenames"].([]any)) != 0 {
		t.Errorf("repos %v", repos)
	}
	legacy := repo["legacy"].([]any)
	entry := legacy[0].(map[string]any)
	if len(legacy) != 1 || entry["board"] != folderID || entry["status"] != "merged" || entry["anchor"] != "main" ||
		entry["objectsBefore"] != float64(3) || entry["objectsAfter"] != float64(3) || entry["region"] != nil || entry["worktreeLive"] != true {
		t.Errorf("legacy %v", legacy)
	}
}

func TestAFolderBoardIsTakenInWhenTheFolderBecomesARepository(t *testing.T) {
	dir := t.TempDir()
	boards, folder := filepath.Join(dir, "boards"), filepath.Join(dir, "folder")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	folderID := writeFolderBoard(t, boards, folder)
	commonDir := becomeRepository(t, folder)

	reg := NewRegistry(boards, time.Hour, "")
	b, err := reg.Open(folder)
	if err != nil {
		t.Fatal(err)
	}
	checkAdopted(t, b, boards, folderID, commonDir, 0)

	again := NewRegistry(boards, time.Hour, "")
	b, err = again.Open(folder)
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Objects()) != len(folderFrames) || !slices.Equal(b.Repo.Merged, []string{folderID}) {
		t.Errorf("reopened: %v, merged %v", b.Objects(), b.Repo.Merged)
	}
	if runs := ledgerRuns(t, boards); len(runs) != 1 {
		t.Errorf("reopening ran again: %v", runs)
	}
}

func TestAFolderBoardIsTakenIntoTheRepositoryBoardStored(t *testing.T) {
	dir := t.TempDir()
	boards, folder := filepath.Join(dir, "boards"), filepath.Join(dir, "folder")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	folderID := writeFolderBoard(t, boards, folder)
	commonDir := becomeRepository(t, folder)
	format := store.Format
	empty := &store.Snapshot{Format: &format, ID: store.RepoID(commonDir), Root: store.Standardized(folder), Revision: 2, Objects: []model.Object{},
		Repo: &store.RepoRecord{CommonDir: commonDir, Worktrees: []store.WorktreeRecord{}}}
	data, err := empty.Encode()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(boards, empty.ID+".json"), data, 0o644); err != nil {
		t.Fatal(err)
	}

	b, err := NewRegistry(boards, time.Hour, "").Open(folder)
	if err != nil {
		t.Fatal(err)
	}
	checkAdopted(t, b, boards, folderID, commonDir, 0)
	if b.Revision() != 8 {
		t.Errorf("revision %d, want the folder board's 7 and one", b.Revision())
	}
}

func TestAFolderBoardOpenInTheRegistryStays(t *testing.T) {
	dir := t.TempDir()
	boards, folder := filepath.Join(dir, "boards"), filepath.Join(dir, "folder")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	folderID := writeFolderBoard(t, boards, folder)
	reg := NewRegistry(boards, time.Hour, "")
	before, err := reg.Open(folder)
	if err != nil || before.ID() != folderID {
		t.Fatalf("opened %v (%v), want the folder's board", before, err)
	}
	becomeRepository(t, folder)

	b, err := reg.Open(folder)
	if err != nil {
		t.Fatal(err)
	}
	if b.ID() == folderID || len(b.Objects()) != 0 || (b.Repo != nil && b.Repo.Merged != nil) {
		t.Errorf("the repository board took in the open folder board: %s %v %+v", b.ID(), b.Objects(), b.Repo)
	}
	if _, err := os.Stat(filepath.Join(boards, folderID+".json")); err != nil {
		t.Errorf("the open folder board's file moved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(boards, store.BackupFolder)); !os.IsNotExist(err) {
		t.Errorf("a migration ran: %v", err)
	}
}

func TestAFolderBoardTakenIntoARepositoryBoardWithObjectsIsARegion(t *testing.T) {
	dir := t.TempDir()
	boards, folder := filepath.Join(dir, "boards"), filepath.Join(dir, "folder")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	folderID := writeFolderBoard(t, boards, folder)
	commonDir := becomeRepository(t, folder)
	format := store.Format
	at := time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC)
	existing := &store.Snapshot{Format: &format, ID: store.RepoID(commonDir), Root: store.Standardized(folder), Revision: 2,
		Objects: []model.Object{{ID: "obj_there", Type: model.Shape, Frame: model.Frame{X: 0, Y: 0, W: 100, H: 100}, Z: 5, Rev: 1,
			CreatedBy: model.Actor{Kind: "user"}, CreatedAt: at, UpdatedAt: at, Props: map[string]any{"shape": "rect"}}},
		Repo: &store.RepoRecord{CommonDir: commonDir, Worktrees: []store.WorktreeRecord{}}}
	data, err := existing.Encode()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(boards, existing.ID+".json"), data, 0o644); err != nil {
		t.Fatal(err)
	}

	b, err := NewRegistry(boards, time.Hour, "").Open(folder)
	if err != nil {
		t.Fatal(err)
	}
	// Right of what is there by the gap, top-aligned, inside a region titled with the worktree.
	dx, dy := 100+200+24.0, 24+32.0
	for id, frame := range folderFrames {
		o := b.Objects()[id]
		if want := (model.Frame{X: frame.X + dx, Y: frame.Y + dy, W: frame.W, H: frame.H}); o.Frame != want {
			t.Errorf("%s at %v, want %v", id, o.Frame, want)
		}
		if o.Z <= 5 {
			t.Errorf("%s at z %v, not above what was there", id, o.Z)
		}
	}
	if path := b.Objects()["obj_code"].Props["path"]; path != "src/a.go" {
		t.Errorf("code path %v", path)
	}
	var region model.Object
	for _, o := range b.Objects() {
		if o.Type == model.Group {
			region = o
		}
	}
	if region.Props["key"] != "worktree:folder" || region.Props["title"] != "folder" || len(region.Props["members"].([]any)) != 3 {
		t.Fatalf("region %+v", region)
	}
	if b.Repo == nil || !slices.Equal(b.Repo.Merged, []string{folderID}) || len(b.Repo.Worktrees) != 1 || b.Repo.Worktrees[0].Region != region.ID {
		t.Errorf("repo %+v", b.Repo)
	}
	entry := ledgerRuns(t, boards)[0]["repos"].([]any)[0].(map[string]any)["legacy"].([]any)[0].(map[string]any)
	if entry["status"] != "merged" || entry["anchor"] != "main" || entry["region"] != region.ID || entry["objectsAfter"] != float64(4) ||
		!slices.Equal(entry["offset"].([]any), []any{dx, dy}) {
		t.Errorf("ledger entry %v", entry)
	}
}

func TestAStoreTheAppHasntMigratedKeepsItsFolderBoards(t *testing.T) {
	dir := t.TempDir()
	boards, folder := filepath.Join(dir, "boards"), filepath.Join(dir, "folder")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	folderID := writeFolderBoard(t, boards, folder)
	commonDir := becomeRepository(t, folder)
	// A legacy per-branch board, as the app kept them before boards were per repository.
	legacyID := store.HashedID(commonDir + "\nmain")
	legacy := fmt.Sprintf(`{"format":2,"id":%q,"root":%q,"revision":1,"objects":[]}`, legacyID, store.Standardized(folder))
	if err := os.WriteFile(filepath.Join(boards, legacyID+".json"), []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}

	b, err := NewRegistry(boards, time.Hour, "").Open(folder)
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Objects()) != 0 || b.Repo.Merged != nil {
		t.Errorf("took in a board of a store the app hasn't migrated: %v %+v", b.Objects(), b.Repo)
	}
	if _, err := os.Stat(filepath.Join(boards, folderID+".json")); err != nil {
		t.Errorf("the folder board's file moved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(boards, store.BackupFolder)); !os.IsNotExist(err) {
		t.Errorf("a ledger was written: %v", err)
	}

	// Once the app's migration has run (its ledger is there), the folder board is taken in.
	if err := os.MkdirAll(filepath.Join(boards, store.BackupFolder), 0o755); err != nil {
		t.Fatal(err)
	}
	ran := `{"runs":[{"dryRun":false,"nonGit":[],"ranAt":"2026-10-01T12:00:00Z","repos":[],"unresolved":[]}]}`
	if err := os.WriteFile(filepath.Join(boards, store.BackupFolder, store.LedgerFile), []byte(ran), 0o644); err != nil {
		t.Fatal(err)
	}
	b, err = NewRegistry(boards, time.Hour, "").Open(folder)
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Objects()) != len(folderFrames) || !slices.Equal(b.Repo.Merged, []string{folderID}) {
		t.Errorf("after the app's migration: %v %+v", b.Objects(), b.Repo)
	}
	if runs := ledgerRuns(t, boards); len(runs) != 2 {
		t.Errorf("ledger runs %v, want the app's and easld's", runs)
	}
}
