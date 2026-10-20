package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/twaldin/easl/conformance"
)

func TestImagePreviewConformance(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "easld-preview-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	suite, err := conformance.FindSuite(wd)
	if err != nil {
		t.Fatal(err)
	}
	scenarios, err := conformance.LoadScenarios(filepath.Join(suite.Dir, "scenarios"))
	if err != nil {
		t.Fatal(err)
	}
	srv := serve(t, filepath.Join(dir, "host"), false)
	defer srv.Close()
	for _, scenario := range scenarios {
		if scenario.Name != "image-preview" {
			continue
		}
		_, err := conformance.RunScenario(scenario, conformance.Options{Socket: srv.Path(), WorkDir: dir, Schema: suite.Schema, Settle: 40 * time.Millisecond})
		if err != nil {
			t.Fatal(err)
		}
		return
	}
	t.Fatal("missing image-preview conformance scenario")
}
