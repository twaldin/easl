package board

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

// Sink is an event subscriber's connection.
type Sink interface {
	Send(v any) bool
	IsOpen() bool
}

type subscriber struct {
	sink   Sink
	board  string // "" for every board
	events map[string]bool
}

// Registry is every open board plus event fan-out to subscribers (BoardRegistry in
// ApiRouter.swift). Mu serialises all board work: hold it while calling into any board.
type Registry struct {
	Mu     sync.Mutex
	Store  *store.Store
	boards map[string]*Board
	// Frontmost is the default board for a call that names none.
	Frontmost   string
	subscribers []subscriber
	// Hook observes every board's events after they are applied (the router's agent.wait).
	Hook func(*Board, model.Event)
	// AgentReports is where integrations spool reports they couldn't deliver; "" replays nothing.
	AgentReports string
	pid          int
}

// NewRegistry opens a registry over the boards stored in dir, saving debounce after changes.
func NewRegistry(dir string, debounce time.Duration, agentReports string) *Registry {
	r := &Registry{boards: map[string]*Board{}, AgentReports: agentReports, pid: os.Getpid()}
	r.Store = store.New(dir, debounce, &r.Mu)
	return r
}

// Boards is every open board, by id.
func (r *Registry) Boards() map[string]*Board { return r.boards }

// SortedBoards is the open boards ordered by id.
func (r *Registry) SortedBoards() []*Board {
	ids := make([]string, 0, len(r.boards))
	for id := range r.boards {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]*Board, len(ids))
	for i, id := range ids {
		out[i] = r.boards[id]
	}
	return out
}

// Open is the board for a directory: its repository's board (rooted at the repository's
// canonical root) when it is in git, tagged with the worktree it was opened from, else the
// directory's own board. A board file easld can't read (store.Unreadable) isn't opened.
func (r *Registry) Open(root string) (*Board, error) {
	root = store.Standardized(root)
	worktree := store.Containing(root)
	id := store.PathID(root)
	if worktree != nil {
		id = store.RepoID(worktree.CommonDir)
	}
	if existing, ok := r.boards[id]; ok {
		if worktree != nil {
			existing.OpenedFrom(*worktree)
		}
		return existing, nil
	}
	boardRoot, commonDir := root, ""
	if worktree != nil {
		boardRoot, commonDir = worktree.CanonicalRoot(), worktree.CommonDir
	}
	b, err := r.load(boardRoot, id, commonDir)
	if err != nil {
		return nil, err
	}
	if worktree != nil {
		b.OpenedFrom(*worktree)
	}
	b.OnEvent = func(e model.Event) {
		if r.Hook != nil {
			r.Hook(b, e)
		}
		r.broadcast(e, b.id)
	}
	r.boards[id] = b
	b.Activity.Record(KindRestart, SystemActor, b.revision, "", "", fmt.Sprintf("easl started (pid %d); board opened with %d objects", r.pid, len(b.objects)), "")
	if r.Frontmost == "" {
		r.Frontmost = id
	}
	r.replayAgentReports(b)
	return b, nil
}

// load is BoardStore.load: the stored board (its root following the board's identity), else a
// new one; a repository board records its common git directory.
func (r *Registry) load(root, id, commonDir string) (*Board, error) {
	snap, err := r.Store.Read(id)
	if err != nil {
		return nil, err
	}
	var b *Board
	if snap != nil {
		snap.Root = root
		b = FromSnapshot(snap)
	} else {
		b = New(id, root)
	}
	if commonDir != "" && (b.Repo == nil || b.Repo.CommonDir != commonDir) {
		rec := &store.RepoRecord{CommonDir: commonDir, Worktrees: []store.WorktreeRecord{}}
		if b.Repo != nil {
			rec.Worktrees = b.Repo.Worktrees
			rec.Merged = b.Repo.Merged
		}
		b.Repo = rec
	}
	b.OnChange = func() { r.Store.ScheduleSave(b.id, b.Snapshot) }
	return b, nil
}

// Board is the open board id names: its own, or a legacy board's id a repository board merged.
func (r *Registry) Board(id string) (*Board, bool) {
	if b, ok := r.boards[id]; ok {
		return b, true
	}
	for _, b := range r.SortedBoards() {
		if b.Repo != nil && contains(b.Repo.Merged, id) {
			return b, true
		}
	}
	return nil, false
}

// Containing is the open board holding object id.
func (r *Registry) Containing(id string) (*Board, bool) {
	for _, b := range r.SortedBoards() {
		if _, ok := b.objects[id]; ok {
			return b, true
		}
	}
	return nil, false
}

// Close saves and closes a board.
func (r *Registry) Close(id string) {
	if b, ok := r.boards[id]; ok {
		delete(r.boards, id)
		r.Store.Cancel(id)
		_ = r.Store.Write(b.Snapshot())
	}
	if r.Frontmost == id {
		r.Frontmost = ""
		if ids := r.SortedBoards(); len(ids) > 0 {
			r.Frontmost = ids[0].id
		}
	}
}

// Subscribe adds an event subscriber (board "" for all, events nil for all).
func (r *Registry) Subscribe(sink Sink, board string, events []string) {
	var filter map[string]bool
	if events != nil {
		filter = map[string]bool{}
		for _, e := range events {
			filter[e] = true
		}
	}
	r.subscribers = append(r.subscribers, subscriber{sink, board, filter})
}

func (r *Registry) broadcast(e model.Event, board string) {
	kept := r.subscribers[:0]
	for _, s := range r.subscribers {
		if s.sink.IsOpen() {
			kept = append(kept, s)
		}
	}
	clear(r.subscribers[len(kept):])
	r.subscribers = kept
	if len(kept) == 0 {
		return
	}
	message := map[string]any{"event": e.Name, "board": board, "data": e.Data}
	for _, s := range kept {
		if s.board != "" && s.board != board {
			continue
		}
		if s.events != nil && !s.events[e.Name] {
			continue
		}
		s.sink.Send(message)
	}
}

// replayAgentReports applies what the board's agents spooled while easld was away, oldest
// first, then deletes it (AgentReportSpool).
func (r *Registry) replayAgentReports(b *Board) {
	if r.AgentReports == "" {
		return
	}
	var tiles []string
	for _, id := range b.sortedIDs() {
		if b.objects[id].Type == model.Terminal {
			tiles = append(tiles, id)
		}
	}
	if len(tiles) == 0 {
		return
	}
	entries := ReadSpool(r.AgentReports, tiles)
	if len(entries) == 0 {
		return
	}
	b.Replay(entries)
	RemoveSpool(entries)
}

// ReadSpool is AgentReportSpool.read: the spooled reports of tiles, oldest first; a file that
// reads but isn't a report is deleted.
func ReadSpool(dir string, tiles []string) []SpoolEntry {
	var entries []SpoolEntry
	for _, tile := range tiles {
		folder := filepath.Join(dir, tile)
		names, err := os.ReadDir(folder)
		if err != nil {
			continue
		}
		for _, n := range names {
			name := n.Name()
			if !strings.HasSuffix(name, ".json") || strings.HasPrefix(name, ".") {
				continue
			}
			file := filepath.Join(folder, name)
			data, err := os.ReadFile(file)
			if err != nil {
				continue
			}
			var v map[string]any
			if json.Unmarshal(data, &v) != nil {
				os.Remove(file)
				continue
			}
			seq, ok1 := TruncInt(v["seq"])
			method, ok2 := v["method"].(string)
			params, present := v["params"]
			if !ok1 || !ok2 || !present {
				os.Remove(file)
				continue
			}
			p, _ := params.(map[string]any)
			entries = append(entries, SpoolEntry{Tile: tile, Seq: seq, Method: method, Params: p, File: file})
		}
	}
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].Seq != entries[j].Seq {
			return entries[i].Seq < entries[j].Seq
		}
		return filepath.Base(entries[i].File) < filepath.Base(entries[j].File)
	})
	return entries
}

// RemoveSpool deletes replayed reports, and each tile's folder once empty.
func RemoveSpool(entries []SpoolEntry) {
	folders := map[string]bool{}
	for _, e := range entries {
		os.Remove(e.File)
		folders[filepath.Dir(e.File)] = true
	}
	for f := range folders {
		if names, err := os.ReadDir(f); err == nil && len(names) == 0 {
			os.Remove(f)
		}
	}
}

// Flush writes every pending save (shutdown). The caller must not hold Mu.
func (r *Registry) Flush() { r.Store.Flush() }
