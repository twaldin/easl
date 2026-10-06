package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/conformance"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/router"
	"github.com/twaldin/easl/easld/internal/server"
	"github.com/twaldin/easl/easld/internal/store"
)

// passing are the conformance scenarios (conformance/scenarios) easld answers exactly as the
// app did when they were recorded. The test fails when one of them stops passing; a scenario
// that starts passing is reported, so it can join the list.
var passing = []string{
	"agents", "arrows", "batch", "board-get-history", "boards", "client-delegation", "client-failures", "client-versions",
	"code-tiles", "events", "follow-attention", "groups", "keys-upsert-find", "layout", "layout-check", "metrics",
	"no-client", "objects-crud", "open-url", "placement", "protocol", "questions", "tray",
}

// Not passing, and why:
//   - measure-notes: recorded against the app, whose AppKit measured its notes and text shapes
//     exactly (SF Pro, TextKit 2; Shantell Sans with GPOS kerning). With no client attached easld
//     measures them from the glyph table (measure/glyphs): within a few points, and marked
//     `approximate: true`. client-delegation replays exact measurement through a scripted client.

// The suite replayed against easld in-process: a fresh home, the real router and socket server.
func TestConformance(t *testing.T) {
	if testing.Short() {
		t.Skip("replays the whole conformance suite")
	}
	// Unix socket paths are short (104 bytes on macOS), and TMPDIR there is long.
	dir, err := os.MkdirTemp("/tmp", "easld-conformance-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	reg := board.NewRegistry(filepath.Join(dir, "boards"), store.DefaultDebounce, filepath.Join(dir, "agent-reports"))
	r := router.New(reg)
	srv, err := server.Listen(filepath.Join(dir, "easl.sock"), r.Handle, r.Answer)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()

	wd, _ := os.Getwd()
	suite, err := conformance.FindSuite(wd)
	if err != nil {
		t.Fatal(err)
	}
	scenarios, err := conformance.LoadScenarios(filepath.Join(suite.Dir, "scenarios"))
	if err != nil {
		t.Fatal(err)
	}
	report, err := suite.ReplayAll(scenarios, conformance.Options{Socket: srv.Path(), WorkDir: dir, Settle: 40 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	var table strings.Builder
	report.Print(&table)
	t.Log("\n" + table.String())

	expected := map[string]bool{}
	for _, name := range passing {
		expected[name] = true
	}
	for _, sc := range report.Scenarios {
		switch {
		case expected[sc.Scenario] && !sc.Pass:
			t.Errorf("scenario %s no longer passes (see the table above)", sc.Scenario)
		case !expected[sc.Scenario] && sc.Pass:
			t.Logf("scenario %s passes now: add it to `passing`", sc.Scenario)
		}
		delete(expected, sc.Scenario)
	}
	for name := range expected {
		t.Errorf("`passing` names %s, which is no scenario (renamed or removed?)", name)
	}
	if len(report.Uncovered) > 0 {
		t.Errorf("schema methods with no scenario and not delegated: %v", report.Uncovered)
	}
}
