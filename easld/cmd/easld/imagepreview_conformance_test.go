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
	scenarios, err = conformance.Select(scenarios, []string{"image-preview", "image-preview-raster"})
	if err != nil {
		t.Fatal(err)
	}
	srv := serve(t, filepath.Join(dir, "host"), false)
	defer srv.Close()
	report, err := suite.ReplayAll(scenarios, conformance.Options{Socket: srv.Path(), WorkDir: dir, Settle: 40 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Passed() {
		for _, result := range report.Scenarios {
			t.Errorf("%s: error=%s steps=%+v", result.Scenario, result.Error, result.Steps)
		}
	}
}
