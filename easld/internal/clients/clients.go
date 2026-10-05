// Package clients is the client protocol's server side (docs/design/next.md, "The client
// protocol"): Mac clients attach on a connection (client.attach) and serve what only they can
// answer; easld forwards those calls to the client chosen for the call's board, correlates the
// answers by id, gives up on a client that doesn't answer in time or goes away, and measures text
// through a client when one serves text.measure, else from the glyph table.
//
// The registry has a lock of its own and never takes the board registry's, so a call may wait on
// a client while the boards stay locked (text.measure) or unlocked (everything else).
package clients

import (
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/textmeasure"
)

// Delegated are the methods a client can serve (client.attach `serves`).
var Delegated = []string{"view.get", "view.render", "view.snapshot", "agent.prompt", "agent.read", "object.reload", "text.measure"}

// Deadlines without a caller's timeoutMs (object.reload and view.render add theirs).
const (
	ViewGetDeadline    = 5 * time.Second
	SnapshotDeadline   = 30 * time.Second
	TerminalDeadline   = 10 * time.Second
	MeasureDeadline    = 2 * time.Second
	ReloadGrace        = 5 * time.Second
	RenderGrace        = 30 * time.Second
	labelCacheCapacity = 10_000
	requestPrefix      = "easld-"
)

// Conn is a client's connection.
type Conn interface {
	Send(v any) bool
	// Done is closed when the connection closes.
	Done() <-chan struct{}
}

// Failure is an API error for the caller.
type Failure struct{ Code, Message string }

func (f *Failure) Error() string { return f.Message }

// Attachment is client.attach's params.
type Attachment struct {
	Version   int
	Schema    string
	App, Host string
	Serves    []string
	Boards    []string
	// Focused is the board the user is looking at; "" leaves the client's last focus.
	Focused string
}

// Client is one attached client.
type Client struct {
	ID        string
	conn      Conn
	app, host string
	schema    string
	serves    map[string]bool
	boards    map[string]bool
	// focused is the board its user focused last, at focusedAt (0: never); attachedAt orders
	// clients that never focused.
	focused    string
	focusedAt  uint64
	attachedAt uint64
}

// Name is how messages name the client: `easl 0.2.0 on studio (client cli_…)`.
func (c *Client) Name() string {
	who := ""
	if c.app != "" {
		who = "easl " + c.app
	}
	if c.host != "" {
		if who == "" {
			who = "a client"
		}
		who += " on " + c.host
	}
	if who == "" {
		return "client " + c.ID
	}
	return who + " (client " + c.ID + ")"
}

type answer struct {
	result  any
	failure *Failure
}

type call struct {
	conn   Conn
	method string
	done   chan answer
}

// Registry is every attached client and the calls waiting on them.
type Registry struct {
	mu      sync.Mutex
	clients map[Conn]*Client
	pending map[string]*call
	seq     uint64 // orders attaches and focuses
	request uint64
	// labels are exact arrow caption chips by caption, as clients measured them.
	labels map[string]measure.TextSize
	// MeasureDeadline is how long text.measure waits for a client before the glyph table answers.
	MeasureDeadline time.Duration
}

// New is a registry with no clients.
func New() *Registry {
	return &Registry{clients: map[Conn]*Client{}, pending: map[string]*call{}, labels: map[string]measure.TextSize{}, MeasureDeadline: MeasureDeadline}
}

// Attach makes conn a client, or updates the client it already is: what it serves (names it
// doesn't know are dropped), the boards it shows, and its focus. A client whose schema version
// differs from the server's is refused.
func (r *Registry) Attach(conn Conn, a Attachment) (*Client, error) {
	who := "a client"
	if a.App != "" {
		who = "easl " + a.App
	}
	if a.Host != "" {
		who += " on " + a.Host
	}
	switch {
	case a.Version < api.SchemaVersion:
		return nil, &Failure{api.CodeUnavailable, fmt.Sprintf("%s is older than this board's server (schema version %d, the server's %d); update it", who, a.Version, api.SchemaVersion)}
	case a.Version > api.SchemaVersion:
		return nil, &Failure{api.CodeUnavailable, fmt.Sprintf("%s is newer than this board's server (schema version %d, the server's %d); update easld", who, a.Version, api.SchemaVersion)}
	}
	if a.Focused != "" && !slices.Contains(a.Boards, a.Focused) {
		return nil, &Failure{api.CodeInvalidParams, "focused names " + a.Focused + ", which isn't one of boards"}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	c, known := r.clients[conn]
	if !known {
		r.seq++
		c = &Client{ID: model.NewID("cli"), conn: conn, attachedAt: r.seq}
		r.clients[conn] = c
		go r.detachWhenClosed(conn)
	}
	c.app, c.host, c.schema = a.App, a.Host, a.Schema
	c.serves = map[string]bool{}
	for _, m := range a.Serves {
		if slices.Contains(Delegated, m) {
			c.serves[m] = true
		}
	}
	c.boards = map[string]bool{}
	for _, b := range a.Boards {
		c.boards[b] = true
	}
	if a.Focused != "" {
		r.seq++
		c.focused, c.focusedAt = a.Focused, r.seq
	}
	return c, nil
}

func (r *Registry) detachWhenClosed(conn Conn) {
	<-conn.Done()
	r.mu.Lock()
	delete(r.clients, conn)
	r.mu.Unlock()
}

// Choose is the client a call of method on board goes to ("" board: any client, for
// text.measure): of those that serve the method and show the board, the one whose user focused
// this board last, then the one focused most recently, then the one attached last. Nil when none.
func (r *Registry) Choose(method, board string) *Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	var candidates []*Client
	for _, c := range r.clients {
		if c.serves[method] && (board == "" || c.boards[board]) {
			candidates = append(candidates, c)
		}
	}
	if len(candidates) == 0 {
		return nil
	}
	sort.Slice(candidates, func(i, j int) bool {
		a, b := candidates[i], candidates[j]
		af, bf := board != "" && a.focused == board, board != "" && b.focused == board
		if af != bf {
			return af
		}
		if a.focusedAt != b.focusedAt {
			return a.focusedAt > b.focusedAt
		}
		return a.attachedAt > b.attachedAt
	})
	return candidates[0]
}

// Clients is how many clients are attached.
func (r *Registry) Clients() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.clients)
}

// Call sends method with params to c and waits for its answer: the result, or the client's error,
// or `unavailable` when it doesn't answer within deadline or disconnects first.
func (r *Registry) Call(c *Client, method string, params map[string]any, deadline time.Duration) (any, *Failure) {
	r.mu.Lock()
	r.request++
	id := requestPrefix + strconv.FormatUint(r.request, 10)
	pending := &call{conn: c.conn, method: method, done: make(chan answer, 1)}
	r.pending[id] = pending
	name := c.Name()
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.pending, id)
		r.mu.Unlock()
	}()
	disconnected := &Failure{api.CodeUnavailable, name + " disconnected before answering " + method}
	if !c.conn.Send(map[string]any{"id": id, "method": method, "params": params}) {
		return nil, disconnected
	}
	timer := time.NewTimer(deadline)
	defer timer.Stop()
	select {
	case a := <-pending.done:
		return a.result, a.failure
	case <-timer.C:
		return nil, &Failure{api.CodeUnavailable, name + " didn't answer " + method + " within " + seconds(deadline) + " s"}
	case <-c.conn.Done():
		// An answer that arrived just before the connection closed still counts.
		select {
		case a := <-pending.done:
			return a.result, a.failure
		default:
			return nil, disconnected
		}
	}
}

func seconds(d time.Duration) string {
	return strconv.FormatFloat(d.Seconds(), 'f', -1, 64)
}

// Answer takes a line a connection sent that has `ok` and no `method`: the answer to a call this
// registry forwarded. It reports whether the line was one (handled here: a late answer, after its
// call gave up, is dropped); other lines are requests for the router.
func (r *Registry) Answer(conn Conn, line map[string]any) bool {
	ok, isBool := line["ok"].(bool)
	if _, hasMethod := line["method"]; hasMethod || !isBool {
		return false
	}
	id, _ := line["id"].(string)
	r.mu.Lock()
	pending, waiting := r.pending[id]
	if waiting && pending.conn != conn {
		waiting = false
	}
	if waiting {
		delete(r.pending, id)
	}
	_, attached := r.clients[conn]
	r.mu.Unlock()
	if !waiting {
		return attached && strings.HasPrefix(id, requestPrefix)
	}
	if ok {
		result := line["result"]
		if result == nil {
			result = map[string]any{}
		}
		pending.done <- answer{result: result}
		return true
	}
	errorObject, _ := line["error"].(map[string]any)
	code, _ := errorObject["code"].(string)
	message, _ := errorObject["message"].(string)
	if code == "" {
		code = api.CodeInternal
	}
	pending.done <- answer{failure: &Failure{code, message}}
	return true
}

// MeasureText measures items as the app lays them out (measure.Texts): exact arrow labels a
// client measured before come from the cache, the rest go to the client chosen for text.measure
// in one batch, and what no client measured (none attached, or it failed or didn't answer within
// MeasureDeadline) comes from the glyph table, approximate.
func (r *Registry) MeasureText(items []measure.TextItem) []measure.TextSize {
	out := make([]measure.TextSize, len(items))
	var missing []int
	r.mu.Lock()
	for i, item := range items {
		if size, ok := r.labels[item.Text]; ok && item.Kind == "arrowLabel" {
			out[i] = size
		} else {
			missing = append(missing, i)
		}
	}
	r.mu.Unlock()
	if len(missing) == 0 {
		return out
	}
	batch := make([]measure.TextItem, len(missing))
	for i, index := range missing {
		batch[i] = items[index]
	}
	sizes := r.measureByClient(batch)
	if sizes == nil {
		sizes = textmeasure.Approximate(batch)
	}
	r.mu.Lock()
	for i, index := range missing {
		out[index] = sizes[i]
		if items[index].Kind == "arrowLabel" && !sizes[i].Approximate {
			if len(r.labels) >= labelCacheCapacity {
				clear(r.labels)
			}
			r.labels[items[index].Text] = sizes[i]
		}
	}
	r.mu.Unlock()
	return out
}

// measureByClient is the chosen client's sizes for items, nil when there is no client or it
// gave no usable answer in time.
func (r *Registry) measureByClient(items []measure.TextItem) []measure.TextSize {
	c := r.Choose("text.measure", "")
	if c == nil {
		return nil
	}
	list := make([]any, len(items))
	for i, item := range items {
		list[i] = ItemJSON(item)
	}
	result, failure := r.Call(c, "text.measure", map[string]any{"items": list}, r.MeasureDeadline)
	if failure != nil {
		return nil
	}
	answered, _ := result.(map[string]any)["sizes"].([]any)
	if len(answered) != len(items) {
		return nil
	}
	sizes := make([]measure.TextSize, len(items))
	for i, value := range answered {
		m, _ := value.(map[string]any)
		w, okW := m["w"].(float64)
		h, okH := m["h"].(float64)
		if !okW || !okH {
			return nil
		}
		shortfall, _ := m["tableShortfall"].(float64)
		sizes[i] = measure.TextSize{W: w, H: h, TableShortfall: shortfall}
	}
	return sizes
}

// ItemJSON is a text.measure item as the schema has it.
func ItemJSON(item measure.TextItem) map[string]any {
	m := map[string]any{"kind": item.Kind, "text": item.Text}
	if item.Width != nil {
		m["width"] = *item.Width
	}
	if item.Kind == "text" && item.TextSize != 0 {
		m["textSize"] = item.TextSize
	}
	if item.Kind == "note" && item.Root != "" {
		m["root"] = item.Root
	}
	return m
}

// SizeJSON is one text.measure size.
func SizeJSON(item measure.TextItem, size measure.TextSize) map[string]any {
	m := map[string]any{"w": size.W, "h": size.H}
	if item.Kind == "note" {
		m["tableShortfall"] = size.TableShortfall
	}
	return m
}
