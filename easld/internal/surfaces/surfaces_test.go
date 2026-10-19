package surfaces

import (
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
)

// link is a connection: what easld sends it goes to sent, the lines it relays to lines.
type link struct {
	mu     sync.Mutex
	sent   chan map[string]any
	lines  chan string
	done   chan struct{}
	closed bool
}

func newLink(t *testing.T) *link {
	l := &link{sent: make(chan map[string]any, 16), lines: make(chan string, 16), done: make(chan struct{})}
	t.Cleanup(l.hangUp)
	return l
}

func (l *link) Send(v any) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return false
	}
	l.sent <- v.(map[string]any)
	return true
}

func (l *link) SendLine(line []byte) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return false
	}
	l.lines <- string(line)
	return true
}

func (l *link) IsOpen() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return !l.closed
}

func (l *link) Done() <-chan struct{} { return l.done }

func (l *link) hangUp() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.closed {
		l.closed = true
		close(l.done)
	}
}

// request is the next thing easld sent l.
func (l *link) request(t *testing.T) map[string]any {
	t.Helper()
	select {
	case m := <-l.sent:
		return m
	case <-time.After(5 * time.Second):
		t.Fatal("nothing was sent")
		return nil
	}
}

// relayed is every line relayed to l so far.
func (l *link) relayed() []string {
	var out []string
	for len(l.lines) > 0 {
		out = append(out, <-l.lines)
	}
	return out
}

type outcome struct {
	result any
	err    error
}

func wait(t *testing.T, done <-chan outcome) outcome {
	t.Helper()
	select {
	case got := <-done:
		return got
	case <-time.After(5 * time.Second):
		t.Fatal("no answer")
		return outcome{}
	}
}

func code(err error) string {
	if f, ok := err.(*clients.Failure); ok {
		return f.Code
	}
	return ""
}

// relay is a registry over one board, whose truth the test sets, and the attached link of the
// Mac that draws its tiles.
type relay struct {
	t      *testing.T
	macs   *clients.Registry
	reg    *Registry
	lock   sync.Mutex // the board lock
	truth  map[Key]Ended
	page   Key
	drawer *link
	mac    *clients.Client
}

func newRelay(t *testing.T) *relay {
	b := board.New("brd_a", t.TempDir())
	r := &relay{t: t, macs: clients.New(), truth: map[Key]Ended{}, page: Key{Board: b, Tile: "obj_page", Machine: "mch_drawer"}}
	r.reg = New(r.macs, func(k Key, _ *clients.Client) Ended { return r.truth[k] })
	r.drawer, r.mac = r.attach("mch_drawer")
	return r
}

func (r *relay) attach(identity string) (*link, *clients.Client) {
	r.t.Helper()
	l := newLink(r.t)
	c, _, err := r.macs.Attach(l, clients.Attachment{Version: api.SchemaVersion, Schema: api.SchemaHash, Host: "mac", Identity: identity,
		Serves: []string{"surface.stream"}, Boards: []string{"brd_a"}})
	if err != nil {
		r.t.Fatal(err)
	}
	return l, c
}

// set is a board change after which why answers reason for k.
func (r *relay) set(k Key, reason Ended) {
	r.lock.Lock()
	defer r.lock.Unlock()
	r.truth[k] = reason
	r.reg.Recheck(k.Board.ID())
}

func (r *relay) open(viewer *link, k Key, hears ...string) <-chan outcome {
	done := make(chan outcome, 1)
	go func() {
		r.lock.Lock()
		defer r.lock.Unlock()
		result, err := r.reg.Open(&r.lock, k, viewer, hears, r.mac, map[string]any{"id": k.Tile, "scale": 1.0})
		done <- outcome{result, err}
	}()
	return done
}

func (r *relay) answer(request map[string]any, result any) {
	r.macs.Answer(r.drawer, map[string]any{"id": request["id"], "ok": true, "result": result})
}

// live is a stream viewer opened on k that the Mac answered as id.
func (r *relay) live(viewer *link, k Key, id string, hears ...string) {
	r.t.Helper()
	opened := r.open(viewer, k, hears...)
	r.answer(r.drawer.request(r.t), map[string]any{"stream": id})
	if got := wait(r.t, opened); got.err != nil {
		r.t.Fatalf("open %s: %v", id, got.err)
	}
}

// forward is viewer's method with params, answered by the Mac when it is asked: the request the
// Mac got (nil: none) and what the viewer got.
func (r *relay) forward(viewer *link, method string, params map[string]any, answer any) (map[string]any, outcome) {
	r.t.Helper()
	done := make(chan outcome, 1)
	go func() {
		result, err := r.reg.Forward(viewer, method, params)
		done <- outcome{result, err}
	}()
	select {
	case got := <-done:
		return nil, got
	case asked := <-r.drawer.sent:
		r.answer(asked, answer)
		return asked, wait(r.t, done)
	case <-time.After(5 * time.Second):
		r.t.Fatalf("%s neither reached the Mac nor answered", method)
		return nil, outcome{}
	}
}

// stopped is the streams the Mac is asked to stop next, sorted.
func (l *link) stopped(t *testing.T, n int) []string {
	t.Helper()
	var ids []string
	for range n {
		request := l.request(t)
		params, _ := request["params"].(map[string]any)
		if request["method"] != "surface.stop" || len(params) != 1 {
			t.Fatalf("the Mac was asked %v, want a surface.stop", request)
		}
		ids = append(ids, params["stream"].(string))
	}
	sort.Strings(ids)
	return ids
}

func frame(stream string) string {
	return `{"event":"surface.frame","board":"brd_a","data":{"stream":"` + stream + `","seq":1,"data":"iVBORw0K\/Gg=="}}`
}

// The viewer that opened a stream drives it, with what it sends reaching the Mac's link
// unchanged and the Mac's answers reaching it unchanged; nobody else can. easld adds nothing:
// the Mac is asked no ack the viewer didn't send.
func TestOnlyTheOpeningViewerDrivesItsStreamThroughItsLink(t *testing.T) {
	r := newRelay(t)
	viewer, outsider := newLink(t), newLink(t)
	opened := r.open(viewer, r.page, Events...)
	request := r.drawer.request(t)
	if request["method"] != "surface.stream" || !reflect.DeepEqual(request["params"], map[string]any{"id": "obj_page", "scale": 1.0}) ||
		!reflect.DeepEqual(request["surfaceEvents"], Events) {
		t.Fatalf("the Mac was asked %v", request)
	}
	answered := map[string]any{"stream": "str_1", "size": map[string]any{"w": 640.0, "h": 480.0}, "scale": 1.0}
	r.answer(request, answered)
	if got := wait(t, opened); got.err != nil || !reflect.DeepEqual(got.result, answered) {
		t.Fatalf("open = %+v, want the Mac's answer", got)
	}
	if len(r.drawer.sent) != 0 {
		t.Fatalf("the Mac was asked %v before the viewer acked", <-r.drawer.sent)
	}
	controls := []struct {
		method string
		params map[string]any
		answer any
	}{
		{"surface.ack", map[string]any{"stream": "str_1", "frame": 0.0}, map[string]any{}},
		{"surface.progress", map[string]any{"stream": "str_1", "frame": 1.0, "offset": 16384.0}, map[string]any{}},
		{"surface.input", map[string]any{"stream": "str_1", "events": []any{map[string]any{"kind": "command", "seq": 1.0, "name": "copy"}}}, map[string]any{"accepted": 1.0, "text": "selected"}},
		{"surface.answer", map[string]any{"stream": "str_1", "dialog": "dlg_1", "accept": true, "password": "hunter2"}, map[string]any{}},
		{"surface.stop", map[string]any{"stream": "str_1"}, map[string]any{"stopped": true}},
	}
	for _, c := range controls {
		if asked, got := r.forward(outsider, c.method, c.params, c.answer); asked != nil || code(got.err) != api.CodeNotFound {
			t.Fatalf("an outsider's %s reached the Mac as %v, answered %+v", c.method, asked, got)
		}
	}
	for _, c := range controls {
		asked, got := r.forward(viewer, c.method, c.params, c.answer)
		if asked["method"] != c.method || !reflect.DeepEqual(asked["params"], c.params) || asked["surfaceEvents"] != nil {
			t.Fatalf("the viewer's %s reached the Mac as %v", c.method, asked)
		}
		if got.err != nil || !reflect.DeepEqual(got.result, c.answer) {
			t.Fatalf("the viewer's %s answered %+v, want %v", c.method, got, c.answer)
		}
	}
	if asked, got := r.forward(viewer, "surface.ack", map[string]any{"stream": "str_1", "frame": 1.0}, map[string]any{}); asked != nil || code(got.err) != api.CodeNotFound {
		t.Fatalf("an ack after stop reached the Mac as %v, answered %+v", asked, got)
	}
}

// A pushed line reaches the one viewer of the live stream it names, as sent, only from the link
// that stream was opened on, on its board, and only an event that viewer heard.
func TestAPushReachesOnlyItsViewerFromItsOwnLink(t *testing.T) {
	r := newRelay(t)
	forger, _ := r.attach("mch_forger")
	frameOnly, all := newLink(t), newLink(t)
	r.live(frameOnly, r.page, "str_1", "surface.frame")
	r.live(all, r.page, "str_2", Events...)
	for name, push := range map[string]struct {
		from *link
		line string
	}{
		"another Mac":    {forger, frame("str_2")},
		"the viewer":     {all, frame("str_2")},
		"another board":  {r.drawer, strings.Replace(frame("str_2"), "brd_a", "brd_b", 1)},
		"no such stream": {r.drawer, frame("str_9")},
		"unheard dialog": {r.drawer, `{"event":"surface.dialog","board":"brd_a","data":{"stream":"str_1","dialog":"dlg_1","kind":"alert","origin":"x"}}`},
		"a board event":  {r.drawer, `{"event":"object.updated","board":"brd_a","data":{"stream":"str_2","id":"obj_page"}}`},
		"malformed":      {r.drawer, `{"event":"surface.frame","board":`},
		"forged close":   {forger, `{"event":"surface.notice","board":"brd_a","data":{"stream":"str_2","kind":"closed"}}`},
	} {
		r.reg.Push(push.from, []byte(push.line))
		if got := append(frameOnly.relayed(), all.relayed()...); len(got) != 0 {
			t.Fatalf("%s: relayed %v", name, got)
		}
	}
	dialog := `{"event":"surface.dialog","board":"brd_a","data":{"stream":"str_2","dialog":"dlg_2","kind":"confirm","origin":"x"}}`
	for _, line := range []string{frame("str_1"), frame("str_2"), dialog} {
		r.reg.Push(r.drawer, []byte(line))
	}
	if got := frameOnly.relayed(); !reflect.DeepEqual(got, []string{frame("str_1")}) {
		t.Fatalf("the frame-only viewer got %v", got)
	}
	if got := all.relayed(); !reflect.DeepEqual(got, []string{frame("str_2"), dialog}) {
		t.Fatalf("the viewer that hears all got %v", got)
	}
	if len(frameOnly.sent)+len(all.sent)+len(forger.sent) != 0 {
		t.Fatal("a push was sent as an event")
	}
}

// A stream the Mac closes, or its viewer stops, is over: nothing the Mac pushes for it after
// reaches the viewer, and the viewer's controls for it are not_found. A stop the Mac fails is
// sent again.
func TestAnEndedStreamHearsAndTakesNothingMore(t *testing.T) {
	r := newRelay(t)
	viewer := newLink(t)
	r.live(viewer, r.page, "str_1", Events...)
	r.live(viewer, r.page, "str_2", Events...)
	closed := `{"event":"surface.notice","board":"brd_a","data":{"stream":"str_1","kind":"closed","reason":"tile closed"}}`
	r.reg.Push(r.drawer, []byte(closed))
	r.reg.Push(r.drawer, []byte(frame("str_1")))
	if got := viewer.relayed(); !reflect.DeepEqual(got, []string{closed}) {
		t.Fatalf("after the Mac closed it the viewer got %v", got)
	}
	if asked, got := r.forward(viewer, "surface.ack", map[string]any{"stream": "str_1", "frame": 0.0}, map[string]any{}); asked != nil || code(got.err) != api.CodeNotFound {
		t.Fatalf("an ack of a closed stream reached the Mac as %v, answered %+v", asked, got)
	}

	stopped := make(chan outcome, 1)
	go func() {
		result, err := r.reg.Forward(viewer, "surface.stop", map[string]any{"stream": "str_2"})
		stopped <- outcome{result, err}
	}()
	request := r.drawer.request(t)
	if request["method"] != "surface.stop" {
		t.Fatalf("the Mac was asked %v, want the viewer's stop", request)
	}
	r.reg.Push(r.drawer, []byte(frame("str_2")))
	r.macs.Answer(r.drawer, map[string]any{"id": request["id"], "ok": false, "error": map[string]any{"code": "unavailable", "message": "busy"}})
	if got := wait(t, stopped); got.err != nil || !reflect.DeepEqual(got.result, map[string]any{"stopped": true}) {
		t.Fatalf("a stop the Mac failed answered %+v", got)
	}
	for range 3 {
		retry := r.drawer.request(t)
		params, _ := retry["params"].(map[string]any)
		if retry["method"] != "surface.stop" || params["stream"] != "str_2" {
			t.Fatalf("the failed stop was retried as %v", retry)
		}
		r.macs.Answer(r.drawer, map[string]any{"id": retry["id"], "ok": false, "error": map[string]any{"code": "unavailable", "message": "busy"}})
	}
	retry := r.drawer.request(t)
	r.answer(retry, map[string]any{"stopped": true})
	if got := viewer.relayed(); len(got) != 0 {
		t.Fatalf("after its stop the viewer got %v", got)
	}
}

func TestBoardClosureEndsCleanupWithoutClosingDrawingConnection(t *testing.T) {
	r := newRelay(t)
	viewer := newLink(t)
	r.live(viewer, r.page, "str_closed", Events...)
	viewer.hangUp()
	stop := r.drawer.request(t)
	r.macs.RemoveBoard(r.page.Board.ID())
	r.macs.Answer(r.drawer, map[string]any{"id": stop["id"], "ok": false, "error": map[string]any{"code": "unavailable", "message": "board closed"}})
	select {
	case retried := <-r.drawer.sent:
		t.Fatalf("closed board kept receiving cleanup: %v", retried)
	case <-time.After(600 * time.Millisecond):
	}
	if !r.drawer.IsOpen() {
		t.Fatal("closing one board disconnected its drawing client")
	}
}

// An open the Mac answers after easld gave up on it is stopped on the Mac, never left driven.
func TestAnOpenTheMacAnswersLateIsStopped(t *testing.T) {
	r := newRelay(t)
	r.reg.OpenDeadline = 20 * time.Millisecond
	viewer := newLink(t)
	opened := r.open(viewer, r.page, Events...)
	request := r.drawer.request(t)
	if got := wait(t, opened); code(got.err) != api.CodeUnavailable {
		t.Fatalf("an unanswered open answered %+v", got)
	}
	r.answer(request, map[string]any{"stream": "str_late"})
	if got := r.drawer.stopped(t, 1); !reflect.DeepEqual(got, []string{"str_late"}) {
		t.Fatalf("stopped %v, want the late stream", got)
	}
	if asked, got := r.forward(viewer, "surface.ack", map[string]any{"stream": "str_late", "frame": 0.0}, map[string]any{}); asked != nil || code(got.err) != api.CodeNotFound {
		t.Fatalf("the late stream took an ack: %v, %+v", asked, got)
	}
}

// A viewer's streams end when its connection closes, stopped on the Mac, whether live or still
// opening; another viewer's stream of the same tile goes on.
func TestAViewerThatLeavesHasItsStreamsStopped(t *testing.T) {
	r := newRelay(t)
	leaving, staying := newLink(t), newLink(t)
	r.live(leaving, r.page, "str_1", Events...)
	r.live(staying, r.page, "str_2", Events...)
	leaving.hangUp()
	if got := r.drawer.stopped(t, 1); !reflect.DeepEqual(got, []string{"str_1"}) {
		t.Fatalf("stopped %v, want the leaving viewer's stream", got)
	}

	opening := newLink(t)
	opened := r.open(opening, r.page, Events...)
	request := r.drawer.request(t)
	opening.hangUp()
	r.answer(request, map[string]any{"stream": "str_3"})
	if got := wait(t, opened); code(got.err) != api.CodeUnavailable {
		t.Fatalf("an open whose viewer left answered %+v", got)
	}
	if got := r.drawer.stopped(t, 1); !reflect.DeepEqual(got, []string{"str_3"}) {
		t.Fatalf("stopped %v, want the stream opened for the viewer that left", got)
	}

	r.reg.Push(r.drawer, []byte(frame("str_2")))
	if got := staying.relayed(); !reflect.DeepEqual(got, []string{frame("str_2")}) {
		t.Fatalf("the staying viewer got %v", got)
	}
}

// A change that ends a stream ends it for good: a live one's viewer is told why (when it hears
// notices) and the Mac stops it; an opening one is stopped as the Mac answers, even if the
// change was undone meanwhile. Streams of other tiles go on.
func TestRecheckEndsLiveStreamsAndDoomsOpeningOnesForGood(t *testing.T) {
	r := newRelay(t)
	other := Key{Board: r.page.Board, Tile: "obj_other", Machine: "mch_drawer"}
	hearing, silent, unrelated, opening := newLink(t), newLink(t), newLink(t), newLink(t)
	r.live(hearing, r.page, "str_1", Events...)
	r.live(silent, r.page, "str_2", "surface.frame")
	r.live(unrelated, other, "str_3", Events...)
	opened := r.open(opening, r.page, Events...)
	request := r.drawer.request(t)

	r.set(r.page, DrawingMoved)
	notice := map[string]any{"event": "surface.notice", "board": "brd_a", "data": map[string]any{"stream": "str_1", "kind": "closed", "reason": "drawing moved"}}
	if got := hearing.request(t); !reflect.DeepEqual(got, notice) {
		t.Fatalf("the viewer that hears notices got %v", got)
	}
	if got := r.drawer.stopped(t, 2); !reflect.DeepEqual(got, []string{"str_1", "str_2"}) {
		t.Fatalf("stopped %v", got)
	}
	r.set(r.page, Holds)
	r.answer(request, map[string]any{"stream": "str_4"})
	if got := wait(t, opened); code(got.err) != api.CodeUnavailable || got.err.Error() != "obj_page's stream ended as it opened: drawing moved" {
		t.Fatalf("an open the drawing moved away from and back answered %+v", got)
	}
	if got := r.drawer.stopped(t, 1); !reflect.DeepEqual(got, []string{"str_4"}) {
		t.Fatalf("stopped %v, want the doomed open's stream", got)
	}

	for _, id := range []string{"str_1", "str_2", "str_3"} {
		r.reg.Push(r.drawer, []byte(frame(id)))
	}
	if got := append(hearing.relayed(), silent.relayed()...); len(got) != 0 {
		t.Fatalf("ended streams got %v", got)
	}
	if len(silent.sent) != 0 {
		t.Fatalf("a viewer that hears no notices was sent %v", <-silent.sent)
	}
	if got := unrelated.relayed(); !reflect.DeepEqual(got, []string{frame("str_3")}) {
		t.Fatalf("another tile's stream got %v", got)
	}
}
