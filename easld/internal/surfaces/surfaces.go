// Package surfaces relays browser tile streams (surface.*, docs/contracts.md "Browser surfaces")
// between a viewer's connection and the attached link of the Mac that draws the tile. easld
// decides only who may talk to which stream: frames, input, dialogs and frame credit are the
// drawing Mac's and the viewer's, passed through unchanged, and none of it outlives the write
// that carries it.
//
// The registry has a lock of its own, never held while waiting on a peer. Open and Recheck run
// with the board lock held (Open lets it go while the Mac answers); Push runs on a drawing
// link's reader and takes only this lock, so a frame never waits on board work, and a reader
// can't wait on the board lock while text.measure holds it waiting for that reader's answer.
// Lock order: the board lock, this one, the clients registry's.
package surfaces

import (
	"context"
	"encoding/json"
	"slices"
	"sync"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
)

// Events are a stream's private events, in the order a stream's hearing lists them.
var Events = []string{"surface.frame", "surface.dialog", "surface.notice"}

const forwardDeadline = 6 * time.Second

// Viewer is the connection that opens a stream, the only one its events reach.
type Viewer interface {
	Send(v any) bool
	// SendLine queues one encoded JSON line as it is (server.Conn.SendLine).
	SendLine(line []byte) bool
	IsOpen() bool
	Done() <-chan struct{}
}

// Key is what a stream was opened against: the board that showed the tile then (a board closed
// and opened again is another), the tile, and the identity of the Mac that drew it
// (drawingMachine.id).
type Key struct {
	Board         *board.Board
	Tile, Machine string
}

// Ended is why easld ends a stream, the reason its viewer's closed notice gives. Holds: it doesn't.
type Ended string

const (
	Holds         Ended = ""
	BoardClosed   Ended = "board closed"
	TileClosed    Ended = "tile closed"
	DrawingMoved  Ended = "drawing moved"
	DrawerOffline Ended = "drawing machine offline"
	viewerLeft    Ended = "its viewer left"
)

// Why is the board's truth about a stream opened against k on drawer, read with the board lock
// held.
type Why func(k Key, drawer *clients.Client) Ended

type stream struct {
	key    Key
	viewer Viewer
	drawer *clients.Client
	hears  []string
	id     string
	doomed Ended
}

func (st *stream) heard(event string) bool { return slices.Contains(st.hears, event) }

// Registry is the streams easld relays: each opening until its drawing Mac answers, then live
// until it ends. An ended stream is gone; nothing revives it.
type Registry struct {
	clients *clients.Registry
	why     Why
	// OpenDeadline is how long Open waits for the drawing Mac: under the app viewer's 15 s, so
	// easld's reason reaches it. The stream of a later answer is stopped.
	OpenDeadline time.Duration

	mu      sync.Mutex
	opening map[*stream]struct{}
	live    map[string]*stream
	watched map[Viewer]struct{}
}

// New is a registry with no streams, opening them through c and ending them when why says so.
func New(c *clients.Registry, why Why) *Registry {
	return &Registry{clients: c, why: why, OpenDeadline: 12 * time.Second,
		opening: map[*stream]struct{}{}, live: map[string]*stream{}, watched: map[Viewer]struct{}{}}
}

// Open is surface.stream with params, unchanged, through drawer (the link ChooseExact chose
// for k) for viewer, which hears the events in hears on k.Board. It records the stream before it
// lets lock go while the Mac answers, then settles it with lock held again: the stream goes live
// only if no Recheck ended it meanwhile, why still holds, and viewer is still connected.
// Otherwise the Mac's stream is stopped and the open fails with the reason, as a stream the Mac
// answers after OpenDeadline is stopped. The result is the Mac's, unchanged. Called, and
// returns, with lock held.
func (s *Registry) Open(lock sync.Locker, k Key, viewer Viewer, hears []string, drawer *clients.Client, params map[string]any) (any, error) {
	st := &stream{key: k, viewer: viewer, drawer: drawer, hears: hears}
	s.mu.Lock()
	s.opening[st] = struct{}{}
	s.watch(viewer)
	s.mu.Unlock()
	lock.Unlock()
	result, failure := s.clients.OpenSurface(drawer, k.Machine, k.Board.ID(), params, hears, s.OpenDeadline, func(late any) {
		if id := streamID(late); id != "" {
			s.stop(drawer, k.Board.ID(), id)
		}
	})
	lock.Lock()
	why := s.why(k, drawer)
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.opening, st)
	if failure != nil {
		return nil, failure
	}
	id := streamID(result)
	if id == "" || s.live[id] != nil {
		return nil, &clients.Failure{Code: api.CodeInternal, Message: "the drawing Mac answered surface.stream without a stream of its own"}
	}
	ended := st.doomed
	if ended == Holds {
		ended = why
	}
	if ended == Holds && !viewer.IsOpen() {
		ended = viewerLeft
	}
	if ended != Holds {
		go s.stop(drawer, k.Board.ID(), id)
		return nil, &clients.Failure{Code: api.CodeUnavailable, Message: k.Tile + "'s stream ended as it opened: " + string(ended)}
	}
	st.id = id
	s.live[id] = st
	return result, nil
}

// Forward is surface.ack, .progress, .input, .answer or .stop from viewer, with params unchanged, to the
// link its stream was opened on, never another link of the same Mac; the result is the Mac's.
// A stream viewer didn't open, or that ended, is not_found, as on a Mac host, and so is one the
// Mac answers not_found for. A stop ends the stream before it is sent, so nothing the Mac
// pushes afterwards reaches the viewer, and is {stopped: true} even when the Mac fails it: the
// stop is sent again, until the Mac answers or its link closes.
func (s *Registry) Forward(viewer Viewer, method string, params map[string]any) (any, error) {
	id, _ := params["stream"].(string)
	s.mu.Lock()
	st := s.live[id]
	owned := st != nil && st.viewer == viewer
	if owned && method == "surface.stop" {
		delete(s.live, id)
	}
	s.mu.Unlock()
	if !owned {
		return nil, &clients.Failure{Code: api.CodeNotFound, Message: "stream " + id + " is not open on this connection"}
	}
	result, failure := s.clients.Call(context.Background(), st.drawer, "", method, params, forwardDeadline)
	switch {
	case failure == nil:
		return result, nil
	case method == "surface.stop":
		if failure.Code != api.CodeNotFound {
			go s.stop(st.drawer, st.key.Board.ID(), id)
		}
		return map[string]any{"stopped": true}, nil
	case failure.Code == api.CodeNotFound && method != "surface.answer":
		s.mu.Lock()
		if s.live[id] == st {
			delete(s.live, id)
		}
		s.mu.Unlock()
	}
	return nil, failure
}

// Recheck ends the streams of board boardID that why no longer holds for. A live one's viewer
// hears a closed notice with the reason (if it heard notices when it opened), after every frame
// already forwarded and before nothing, and the Mac's stream is stopped. An opening one is
// doomed, and Open stops what the Mac answers. Final: a later change back revives nothing.
// Called with the board lock held.
func (s *Registry) Recheck(boardID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for st := range s.opening {
		if st.key.Board.ID() == boardID && st.doomed == Holds {
			st.doomed = s.why(st.key, st.drawer)
		}
	}
	for id, st := range s.live {
		if st.key.Board.ID() != boardID {
			continue
		}
		reason := s.why(st.key, st.drawer)
		if reason == Holds {
			continue
		}
		delete(s.live, id)
		if st.heard("surface.notice") {
			st.viewer.Send(map[string]any{"event": "surface.notice", "board": boardID,
				"data": map[string]any{"stream": id, "kind": "closed", "reason": string(reason)}})
		}
		go s.stop(st.drawer, st.key.Board.ID(), id)
	}
}

// Watches reports whether an opening or live stream shows tile on board boardID: whether a
// change to it needs a Recheck.
func (s *Registry) Watches(boardID, tile string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for st := range s.opening {
		if st.key.Board.ID() == boardID && st.key.Tile == tile {
			return true
		}
	}
	for _, st := range s.live {
		if st.key.Board.ID() == boardID && st.key.Tile == tile {
			return true
		}
	}
	return false
}

// Push takes an event line a drawing link pushed (server.Pushes). It goes, byte for byte, to the
// one viewer whose live stream it names, when from is the link that stream was opened on, board
// is the stream's, and the viewer heard the event when it opened. A closed notice from that link
// also ends the stream. Anything else is dropped: it is never a board event or a broadcast.
// line is valid only during the call.
func (s *Registry) Push(from clients.Conn, line []byte) {
	var head struct {
		Event string `json:"event"`
		Board string `json:"board"`
		Data  struct {
			Stream string `json:"stream"`
			Kind   string `json:"kind"`
		} `json:"data"`
	}
	if json.Unmarshal(line, &head) != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	st := s.live[head.Data.Stream]
	if st == nil || !st.drawer.Is(from) || head.Board != st.key.Board.ID() {
		return
	}
	if head.Event == "surface.notice" && head.Data.Kind == "closed" {
		delete(s.live, st.id)
	}
	if st.heard(head.Event) {
		st.viewer.SendLine(line)
	}
}

func (s *Registry) watch(viewer Viewer) {
	if _, ok := s.watched[viewer]; ok {
		return
	}
	s.watched[viewer] = struct{}{}
	go func() {
		<-viewer.Done()
		s.mu.Lock()
		defer s.mu.Unlock()
		delete(s.watched, viewer)
		for id, st := range s.live {
			if st.viewer == viewer {
				delete(s.live, id)
				go s.stop(st.drawer, st.key.Board.ID(), id)
			}
		}
	}()
}

func (s *Registry) stop(drawer *clients.Client, board, id string) {
	var timer *time.Timer
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	for {
		failure := s.clients.StopSurface(drawer, board, id)
		if failure == nil || failure.Code == api.CodeNotFound {
			return
		}
		if timer == nil {
			timer = time.NewTimer(250 * time.Millisecond)
		} else {
			timer.Reset(250 * time.Millisecond)
		}
		select {
		case <-drawer.Done():
			return
		case <-timer.C:
		}
	}
}

func streamID(result any) string {
	m, _ := result.(map[string]any)
	id, _ := m["stream"].(string)
	return id
}
