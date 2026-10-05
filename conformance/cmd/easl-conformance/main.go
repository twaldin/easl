// Command easl-conformance records and replays the easl API conformance suite (docs/testing.md).
//
//	easl-conformance replay [--socket path] [--json out.json] [scenario…]
//	easl-conformance record [--socket path] [--on "label"] [scenario…]
//
// The socket defaults to $EASL_SOCKET. replay prints a pass/fail table and exits 1 on any failure.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/twaldin/easl/conformance"
)

func main() {
	if len(os.Args) < 2 || (os.Args[1] != "record" && os.Args[1] != "replay") {
		fmt.Fprintln(os.Stderr, "usage: easl-conformance record|replay [--socket path] [scenario…]")
		os.Exit(2)
	}
	mode := os.Args[1]
	flags := flag.NewFlagSet(mode, flag.ExitOnError)
	socket := flags.String("socket", os.Getenv("EASL_SOCKET"), "server socket (default $EASL_SOCKET)")
	settle := flags.Duration("settle", 120*time.Millisecond, "quiet time that ends a step's events")
	jsonOut := flags.String("json", "", "replay: also write the report as JSON to this file")
	on := flags.String("on", "", "record: what the fixtures were recorded against")
	dir := flags.String("dir", "", "repository root (default: found above the working directory)")
	flags.Parse(os.Args[2:])
	if *socket == "" {
		fail("no socket: pass --socket or set EASL_SOCKET")
	}
	start := *dir
	if start == "" {
		start, _ = os.Getwd()
	}
	suite, err := conformance.FindSuite(start)
	check(err)
	all, err := conformance.LoadScenarios(filepath.Join(suite.Dir, "scenarios"))
	check(err)
	scenarios, err := conformance.Select(all, flags.Args())
	check(err)
	options := conformance.Options{Socket: *socket, Settle: *settle}

	if mode == "record" {
		check(suite.RecordAll(scenarios, options, *on, os.Stdout))
		return
	}
	report, err := suite.ReplayAll(scenarios, options)
	check(err)
	report.Print(os.Stdout)
	if *jsonOut != "" {
		data, _ := json.MarshalIndent(report, "", "  ")
		check(os.WriteFile(*jsonOut, data, 0o644))
	}
	if !report.Passed() {
		os.Exit(1)
	}
}

func check(err error) {
	if err != nil {
		fail(err.Error())
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "easl-conformance:", msg)
	os.Exit(2)
}
