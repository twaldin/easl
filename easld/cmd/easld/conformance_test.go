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
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/session/zmxtest"
	"github.com/twaldin/easl/easld/internal/store"
)

// passing are the conformance scenarios (conformance/scenarios) easld answers exactly as the
// app did when they were recorded. The test fails when one of them stops passing; a scenario
// that starts passing is reported, so it can join the list.
var passing = []string{
	"agent-control", "agents", "arrows", "batch", "board-get-history", "boards", "client-delegation", "client-failures", "client-mode", "client-versions",
	"code-tiles", "events", "follow-attention", "groups", "keys-upsert-find", "layout", "layout-check", "messages",
	"metrics", "no-client", "objects-crud", "open-url", "owned-terminals", "placement", "protocol", "questions", "tray",
}

// Not passing, and why:
//   - measure-notes: recorded against the app, whose AppKit measured its notes and text shapes
//     exactly (SF Pro, TextKit 2; Shantell Sans with GPOS kerning). With no client attached easld
//     measures them from the glyph table (measure/glyphs): within a few points, and marked
//     `approximate: true`. client-delegation replays exact measurement through a scripted client.

// owning are the scenarios replayed against an easld that owns its boards' terminals
// (--own-terminals), with a zmx that runs no session (zmxtest); the rest run against one in its
// default mode (an easld on a Mac, where the app runs its terminals): no zmx, no ownership.
var owning = map[string]bool{"owned-terminals": true}

// The suite replayed against easld in-process: a fresh home, the real router and socket server,
// in the mode each scenario needs (owning).
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

	wd, _ := os.Getwd()
	suite, err := conformance.FindSuite(wd)
	if err != nil {
		t.Fatal(err)
	}
	scenarios, err := conformance.LoadScenarios(filepath.Join(suite.Dir, "scenarios"))
	if err != nil {
		t.Fatal(err)
	}
	var plain, owned []conformance.Scenario
	for _, sc := range scenarios {
		if owning[sc.Name] {
			owned = append(owned, sc)
		} else {
			plain = append(plain, sc)
		}
	}
	var results []conformance.ScenarioResult
	var uncovered []string
	var table strings.Builder
	for _, run := range []struct {
		home      string
		own       bool
		scenarios []conformance.Scenario
	}{{filepath.Join(dir, "default"), false, plain}, {filepath.Join(dir, "owning"), true, owned}} {
		srv := serve(t, run.home, run.own)
		report, err := suite.ReplayAll(run.scenarios, conformance.Options{Socket: srv.Path(), WorkDir: dir, Settle: 40 * time.Millisecond})
		srv.Close()
		if err != nil {
			t.Fatal(err)
		}
		report.Print(&table)
		results = append(results, report.Scenarios...)
		// Uncovered is the whole suite's (every scenario on disk), the same for both runs.
		uncovered = report.Uncovered
	}
	t.Log("\n" + table.String())

	expected := map[string]bool{}
	for _, name := range passing {
		expected[name] = true
	}
	for _, sc := range results {
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
	if len(uncovered) > 0 {
		t.Errorf("schema methods with no scenario and not delegated: %v", uncovered)
	}
}

// serve is easld on `home` (its socket there): by default, or owning its boards' terminals with
// zmxtest's zmx (--own-terminals).
func serve(t *testing.T, home string, own bool) *server.Server {
	t.Helper()
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(home, "easl.sock")
	reg := board.NewRegistry(filepath.Join(home, "boards"), store.DefaultDebounce, filepath.Join(home, "agent-reports"))
	r := router.New(reg)
	if own {
		zmx, err := zmxtest.Install(home)
		if err != nil {
			t.Fatal(err)
		}
		r.Sessions = session.New(zmx, filepath.Join(home, "sessions"))
		r.Owns = &session.Owner{Socket: socket, Home: home, Resources: session.Resources(r.Sessions.Home)}
	}
	srv, err := server.Listen(socket, r.Handle, r.Answer)
	if err != nil {
		t.Fatal(err)
	}
	return srv
}
