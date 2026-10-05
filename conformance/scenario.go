package conformance

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Scenario is one scripted conversation with the server, on a board of its own: a fresh
// directory (optionally a git repository with fixed commit dates, so commit ids are the same on
// every run) opened with board.open, with an event subscription to that board.
type Scenario struct {
	Name        string `json:"-"`
	Description string `json:"description"`
	// Files written into the scenario directory before it opens ("base64:…" for binary content).
	Files map[string]string `json:"files,omitempty"`
	Git   bool              `json:"git,omitempty"`
	// Pages served over http on 127.0.0.1 while the scenario runs, by path ("/page": "<html>…"),
	// for browser tiles that must load something real. `{{httpHost}}` is the server's host:port,
	// recorded as `<http-host>`.
	Serve map[string]string `json:"serve,omitempty"`
	// Paths (as in Step.Ignore) ignored in every step, with the reason.
	Ignore map[string]string `json:"ignore,omitempty"`
	// Paths (as in Step.Ignore) of arrays listed in no particular order, compared sorted, with
	// the reason; applied in every step.
	Unordered map[string]string `json:"unordered,omitempty"`
	Steps     []Step            `json:"steps"`
}

// Step is one request, or one harness action. Strings in params may hold templates:
// `{{board}}`, `{{root}}`, `{{name.path.to.value}}` (a saved step's result; numeric path parts
// index arrays). A string that is only a template becomes the value itself (a number stays a
// number); inside a longer string it is spliced in as text.
type Step struct {
	Call   string `json:"call,omitempty"`
	Params any    `json:"params,omitempty"`
	// Connection name; default "main". Each name is its own socket connection.
	Conn string `json:"conn,omitempty"`
	// Remember the result under this name for templates (and for Await).
	Save string `json:"save,omitempty"`
	// Send without waiting for the reply; a later step `await`s it.
	Async bool   `json:"async,omitempty"`
	Await string `json:"await,omitempty"`
	// A raw line sent as-is (framing: malformed JSON, missing method).
	Raw *string `json:"raw,omitempty"`
	// Harness file actions in the scenario directory: the content is recorded and compared.
	ReadFile  string     `json:"readFile,omitempty"`
	WriteFile *WriteFile `json:"writeFile,omitempty"`
	SleepMs   int        `json:"sleepMs,omitempty"`
	// Extra time to let events arrive after this step (default: the runner's settle time).
	SettleMs int `json:"settleMs,omitempty"`
	// Record paths left out of the comparison (value and presence), with the reason:
	// `response.result.object.props.title`, `events.*.data.frame`; `*` matches any key or index.
	Ignore map[string]string `json:"ignore,omitempty"`
	// Parts of the strings at record paths (as in Ignore) left out of the comparison: the
	// matches of `match` become `as`, and the rest of the string is still compared.
	Mask map[string]Mask `json:"mask,omitempty"`
	// Arrays compared as sets (sorted first), with the reason.
	Unordered map[string]string `json:"unordered,omitempty"`
	// Keep only the array elements at a response path whose fields equal the given ones
	// (templates expanded): `{"result.boards": {"board": "{{board}}"}}` keeps this scenario's
	// board out of a list that holds every board the server ever stored.
	Keep map[string]map[string]any `json:"keep,omitempty"`
	// The result is the server's own measurements (app.metrics): instead of being compared,
	// it is checked against the method's result schema, and the transcript keeps the verdict.
	// The value says why.
	Shape string `json:"shape,omitempty"`
	// Drop the step's events (a step whose events depend on timing the scenario can't control).
	NoEvents bool   `json:"noEvents,omitempty"`
	Note     string `json:"note,omitempty"`
}

type WriteFile struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// Mask is one Step.Mask rule.
type Mask struct {
	Match string `json:"match"` // a Go regular expression
	As    string `json:"as"`    // its replacement ($1 for a group)
	Why   string `json:"why"`
}

// Label names a step in reports: its method, or the harness action.
func (s Step) Label() string {
	switch {
	case s.Call != "":
		return s.Call
	case s.Await != "":
		return "await " + s.Await
	case s.Raw != nil:
		return "raw line"
	case s.ReadFile != "":
		return "read " + s.ReadFile
	case s.WriteFile != nil:
		return "write " + s.WriteFile.Path
	case s.SleepMs > 0:
		return "sleep"
	}
	return "?"
}

// LoadScenarios reads every scenario file in dir, sorted by name.
func LoadScenarios(dir string) ([]Scenario, error) {
	paths, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	var out []Scenario
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var s Scenario
		if err := json.Unmarshal(data, &s); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		s.Name = strings.TrimSuffix(filepath.Base(path), ".json")
		for i, st := range s.Steps {
			for p, m := range st.Mask {
				if _, err := regexp.Compile(m.Match); err != nil {
					return nil, fmt.Errorf("%s: step %d: mask %s: %w", path, i, p, err)
				}
			}
		}
		out = append(out, s)
	}
	return out, nil
}

var templatePattern = regexp.MustCompile(`\{\{([^}]+)\}\}`)

// expand resolves templates in v against vars (board, root) and saved results.
func expand(v any, vars map[string]any) (any, error) {
	switch x := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			r, err := expand(e, vars)
			if err != nil {
				return nil, err
			}
			out[k] = r
		}
		return out, nil
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			r, err := expand(e, vars)
			if err != nil {
				return nil, err
			}
			out[i] = r
		}
		return out, nil
	case string:
		if m := templatePattern.FindStringSubmatch(x); m != nil && m[0] == x {
			return lookup(vars, m[1])
		}
		var failure error
		out := templatePattern.ReplaceAllStringFunc(x, func(t string) string {
			r, err := lookup(vars, templatePattern.FindStringSubmatch(t)[1])
			if err != nil {
				failure = err
				return t
			}
			if s, ok := r.(string); ok {
				return s
			}
			b, _ := json.Marshal(r)
			return string(b)
		})
		return out, failure
	default:
		return v, nil
	}
}

func lookup(vars map[string]any, path string) (any, error) {
	var cur any = vars
	for _, part := range strings.Split(strings.TrimSpace(path), ".") {
		switch c := cur.(type) {
		case map[string]any:
			next, ok := c[part]
			if !ok {
				return nil, fmt.Errorf("template {{%s}}: no %q", path, part)
			}
			cur = next
		case []any:
			i, err := strconv.Atoi(part)
			if err != nil || i < 0 || i >= len(c) {
				return nil, fmt.Errorf("template {{%s}}: bad index %q", path, part)
			}
			cur = c[i]
		default:
			return nil, fmt.Errorf("template {{%s}}: %q is not inside an object or array", path, part)
		}
	}
	return cur, nil
}
