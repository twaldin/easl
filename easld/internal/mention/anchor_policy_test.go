package mention

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/twaldin/easl/easld/internal/measure"
)

func TestRefusedFencesAreNotAnchored(t *testing.T) {
	board := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.rs")
	const marker = "DO_NOT_SHOW_OUTSIDE_HOST_68c1"
	if err := os.WriteFile(outside, []byte(marker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeFile(t, board, "inside.rs", "visible line\n")
	reading := measure.LinkReading{Root: board, Board: board}
	refused := "Authored prose\n\n```rs file=" + outside + "#L1\n```\n"
	if got := AnchoringRanges(refused, reading); got != refused {
		t.Fatalf("anchored a refused fence: %q", got)
	}
	allowed := "```rs file=inside.rs#L1\n```\n"
	if got := AnchoringRanges(allowed, reading); got != "```rs file=inside.rs#L1 anchor=\"visible line\"\n```\n" {
		t.Fatalf("allowed anchor %q", got)
	}
	status := NoteFences(refused+"\n"+allowed, reading)
	if len(status) != 2 {
		t.Fatalf("fences %v", status)
	}
	first := status[0].(map[string]any)
	if first["state"] != "stale" || first["reason"] != "path refused" || first["range"] != nil {
		t.Fatalf("refused status %v", first)
	}
	second := status[1].(map[string]any)
	if second["state"] != "live" || second["reason"] != nil {
		t.Fatalf("allowed status %v", second)
	}
}
