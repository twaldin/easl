package store

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

var adoptedAt = time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)

// repository is dir made a git repository with a commit, its subdirectory `sub` holding a.go;
// its common git directory.
func repository(t *testing.T, dir string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sub", "a.go"), []byte("package a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-q"}, {"add", "."}, {"commit", "-q", "-m", "init"}} {
		cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"}, args...)...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	return Containing(dir).CommonDir
}

func adoptedObject(id string, kind model.ObjectType, x float64, props map[string]any) model.Object {
	return model.Object{ID: id, Type: kind, Frame: model.Frame{X: x, Y: 0, W: 200, H: 100}, Z: 1, Rev: 1, CreatedBy: model.Actor{Kind: "user"},
		CreatedAt: adoptedAt, UpdatedAt: adoptedAt, Props: props}
}

// stored writes snap into the store at dir.
func stored(t *testing.T, dir string, snap *Snapshot) {
	t.Helper()
	format := Format
	snap.Format = &format
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, snap.ID+".json"), encoded(t, snap), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readStored(t *testing.T, s *Store, id string) *Snapshot {
	t.Helper()
	snap, err := s.Read(id)
	if err != nil || snap == nil {
		t.Fatalf("board %s: %v (%v)", id, snap, err)
	}
	return snap
}

func codeMention(id, path string) model.Mention {
	return model.Mention{ID: id, Target: map[string]any{"kind": "code", "object": "obj_code", "path": path}, Label: "a.go", StagedAt: adoptedAt}
}

// A subfolder's board taken into its repository's: the terminals' unacknowledged messages come
// along after the repository board's own (their mentions re-rooted as the tray's are), and so do
// renamed terminals' old names, the repository board's kept where both have one. Its notes and
// HTML tiles without a root keep resolving against the subfolder, and its diagrams' files (the
// symbol's, the aim's, every node's, and the paths in node ids, wherever an id is: expanded
// nodes, the root, edges, an arrow's bound end) are written as the repository board's diagram
// builds write them: relative to the repository, whether the old board had them relative or
// absolute, when they lie in it.
func TestASubfoldersBoardKeepsItsMessagesAliasesNoteRootsAndDiagramPaths(t *testing.T) {
	dir := t.TempDir()
	repo, boards := filepath.Join(dir, "repo"), filepath.Join(dir, "boards")
	commonDir := repository(t, repo)
	sub := filepath.Join(repo, "sub")
	inside := filepath.Join(sub, "b.go")
	ours := Message{ID: "msg_ours", Text: "first", When: "next-turn", Mentions: []model.Mention{}, QueuedAt: adoptedAt}
	theirs := Message{ID: "msg_theirs", Text: "second", From: "obj_term", When: "now", Mentions: []model.Mention{codeMention("men_1", "a.go")}, QueuedAt: adoptedAt}
	stored(t, boards, &Snapshot{ID: RepoID(commonDir), Root: Standardized(repo), Revision: 3,
		Objects: []model.Object{adoptedObject("obj_there", model.Terminal, 0, map[string]any{})},
		Aliases: map[string]string{"old": "obj_there", "kept": "obj_there"}, Messages: map[string][]Message{"obj_term": {ours}},
		Repo: &RepoRecord{CommonDir: commonDir, Worktrees: []WorktreeRecord{}}})
	stored(t, boards, &Snapshot{ID: PathID(sub), Root: Standardized(sub), Revision: 2, Objects: []model.Object{
		adoptedObject("obj_term", model.Terminal, 0, map[string]any{}),
		adoptedObject("obj_note", model.Note, 300, map[string]any{"markdown": "![x](x.png)"}),
		adoptedObject("obj_html", model.HTML, 600, map[string]any{"html": "<a href=b.html>b</a>"}),
		adoptedObject("obj_diagram", model.Diagram, 900, map[string]any{"path": "a.go", "expanded": []any{"a.go#main", "plain", inside + "#helper"}, "graph": map[string]any{
			"aim": map[string]any{"kind": "calls", "path": "a.go", "direction": "both"}, "root": "a.go#main",
			"nodes": []any{map[string]any{"id": "a.go#main", "path": "a.go", "kept": true}, map[string]any{"id": "/elsewhere/b.go#g#h", "path": "/elsewhere/b.go"},
				map[string]any{"id": inside + "#helper", "path": inside}},
			"edges": []any{map[string]any{"from": "a.go#main", "to": "/elsewhere/b.go#g#h"}, map[string]any{"from": "a.go#main", "to": inside + "#helper"}}}}),
		adoptedObject("obj_arrow", model.Arrow, 0, map[string]any{"from": map[string]any{"object": "obj_diagram", "node": "a.go#main"},
			"to": map[string]any{"object": "obj_diagram", "node": inside + "#helper"}}),
	}, Aliases: map[string]string{"old": "obj_term", "worker": "obj_term"}, Messages: map[string][]Message{"obj_term": {theirs}}})

	s := New(boards, time.Hour, nil)
	s.Loading(RepoID(commonDir), commonDir, adoptedAt)
	got := readStored(t, s, RepoID(commonDir))
	if want := map[string]string{"old": "obj_there", "kept": "obj_there", "worker": "obj_term"}; !reflect.DeepEqual(got.Aliases, want) {
		t.Errorf("aliases %v, want %v", got.Aliases, want)
	}
	moved := theirs
	moved.Mentions = []model.Mention{codeMention("men_1", "sub/a.go")}
	if want := map[string][]Message{"obj_term": {ours, moved}}; !reflect.DeepEqual(got.Messages, want) {
		t.Errorf("messages %+v, want %+v", got.Messages, want)
	}
	objects := map[string]model.Object{}
	for _, o := range got.Objects {
		objects[o.ID] = o
	}
	for _, id := range []string{"obj_note", "obj_html"} {
		if root := objects[id].Props["root"]; root != "sub" {
			t.Errorf("%s root %v, want sub", id, root)
		}
	}
	diagram := objects["obj_diagram"].Props
	want := map[string]any{"path": "sub/a.go", "expanded": []any{"sub/a.go#main", "plain", "sub/b.go#helper"}, "graph": map[string]any{
		"aim": map[string]any{"kind": "calls", "path": "sub/a.go", "direction": "both"}, "root": "sub/a.go#main",
		"nodes": []any{map[string]any{"id": "sub/a.go#main", "path": "sub/a.go", "kept": true}, map[string]any{"id": "/elsewhere/b.go#g#h", "path": "/elsewhere/b.go"},
			map[string]any{"id": "sub/b.go#helper", "path": "sub/b.go"}},
		"edges": []any{map[string]any{"from": "sub/a.go#main", "to": "/elsewhere/b.go#g#h"}, map[string]any{"from": "sub/a.go#main", "to": "sub/b.go#helper"}}}}
	if !reflect.DeepEqual(diagram, want) {
		t.Errorf("diagram %v\nwant %v", diagram, want)
	}
	if arrow := objects["obj_arrow"].Props; arrow["from"].(map[string]any)["node"] != "sub/a.go#main" ||
		!reflect.DeepEqual(arrow["to"], map[string]any{"object": "obj_diagram", "node": "sub/b.go#helper"}) {
		t.Errorf("arrow %v", arrow)
	}
}

// A board of the repository's top level, adopted, leaves its notes without a root: the board's
// root is theirs still.
func TestTheTopLevelsBoardsNotesKeepNoRoot(t *testing.T) {
	dir := t.TempDir()
	repo, boards := filepath.Join(dir, "repo"), filepath.Join(dir, "boards")
	commonDir := repository(t, repo)
	stored(t, boards, &Snapshot{ID: PathID(repo), Root: Standardized(repo), Revision: 1, Objects: []model.Object{
		adoptedObject("obj_note", model.Note, 0, map[string]any{"markdown": "x"}),
	}})
	s := New(boards, time.Hour, nil)
	s.Loading(RepoID(commonDir), commonDir, adoptedAt)
	got := readStored(t, s, RepoID(commonDir))
	if len(got.Objects) != 1 || got.Objects[0].Props["root"] != nil {
		t.Errorf("objects %+v", got.Objects)
	}
}

// conflicting is repo made a repository whose stored board already holds the objects of repo's
// stored folder board (so the folder board conflicts); repo's common git directory.
func conflicting(t *testing.T, repo, boards string) string {
	t.Helper()
	commonDir := repository(t, repo)
	same := []model.Object{adoptedObject("obj_same", model.Note, 0, map[string]any{})}
	stored(t, boards, &Snapshot{ID: RepoID(commonDir), Root: Standardized(repo), Revision: 1, Objects: same,
		Repo: &RepoRecord{CommonDir: commonDir, Worktrees: []WorktreeRecord{}}})
	stored(t, boards, &Snapshot{ID: PathID(repo), Root: Standardized(repo), Revision: 1, Objects: same})
	return commonDir
}

type unresolvedBoard struct {
	Board, Root string
	Objects     int
}

// ledgerRuns is each run of the store's ledger, as the boards it left unresolved.
func ledgerRuns(t *testing.T, boards string) [][]unresolvedBoard {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(boards, BackupFolder, LedgerFile))
	var ledger struct {
		Runs []struct {
			Unresolved []unresolvedBoard `json:"unresolved"`
		} `json:"runs"`
	}
	if err != nil || json.Unmarshal(data, &ledger) != nil {
		t.Fatalf("ledger %s: %v", data, err)
	}
	runs := [][]unresolvedBoard{}
	for _, run := range ledger.Runs {
		runs = append(runs, run.Unresolved)
	}
	return runs
}

// A load that takes in nothing (its folder board's objects clash with the repository board's)
// leaves both boards' files as they are. The folder board is reported once, unresolved, as the
// app's run reports it: not by every load after.
func TestAConflictingFolderBoardIsReportedOnceNotAtEveryLoad(t *testing.T) {
	dir := t.TempDir()
	repo, boards := filepath.Join(dir, "repo"), filepath.Join(dir, "boards")
	commonDir := conflicting(t, repo, boards)
	repoFile := filepath.Join(boards, RepoID(commonDir)+".json")
	before, err := os.ReadFile(repoFile)
	if err != nil {
		t.Fatal(err)
	}
	for range 3 {
		New(boards, time.Hour, nil).Loading(RepoID(commonDir), commonDir, adoptedAt)
	}
	want := [][]unresolvedBoard{{{Board: PathID(repo), Root: Standardized(repo), Objects: 1}}}
	if runs := ledgerRuns(t, boards); !reflect.DeepEqual(runs, want) {
		t.Errorf("the ledger's runs left %v unresolved, want %v", runs, want)
	}
	if _, err := os.Stat(filepath.Join(boards, PathID(repo)+".json")); err != nil {
		t.Errorf("the conflicting board's file moved: %v", err)
	}
	if after, _ := os.ReadFile(repoFile); string(after) != string(before) {
		t.Errorf("the repository board was rewritten:\n%s\nwas\n%s", after, before)
	}
}

// Two repositories' conflicting folder boards, in a store the app has migrated: each
// repository's load leaves both unresolved, so launches that load both add nothing after the
// first.
func TestTwoRepositoriesConflictingFolderBoardsAreReportedOnce(t *testing.T) {
	dir := t.TempDir()
	first, second, boards := filepath.Join(dir, "first"), filepath.Join(dir, "second"), filepath.Join(dir, "boards")
	firstCommon, secondCommon := conflicting(t, first, boards), conflicting(t, second, boards)
	ledger := filepath.Join(boards, BackupFolder, LedgerFile)
	if err := os.MkdirAll(filepath.Dir(ledger), 0o755); err != nil {
		t.Fatal(err)
	}
	ran := `{"runs":[{"dryRun":false,"nonGit":[],"ranAt":"2026-10-01T12:00:00Z","repos":[],"unresolved":[]}]}`
	if err := os.WriteFile(ledger, []byte(ran), 0o644); err != nil {
		t.Fatal(err)
	}
	launch := func() {
		s := New(boards, time.Hour, nil)
		s.Loading(RepoID(firstCommon), firstCommon, adoptedAt)
		s.Loading(RepoID(secondCommon), secondCommon, adoptedAt)
	}
	launch()
	runs := len(ledgerRuns(t, boards))
	launch()
	launch()
	got := ledgerRuns(t, boards)
	if len(got) != runs {
		t.Errorf("%d runs, want the %d of the first launch", len(got), runs)
	}
	want := []string{PathID(first), PathID(second)}
	slices.Sort(want)
	last := []string{}
	for _, u := range got[len(got)-1] {
		last = append(last, u.Board)
	}
	if !slices.Equal(last, want) {
		t.Errorf("the last run left %v unresolved, want %v", last, want)
	}
}

// adoptedDiagramProps is a graph with a node of path and an external file's node, both
// expanded and connected by an edge. An adoption must map all their identities together.
func adoptedDiagramProps(path, external string) map[string]any {
	node, other := path+"#run", external+"#helper"
	return map[string]any{"kind": "calls", "path": path, "symbol": "run", "expanded": []any{node, other},
		"graph": map[string]any{"aim": map[string]any{"kind": "calls", "path": path}, "root": node,
			"nodes": []any{map[string]any{"id": node, "path": path}, map[string]any{"id": other, "path": external}},
			"edges": []any{map[string]any{"from": node, "to": other}}}}
}

// Diagram paths and ids are relative to the destination board root, also when the source is
// a nested linked checkout or a symlink spelling of a file. External files stay absolute.
func TestAnAdoptedDiagramKeepsItsIdentitiesRelativeToItsDestinationRoot(t *testing.T) {
	for _, aliased := range []bool{false, true} {
		name := "nested linked checkout"
		if aliased {
			name = "symlink alias"
		}
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			repo, boards := filepath.Join(dir, "repo"), filepath.Join(dir, "boards")
			commonDir := repository(t, repo)
			source, path, expected := repo, "sub/a.go", "sub/a.go"
			if aliased {
				alias := filepath.Join(dir, "repo-alias")
				if err := os.Symlink(repo, alias); err != nil {
					t.Fatal(err)
				}
				path = alias + "/sub/./a.go"
			} else {
				source = filepath.Join(repo, ".worktrees", "topic")
				cmd := exec.Command("git", "worktree", "add", "-q", "-b", "topic", source)
				cmd.Dir = repo
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("git worktree add: %v\n%s", err, out)
				}
				expected = ".worktrees/topic/sub/a.go"
			}
			external := filepath.Join(dir, "external", "b.go")
			stored(t, boards, &Snapshot{ID: PathID(source), Root: Standardized(source), Revision: 1, Objects: []model.Object{
				adoptedObject("obj_diagram", model.Diagram, 0, adoptedDiagramProps(path, external)),
				adoptedObject("obj_arrow", model.Arrow, 300, map[string]any{"from": map[string]any{"object": "obj_diagram", "node": path + "#run"},
					"to": map[string]any{"object": "obj_diagram", "node": external + "#helper"}}),
			}})
			s := New(boards, time.Hour, nil)
			s.Loading(RepoID(commonDir), commonDir, adoptedAt)
			got := readStored(t, s, RepoID(commonDir))
			if realPath(got.Root) != realPath(repo) {
				t.Fatalf("board root %s, want %s", got.Root, repo)
			}
			objects := map[string]model.Object{}
			for _, o := range got.Objects {
				objects[o.ID] = o
			}
			if want := adoptedDiagramProps(expected, external); !reflect.DeepEqual(objects["obj_diagram"].Props, want) {
				t.Errorf("diagram %v\nwant %v", objects["obj_diagram"].Props, want)
			}
			wantArrow := map[string]any{"from": map[string]any{"object": "obj_diagram", "node": expected + "#run"},
				"to": map[string]any{"object": "obj_diagram", "node": external + "#helper"}}
			if !reflect.DeepEqual(objects["obj_arrow"].Props, wantArrow) {
				t.Errorf("arrow %v, want %v", objects["obj_arrow"].Props, wantArrow)
			}
		})
	}
}

func TestBranchlessRegionFallbackKeepsDetachedAndHistoricalWorktrees(t *testing.T) {
	dir := t.TempDir()
	repo, worktree := filepath.Join(dir, "repo"), filepath.Join(dir, "topic")
	commonDir := repository(t, repo)
	runGit := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = repo
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	runGit("worktree", "add", "-q", "-b", "topic", worktree)
	path := Normalized(worktree)
	topic, old := "topic", "old"
	objects := map[string]model.Object{
		"obj_path": adoptedObject("obj_path", model.Group, 0, map[string]any{}),
		"obj_old":  adoptedObject("obj_old", model.Group, 0, map[string]any{}),
	}
	r := RepoRecord{CommonDir: commonDir, Worktrees: []WorktreeRecord{
		{Path: path, Region: "obj_path"},
		{Path: path, Branch: &topic},
		{Path: path, Branch: &old, Region: "obj_old"},
	}}
	list := r.WorktreeList(objects)
	var live, historical []WorktreeInfo
	for _, row := range list {
		if row.Path != path {
			continue
		}
		if row.Live {
			live = append(live, row)
		} else {
			historical = append(historical, row)
		}
	}
	if len(live) != 1 || !sameBranch(live[0].Branch, &topic) || live[0].Region != "obj_path" || len(historical) != 1 || !sameBranch(historical[0].Branch, &old) {
		t.Fatalf("live %v, historical %v", live, historical)
	}
	r.Worktrees[1].Region = "obj_missing"
	if got := r.Region(&topic, path, objects); got != "obj_path" {
		t.Fatalf("missing branch group prevented path fallback: %s", got)
	}
	r.Worktrees[1].Region = "obj_old"
	if got := r.Region(&topic, path, objects); got != "obj_old" {
		t.Fatalf("known branch region lost precedence: %s", got)
	}
	if got := r.Region(nil, path, objects); got != "obj_path" {
		t.Fatalf("detached HEAD lost its path region: %s", got)
	}
	runGit("worktree", "remove", "--force", worktree)
	var archived []WorktreeInfo
	for _, row := range r.WorktreeList(objects) {
		if row.Path == path {
			archived = append(archived, row)
			if row.Live {
				t.Fatalf("deleted worktree is live: %v", row)
			}
		}
	}
	if len(archived) != 3 {
		t.Fatalf("deleted worktree lost history: %v", archived)
	}
}
