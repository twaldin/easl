package conformance

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
)

// StepResult is one step's verdict on replay.
type StepResult struct {
	Scenario string   `json:"scenario"`
	Index    int      `json:"index"`
	Step     string   `json:"step"`
	Method   string   `json:"method,omitempty"`
	Pass     bool     `json:"pass"`
	Diffs    []string `json:"diffs,omitempty"`
}

// ScenarioResult is one scenario's verdict; Error is set when it couldn't run at all.
type ScenarioResult struct {
	Scenario string       `json:"scenario"`
	Pass     bool         `json:"pass"`
	Error    string       `json:"error,omitempty"`
	Steps    []StepResult `json:"steps"`
}

// Report is a whole replay.
type Report struct {
	Socket    string            `json:"socket"`
	Scenarios []ScenarioResult  `json:"scenarios"`
	Delegated map[string]string `json:"delegated"`
	// Schema methods neither exercised by a scenario nor delegated.
	Uncovered []string `json:"uncovered,omitempty"`
	// The schema's methods; a step calling anything else (an unknown-method error) counts in
	// the family "(not in schema)".
	Known map[string]bool `json:"-"`
}

// Suite locates the scenarios, fixtures, delegated list and schema.
type Suite struct {
	Dir    string // conformance/
	Schema string // schema/easl-api.json
}

// FindSuite walks up from dir to the repository holding conformance/scenarios.
func FindSuite(dir string) (Suite, error) {
	for d := dir; ; d = filepath.Dir(d) {
		if st, err := os.Stat(filepath.Join(d, "conformance", "scenarios")); err == nil && st.IsDir() {
			return Suite{Dir: filepath.Join(d, "conformance"), Schema: filepath.Join(d, "schema", "easl-api.json")}, nil
		}
		if filepath.Dir(d) == d {
			return Suite{}, fmt.Errorf("no conformance/scenarios above %s", dir)
		}
	}
}

func (s Suite) fixturePath(name string) string {
	return filepath.Join(s.Dir, "fixtures", name+".json")
}

// Delegated reads the methods the suite leaves to the Mac client, with why.
func (s Suite) Delegated() (map[string]string, error) {
	data, err := os.ReadFile(filepath.Join(s.Dir, "delegated.json"))
	if err != nil {
		return nil, err
	}
	var out map[string]string
	return out, json.Unmarshal(data, &out)
}

// Select filters scenarios by name (all when names is empty).
func Select(all []Scenario, names []string) ([]Scenario, error) {
	if len(names) == 0 {
		return all, nil
	}
	byName := map[string]Scenario{}
	for _, s := range all {
		byName[s.Name] = s
	}
	var out []Scenario
	for _, n := range names {
		s, ok := byName[n]
		if !ok {
			return nil, fmt.Errorf("no scenario %q", n)
		}
		out = append(out, s)
	}
	return out, nil
}

// RecordAll runs scenarios and writes their fixtures.
func (s Suite) RecordAll(scenarios []Scenario, o Options, recordedOn string, log io.Writer) error {
	if err := os.MkdirAll(filepath.Join(s.Dir, "fixtures"), 0o755); err != nil {
		return err
	}
	for _, sc := range scenarios {
		records, err := RunScenario(sc, o)
		if err != nil {
			return fmt.Errorf("%s: %w", sc.Name, err)
		}
		for i, r := range records {
			if len(r.Unsubscribed) > 0 {
				return fmt.Errorf("%s step %d (%s): not recorded: %s", sc.Name, i, r.Step, unsubscribedDiff(r.Unsubscribed))
			}
		}
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", "  ")
		if err := enc.Encode(Fixture{Scenario: sc.Name, Description: sc.Description, RecordedOn: recordedOn, Steps: records}); err != nil {
			return err
		}
		if err := os.WriteFile(s.fixturePath(sc.Name), buf.Bytes(), 0o644); err != nil {
			return err
		}
		fmt.Fprintf(log, "recorded %s (%d steps)\n", sc.Name, len(records))
	}
	return nil
}

// ReplayAll runs scenarios and compares each with its fixture.
func (s Suite) ReplayAll(scenarios []Scenario, o Options) (Report, error) {
	report := Report{Socket: o.Socket}
	delegated, err := s.Delegated()
	if err != nil {
		return report, err
	}
	report.Delegated = delegated
	for _, sc := range scenarios {
		report.Scenarios = append(report.Scenarios, s.replay(sc, o))
	}
	if all, err := LoadScenarios(filepath.Join(s.Dir, "scenarios")); err == nil {
		report.Uncovered = s.uncovered(all, delegated)
	}
	report.Known = s.methods()
	return report, nil
}

func (s Suite) replay(sc Scenario, o Options) ScenarioResult {
	result := ScenarioResult{Scenario: sc.Name}
	data, err := os.ReadFile(s.fixturePath(sc.Name))
	if err != nil {
		result.Error = "no fixture: " + err.Error()
		return result
	}
	var fixture Fixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		result.Error = "bad fixture: " + err.Error()
		return result
	}
	got, err := RunScenario(sc, o)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.Pass = true
	for i, want := range fixture.Steps {
		step := StepResult{Scenario: sc.Name, Index: i, Step: want.Step, Method: want.Method}
		if i >= len(got) {
			step.Diffs = []string{"step missing from the run"}
		} else {
			step.Diffs = diffRecords(want, got[i])
		}
		step.Pass = len(step.Diffs) == 0
		result.Pass = result.Pass && step.Pass
		result.Steps = append(result.Steps, step)
	}
	if len(got) != len(fixture.Steps) {
		result.Pass = false
	}
	return result
}

// diffRecords compares two transcripts of a step as JSON values (so a fixture written to disk
// and a fresh run compare alike) and names the paths that differ. Events on a connection that
// never subscribed fail the step whatever the fixture says (a recording never has them).
func diffRecords(want, got Record) []string {
	var diffs []string
	if len(got.Unsubscribed) > 0 {
		diffs = append(diffs, unsubscribedDiff(got.Unsubscribed))
	}
	want.Unsubscribed, got.Unsubscribed = nil, nil
	var w, g any
	roundTrip(want, &w)
	roundTrip(got, &g)
	diffValues("", w, g, &diffs)
	return diffs
}

func unsubscribedDiff(events []any) string {
	var names []string
	for _, e := range events {
		m, _ := e.(map[string]any)
		names = append(names, fmt.Sprintf("%v on %v", m["event"], m["conn"]))
	}
	return "events on connections that never subscribed: " + strings.Join(names, ", ")
}

func roundTrip(v any, out *any) {
	data, _ := json.Marshal(v)
	json.Unmarshal(data, out)
}

const maxDiffs = 8

func diffValues(path string, want, got any, diffs *[]string) {
	if len(*diffs) >= maxDiffs || reflect.DeepEqual(want, got) {
		return
	}
	switch w := want.(type) {
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			break
		}
		keys := map[string]bool{}
		for k := range w {
			keys[k] = true
		}
		for k := range g {
			keys[k] = true
		}
		sorted := make([]string, 0, len(keys))
		for k := range keys {
			sorted = append(sorted, k)
		}
		sort.Strings(sorted)
		// A key's presence is compared before its value: an absent key and an explicit null
		// (`props.title: null`, a removal) are different answers.
		for _, k := range sorted {
			wv, inWant := w[k]
			gv, inGot := g[k]
			switch {
			case len(*diffs) >= maxDiffs:
				return
			case !inGot:
				*diffs = append(*diffs, fmt.Sprintf("%s: absent, want %s", join(path, k), short(wv)))
			case !inWant:
				*diffs = append(*diffs, fmt.Sprintf("%s: got %s, want it absent", join(path, k), short(gv)))
			default:
				diffValues(join(path, k), wv, gv, diffs)
			}
		}
		return
	case []any:
		g, ok := got.([]any)
		if !ok {
			break
		}
		if len(w) != len(g) {
			*diffs = append(*diffs, fmt.Sprintf("%s: %d items, want %d", orRoot(path), len(g), len(w)))
		}
		for i := 0; i < len(w) && i < len(g); i++ {
			diffValues(join(path, fmt.Sprint(i)), w[i], g[i], diffs)
		}
		return
	}
	*diffs = append(*diffs, fmt.Sprintf("%s: got %s, want %s", orRoot(path), short(got), short(want)))
}

func join(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

func orRoot(path string) string {
	if path == "" {
		return "(record)"
	}
	return path
}

func short(v any) string {
	data, _ := json.Marshal(v)
	s := string(data)
	if len(s) > 160 {
		s = s[:157] + "..."
	}
	return s
}

// methods are the schema's method names (nil when the schema can't be read).
func (s Suite) methods() map[string]bool {
	data, err := os.ReadFile(s.Schema)
	if err != nil {
		return nil
	}
	var schema struct {
		Methods map[string]any `json:"methods"`
	}
	if json.Unmarshal(data, &schema) != nil {
		return nil
	}
	out := map[string]bool{}
	for m := range schema.Methods {
		out[m] = true
	}
	return out
}

// uncovered lists schema methods no scenario calls and the delegated list doesn't name.
func (s Suite) uncovered(all []Scenario, delegated map[string]string) []string {
	data, err := os.ReadFile(s.Schema)
	if err != nil {
		return nil
	}
	var schema struct {
		Methods map[string]any `json:"methods"`
	}
	if json.Unmarshal(data, &schema) != nil {
		return nil
	}
	called := map[string]bool{"board.open": true, "events.subscribe": true}
	for _, sc := range all {
		for _, st := range sc.Steps {
			called[st.Call] = true
			collectBatchMethods(st.Params, called)
		}
	}
	var out []string
	for m := range schema.Methods {
		if !called[m] && delegated[m] == "" {
			out = append(out, m)
		}
	}
	sort.Strings(out)
	return out
}

func collectBatchMethods(v any, into map[string]bool) {
	params, _ := v.(map[string]any)
	ops, _ := params["ops"].([]any)
	for _, op := range ops {
		if m, ok := op.(map[string]any)["method"].(string); ok {
			into[m] = true
		}
	}
}

// Family is a method's namespace: "object" for object.create.
func Family(method string) string {
	if i := strings.IndexByte(method, '.'); i > 0 {
		return method[:i]
	}
	if method == "" {
		return "harness"
	}
	return method
}

type tally struct{ pass, total int }

// Print writes the pass/fail tables: scenarios, then methods by family.
func (r Report) Print(w io.Writer) {
	fmt.Fprintf(w, "easl API conformance against %s\n\n", r.Socket)
	fmt.Fprintf(w, "%-28s %-6s %s\n", "SCENARIO", "RESULT", "STEPS")
	methods := map[string]*tally{}
	families := map[string]*tally{}
	var failures []string
	passed := 0
	for _, sc := range r.Scenarios {
		ok := 0
		for _, st := range sc.Steps {
			name := st.Method
			if name == "" {
				name = "(harness: " + strings.SplitN(st.Step, " ", 2)[0] + ")"
			}
			if methods[name] == nil {
				methods[name] = &tally{}
			}
			fam := Family(st.Method)
			if st.Method != "" && r.Known != nil && !r.Known[st.Method] {
				fam = "(not in schema)"
			}
			if families[fam] == nil {
				families[fam] = &tally{}
			}
			methods[name].total++
			families[fam].total++
			if st.Pass {
				ok++
				methods[name].pass++
				families[fam].pass++
			} else {
				failures = append(failures, fmt.Sprintf("%s step %d (%s):\n    %s", sc.Scenario, st.Index, st.Step, strings.Join(st.Diffs, "\n    ")))
			}
		}
		verdict := "FAIL"
		if sc.Pass {
			verdict = "pass"
			passed++
		}
		detail := fmt.Sprintf("%d/%d", ok, len(sc.Steps))
		if sc.Error != "" {
			detail = "error: " + sc.Error
			failures = append(failures, fmt.Sprintf("%s: %s", sc.Scenario, sc.Error))
		}
		fmt.Fprintf(w, "%-28s %-6s %s\n", sc.Scenario, verdict, detail)
	}

	fmt.Fprintf(w, "\n%-28s %s\n", "METHOD", "STEPS PASSED")
	printTallies(w, methods)
	fmt.Fprintf(w, "\n%-28s %s\n", "FAMILY", "STEPS PASSED")
	printTallies(w, families)

	if len(r.Delegated) > 0 {
		fmt.Fprintf(w, "\nClient-delegated (not replayed):\n")
		names := make([]string, 0, len(r.Delegated))
		for m := range r.Delegated {
			names = append(names, m)
		}
		sort.Strings(names)
		for _, m := range names {
			fmt.Fprintf(w, "  %-20s %s\n", m, r.Delegated[m])
		}
	}
	if len(r.Uncovered) > 0 {
		fmt.Fprintf(w, "\nSchema methods with no scenario and not delegated: %s\n", strings.Join(r.Uncovered, ", "))
	}
	if len(failures) > 0 {
		fmt.Fprintf(w, "\nFailures:\n")
		for _, f := range failures {
			fmt.Fprintf(w, "  %s\n", f)
		}
	}
	fmt.Fprintf(w, "\n%d/%d scenarios pass\n", passed, len(r.Scenarios))
}

func printTallies(w io.Writer, t map[string]*tally) {
	names := make([]string, 0, len(t))
	for n := range t {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		mark := ""
		if t[n].pass < t[n].total {
			mark = "  ✗"
		}
		fmt.Fprintf(w, "%-28s %d/%d%s\n", n, t[n].pass, t[n].total, mark)
	}
}

// Passed reports whether every scenario passed and nothing was left uncovered.
func (r Report) Passed() bool {
	for _, sc := range r.Scenarios {
		if !sc.Pass {
			return false
		}
	}
	return len(r.Uncovered) == 0
}
