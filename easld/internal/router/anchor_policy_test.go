package router

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCreateAndUpdateDoNotAnchorOutsideFiles(t *testing.T) {
	f := newFixture(t)
	const marker = "DO_NOT_SHOW_OUTSIDE_HOST_68c1"
	outside := filepath.Join(t.TempDir(), "outside.rs")
	if err := os.WriteFile(outside, []byte(marker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(filepath.Dir(f.board.Root()), "outside.rs"), []byte(marker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(f.board.Root(), "escape.rs")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.board.Root(), "inside.rs"), []byte("visible line\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	for i, markdown := range []string{
		"Authored prose\n\n```rs file=" + outside + "#L1\n```\n",
		"Authored prose\n\n```rs file=../outside.rs#L1\n```\n",
		"Authored prose\n\n```rs file=escape.rs#L1\n```\n",
		"Authored prose\n\n```rs file=" + outside + "#L1 anchor=\"kept\"\n```\n",
	} {
		created := f.result("object.create", note(float64(i*350), map[string]any{"markdown": markdown}))
		got := created["object"].(map[string]any)["props"].(map[string]any)["markdown"].(string)
		if got != markdown || strings.Contains(got, marker) {
			t.Errorf("create %d markdown %q", i, got)
		}
		id := created["object"].(map[string]any)["id"].(string)
		fence := f.result("object.get", map[string]any{"id": id})["fences"].([]any)[0].(map[string]any)
		if fence["state"] != "stale" || fence["reason"] != "path refused" || fence["range"] != nil || fence["written"] != nil {
			t.Errorf("create %d status %v", i, fence)
		}
	}

	allowed := "Authored prose\n\n```rs file=inside.rs#L1\n```\n"
	created := f.result("object.create", note(1400, map[string]any{"markdown": allowed}))
	got := created["object"].(map[string]any)["props"].(map[string]any)["markdown"].(string)
	if got != "Authored prose\n\n```rs file=inside.rs#L1 anchor=\"visible line\"\n```\n" || strings.Contains(got, marker) {
		t.Fatalf("allowed create %q", got)
	}
	id := created["object"].(map[string]any)["id"].(string)
	live := f.result("object.get", map[string]any{"id": id})["fences"].([]any)[0].(map[string]any)
	if live["state"] != "live" || live["reason"] != nil {
		t.Fatalf("allowed status %v", live)
	}

	updatedMD := "Kept prose\n\n```rs file=" + outside + "#L1\n```\n"
	updated := f.result("object.update", map[string]any{"id": id, "props": map[string]any{"markdown": updatedMD}})
	got = updated["object"].(map[string]any)["props"].(map[string]any)["markdown"].(string)
	if got != updatedMD || strings.Contains(got, marker) {
		t.Fatalf("refused update %q", got)
	}
	moved := f.result("object.update", map[string]any{"id": id, "props": map[string]any{"markdown": "```rs file=inside.rs#L1\n```\n"}})
	got = moved["object"].(map[string]any)["props"].(map[string]any)["markdown"].(string)
	if got != "```rs file=inside.rs#L1 anchor=\"visible line\"\n```\n" {
		t.Fatalf("allowed update %q", got)
	}

	code := f.result("object.create", map[string]any{
		"type": "code",
		"props": map[string]any{
			"path":  outside,
			"range": map[string]any{"start": 1.0, "end": 1.0},
		},
		"frame": map[string]any{"x": 0.0, "y": 500.0, "w": 200.0, "h": 100.0},
	})
	codeID := code["object"].(map[string]any)["id"].(string)
	rangeStatus := f.result("object.get", map[string]any{"id": codeID})["rangeStatus"].(map[string]any)
	if rangeStatus["state"] != "live" || rangeStatus["reason"] != nil {
		t.Fatalf("code tile outside the board %v", rangeStatus)
	}
}

func TestSourceOverrideDoesNotAuthorizeOutsideTheBoard(t *testing.T) {
	parent := t.TempDir()
	repo := filepath.Join(parent, "repo")
	outside := filepath.Join(parent, "outside")
	if err := os.MkdirAll(filepath.Join(repo, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "init", "-q", "-b", "main")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	const marker = "DO_NOT_SHOW_OUTSIDE_HOST_68c1"
	if err := os.WriteFile(filepath.Join(outside, "secret.rs"), []byte(marker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "src", "a.rs"), []byte("src line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-q", "-m", "one")

	f := newFixture(t)
	id := f.result("board.open", map[string]any{"root": repo})["board"].(string)
	created := f.result("object.create", map[string]any{
		"board": id,
		"type":  "note",
		"props": map[string]any{"root": outside, "markdown": "```rs file=secret.rs#L1\n```\n"},
		"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0},
	})
	got := created["object"].(map[string]any)["props"].(map[string]any)["markdown"].(string)
	if strings.Contains(got, marker) || strings.Contains(got, "anchor=") {
		t.Fatalf("outside-root override %q", got)
	}
	noteID := created["object"].(map[string]any)["id"].(string)
	fence := f.result("object.get", map[string]any{"id": noteID})["fences"].([]any)[0].(map[string]any)
	if fence["state"] != "stale" || fence["reason"] != "path refused" || fence["range"] != nil {
		t.Fatalf("override status %v", fence)
	}

	allowed := f.result("object.create", map[string]any{
		"board": id,
		"type":  "note",
		"props": map[string]any{"root": "src", "markdown": "```rs file=a.rs#L1\n```\n"},
		"frame": map[string]any{"x": 300.0, "y": 0.0, "w": 200.0, "h": 100.0},
	})
	got = allowed["object"].(map[string]any)["props"].(map[string]any)["markdown"].(string)
	if got != "```rs file=a.rs#L1 anchor=\"src line\"\n```\n" {
		t.Fatalf("in-board override %q", got)
	}
}
