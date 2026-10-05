package store

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/twaldin/easl/easld/internal/metrics"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/swiftjson"
)

// DefaultDebounce is how long a board's changes wait before they are written (BoardStore).
const DefaultDebounce = 500 * time.Millisecond

// Store persists boards as `<dir>/<id>.json`: one per git repository (its common git
// directory), one per directory outside git. Saves are debounced; Flush writes what is pending.
type Store struct {
	Dir      string
	debounce time.Duration
	// lock guards the boards a snapshot function reads; timers take it to snapshot.
	lock sync.Locker
	// taken numbers snapshots in the order they are taken (always under lock), so a save that
	// lost a race to a newer one is dropped instead of renamed over it.
	taken atomic.Uint64

	mu       sync.Mutex
	pending  map[string]*pendingSave
	inFlight int        // debounced saves that left pending but haven't written yet
	idle     *sync.Cond // on mu; signalled when inFlight drops to 0

	writeMu sync.Mutex
	written map[string]uint64 // per board, the number of the snapshot on disk
}

type pendingSave struct {
	timer    *time.Timer
	snapshot func() *Snapshot
}

// New opens (and creates) a store directory. lock is held while a debounced save takes its
// snapshot: the lock the boards are changed under. Temporary files a crashed save left behind
// are removed: one easld at a time uses a home (its instance lock), so none is being written.
func New(dir string, debounce time.Duration, lock sync.Locker) *Store {
	_ = os.MkdirAll(dir, 0o755)
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			if isSaveTemp(e.Name()) {
				os.Remove(filepath.Join(dir, e.Name()))
			}
		}
	}
	s := &Store{Dir: dir, debounce: debounce, lock: lock, pending: map[string]*pendingSave{}, written: map[string]uint64{}}
	s.idle = sync.NewCond(&s.mu)
	return s
}

// Path is the board file of id.
func (s *Store) Path(id string) string { return filepath.Join(s.Dir, id+".json") }

// Unreadable is a board file easld must not open: it doesn't decode, or it is in a newer format
// than Format. The app's `try?` decode would start such a board empty and overwrite the file on
// its first save; easld leaves it alone instead, so a board a newer app wrote is never lost.
type Unreadable struct {
	Path   string
	Format int // the file's format when it is newer than Format, else 0
	Err    error
}

func (e *Unreadable) Error() string {
	if e.Format > 0 {
		return fmt.Sprintf("board file %s is format %d, newer than the %d this easld reads; it is left as it is", e.Path, e.Format, Format)
	}
	return fmt.Sprintf("board file %s can't be read (%v); it is left as it is", e.Path, e.Err)
}

// Read decodes a stored board: nil and no error when there is none, an *Unreadable error when
// there is one easld can't open.
func (s *Store) Read(id string) (*Snapshot, error) {
	path := s.Path(id)
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, &Unreadable{Path: path, Err: err}
	}
	snap, err := DecodeSnapshot(data)
	if err != nil {
		return nil, &Unreadable{Path: path, Err: err}
	}
	if snap.Format != nil && *snap.Format > Format {
		return nil, &Unreadable{Path: path, Format: *snap.Format}
	}
	return snap, nil
}

// ScheduleSave writes the board `debounce` after its last change. snapshot is called with the
// store's lock held.
func (s *Store) ScheduleSave(id string, snapshot func() *Snapshot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.pending[id]; ok {
		p.timer.Stop()
	}
	p := &pendingSave{snapshot: snapshot}
	p.timer = time.AfterFunc(s.debounce, func() {
		s.mu.Lock()
		if s.pending[id] != p {
			s.mu.Unlock()
			return
		}
		delete(s.pending, id)
		s.inFlight++
		s.mu.Unlock()
		defer s.landed()
		s.saveNow(p.snapshot)
	})
	s.pending[id] = p
}

func (s *Store) landed() {
	s.mu.Lock()
	s.inFlight--
	if s.inFlight == 0 {
		s.idle.Broadcast()
	}
	s.mu.Unlock()
}

// saveNow snapshots under the store's lock and writes the snapshot.
func (s *Store) saveNow(snapshot func() *Snapshot) {
	s.lock.Lock()
	snap := snapshot()
	n := s.taken.Add(1)
	s.lock.Unlock()
	_ = s.save(snap, n)
}

// Cancel drops a pending save of id (the caller is about to save it itself).
func (s *Store) Cancel(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.pending[id]; ok {
		p.timer.Stop()
		delete(s.pending, id)
	}
}

// Write saves a snapshot now, atomically (BoardStore.save). The caller holds the store's lock,
// which snap was taken under. A snapshot that can't be encoded (NaN or infinity) leaves the
// file as it was, as the app's save does when JSONEncoder throws.
func (s *Store) Write(snap *Snapshot) error {
	return s.save(snap, s.taken.Add(1))
}

// save writes snapshot number n of its board unless a later one is on disk already.
func (s *Store) save(snap *Snapshot, n uint64) error {
	start := time.Now()
	data, err := snap.Encode()
	if err != nil {
		return err
	}
	metrics.Shared.Record("save.encode", metrics.Since(start), 0)
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if n <= s.written[snap.ID] {
		return nil
	}
	start = time.Now()
	if err := writeAtomic(s.Path(snap.ID), data); err != nil {
		return err
	}
	metrics.Shared.Record("save.write", metrics.Since(start), len(data))
	s.written[snap.ID] = n
	return nil
}

// Flush writes every pending save now and waits for saves already under way (shutdown). It
// takes the store's lock to snapshot, so the caller must not hold it.
func (s *Store) Flush() {
	s.mu.Lock()
	pending := s.pending
	s.pending = map[string]*pendingSave{}
	s.mu.Unlock()
	ids := make([]string, 0, len(pending))
	for id, p := range pending {
		p.timer.Stop()
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		s.saveNow(pending[id].snapshot)
	}
	s.mu.Lock()
	for s.inFlight > 0 {
		s.idle.Wait()
	}
	s.mu.Unlock()
}

// writeAtomic replaces path with data as Data.write(options: .atomic) does: a temporary file
// beside it (mode 0666 less the umask, as Foundation creates it), synced, then renamed over.
func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	var tmp *os.File
	for {
		var suffix [6]byte
		rand.Read(suffix[:])
		name := filepath.Join(filepath.Dir(path), saveTempPrefix(filepath.Base(path))+hex.EncodeToString(suffix[:]))
		f, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666)
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		if err != nil {
			return err
		}
		tmp = f
		break
	}
	_, err := tmp.Write(data)
	if err == nil {
		err = tmp.Sync()
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), path)
	}
	if err != nil {
		os.Remove(tmp.Name())
	}
	return err
}

// saveTempPrefix starts the name of a save's temporary file for the file named base.
func saveTempPrefix(base string) string { return "." + base + ".tmp-" }

// isSaveTemp is whether a store entry is a save's temporary file: `.<id>.json.tmp-<hex>`.
func isSaveTemp(name string) bool {
	head, _, found := strings.Cut(name, ".json.tmp-")
	return found && strings.HasPrefix(head, ".")
}

// Stored is a board as stored on disk, whether or not it is open (BoardStore.Stored).
type Stored struct {
	ID          string
	Root        string
	Archived    bool
	UpdatedAt   *time.Time
	ObjectCount int
	Repo        string // "" outside git
	Worktrees   []WorktreeInfo
	HasRepo     bool
}

// List is every readable board file in the store, sorted by id.
func (s *Store) List() []Stored {
	entries, _ := os.ReadDir(s.Dir)
	var out []Stored
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		path := filepath.Join(s.Dir, e.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		snap, err := DecodeSnapshot(data)
		if err != nil {
			continue
		}
		entry := Stored{ID: snap.ID, Root: snap.Root, Archived: !IsDirectory(snap.Root), ObjectCount: len(snap.Objects)}
		if info, err := e.Info(); err == nil {
			t := info.ModTime()
			entry.UpdatedAt = &t
		}
		if snap.Repo != nil {
			objects := map[string]model.Object{}
			for _, o := range snap.Objects {
				if _, dup := objects[o.ID]; !dup {
					objects[o.ID] = o
				}
			}
			entry.Repo = snap.Repo.CommonDir
			entry.HasRepo = true
			entry.Worktrees = snap.Repo.WorktreeList(objects)
		}
		out = append(out, entry)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Export writes a human-readable snapshot (BoardStore.export): the tray, attention markers,
// agents' answers, lifecycle seqs and repo record left out; pretty-printed with sorted keys and
// unescaped slashes, ending in a newline.
func Export(snap Snapshot, path string) error {
	snap.Tray, snap.HasTray = nil, false
	snap.Attention = nil
	snap.FinalAnswers = nil
	snap.TurnErrors = nil
	snap.LifecycleSeq = nil
	snap.Repo = nil
	snap.Unknown = nil // the app's export writes BoardSnapshot's own keys
	data, err := swiftjson.Encode(snap.JSON(), true, false)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return writeAtomic(path, data)
}

// HashedID is `brd_` + 20 hex digits of SHA-256 of identity.
func HashedID(identity string) string {
	sum := sha256.Sum256([]byte(identity))
	return "brd_" + hex.EncodeToString(sum[:])[:20]
}

// RepoID is the board id of a repository: its common git directory.
func RepoID(commonDir string) string { return HashedID(commonDir) }

// PathID is the board id of a directory outside git: its path.
func PathID(root string) string { return HashedID(Standardized(root)) }

// WorktreeInfo is a worktree as board.list and board.open report it.
type WorktreeInfo struct {
	Path   string
	Branch *string
	Live   bool
	Main   bool
	Region string
}

func (w WorktreeInfo) JSON() map[string]any {
	m := map[string]any{"path": w.Path, "live": w.Live, "main": w.Main}
	if w.Branch != nil {
		m["branch"] = *w.Branch
	}
	if w.Region != "" {
		m["region"] = w.Region
	}
	return m
}

func branchPtr(w Worktree) *string {
	if b, ok := w.Branch(); ok {
		return &b
	}
	return nil
}

func sameBranch(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// WorktreeList is the worktrees to report: the repository's live ones (main checkout first)
// and every recorded one, without repeats; a record's region must exist among objects.
func (r RepoRecord) WorktreeList(objects map[string]model.Object) []WorktreeInfo {
	var list []WorktreeInfo
	for _, w := range Worktrees(r.CommonDir) {
		path := Normalized(w.Toplevel)
		branch := branchPtr(w)
		list = append(list, WorktreeInfo{Path: path, Branch: branch, Live: true, Main: w.IsMain(), Region: r.Region(branch, path, objects)})
	}
	for _, rec := range r.Worktrees {
		seen := false
		for _, l := range list {
			if l.Path == rec.Path && sameBranch(l.Branch, rec.Branch) {
				seen = true
			}
		}
		if seen {
			continue
		}
		region := ""
		if _, ok := objects[rec.Region]; ok && rec.Region != "" {
			region = rec.Region
		}
		checkout := Containing(rec.Path)
		live := checkout != nil && checkout.CommonDir == r.CommonDir && Normalized(checkout.Toplevel) == rec.Path && rec.Branch == nil
		list = append(list, WorktreeInfo{Path: rec.Path, Branch: rec.Branch, Live: live, Region: region})
	}
	return list
}

// Region is the region of branch (any worktree it was in), else of the worktree at path when
// detached; "" when there's none on the board.
func (r RepoRecord) Region(branch *string, path string, objects map[string]model.Object) string {
	for _, w := range r.Worktrees {
		match := false
		if branch != nil {
			match = w.Branch != nil && *w.Branch == *branch
		} else {
			match = w.Path == path && w.Branch == nil
		}
		if match && w.Region != "" {
			if _, ok := objects[w.Region]; ok {
				return w.Region
			}
		}
	}
	return ""
}

// Record adds the worktree at path (normalized) with its branch; false when already recorded.
func (r *RepoRecord) Record(path string, branch *string) bool {
	path = Normalized(path)
	for _, w := range r.Worktrees {
		if w.Path == path && sameBranch(w.Branch, branch) {
			return false
		}
	}
	r.Worktrees = append(r.Worktrees, WorktreeRecord{Path: path, Branch: branch})
	return true
}

// BranchOf is a worktree's branch as an optional (nil when detached).
func BranchOf(w Worktree) *string { return branchPtr(w) }
