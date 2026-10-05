package conformance

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Options configure a run against one server socket.
type Options struct {
	Socket string
	// Where scenario directories are created; default os.TempDir().
	WorkDir string
	// How long an event subscription must stay quiet after a step before its events are taken.
	Settle time.Duration
	// How long to wait for a reply.
	Timeout time.Duration
}

func (o Options) withDefaults() Options {
	if o.Settle == 0 {
		o.Settle = 120 * time.Millisecond
	}
	if o.Timeout == 0 {
		o.Timeout = 30 * time.Second
	}
	if o.WorkDir == "" {
		o.WorkDir = os.TempDir()
	}
	return o
}

// Record is one step as it happened, normalised: what was sent, what came back, and the events
// subscribed connections received before the next step.
type Record struct {
	Step     string `json:"step"`
	Method   string `json:"method,omitempty"`
	Conn     string `json:"conn,omitempty"`
	Request  any    `json:"request,omitempty"`
	Response any    `json:"response,omitempty"`
	Events   []any  `json:"events,omitempty"`
	Content  any    `json:"content,omitempty"`
	// Events that arrived on connections that never subscribed (each with its `conn`): the
	// transport sends event lines only after a successful events.subscribe, so any fails the
	// step, and a recording that has them is refused.
	Unsubscribed []any `json:"unsubscribedEvents,omitempty"`
	// Paths left out of the comparison, with why.
	Ignored map[string]string `json:"ignored,omitempty"`
	// Paths whose text had a part masked (Step.Mask), with why.
	Masked map[string]string `json:"masked,omitempty"`
}

// Fixture is a scenario's recorded transcript.
type Fixture struct {
	Scenario    string   `json:"scenario"`
	Description string   `json:"description"`
	RecordedOn  string   `json:"recordedOn,omitempty"`
	Steps       []Record `json:"steps"`
}

// eventsConn is the connection every scenario subscribes to its board's events on.
const eventsConn = "events"

// RunScenario runs one scenario on a fresh board and returns its normalised transcript. An error
// means the harness couldn't run it (no socket, a template naming a value that isn't there), not
// that the server answered differently.
func RunScenario(s Scenario, o Options) ([]Record, error) {
	o = o.withDefaults()
	base, err := filepath.EvalSymlinks(o.WorkDir)
	if err != nil {
		return nil, err
	}
	run, err := os.MkdirTemp(base, "easl-conformance-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(run)
	root := filepath.Join(run, s.Name)
	if err := setup(root, s); err != nil {
		return nil, fmt.Errorf("setting up %s: %w", s.Name, err)
	}

	home, _ := os.UserHomeDir()
	paths := []pathSubst{{root, "<root>"}, {run, "<run>"}}
	vars := map[string]any{"root": root}
	if len(s.Serve) > 0 {
		pages := http.NewServeMux()
		for path, body := range s.Serve {
			body := body
			pages.HandleFunc(path, func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				io.WriteString(w, body)
			})
		}
		web := httptest.NewServer(pages)
		defer web.Close()
		host := strings.TrimPrefix(web.URL, "http://")
		vars["httpHost"] = host
		paths = append(paths, pathSubst{host, "<http-host>"})
	}
	if alt := strings.TrimPrefix(root, "/private"); alt != root {
		paths = append(paths, pathSubst{alt, "<root>"})
	}
	if home != "" {
		paths = append(paths, pathSubst{home, "~"})
	}
	norm := newNormalizer(paths)
	// Ids the scenario writes itself (`obj_missing`) are the same for every server: they stay
	// as they are.
	for _, st := range s.Steps {
		for _, id := range literalIDs(st.Params, nil) {
			norm.alias(id, id)
		}
	}

	conns := map[string]*conn{}
	subscribed := map[string]bool{}
	defer func() {
		for _, c := range conns {
			c.close()
		}
	}()
	get := func(name string) (*conn, error) {
		if c, ok := conns[name]; ok {
			return c, nil
		}
		c, err := dial(o.Socket)
		if err != nil {
			return nil, err
		}
		conns[name] = c
		return c, nil
	}

	type pending struct {
		conn, id string
		index    int
	}
	asyncs := map[string]pending{}
	var records []Record
	var raw []rawRecord

	steps := append([]Step{
		{Call: "board.open", Params: map[string]any{"root": "{{root}}"}, Save: "open"},
		{Call: "events.subscribe", Params: map[string]any{"board": "{{board}}"}, Conn: eventsConn},
	}, s.Steps...)

	for i, step := range steps {
		connName := step.Conn
		if connName == "" {
			connName = "main"
		}
		r := rawRecord{step: step, conn: connName}
		switch {
		case step.Call != "":
			c, err := get(connName)
			if err != nil {
				return nil, err
			}
			params, err := expand(orEmpty(step.Params), vars)
			if err != nil {
				return nil, fmt.Errorf("step %d (%s): %w", i, step.Label(), err)
			}
			r.request = params
			id, err := c.send(step.Call, params)
			if err != nil {
				return nil, err
			}
			if step.Async {
				asyncs[step.Save] = pending{connName, id, len(raw)}
				r.response = nil
				break
			}
			resp, err := c.await(id, o.Timeout)
			if err != nil {
				return nil, fmt.Errorf("step %d (%s): %w", i, step.Label(), err)
			}
			if step.Call == "board.history" {
				dropClientEntries(params, resp)
			}
			if err := keep(resp, step.Keep, vars); err != nil {
				return nil, fmt.Errorf("step %d (%s): %w", i, step.Label(), err)
			}
			r.response = resp
			if step.Call == "events.subscribe" && resp["ok"] == true {
				subscribed[connName] = true
			}
			if step.Save != "" {
				vars[step.Save] = resp["result"]
				if !isOK(resp) {
					vars[step.Save] = resp["error"]
				}
			}
			if i == 0 {
				result, _ := resp["result"].(map[string]any)
				board, _ := result["board"].(string)
				if board == "" {
					return nil, fmt.Errorf("board.open %s failed: %v", root, resp["error"])
				}
				vars["board"] = board
				norm.alias(board, "<board>")
			}
		case step.Await != "":
			p, ok := asyncs[step.Await]
			if !ok {
				return nil, fmt.Errorf("step %d awaits %q, which no async step saved", i, step.Await)
			}
			resp, err := conns[p.conn].await(p.id, o.Timeout)
			if err != nil {
				return nil, fmt.Errorf("step %d (%s): %w", i, step.Label(), err)
			}
			r.conn = p.conn
			r.response = resp
			vars[step.Await] = resp["result"]
		case step.Raw != nil:
			c, err := get(connName)
			if err != nil {
				return nil, err
			}
			r.request = *step.Raw
			if err := c.writeLine([]byte(*step.Raw)); err != nil {
				return nil, err
			}
			resp, err := c.awaitLoose(o.Timeout)
			if err != nil {
				// A line with an id comes back as a reply to that id.
				var sent map[string]any
				if json.Unmarshal([]byte(*step.Raw), &sent) == nil && sent["id"] != nil {
					resp, err = c.await(fmt.Sprint(sent["id"]), o.Timeout)
				}
				if err != nil {
					return nil, fmt.Errorf("step %d (raw line): %w", i, err)
				}
			}
			r.response = resp
		case step.ReadFile != "":
			data, err := os.ReadFile(filepath.Join(root, step.ReadFile))
			if err != nil {
				r.content = map[string]any{"error": "missing"}
			} else {
				var parsed any
				if json.Unmarshal(data, &parsed) == nil {
					r.content = parsed
				} else {
					r.content = string(data)
				}
			}
		case step.WriteFile != nil:
			path := filepath.Join(root, step.WriteFile.Path)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return nil, err
			}
			if err := os.WriteFile(path, []byte(step.WriteFile.Content), 0o644); err != nil {
				return nil, err
			}
		case step.SleepMs > 0:
			time.Sleep(time.Duration(step.SleepMs) * time.Millisecond)
		default:
			return nil, fmt.Errorf("step %d does nothing", i)
		}
		settle := o.Settle
		if step.SettleMs > 0 {
			settle = time.Duration(step.SettleMs) * time.Millisecond
		}
		r.events, r.strays = collect(conns, subscribed, settle)
		if step.NoEvents {
			r.events = nil
		}
		raw = append(raw, r)
	}
	teardown(conns["main"], vars["board"], o.Timeout)

	for _, r := range raw {
		records = append(records, r.normalized(norm, s.Ignore, mergeMaps(s.Unordered, r.step.Unordered)))
	}
	return records, nil
}

type rawRecord struct {
	step     Step
	conn     string
	request  any
	response map[string]any
	events   []any
	strays   []any
	content  any
}

func (r rawRecord) normalized(norm *normalizer, scenarioIgnore map[string]string, unordered map[string]string) Record {
	rec := Record{Step: r.step.Label(), Method: r.step.Call}
	norm.method = r.step.Call
	if r.conn != "main" {
		rec.Conn = r.conn
	}
	norm.learnIDs(r.request, r.response, r.events, r.strays, r.content)
	if r.request != nil {
		rec.Request = norm.value(r.request, "", false)
	}
	if r.response != nil {
		resp := map[string]any{}
		for k, v := range r.response {
			resp[k] = v
		}
		rec.Response = norm.value(resp, "", false)
	}
	for _, e := range r.events {
		rec.Events = append(rec.Events, norm.value(e, "", false))
	}
	for _, e := range r.strays {
		rec.Unsubscribed = append(rec.Unsubscribed, norm.value(e, "", false))
	}
	if r.content != nil {
		rec.Content = norm.value(r.content, "", false)
	}
	for p := range unordered {
		doc := map[string]any{"request": rec.Request, "response": rec.Response, "events": toAny(rec.Events)}
		sortUnordered(doc, strings.Split(p, "."))
	}
	if len(r.step.Mask) > 0 {
		doc := map[string]any{"request": rec.Request, "response": rec.Response, "events": toAny(rec.Events), "content": rec.Content}
		rec.Masked = map[string]string{}
		for p, m := range r.step.Mask {
			mask(doc, strings.Split(p, "."), regexp.MustCompile(m.Match), m.As)
			rec.Masked[p] = m.Why
		}
		rec.Request, rec.Response, rec.Content = doc["request"], doc["response"], doc["content"]
	}
	ignore := map[string]string{}
	for p, why := range scenarioIgnore {
		ignore[p] = why
	}
	for p, why := range r.step.Ignore {
		ignore[p] = why
	}
	if len(ignore) > 0 {
		doc := map[string]any{"request": rec.Request, "response": rec.Response, "events": toAny(rec.Events), "content": rec.Content}
		for p := range ignore {
			blank(doc, strings.Split(p, "."))
		}
		rec.Request, rec.Response, rec.Content = doc["request"], doc["response"], doc["content"]
		if evs, ok := doc["events"].([]any); ok {
			rec.Events = evs
		}
		rec.Ignored = ignore
	}
	return rec
}

func toAny(v []any) any {
	if v == nil {
		return nil
	}
	return v
}

// blank removes the values at path (map keys are deleted, array elements become "<ignored>"),
// so neither the value nor whether it is there at all is compared; reports whether any existed.
func blank(v any, path []string) bool {
	if len(path) == 0 {
		return false
	}
	head, rest := path[0], path[1:]
	hit := false
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			if head != "*" && head != k {
				continue
			}
			if len(rest) == 0 {
				delete(x, k)
				hit = true
			} else if blank(e, rest) {
				hit = true
			}
		}
	case []any:
		for i, e := range x {
			if head != "*" && head != fmt.Sprint(i) {
				continue
			}
			if len(rest) == 0 {
				x[i] = "<ignored>"
				hit = true
			} else if blank(e, rest) {
				hit = true
			}
		}
	}
	return hit
}

// mask rewrites the parts of the strings at path that match re with as (Step.Mask); the rest of
// each string is still compared.
func mask(v any, path []string, re *regexp.Regexp, as string) {
	if len(path) == 0 {
		return
	}
	head, rest := path[0], path[1:]
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			if head != "*" && head != k {
				continue
			}
			if s, ok := e.(string); ok && len(rest) == 0 {
				x[k] = re.ReplaceAllString(s, as)
			} else {
				mask(e, rest, re, as)
			}
		}
	case []any:
		for i, e := range x {
			if head != "*" && head != fmt.Sprint(i) {
				continue
			}
			if s, ok := e.(string); ok && len(rest) == 0 {
				x[i] = re.ReplaceAllString(s, as)
			} else {
				mask(e, rest, re, as)
			}
		}
	}
}

// collect waits until every connection has been quiet for settle, then takes their events,
// connection by connection in name order: those of subscribed connections, and apart from them
// (strays) any that arrived on a connection that never subscribed.
func collect(conns map[string]*conn, subscribed map[string]bool, settle time.Duration) (events, strays []any) {
	if len(conns) == 0 {
		return nil, nil
	}
	start := time.Now()
	deadline := start.Add(10 * settle)
	for {
		last := start
		for _, c := range conns {
			if t := c.quietSince(); t.After(last) {
				last = t
			}
		}
		wait := time.Until(last.Add(settle))
		if wait <= 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(wait)
	}
	names := make([]string, 0, len(conns))
	for name := range conns {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		for _, e := range conns[name].takeEvents() {
			ev := map[string]any{}
			for k, v := range e {
				ev[k] = v
			}
			if name != eventsConn || !subscribed[name] {
				ev["conn"] = name
			}
			if subscribed[name] {
				events = append(events, ev)
			} else {
				strays = append(strays, ev)
			}
		}
	}
	return events, strays
}

// teardown deletes the scenario's terminal tiles, so their sessions end with the scenario.
func teardown(c *conn, board any, timeout time.Duration) {
	if c == nil || board == nil {
		return
	}
	id, err := c.send("board.get", map[string]any{"board": board})
	if err != nil {
		return
	}
	resp, err := c.await(id, timeout)
	if err != nil || !isOK(resp) {
		return
	}
	result, _ := resp["result"].(map[string]any)
	objects, _ := result["objects"].([]any)
	for _, o := range objects {
		obj, _ := o.(map[string]any)
		if obj["type"] == "terminal" || obj["type"] == "browser" {
			if id, err := c.send("object.delete", map[string]any{"id": obj["id"]}); err == nil {
				c.await(id, timeout)
			}
		}
	}
}

func isOK(resp map[string]any) bool { return resp["ok"] == true }

func orEmpty(v any) any {
	if v == nil {
		return map[string]any{}
	}
	return v
}

// setup creates the scenario directory with its files, and makes it a git repository with one
// commit (fixed author, committer and dates, so the commit id is the same on every run) when
// the scenario asks.
func setup(root string, s Scenario) error {
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	for name, content := range s.Files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		data := []byte(content)
		if encoded, ok := strings.CutPrefix(content, "base64:"); ok {
			decoded, err := base64.StdEncoding.DecodeString(encoded)
			if err != nil {
				return fmt.Errorf("%s: %w", name, err)
			}
			data = decoded
		}
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return err
		}
	}
	if !s.Git {
		return nil
	}
	env := append(os.Environ(),
		"GIT_AUTHOR_NAME=easl", "GIT_AUTHOR_EMAIL=conformance@easl.invalid", "GIT_AUTHOR_DATE=2026-01-01T00:00:00Z",
		"GIT_COMMITTER_NAME=easl", "GIT_COMMITTER_EMAIL=conformance@easl.invalid", "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"add", "-A"},
		{"commit", "-q", "--allow-empty", "-m", "conformance fixture"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		cmd.Env = env
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("git %s: %v: %s", strings.Join(args, " "), err, out)
		}
	}
	return nil
}

// keep filters arrays in a response (Step.Keep).
func keep(resp map[string]any, rules map[string]map[string]any, vars map[string]any) error {
	for path, fields := range rules {
		want, err := expand(map[string]any(fields), vars)
		if err != nil {
			return err
		}
		parts := strings.Split(path, ".")
		var parent any = resp
		for _, p := range parts[:len(parts)-1] {
			m, _ := parent.(map[string]any)
			parent = m[p]
		}
		m, _ := parent.(map[string]any)
		list, ok := m[parts[len(parts)-1]].([]any)
		if !ok {
			continue
		}
		kept := []any{}
		for _, e := range list {
			em, _ := e.(map[string]any)
			match := true
			for k, v := range want.(map[string]any) {
				if fmt.Sprint(em[k]) != fmt.Sprint(v) {
					match = false
				}
			}
			if match {
				kept = append(kept, e)
			}
		}
		m[parts[len(parts)-1]] = kept
	}
	return nil
}

// clientKinds are activity entries the Mac client causes on its own schedule: where the user's
// view settled, what they selected. The dev instance's window logs them whenever it settles,
// so a board.history that doesn't ask for them by `kinds` leaves them out of the comparison.
var clientKinds = map[string]bool{"viewport": true, "selection": true}

func dropClientEntries(params any, resp map[string]any) {
	p, _ := params.(map[string]any)
	if kinds, ok := p["kinds"].([]any); ok {
		for _, k := range kinds {
			if clientKinds[fmt.Sprint(k)] {
				return
			}
		}
	}
	result, _ := resp["result"].(map[string]any)
	entries, ok := result["entries"].([]any)
	if !ok {
		return
	}
	kept := []any{}
	for _, e := range entries {
		if m, _ := e.(map[string]any); !clientKinds[fmt.Sprint(m["kind"])] {
			kept = append(kept, e)
		}
	}
	result["entries"] = kept
}

// sortUnordered sorts the arrays at the given record paths by their elements' JSON, for results
// the server lists in no particular order.
func sortUnordered(v any, path []string) {
	if len(path) == 0 {
		if list, ok := v.([]any); ok {
			sort.SliceStable(list, func(i, j int) bool {
				a, _ := json.Marshal(list[i])
				b, _ := json.Marshal(list[j])
				return string(a) < string(b)
			})
		}
		return
	}
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			if path[0] == "*" || path[0] == k {
				sortUnordered(e, path[1:])
			}
		}
	case []any:
		for i, e := range x {
			if path[0] == "*" || path[0] == fmt.Sprint(i) {
				sortUnordered(e, path[1:])
			}
		}
	}
}

// literalIDs appends the id-shaped strings written in a step's params (not templates).
func literalIDs(v any, into []string) []string {
	switch x := v.(type) {
	case map[string]any:
		for _, e := range x {
			into = literalIDs(e, into)
		}
	case []any:
		for _, e := range x {
			into = literalIDs(e, into)
		}
	case string:
		if idShape.MatchString(x) {
			into = append(into, x)
		}
	}
	return into
}

func mergeMaps(a, b map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}
