// Package router maps schema/easl-api.json methods onto boards: a port of ApiRouter.swift as
// it behaves without the Mac app's closures (no window, terminal surfaces, WebKit or renderer),
// whose work goes to an attached Mac client instead (the client protocol, package clients).
// Every request runs under the registry's lock, as Swift runs everything on the main actor; a
// call forwarded to a client releases it while it waits.
package router

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/relay"
	"github.com/twaldin/easl/easld/internal/server"
	"github.com/twaldin/easl/easld/internal/session"
	"github.com/twaldin/easl/easld/internal/swiftjson"
)

// Failure is an API error with its code (ApiRouter.Failure).
type Failure struct {
	Code    string
	Message string
}

func (f *Failure) Error() string { return f.Message }

func fail(code, format string, args ...any) error {
	return &Failure{code, fmt.Sprintf(format, args...)}
}

func invalid(format string, args ...any) error { return fail(api.CodeInvalidParams, format, args...) }

// Conn is what the router needs of a connection.
type Conn interface {
	Send(v any) bool
	IsOpen() bool
	// Done is closed when the connection closes.
	Done() <-chan struct{}
}

// Router serves the API over a board registry.
type Router struct {
	reg *board.Registry
	// clients are the attached Mac clients, which serve the delegated methods and measure text.
	clients *clients.Registry

	pendingPrompts map[string]time.Time
	waiters        []*waiter
	// messageHolds: which connection holds each message agent.inbox handed out and its
	// integration hasn't acked yet; offered again once that connection closes.
	messageHolds map[messageHold]Conn
	// inboxWaiters are agent.inbox long polls waiting for a message to their terminal.
	inboxWaiters []*inboxWaiter
	// restarts: the terminals agent.restart is having a client kill and relaunch, each with
	// the restart (a number from restartSeq) that holds it. Until it is done nothing reaches the
	// terminal: agent.prompt is refused, agent.inbox offers nothing, another restart is refused.
	restarts   map[string]uint64
	restartSeq uint64
	// typing: the terminals a client is typing an agent.prompt into now, with how many prompts.
	typing map[string]int
	// FirstReportGrace: how long agent.wait gives a terminal with no lifecycle to start reporting.
	FirstReportGrace time.Duration
	// PromptStartGrace: how long agent.wait gives a prompt to start the agent's turn.
	PromptStartGrace time.Duration
	// Sessions runs hosted terminals' zmx sessions (session.*) and owned ones; nil: none
	// (`unavailable`).
	Sessions *session.Manager
	// Relays serve clients' sockets on this machine (relay.open); nil: none (`unavailable`).
	Relays *relay.Relays
	// Owns, set by `--own-terminals`, makes easld start and end the sessions of the terminals on
	// its boards that have no `props.host` (lifecycle.go), with its variables and labels. Nil: a
	// Mac's app runs them, and easld starts none.
	Owns *session.Owner
	// Reopens is the file listing the boards easld reopens at start when it owns their
	// terminals (Restore): each board opened is added. "": none.
	Reopens string
	// lifecycle runs owned terminals' sessions off the lock.
	lifecycle lifecycle
}

// New is a router over reg; it observes every board's events (agent.wait), and measures the
// text of reg's boards through its clients.
func New(reg *board.Registry) *Router {
	r := &Router{reg: reg, clients: clients.New(), pendingPrompts: map[string]time.Time{}, messageHolds: map[messageHold]Conn{}, restarts: map[string]uint64{}, typing: map[string]int{},
		FirstReportGrace: 15 * time.Second, PromptStartGrace: 60 * time.Second}
	reg.Hook = r.observe
	reg.Bounced = r.bounce
	reg.Terminals = r.terminals
	reg.Opened = r.opened
	reg.Texts = r.clients
	return r
}

// Clients is the attached clients.
func (r *Router) Clients() *clients.Registry { return r.clients }

// Answer is the server's Answers: a client's answer to a call forwarded to it.
func (r *Router) Answer(c *server.Conn, line map[string]any) bool {
	return r.clients.Answer(c, line)
}

// Handle is the server's handler: the response, or nil when the reply is deferred (agent.wait,
// an agent.inbox long poll) or the connection became an event stream.
func (r *Router) Handle(req any, c *server.Conn) any {
	return r.HandleConn(req, c)
}

// HandleConn is Handle for any connection. The sessions of owned terminals a request created or
// deleted are up or gone (or their failure logged) before it is answered: they run once the
// registry's lock is let go.
func (r *Router) HandleConn(req any, c Conn) any {
	if reply, ok := r.hostCall(req); ok {
		return reply
	}
	reply, before, after := r.locked(req, c)
	if after != before {
		r.waitSessions(after)
	}
	return reply
}

// locked handles req under the registry's lock, with the session jobs queued before and after.
func (r *Router) locked(req any, c Conn) (reply any, before, after uint64) {
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	before = r.queuedSessions()
	reply = r.handle(req, c)
	return reply, before, r.queuedSessions()
}

func (r *Router) handle(req any, c Conn) any {
	m, _ := req.(map[string]any)
	id := m["id"]
	method, ok := m["method"].(string)
	if !ok {
		return errorReply(id, &Failure{api.CodeInvalidParams, "missing method"})
	}
	params, present := m["params"]
	if !present || params == nil {
		params = map[string]any{}
	}
	result, err := r.call(id, method, params, c)
	if err != nil {
		return errorReply(id, asFailure(err))
	}
	if result == nil {
		return nil
	}
	// Swift encodes every result with JSONEncoder (JSONValue.encode), which throws on NaN and
	// infinities; the change is made, the reply is that error.
	if nf, bad := nonFinite(result); bad {
		return errorReply(id, &Failure{api.CodeInvalidParams, nf.Debug()})
	}
	return okReply(id, result)
}

// nonFinite finds a NaN or infinite number in a result.
func nonFinite(v any) (swiftjson.NonFinite, bool) {
	switch x := v.(type) {
	case nil, bool, string, int:
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return swiftjson.NonFinite{Value: x}, true
		}
	case []any:
		for _, e := range x {
			if nf, bad := nonFinite(e); bad {
				return nf, true
			}
		}
	case map[string]any:
		for _, e := range x {
			if nf, bad := nonFinite(e); bad {
				return nf, true
			}
		}
	case model.Frame:
		return nonFinite([]any{x.X, x.Y, x.W, x.H})
	case model.Object:
		if nf, bad := nonFinite(x.Frame); bad {
			return nf, true
		}
		if nf, bad := nonFinite(x.Z); bad {
			return nf, true
		}
		return nonFinite(x.Props)
	case []model.Object:
		for _, o := range x {
			if nf, bad := nonFinite(o); bad {
				return nf, true
			}
		}
	default:
		var unsupported *json.UnsupportedValueError
		if _, err := json.Marshal(x); errors.As(err, &unsupported) {
			f, _ := strconv.ParseFloat(unsupported.Str, 64)
			return swiftjson.NonFinite{Value: f}, true
		}
	}
	return swiftjson.NonFinite{}, false
}

func (r *Router) call(id any, method string, raw any, c Conn) (any, error) {
	if method == "client.attach" {
		// A newer client may send params this server doesn't know: they are ignored.
		raw = known(method, raw)
	}
	if err := checkParams(method, raw); err != nil {
		return nil, err
	}
	p, _ := raw.(map[string]any)
	switch method {
	case "client.attach":
		return r.attach(p, c)
	case "text.measure":
		return r.textMeasure(p)
	case "events.subscribe":
		boardID := ""
		if s, ok := p["board"].(string); ok {
			boardID = s
			if b, ok := r.reg.Board(s); ok {
				boardID = b.ID()
			}
		}
		var events []string
		if list, ok := p["events"].([]any); ok {
			events = []string{}
			for _, e := range list {
				if s, ok := e.(string); ok {
					events = append(events, s)
				}
			}
		}
		r.reg.Subscribe(c, boardID, events)
		c.Send(okReply(id, map[string]any{}))
		return nil, nil
	case "agent.wait":
		return r.wait(id, p, c)
	case "agent.inbox":
		return r.inbox(id, p, c)
	case "agent.read":
		return r.read(p)
	case "agent.prompt":
		return r.prompt(p)
	case "agent.restart":
		return r.restart(p)
	case "view.render":
		return r.render(p)
	case "view.snapshot":
		return r.snapshot(p)
	case "tray.drain":
		return r.drain(p)
	case "object.get":
		return r.get(p)
	case "object.find":
		return r.find(p)
	case "object.measure":
		return r.measure(p)
	case "object.reload":
		return r.reload(p)
	case "object.batch":
		return r.batch(p)
	case "layout.check":
		return r.check(p)
	case "object.create", "object.update", "object.upsert":
		return r.write(method, p)
	}
	return r.dispatch(method, p)
}

func okReply(id, result any) map[string]any {
	return map[string]any{"id": id, "ok": true, "result": result}
}

func errorReply(id any, f *Failure) map[string]any {
	return map[string]any{"id": id, "ok": false, "error": map[string]any{"code": f.Code, "message": f.Message}}
}

// known is params without the keys method's schema doesn't list.
func known(method string, raw any) any {
	given, ok := raw.(map[string]any)
	if !ok {
		return raw
	}
	out := map[string]any{}
	for _, k := range api.Methods[method].Accepted {
		if v, ok := given[k]; ok {
			out[k] = v
		}
	}
	return out
}

// asFailure maps an error to its API code (ApiRouter.handle's catch clauses).
func asFailure(err error) *Failure {
	var f *Failure
	if errors.As(err, &f) {
		return f
	}
	var be *board.Error
	if errors.As(err, &be) {
		return &Failure{be.Code, be.Message}
	}
	var mf *measure.Failure
	if errors.As(err, &mf) {
		return &Failure{mf.Code, mf.Message}
	}
	var cf *clients.Failure
	if errors.As(err, &cf) {
		return &Failure{cf.Code, cf.Message}
	}
	var se *session.Error
	if errors.As(err, &se) {
		return &Failure{se.Code, se.Message}
	}
	var re *relay.Error
	if errors.As(err, &re) {
		return &Failure{re.Code, re.Message}
	}
	return &Failure{api.CodeInvalidParams, err.Error()}
}

// checkParams rejects a param the method's schema doesn't list and a missing required one,
// naming what the method takes.
func checkParams(method string, raw any) error {
	spec, ok := api.Methods[method]
	given, isObject := raw.(map[string]any)
	if !ok || !isObject {
		return nil
	}
	accepted := map[string]bool{}
	for _, a := range spec.Accepted {
		accepted[a] = true
	}
	var unknown []string
	for k := range given {
		if !accepted[k] {
			unknown = append(unknown, k)
		}
	}
	sort.Strings(unknown)
	var missing []string
	for _, k := range spec.Required {
		if v, ok := given[k]; !ok || v == nil {
			missing = append(missing, k)
		}
	}
	if len(unknown) == 0 && len(missing) == 0 {
		return nil
	}
	var problems []string
	if len(unknown) > 0 {
		s := "s"
		if len(unknown) == 1 {
			s = ""
		}
		problems = append(problems, "unknown param"+s+" "+strings.Join(unknown, ", "))
	}
	if len(missing) > 0 {
		problems = append(problems, "missing "+strings.Join(missing, ", "))
	}
	takes := "no params"
	if len(spec.Accepted) > 0 {
		required := map[string]bool{}
		for _, k := range spec.Required {
			required[k] = true
		}
		parts := make([]string, len(spec.Accepted))
		for i, a := range spec.Accepted {
			parts[i] = a
			if required[a] {
				parts[i] += " (required)"
			}
		}
		takes = strings.Join(parts, ", ")
	}
	return invalid("%s; %s takes %s", strings.Join(problems, "; "), method, takes)
}

// --- helpers ---

func str(p map[string]any, key string) (string, error) {
	s, ok := p[key].(string)
	if !ok {
		return "", invalid("missing %s", key)
	}
	return s, nil
}

func optStr(p map[string]any, key string) (string, bool) {
	s, ok := p[key].(string)
	return s, ok
}

func num(p map[string]any, key string) (float64, bool) {
	f, ok := p[key].(float64)
	return f, ok
}

// intParam reads a number as JSONValue.int does (truncating).
func intParam(p map[string]any, key string) (int, bool) { return board.TruncInt(p[key]) }

func boolParam(p map[string]any, key string) bool {
	b, _ := p[key].(bool)
	return b
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

func strings_(list any) []string {
	items, _ := list.([]any)
	var out []string
	for _, x := range items {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// boardOf is the target board: explicit board, else the caller tile's, else the frontmost.
func (r *Router) boardOf(p map[string]any) (*board.Board, error) {
	if id, ok := p["board"].(string); ok {
		b, ok := r.reg.Board(id)
		if !ok {
			return nil, board.NotFound("board %s", id)
		}
		return b, nil
	}
	if caller, ok := p["caller"].(string); ok {
		if b, ok := r.reg.Containing(caller); ok {
			return b, nil
		}
	}
	if b, ok := r.reg.Boards()[r.reg.Frontmost]; ok {
		return b, nil
	}
	return nil, fail(api.CodeNotFound, "no open board")
}

func (r *Router) boardForObject(id string) (*board.Board, error) {
	b, ok := r.reg.Containing(id)
	if !ok {
		return nil, board.NotFound("object %s", id)
	}
	return b, nil
}

// callerOf honours a caller only when it is a terminal tile on an open board.
func (r *Router) callerOf(p map[string]any) string {
	caller, ok := p["caller"].(string)
	if !ok {
		return ""
	}
	b, ok := r.reg.Containing(caller)
	if !ok || b.Objects()[caller].Type != model.Terminal {
		return ""
	}
	return caller
}

// option is an optional enum parameter; an unknown value is invalid rather than ignored.
func option(p map[string]any, key string, cases []string, fallback string) (string, error) {
	raw, ok := p[key].(string)
	if !ok {
		return fallback, nil
	}
	for _, c := range cases {
		if c == raw {
			return raw, nil
		}
	}
	return "", invalid("%s must be one of %s", key, strings.Join(cases, ", "))
}

func point(p map[string]any, key string) (*board.Point, error) {
	v, present := p[key]
	if !present {
		return nil, nil
	}
	m := asMap(v)
	x, ok1 := m["x"].(float64)
	y, ok2 := m["y"].(float64)
	if !ok1 || !ok2 {
		return nil, invalid("%s needs x and y", key)
	}
	return &board.Point{X: x, Y: y}, nil
}

func objectJSON(o model.Object) map[string]any { return o.APIJSON() }

// withWarnings adds `warnings` (unknown props) when there are any.
func withWarnings(result map[string]any, warnings []string) map[string]any {
	if len(warnings) > 0 {
		list := make([]any, len(warnings))
		for i, w := range warnings {
			list[i] = w
		}
		result["warnings"] = list
	}
	return result
}

// describe is Swift's default description of a JSONValue (`string("x")`), which some messages
// interpolate.
func describe(v any) string {
	switch x := v.(type) {
	case nil:
		return "null"
	case bool:
		return "bool(" + strconv.FormatBool(x) + ")"
	case float64:
		return "number(" + swiftjson.Description(x) + ")"
	case string:
		return "string(" + swiftQuoted(x) + ")"
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = describe(e)
		}
		return "array([" + strings.Join(parts, ", ") + "])"
	case map[string]any:
		if len(x) == 0 {
			return "object([:])"
		}
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, len(keys))
		for i, k := range keys {
			parts[i] = swiftQuoted(k) + ": " + describe(x[k])
		}
		return "object([" + strings.Join(parts, ", ") + "])"
	}
	return fmt.Sprint(v)
}

// swiftQuoted is String.debugDescription.
func swiftQuoted(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case 0:
			b.WriteString(`\0`)
		default:
			if r < 0x20 || r == 0x7f {
				fmt.Fprintf(&b, `\u{%x}`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
