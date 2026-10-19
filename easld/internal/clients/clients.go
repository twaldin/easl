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
	"context"
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
// browser.call is the drawing Mac's page commands; without it, and without a
// persistent identity, a client cannot own a browser tile. surface.stream is a browser tile's
// stream for another viewer; the other surface methods name a stream it opened.
var Delegated = []string{"view.get", "view.render", "view.snapshot", "agent.prompt", "agent.read", "agent.restart", "object.reload", "object.measure", "text.measure", "browser.call",
	"surface.stream", "surface.ack", "surface.progress", "surface.input", "surface.answer", "surface.stop"}

const (
	ViewGetDeadline  = 5 * time.Second
	SnapshotDeadline = 30 * time.Second
	TerminalDeadline = 10 * time.Second
	MeasureDeadline  = 2 * time.Second
	// HTMLMeasureDeadline is how long an html object.measure waits. The client reads
	// excerpts and images from the host, which needs 20s, plus the 5s grace object.reload
	// gives an answer already in flight.
	HTMLMeasureDeadline = 25 * time.Second
	ReloadGrace         = 5 * time.Second
	RenderGrace         = 30 * time.Second
	labelCacheCapacity  = 10_000
	requestPrefix       = "easld-"
)

// Conn is a client's connection. Send queues without waiting on the peer or calling the registry.
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
	// Identity is the app home's persistent machine id. Empty is a legacy client:
	// it can still attach, and cannot own a browser tile.
	Identity string
	Serves   []string
	Boards   []string
	// Focused is the board the user is looking at; "" leaves the client's last focus.
	Focused string
}

// Client is one attached client.
type Client struct {
	ID        string
	conn      Conn
	app, host string
	identity  string
	schema    string
	serves    map[string]bool
	boards    map[string]bool
	// focused is the board its user focused last, at focusedAt (0: never); attachedAt orders
	// clients that never focused. attachedAt is the connection's, not bumped on reattach.
	focused    string
	focusedAt  uint64
	attachedAt uint64
}

// Done closes when the attached client's connection closes.
func (c *Client) Done() <-chan struct{} { return c.conn.Done() }

// Is reports whether conn is the connection c is attached on.
func (c *Client) Is(conn Conn) bool { return c.conn == conn }

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
	board  string
	done   chan answer
	// late takes a success that arrives after its caller gave up (OpenSurface); set only then,
	// and the entry stays until that answer or the connection closes.
	late func(result any)
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
	onPresence      func([]string)
}

// New is a registry with no clients.
func New() *Registry {
	return &Registry{clients: map[Conn]*Client{}, pending: map[string]*call{}, labels: map[string]measure.TextSize{}, MeasureDeadline: MeasureDeadline}
}

// OnPresence sets the detach hook. It runs without the registry lock, after the client is
// gone, so the caller can take the board lock.
func (r *Registry) OnPresence(fn func([]string)) {
	r.mu.Lock()
	r.onPresence = fn
	r.mu.Unlock()
}

// Attach makes conn a client, or updates the client it already is: what it serves (names it
// doesn't know are dropped), the boards it shows, its identity, and its focus. A client built
// from an older schema version than the server's is refused; a newer one is accepted and speaks
// the server's version (the reply names it), using what both know. The returned boards are the
// union of the boards it showed before and the boards it shows now.
func (r *Registry) Attach(conn Conn, a Attachment) (*Client, []string, error) {
	if a.Version < api.SchemaVersion {
		who := "a client"
		if a.App != "" {
			who = "easl " + a.App
		}
		if a.Host != "" {
			who += " on " + a.Host
		}
		return nil, nil, &Failure{api.CodeUnavailable, fmt.Sprintf("%s is older than this board's server (schema version %d, the server's %d); update it", who, a.Version, api.SchemaVersion)}
	}
	if a.Focused != "" && !slices.Contains(a.Boards, a.Focused) {
		return nil, nil, &Failure{api.CodeInvalidParams, "focused names " + a.Focused + ", which isn't one of boards"}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	c, known := r.clients[conn]
	var before []string
	if !known {
		r.seq++
		c = &Client{ID: model.NewID("cli"), conn: conn, attachedAt: r.seq}
		r.clients[conn] = c
		go r.detachWhenClosed(conn)
	} else {
		before = boardIDs(c.boards)
	}
	c.app, c.host, c.schema, c.identity = a.App, a.Host, a.Schema, a.Identity
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
	return c, unionIDs(before, boardIDs(c.boards)), nil
}

func (r *Registry) detachWhenClosed(conn Conn) {
	<-conn.Done()
	r.mu.Lock()
	c := r.clients[conn]
	var boards []string
	if c != nil {
		boards = boardIDs(c.boards)
		delete(r.clients, conn)
	}
	for id, pending := range r.pending {
		if pending.conn == conn && pending.late != nil {
			delete(r.pending, id)
		}
	}
	notify := r.onPresence
	r.mu.Unlock()
	if notify != nil && len(boards) > 0 {
		notify(boards)
	}
}

func boardIDs(boards map[string]bool) []string {
	out := make([]string, 0, len(boards))
	for id := range boards {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

func unionIDs(a, b []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, id := range append(append([]string{}, a...), b...) {
		if id != "" && !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out
}

func (r *Registry) RemoveBoard(board string) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	changed := map[string]bool{}
	for _, c := range r.clients {
		if c.boards[board] || c.focused == board {
			for id := range c.boards {
				if id != board {
					changed[id] = true
				}
			}
		}
		delete(c.boards, board)
		if c.focused == board {
			c.focused, c.focusedAt = "", 0
		}
	}
	for id, pending := range r.pending {
		if pending.board == board {
			delete(r.pending, id)
			pending.done <- answer{failure: &Failure{api.CodeNotFound, "board " + board + " was closed"}}
		}
	}
	return boardIDs(changed)
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

// Owner is a drawing machine copied out of the registry lock.
type Owner struct {
	Identity, Host string
}

// ChooseExact is the newest attached link with identity, showing board, that serves method.
// Focus is never a fallback. Nil when none match.
func (r *Registry) ChooseExact(identity, board, method string) *Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.exact(identity, board, method)
}

// exact is ChooseExact with mu held.
func (r *Registry) exact(identity, board, method string) *Client {
	if identity == "" || board == "" || method == "" {
		return nil
	}
	var best *Client
	for _, c := range r.clients {
		if c.identity != identity || !c.boards[board] || !c.serves[method] {
			continue
		}
		if best == nil || c.attachedAt > best.attachedAt {
			best = c
		}
	}
	return best
}

// HasIdentity reports whether any link with identity shows board, whatever it serves.
func (r *Registry) HasIdentity(identity, board string) bool {
	if identity == "" || board == "" {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, c := range r.clients {
		if c.identity == identity && c.boards[board] {
			return true
		}
	}
	return false
}

// Eligible is the client on conn when it has a persistent identity, serves browser.call, and
// shows board. Host is the retained offline label.
func (r *Registry) Eligible(conn Conn, board string) (Owner, bool) {
	if conn == nil || board == "" {
		return Owner{}, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	c := r.clients[conn]
	if c == nil || c.identity == "" || !c.serves["browser.call"] || !c.boards[board] {
		return Owner{}, false
	}
	return Owner{Identity: c.identity, Host: c.host}, true
}

// Reporter is the client on conn, for browser.report's authority check. ok is false when
// conn is not attached.
func (r *Registry) Reporter(conn Conn) (identity string, boards map[string]bool, ok bool) {
	if conn == nil {
		return "", nil, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	c := r.clients[conn]
	if c == nil {
		return "", nil, false
	}
	boards = map[string]bool{}
	for id := range c.boards {
		boards[id] = true
	}
	return c.identity, boards, true
}

// Earliest is the eligible client that attached first on board: a persistent identity, serving
// browser.call. The zero Owner and false when none.
func (r *Registry) Earliest(board string) (Owner, bool) {
	if board == "" {
		return Owner{}, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	var best *Client
	for _, c := range r.clients {
		if c.identity == "" || !c.serves["browser.call"] || !c.boards[board] {
			continue
		}
		if best == nil || c.attachedAt < best.attachedAt {
			best = c
		}
	}
	if best == nil {
		return Owner{}, false
	}
	return Owner{Identity: best.identity, Host: best.host}, true
}

// Clients is how many clients are attached.
func (r *Registry) Clients() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.clients)
}

// ListedClient is one attached client as client.list reports it. Focused is the board
// its user focused last, empty when it never has. Boards and Serves are sorted.
type ListedClient struct {
	ID, Identity, App, Host, Focused string
	Boards, Serves                   []string
}

// List is a stable snapshot of the attached clients, sorted by id.
func (r *Registry) List() []ListedClient {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]ListedClient, 0, len(r.clients))
	for _, c := range r.clients {
		item := ListedClient{
			ID: c.ID, Identity: c.identity, App: c.app, Host: c.host, Focused: c.focused,
			Boards: make([]string, 0, len(c.boards)),
			Serves: make([]string, 0, len(c.serves)),
		}
		for id := range c.boards {
			item.Boards = append(item.Boards, id)
		}
		for method := range c.serves {
			item.Serves = append(item.Serves, method)
		}
		sort.Strings(item.Boards)
		sort.Strings(item.Serves)
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Call sends method with params to c and waits for its answer, cancellation, deadline or disconnect.
func (r *Registry) Call(ctx context.Context, c *Client, board, method string, params map[string]any, deadline time.Duration) (any, *Failure) {
	return r.call(ctx, c, board, method, params, deadline, nil)
}

type opening struct {
	identity, board string
	events          []string
	late            func(result any)
}

// OpenSurface is Call of surface.stream on c, the link that draws identity's pages on board,
// for a viewer that hears events. c is checked to be that link as the request is sent, and the
// request carries events beside params as surfaceEvents. A success that arrives after deadline
// isn't dropped: late gets it, in a goroutine of its own, unless c's connection closes first
// (taking the stream with it). One that arrives as the deadline passes is returned.
func (r *Registry) OpenSurface(c *Client, identity, board string, params map[string]any, events []string, deadline time.Duration, late func(result any)) (any, *Failure) {
	return r.call(context.Background(), c, "", "surface.stream", params, deadline, &opening{identity, board, events, late})
}

// StopSurface waits while c still shows board. Closing the board ends its producer streams.
func (r *Registry) StopSurface(c *Client, board, stream string) *Failure {
	_, failure := r.call(context.Background(), c, board, "surface.stop", map[string]any{"stream": stream}, untilClosed, nil)
	return failure
}

const untilClosed time.Duration = -1

func (r *Registry) call(ctx context.Context, c *Client, board, method string, params map[string]any, deadline time.Duration, open *opening) (any, *Failure) {
	if ctx.Err() != nil {
		return nil, &Failure{api.CodeUnavailable, method + " was cancelled"}
	}
	r.mu.Lock()
	if board != "" && !c.boards[board] {
		r.mu.Unlock()
		return nil, &Failure{api.CodeNotFound, "board " + board + " was closed"}
	}
	request := map[string]any{"method": method, "params": params}
	if open != nil {
		if r.exact(open.identity, open.board, method) != c {
			name := c.Name()
			r.mu.Unlock()
			return nil, &Failure{api.CodeUnavailable, name + " no longer draws " + open.identity + "'s pages on board " + open.board}
		}
		request["surfaceEvents"] = open.events
	}
	r.request++
	id := requestPrefix + strconv.FormatUint(r.request, 10)
	request["id"] = id
	pending := &call{conn: c.conn, method: method, board: board, done: make(chan answer, 1)}
	r.pending[id] = pending
	name := c.Name()
	// Capability removal must not reject this call before its request is queued.
	sent := c.conn.Send(request)
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		if pending.late == nil {
			delete(r.pending, id)
		}
		r.mu.Unlock()
	}()
	disconnected := &Failure{api.CodeUnavailable, name + " disconnected before answering " + method}
	if !sent {
		return nil, disconnected
	}
	var expired <-chan time.Time
	if deadline != untilClosed {
		timer := time.NewTimer(deadline)
		defer timer.Stop()
		expired = timer.C
	}
	select {
	case a := <-pending.done:
		return a.result, a.failure
	case <-ctx.Done():
		return nil, &Failure{api.CodeUnavailable, name + "'s " + method + " was cancelled"}
	case <-expired:
		timedOut := &Failure{api.CodeUnavailable, name + " didn't answer " + method + " within " + seconds(deadline) + " s"}
		if open == nil {
			return nil, timedOut
		}
		r.mu.Lock()
		_, waiting := r.pending[id]
		if waiting {
			select {
			case <-c.conn.Done():
				delete(r.pending, id)
				r.mu.Unlock()
				return nil, disconnected
			default:
			}
			pending.late = open.late
		}
		r.mu.Unlock()
		if waiting {
			return nil, timedOut
		}
		a := <-pending.done
		return a.result, a.failure
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
// call gave up, is dropped, unless OpenSurface's late takes its success); other lines are
// requests for the router.
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
	var late func(result any)
	if waiting {
		delete(r.pending, id)
		late = pending.late
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
		if late != nil {
			go late(result)
		}
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
	result, failure := r.Call(context.Background(), c, "", "text.measure", map[string]any{"items": list}, r.MeasureDeadline)
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
