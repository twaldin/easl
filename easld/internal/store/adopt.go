package store

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/route"
	"github.com/twaldin/easl/easld/internal/swiftjson"
)

// A folder's board (path-keyed: PathID of its root) made before the folder was in git is taken
// into its repository's board when that board first loads, as the app's BoardStore does
// (mergeIntoRepositoryBoard, RepoBoardMigration for identity `.path`; docs/design/repo-boards.md
// "Migration"): its objects become the repository board's (a region of it unless it is the
// first, from the main checkout), re-rooted onto the canonical root; its file moves to
// BackupFolder and the run is appended to the ledger there. easld writes no per-branch board,
// so the app's launch migration alone merges those.

// BackupFolder is RepoBoardMigration.backupFolder: where merged board files move, beside the ledger.
const BackupFolder = "pre-repo-migration"

// LedgerFile is RepoBoardMigration.reportFile: every migration run's report, latest last.
const LedgerFile = "migration.json"

// regionGap is RepoBoardMigration.gap: space between regions placed side by side.
const regionGap = 200.0

// MigrationRun is RepoBoardMigration.Report: one run of the ledger.
type MigrationRun struct {
	RanAt  time.Time
	DryRun bool
	Repos  []RepoReport
	// NonGit is the app's: easld identifies no board outside git. Unresolved (the legacy boards
	// the run left in the store, by board, sorted) is the last run's, carried over, with this
	// run's conflicts (see appendToLedger).
	NonGit     []string
	Unresolved []any
}

// RepoReport is RepoBoardMigration.RepoReport.
type RepoReport struct {
	Board         string
	Root          string
	CommonDir     string
	ObjectsBefore int
	ObjectsAfter  int
	Legacy        []LegacyReport
	KeyRenames    []KeyRename
}

// KeyRename is RepoBoardMigration.KeyRename.
type KeyRename struct {
	Object, Board, From, To string
}

// LegacyReport is RepoBoardMigration.LegacyReport, of a path-keyed board; Branch is its live
// worktree's HEAD, independent of the absolute reroot anchor.
type LegacyReport struct {
	Board, Root, Label string
	Branch             *string
	Anchor             string // "main" or "worktree"
	Worktree           string
	WorktreeLive       bool
	Temporary          bool
	Status             string // merged, alreadyMerged, conflict
	ObjectsBefore      int
	ObjectsAfter       int
	Region             string    // "" for none
	Offset             []float64 // nil for none
	Unanchored         []string
}

// Loading is BoardStore.load's bookkeeping before board id's file is read: the board counts as
// loaded from now on and, the first time a repository's board (commonDir != "") loads, the
// boards of directories that became part of that repository are merged into it
// (mergeIntoRepositoryBoard). The caller holds the store's lock.
func (s *Store) Loading(id, commonDir string, now time.Time) {
	if s.loaded == nil {
		s.loaded = map[string]bool{}
	}
	if s.loaded[id] {
		return
	}
	s.loaded[id] = true
	if commonDir != "" {
		s.mergeIntoRepositoryBoard(commonDir, now)
	}
}

// mergeIntoRepositoryBoard is BoardStore.mergeIntoRepositoryBoard for path-keyed boards: those
// whose directory lies in a worktree of commonDir now, none loaded, are merged into its board
// (RepoBoardMigration.run with `only` and `skipping`). Starts no git process: a path-keyed
// board costs the walk up its directory for `.git` (Containing).
//
// A store holding legacy per-branch boards with no ledger yet is left alone: the app's launch
// migration hasn't run on it, and it merges those boards and the path-keyed ones in git alike.
// A ledger written here would tell the app it had run (RepoBoardMigration.pending), and the
// legacy boards would never be merged. easld identifies no legacy board, so that store is the
// app's to migrate first.
func (s *Store) mergeIntoRepositoryBoard(commonDir string, now time.Time) {
	stored := s.storedPathBoards()
	if s.legacyStored && !exists(filepath.Join(s.Dir, BackupFolder, LedgerFile)) {
		return
	}
	var boards []pathBoard
	for _, id := range sortedKeys(stored) {
		root := s.pathBoards[id]
		if s.loaded[id] || !IsDirectory(root) {
			continue
		}
		w := Containing(Standardized(root))
		if w == nil || w.CommonDir != commonDir {
			continue
		}
		file := s.Path(id)
		data, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		snap, err := DecodeSnapshot(data)
		// A board in a newer format than easld reads isn't taken apart; nor is a file that
		// changed into another board since it was indexed.
		if err != nil || (snap.Format != nil && *snap.Format > Format) || snap.ID != id || snap.Repo != nil {
			continue
		}
		var modified time.Time
		if info, err := os.Stat(file); err == nil {
			modified = info.ModTime()
		}
		boards = append(boards, pathBoard{file: file, snap: snap, top: w.Toplevel, branch: branchPtr(*w), modified: modified})
	}
	if len(boards) == 0 {
		return
	}
	targetID := RepoID(commonDir)
	existing, err := s.Read(targetID)
	if err != nil {
		// A repository board easld can't read is never rewritten (Unreadable).
		return
	}
	var existingModified time.Time
	if info, err := os.Stat(s.Path(targetID)); err == nil && existing != nil {
		existingModified = info.ModTime()
	}
	target, report, merged := mergePathBoards(boards, existing, existingModified, commonDir, now)
	// Nothing merged or backed up (every board a conflict): the target stays as it is.
	if len(merged) > 0 {
		target.Revision++
		if err := s.Write(target); err != nil {
			return
		}
		for _, file := range merged {
			backUp(file, s.Dir, now)
		}
	}
	for _, l := range report.Legacy {
		if l.Status != "conflict" {
			delete(s.pathBoards, l.Board)
		}
	}
	appendToLedger(&MigrationRun{RanAt: now, Repos: []RepoReport{report}, NonGit: []string{}, Unresolved: []any{}}, s.Dir)
}

// storedPathBoards is BoardStore.storedPathBoards: pathBoards, read from the store's files the
// first time (a board without `repo` whose id is its root's PathID); legacyStored says whether
// a board without `repo` has another id (a legacy per-branch board).
func (s *Store) storedPathBoards() map[string]string {
	if s.pathBoards != nil {
		return s.pathBoards
	}
	found := map[string]string{}
	entries, _ := os.ReadDir(s.Dir)
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(s.Dir, e.Name()))
		if err != nil {
			continue
		}
		var header struct {
			ID   *string         `json:"id"`
			Root *string         `json:"root"`
			Repo json.RawMessage `json:"repo"`
		}
		if json.Unmarshal(data, &header) != nil || header.ID == nil || header.Root == nil {
			continue
		}
		if len(header.Repo) > 0 && string(header.Repo) != "null" {
			continue
		}
		if *header.ID != PathID(*header.Root) {
			s.legacyStored = true
			continue
		}
		found[*header.ID] = *header.Root
	}
	s.pathBoards = found
	return found
}

// pathBoard is RepoBoardMigration.Legacy of identity `.path`: a stored path-keyed board, live in
// the worktree whose top level is top.
type pathBoard struct {
	file     string
	snap     *Snapshot
	top      string
	branch   *string
	modified time.Time // when its file was saved: the latest board's object keeps a shared key
}

// label is RepoBoardMigration.label: the worktree's directory name.
func (p pathBoard) label() string { return filepath.Base(p.top) }

// keySource is where an object came from, for keys two boards hold (uniqueKeys).
type keySource struct {
	board    string
	modified time.Time
	label    *string
}

// mergePathBoards is RepoBoardMigration.merge for boards of identity `.path`: the repository
// board (existing, else a new one at the canonical root) with boards merged in, its report, and
// the files of the boards merged (or merged before) to back up.
func mergePathBoards(boards []pathBoard, existing *Snapshot, existingModified time.Time, commonDir string, now time.Time) (*Snapshot, RepoReport, []string) {
	canonical := CanonicalRoot(commonDir)
	var main *Worktree
	if w := Containing(canonical); w != nil && w.IsMain() && w.CommonDir == commonDir {
		main = w
	}
	target := existing
	if target == nil {
		format := Format
		target = &Snapshot{Format: &format, ID: RepoID(commonDir), Root: canonical, Objects: []model.Object{}}
	}
	target.Root = canonical
	repo := RepoRecord{CommonDir: commonDir, Worktrees: []WorktreeRecord{}}
	if target.Repo != nil {
		repo = *target.Repo
		repo.Worktrees = append([]WorktreeRecord{}, target.Repo.Worktrees...)
		if target.Repo.Merged != nil {
			repo.Merged = append([]string{}, target.Repo.Merged...)
		}
	}
	before := len(target.Objects)

	isMainCheckout := func(p pathBoard) bool {
		return main != nil && realPath(Standardized(p.top)) == realPath(Standardized(main.Toplevel))
	}
	base := -1
	if len(target.Objects) == 0 {
		for i, p := range boards {
			if isMainCheckout(p) {
				base = i
				break
			}
		}
	}
	var ordered []pathBoard
	var rest []pathBoard
	for i, p := range boards {
		if i == base {
			ordered = append(ordered, p)
		} else {
			rest = append(rest, p)
		}
	}
	sort.SliceStable(rest, func(i, j int) bool { return rest[i].label() < rest[j].label() })
	ordered = append(ordered, rest...)
	isBase := func(p pathBoard) bool { return base >= 0 && p.file == boards[base].file }

	var reports []LegacyReport
	var merged []string
	placed, hasPlaced := extent(target.Objects)
	sources := map[string]keySource{}
	for _, o := range target.Objects {
		sources[o.ID] = keySource{board: target.ID, modified: existingModified}
	}
	for _, p := range ordered {
		snap := p.snap
		label := p.label()
		anchor := anchorAbsolute
		if isBase(p) || isMainCheckout(p) {
			anchor = anchorMain
		}
		entry := LegacyReport{Board: snap.ID, Root: snap.Root, Label: label, Branch: p.branch, Anchor: anchor, Worktree: p.top, WorktreeLive: true,
			Temporary: isTemporary(p.top), Status: "merged", ObjectsBefore: len(snap.Objects), Unanchored: []string{}}
		if slices.Contains(repo.Merged, snap.ID) {
			entry.Status = "alreadyMerged"
			reports = append(reports, entry)
			merged = append(merged, p.file)
			continue
		}
		taken := map[string]bool{}
		for _, o := range target.Objects {
			taken[o.ID] = true
		}
		if slices.ContainsFunc(snap.Objects, func(o model.Object) bool { return taken[o.ID] }) {
			entry.Status = "conflict"
			reports = append(reports, entry)
			continue
		}

		r := rerooter{oldRoot: Standardized(snap.Root), top: p.top, live: true, anchor: anchor, destinationRoot: Standardized(target.Root)}
		format := 1
		if snap.Format != nil {
			format = *snap.Format
		}
		objects := make([]model.Object, len(snap.Objects))
		for i, o := range snap.Objects {
			o = o.Clone()
			if format < 2 && o.Type.IsTile() {
				o.Frame.H += route.TileTitleHeight
			}
			objects[i] = r.reroot(o)
		}
		tray := make([]model.Mention, len(snap.Tray))
		for i, m := range snap.Tray {
			tray[i] = r.rerootMention(m)
		}

		var region *model.Object
		if !isBase(p) && len(objects) > 0 {
			// Every object of the board moves right of what is placed, top-aligned with it,
			// inside a group titled with its worktree.
			grouped := map[string]bool{}
			for _, o := range objects {
				if o.Type != model.Group {
					continue
				}
				if spec, ok := route.ParseGroup(o.Props); ok {
					for _, id := range spec.Members {
						grouped[id] = true
					}
				}
			}
			var members []string
			var memberFrames, all []model.Frame
			for _, o := range objects {
				all = append(all, o.Frame)
				if !grouped[o.ID] && o.Type != model.Arrow {
					members = append(members, o.ID)
					memberFrames = append(memberFrames, o.Frame)
				}
			}
			bounds, ok := union(memberFrames)
			if !ok {
				bounds, _ = union(all)
			}
			inset := route.GroupDefaultPadding
			dx, dy := 0.0, 0.0
			if hasPlaced {
				dx = placed.MaxX() + regionGap - (bounds.X - inset)
				dy = placed.Y - (bounds.Y - inset - route.GroupTitleHeight)
			}
			dz := 0.0
			if len(target.Objects) > 0 {
				dz = maxZ(target.Objects, 0) + 1 - minZ(objects, 0)
			}
			for i := range objects {
				objects[i] = shifted(objects[i], dx, dy, dz)
			}
			if len(members) > 0 {
				list := make([]any, len(members))
				for i, id := range members {
					list[i] = id
				}
				region = &model.Object{
					ID: model.NewID("obj"), Type: model.Group, Rev: 1, CreatedBy: model.Actor{Kind: "user"}, CreatedAt: now, UpdatedAt: now,
					Frame: model.Frame{X: bounds.X + dx - inset, Y: bounds.Y + dy - inset - route.GroupTitleHeight,
						W: bounds.W + 2*inset, H: bounds.H + 2*inset + route.GroupTitleHeight},
					Z:     maxZ(objects, 0) + 1,
					Props: map[string]any{"members": list, "title": label, "key": "worktree:" + label},
				}
			}
			entry.Offset = []float64{dx, dy}
		}
		if region != nil {
			objects = append(objects, *region)
			// A throwaway checkout's region stays marked until the user has seen it.
			if entry.Temporary {
				message := fmt.Sprintf("From a temporary worktree (%s): delete this region if you don't need it", p.top)
				target.Attention = append(target.Attention, Attention{Object: region.ID, Message: &message, RaisedAt: now})
			}
		}
		for _, o := range objects {
			sources[o.ID] = keySource{board: snap.ID, modified: p.modified, label: &label}
		}
		target.Objects = append(target.Objects, objects...)
		if e, ok := extent(objects); ok {
			if hasPlaced {
				placed, _ = union([]model.Frame{placed, e})
			} else {
				placed, hasPlaced = e, true
			}
		}

		target.Tray = uniqueBy(append(append([]model.Mention{}, target.Tray...), tray...), func(m model.Mention) string { return m.ID })
		target.HasTray = true
		target.Attention = uniqueBy(append(append([]Attention{}, target.Attention...), snap.Attention...), func(a Attention) string { return a.Object })
		if len(target.Attention) == 0 {
			target.Attention = nil
		}
		target.FinalAnswers = mergedMap(target.FinalAnswers, snap.FinalAnswers)
		target.TurnErrors = mergedMap(target.TurnErrors, snap.TurnErrors)
		target.LifecycleSeq = mergedMap(target.LifecycleSeq, snap.LifecycleSeq)
		if len(snap.RelaunchedAgents) > 0 {
			target.RelaunchedAgents = append(target.RelaunchedAgents, snap.RelaunchedAgents...)
			slices.Sort(target.RelaunchedAgents)
			target.RelaunchedAgents = slices.Compact(target.RelaunchedAgents)
		}
		// Renamed terminals' old names and their unacknowledged messages come along: a message
		// the board drops is neither delivered nor bounced.
		target.Aliases = mergedMap(target.Aliases, snap.Aliases)
		for _, tile := range sortedKeys(snap.Messages) {
			if target.Messages == nil {
				target.Messages = map[string][]Message{}
			}
			for _, m := range snap.Messages[tile] {
				mentions := make([]model.Mention, len(m.Mentions))
				for i, men := range m.Mentions {
					mentions[i] = r.rerootMention(men)
				}
				m.Mentions = mentions
				target.Messages[tile] = append(target.Messages[tile], m)
			}
		}
		if theirs := snap.PromptTarget; theirs != nil {
			ours := PromptTargetState{FocusOrder: []string{}}
			if target.PromptTarget != nil {
				ours = *target.PromptTarget
			}
			// The base board's terminals stay the most recently focused.
			if isBase(p) {
				ours.FocusOrder = append(append([]string{}, ours.FocusOrder...), theirs.FocusOrder...)
			} else {
				ours.FocusOrder = append(append([]string{}, theirs.FocusOrder...), ours.FocusOrder...)
			}
			if ours.Chosen == "" {
				ours.Chosen = theirs.Chosen
			}
			target.PromptTarget = &ours
		}
		target.Revision = max(target.Revision, snap.Revision)
		if !(anchor == anchorMain && isMainCheckout(p)) || region != nil {
			path := Normalized(p.top)
			regionID := ""
			if region != nil {
				regionID = region.ID
			}
			if i := slices.IndexFunc(repo.Worktrees, func(w WorktreeRecord) bool { return w.Path == path && sameBranch(w.Branch, p.branch) }); i >= 0 {
				if regionID != "" {
					repo.Worktrees[i].Region = regionID
				}
			} else {
				repo.Worktrees = append(repo.Worktrees, WorktreeRecord{Path: path, Branch: p.branch, Region: regionID})
			}
		}
		repo.Merged = append(repo.Merged, snap.ID)
		entry.ObjectsAfter = len(objects)
		if region != nil {
			entry.Region = region.ID
		}
		entry.Unanchored = r.unanchored
		reports = append(reports, entry)
		merged = append(merged, p.file)
	}
	renames := uniqueKeys(target.Objects, sources)
	format := Format
	target.Format = &format
	target.Repo = &repo
	report := RepoReport{Board: target.ID, Root: canonical, CommonDir: commonDir, ObjectsBefore: before, ObjectsAfter: len(target.Objects),
		Legacy: reports, KeyRenames: renames}
	return target, report, merged
}

// uniqueKeys is RepoBoardMigration.uniqueKeys: one holder per `props.key`, the object from the
// board saved last keeps it, every other becomes `<key>@<its board's worktree>` (a further `-2`,
// `-3` when that is taken too).
func uniqueKeys(objects []model.Object, sources map[string]keySource) []KeyRename {
	holders := map[string][]int{}
	for i, o := range objects {
		if key, _ := o.Props["key"].(string); key != "" {
			holders[key] = append(holders[key], i)
		}
	}
	taken := map[string]bool{}
	for key := range holders {
		taken[key] = true
	}
	renames := []KeyRename{}
	for _, key := range sortedKeys(holders) {
		indices := holders[key]
		if len(indices) < 2 {
			continue
		}
		ranked := append([]int{}, indices...)
		sort.SliceStable(ranked, func(a, b int) bool {
			x, y := sources[objects[ranked[a]].ID].modified, sources[objects[ranked[b]].ID].modified
			if !x.Equal(y) {
				return x.After(y)
			}
			return objects[ranked[a]].ID < objects[ranked[b]].ID
		})
		for _, i := range ranked[1:] {
			source, known := sources[objects[i].ID]
			label := "repo"
			if source.label != nil {
				label = *source.label
			}
			base := key + "@" + label
			renamed, n := base, 2
			for taken[renamed] {
				renamed = fmt.Sprintf("%s-%d", base, n)
				n++
			}
			taken[renamed] = true
			if objects[i].Props == nil {
				objects[i].Props = map[string]any{}
			}
			objects[i].Props["key"] = renamed
			board := ""
			if known {
				board = source.board
			}
			renames = append(renames, KeyRename{Object: objects[i].ID, Board: board, From: key, To: renamed})
		}
	}
	return renames
}

// isTemporary is RepoBoardMigration.isTemporary: the worktree is (was) in a temporary directory.
func isTemporary(path string) bool {
	real := realPath(Standardized(path))
	return strings.HasPrefix(real, "/private/tmp/") || strings.HasPrefix(real, "/private/var/folders/")
}

// shifted is RepoBoardMigration.shifted: an object moved by (dx, dy) and its z by dz; an arrow's
// point-bound ends move with it.
func shifted(o model.Object, dx, dy, dz float64) model.Object {
	o.Frame.X += dx
	o.Frame.Y += dy
	o.Z += dz
	if o.Type == model.Arrow && o.Props != nil {
		for _, end := range []string{"from", "to"} {
			m, _ := o.Props[end].(map[string]any)
			point, _ := m["point"].([]any)
			if len(point) != 2 {
				continue
			}
			x, ok1 := point[0].(float64)
			y, ok2 := point[1].(float64)
			if !ok1 || !ok2 {
				continue
			}
			o.Props[end] = map[string]any{"point": []any{x + dx, y + dy}}
		}
	}
	return o
}

// extent is RepoBoardMigration.extent: the bounds of what the objects draw (arrows follow their
// ends, so they don't count unless nothing else is there).
func extent(objects []model.Object) (model.Frame, bool) {
	var drawn, all []model.Frame
	for _, o := range objects {
		all = append(all, o.Frame)
		if o.Type != model.Arrow {
			drawn = append(drawn, o.Frame)
		}
	}
	if f, ok := union(drawn); ok {
		return f, true
	}
	return union(all)
}

func union(frames []model.Frame) (model.Frame, bool) {
	if len(frames) == 0 {
		return model.Frame{}, false
	}
	u := frames[0]
	for _, f := range frames[1:] {
		x, y := min(u.X, f.X), min(u.Y, f.Y)
		u = model.Frame{X: x, Y: y, W: max(u.MaxX(), f.MaxX()) - x, H: max(u.MaxY(), f.MaxY()) - y}
	}
	return u, true
}

// maxZ and minZ are the objects' highest and lowest z, or `none` without objects.
func maxZ(objects []model.Object, none float64) float64 {
	if len(objects) == 0 {
		return none
	}
	z := objects[0].Z
	for _, o := range objects[1:] {
		z = max(z, o.Z)
	}
	return z
}

func minZ(objects []model.Object, none float64) float64 {
	if len(objects) == 0 {
		return none
	}
	z := objects[0].Z
	for _, o := range objects[1:] {
		z = min(z, o.Z)
	}
	return z
}

// mergedMap is ours with theirs' entries it lacks; nil when that is empty.
func mergedMap[V any](ours, theirs map[string]V) map[string]V {
	out := map[string]V{}
	for k, v := range theirs {
		out[k] = v
	}
	for k, v := range ours {
		out[k] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func uniqueBy[T any](list []T, key func(T) string) []T {
	seen := map[string]bool{}
	out := []T{}
	for _, v := range list {
		if k := key(v); !seen[k] {
			seen[k] = true
			out = append(out, v)
		}
	}
	return out
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Rerooter anchors (Rerooter.Anchor.name) a path-keyed board can have: it names no branch.
const (
	anchorMain     = "main"     // the main checkout: paths relative to the new root
	anchorAbsolute = "worktree" // another worktree: paths absolute in it
)

// rerooter is Rerooter for a board without a branch (anchor main or absolute): it rewrites a
// path-keyed board's paths for the repository board's root.
type rerooter struct {
	oldRoot, top string
	live         bool
	anchor       string
	// destinationRoot is the board that will build the diagram next, not this worktree's top.
	destinationRoot string
	unanchored      []string
}

// absolute is `path` as written on the old board, absolute.
func (r *rerooter) absolute(path string) string {
	if strings.HasPrefix(path, "/") {
		return path
	}
	return Standardized(r.oldRoot + "/" + path)
}

// repoRelative is `path` relative to the repository's top level, when it lies in the worktree.
func (r *rerooter) repoRelative(path string) (string, bool) {
	abs := r.absolute(path)
	if strings.HasPrefix(abs, r.top+"/") {
		return abs[len(r.top)+1:], true
	}
	return "", false
}

// tilePath is Rerooter.tilePath without a branch: relative to the repository from the main
// checkout, else absolute in the worktree.
func (r *rerooter) tilePath(path, what string) string {
	if strings.HasPrefix(path, "/") {
		return path
	}
	if r.anchor == anchorMain {
		if rel, ok := r.repoRelative(path); ok {
			return rel
		}
	}
	return r.pinned(r.absolute(path), what)
}

// worktreePath is Rerooter.worktreePath: a path nothing anchors by branch (an image).
func (r *rerooter) worktreePath(path, what string) string { return r.tilePath(path, what) }

// pinned is an absolute path in the worktree, reported when that worktree is gone or the path is.
func (r *rerooter) pinned(path, what string) string {
	if !r.live || !exists(path) {
		r.unanchored = append(r.unanchored, what+": "+path)
	}
	return path
}

// rootPath is Rerooter.rootPath: a `root` prop, relative to the new root in the main checkout,
// else absolute.
func (r *rerooter) rootPath(path, what string) string {
	if r.anchor == anchorMain {
		if rel, ok := r.repoRelative(path); ok {
			if rel == "" {
				return "."
			}
			return rel
		}
	}
	abs := r.absolute(path)
	if !exists(abs) {
		r.unanchored = append(r.unanchored, what+": "+abs)
	}
	return abs
}

// reroot is Rerooter.reroot(_:branch:) with no branch. o is the caller's own copy.
func (r *rerooter) reroot(o model.Object) model.Object {
	props := o.Props
	if props == nil {
		return o
	}
	what := o.ID + " " + string(o.Type)
	switch o.Type {
	case model.Code:
		if path, ok := props["path"].(string); ok {
			props["path"] = r.tilePath(path, what)
		}
		if history, ok := props["history"].([]any); ok {
			for i, entry := range history {
				fields, _ := entry.(map[string]any)
				if path, ok := fields["path"].(string); ok {
					fields["path"] = r.tilePath(path, what+" history")
					history[i] = fields
				}
			}
		}
	case model.Note, model.HTML:
		// A note's relative images and links resolve against its root, the board's when it
		// names none: the old root, unless that is the new one.
		if root, _ := props["root"].(string); root != "" {
			props["root"] = r.rootPath(root, what)
		} else if r.anchor == anchorAbsolute || r.place() != "" {
			props["root"] = r.rootPath(r.oldRoot, what)
		}
	case model.Changes:
		if root, _ := props["root"].(string); root != "" {
			props["root"] = r.rootPath(root, what)
			break
		}
		// Paths and Viewed keys were relative to the old root.
		place := r.place()
		moved := func(path string) string {
			switch {
			case strings.HasPrefix(path, "/"):
				return path
			case r.anchor == anchorAbsolute:
				return r.absolute(path)
			case place == "":
				return path
			}
			return place + "/" + path
		}
		if r.anchor == anchorAbsolute {
			props["root"] = r.rootPath(r.oldRoot, what)
		} else if paths, ok := props["paths"].([]any); ok {
			for i, p := range paths {
				if s, ok := p.(string); ok {
					paths[i] = moved(s)
				}
			}
		}
		if viewed, ok := props["viewed"].(map[string]any); ok {
			out := map[string]any{}
			for _, k := range sortedKeys(viewed) {
				if _, dup := out[moved(k)]; !dup {
					out[moved(k)] = viewed[k]
				}
			}
			props["viewed"] = out
		}
	case model.Image:
		if path, ok := props["path"].(string); ok {
			props["path"] = r.worktreePath(path, what)
		}
	case model.Diagram:
		// Its file, the graph as last computed (node paths and ids, its aim) and the nodes it
		// expanded, as the repository board's next build writes them (moved), so that build
		// finds them again: nothing anchors a diagram by branch.
		if path, ok := props["path"].(string); ok {
			rebased := r.moved(path)
			if strings.HasPrefix(rebased, "/") && !strings.HasPrefix(path, "/") {
				rebased = r.pinned(rebased, what)
			}
			props["path"] = rebased
		}
		if expanded, ok := props["expanded"].([]any); ok {
			for i, id := range expanded {
				if id, ok := id.(string); ok {
					expanded[i] = r.nodeID(id)
				}
			}
		}
		graph, _ := props["graph"].(map[string]any)
		if aim, ok := graph["aim"].(map[string]any); ok {
			if path, ok := aim["path"].(string); ok {
				aim["path"] = r.moved(path)
			}
		}
		if root, ok := graph["root"].(string); ok {
			graph["root"] = r.nodeID(root)
		}
		nodes, _ := graph["nodes"].([]any)
		for _, node := range nodes {
			if fields, ok := node.(map[string]any); ok {
				if id, ok := fields["id"].(string); ok {
					fields["id"] = r.nodeID(id)
				}
				if path, ok := fields["path"].(string); ok {
					fields["path"] = r.moved(path)
				}
			}
		}
		edges, _ := graph["edges"].([]any)
		for _, edge := range edges {
			if fields, ok := edge.(map[string]any); ok {
				for _, end := range []string{"from", "to"} {
					if id, ok := fields[end].(string); ok {
						fields[end] = r.nodeID(id)
					}
				}
			}
		}
	case model.Arrow:
		// An end bound to a diagram's node names it by id.
		for _, end := range []string{"from", "to"} {
			if binding, ok := props[end].(map[string]any); ok {
				if node, ok := binding["node"].(string); ok {
					binding["node"] = r.nodeID(node)
				}
			}
		}
	case model.Terminal:
		if cwd, _ := props["cwd"].(string); cwd != "" {
			dir := r.absolute(cwd)
			props["cwd"] = dir
			if !r.live || !IsDirectory(dir) {
				r.unanchored = append(r.unanchored, what+" cwd: "+dir)
			}
			if _, has := props["worktree"]; !has && (dir == r.top || strings.HasPrefix(dir, r.top+"/")) {
				props["worktree"] = Normalized(r.top)
			}
		}
	}
	return o
}

// place is the old root relative to the worktree's top level ("" when it is the top level).
func (r *rerooter) place() string {
	if strings.HasPrefix(r.oldRoot, r.top+"/") {
		return r.oldRoot[len(r.top)+1:]
	}
	return ""
}

// moved is Rerooter.moved: as Board.RelativePath and the destination board's next diagram
// build write it, relative to that board's root when beneath it as written or through symlinks,
// including nested linked worktrees; standardized and absolute otherwise.
func (r *rerooter) moved(path string) string {
	abs := Standardized(r.absolute(path))
	if strings.HasPrefix(abs, r.destinationRoot+"/") {
		return abs[len(r.destinationRoot)+1:]
	}
	real, realRoot := realPath(abs), realPath(r.destinationRoot)
	if strings.HasPrefix(real, realRoot+"/") {
		return real[len(realRoot)+1:]
	}
	return abs
}

// nodeID is Rerooter.nodeID: a diagram node's id, `<path>#<symbol>` (CallGraphBuilder), its path
// moved as the node's is, so the diagram's next build finds its nodes, expansions and bound
// arrows again.
func (r *rerooter) nodeID(id string) string {
	path, symbol, found := strings.Cut(id, "#")
	if !found {
		return id
	}
	return r.moved(path) + "#" + symbol
}

// rerootMention is Rerooter.reroot(_: Mention): a staged code or image mention's path, rewritten
// as its tile's.
func (r *rerooter) rerootMention(m model.Mention) model.Mention {
	kind, _ := m.Target["kind"].(string)
	path, ok := m.Target["path"].(string)
	if !ok || (kind != "code" && kind != "image") {
		return m
	}
	target, _ := model.Clone(m.Target).(map[string]any)
	if kind == "code" {
		target["path"] = r.tilePath(path, "tray "+m.ID)
	} else {
		target["path"] = r.worktreePath(path, "tray "+m.ID)
	}
	m.Target = target
	return m
}

// backUp is RepoBoardMigration.backUp: file moves to BackupFolder, as `<id>-<unix seconds>.json`
// when its name is taken there.
func backUp(file, dir string, now time.Time) {
	backups := filepath.Join(dir, BackupFolder)
	_ = os.MkdirAll(backups, 0o755)
	destination := filepath.Join(backups, filepath.Base(file))
	if exists(destination) {
		destination = filepath.Join(backups, fmt.Sprintf("%s-%d.json", strings.TrimSuffix(filepath.Base(file), ".json"), now.Unix()))
	}
	_ = os.Rename(file, destination)
}

// appendToLedger is RepoBoardMigration.appendToLedger: run appended to the ledger's runs (its
// earlier runs kept as they decode), pretty-printed with sorted keys and unescaped slashes. A
// ledger that isn't one starts again, as the app's would. The app reads the last run's
// `unresolved` as the legacy boards to retry, and lists there every legacy board a run leaves
// in the store, conflicts too, sorted, whichever repository the run is for. easld identifies
// only this repository's folder boards: the last run's other boards carry over, and this run's
// conflicts join them. A run that took in nothing (only conflicts) and leaves the last run's
// `unresolved` as it was isn't appended: each load would add it again.
func appendToLedger(run *MigrationRun, dir string) {
	path := filepath.Join(dir, BackupFolder, LedgerFile)
	ledger := map[string]any{}
	if data, err := os.ReadFile(path); err == nil {
		if json.Unmarshal(data, &ledger) != nil {
			ledger = map[string]any{}
		}
	}
	runs, ok := ledger["runs"].([]any)
	if !ok {
		ledger, runs = map[string]any{}, []any{}
	}
	var earlier []any
	if len(runs) > 0 {
		last, _ := runs[len(runs)-1].(map[string]any)
		earlier, _ = last["unresolved"].([]any)
	}
	board := func(u any) string {
		id, _ := u.(map[string]any)["board"].(string)
		return id
	}
	seen := map[string]bool{}
	for _, repo := range run.Repos {
		for _, l := range repo.Legacy {
			seen[l.Board] = true
			if l.Status == "conflict" {
				run.Unresolved = append(run.Unresolved, map[string]any{"board": l.Board, "root": l.Root, "objects": l.ObjectsBefore})
			}
		}
	}
	for _, u := range earlier {
		if !seen[board(u)] {
			run.Unresolved = append(run.Unresolved, u)
		}
	}
	slices.SortStableFunc(run.Unresolved, func(a, b any) int { return strings.Compare(board(a), board(b)) })
	// A repository's load that changed nothing (its boards still conflict, the same ones left
	// unresolved) adds no run: each load would add the same one.
	boards := func(list []any) []string {
		ids := []string{}
		for _, u := range list {
			ids = append(ids, board(u))
		}
		return ids
	}
	if !slices.ContainsFunc(run.Repos, func(repo RepoReport) bool {
		return slices.ContainsFunc(repo.Legacy, func(l LegacyReport) bool { return l.Status != "conflict" })
	}) && slices.Equal(boards(run.Unresolved), boards(earlier)) {
		return
	}
	ledger["runs"] = append(runs, run.json())
	data, err := swiftjson.Encode(ledger, true, false)
	if err != nil {
		return
	}
	_ = writeAtomic(path, data)
}

// json is the run as the ledger holds it (RepoBoardMigration.Report's Codable form: optionals
// absent when nil, dates ISO 8601).
func (run *MigrationRun) json() map[string]any {
	repos := make([]any, len(run.Repos))
	for i, repo := range run.Repos {
		legacy := make([]any, len(repo.Legacy))
		for j, l := range repo.Legacy {
			unanchored := make([]any, len(l.Unanchored))
			for k, u := range l.Unanchored {
				unanchored[k] = u
			}
			m := map[string]any{
				"board": l.Board, "root": l.Root, "label": l.Label, "anchor": l.Anchor, "worktree": l.Worktree,
				"worktreeLive": l.WorktreeLive, "temporary": l.Temporary, "status": l.Status,
				"objectsBefore": l.ObjectsBefore, "objectsAfter": l.ObjectsAfter, "unanchored": unanchored,
			}
			if l.Branch != nil {
				m["branch"] = *l.Branch
			}
			if l.Region != "" {
				m["region"] = l.Region
			}
			if l.Offset != nil {
				m["offset"] = []any{l.Offset[0], l.Offset[1]}
			}
			legacy[j] = m
		}
		renames := make([]any, len(repo.KeyRenames))
		for j, k := range repo.KeyRenames {
			renames[j] = map[string]any{"object": k.Object, "board": k.Board, "from": k.From, "to": k.To}
		}
		repos[i] = map[string]any{
			"board": repo.Board, "root": repo.Root, "commonDir": repo.CommonDir, "objectsBefore": repo.ObjectsBefore,
			"objectsAfter": repo.ObjectsAfter, "legacy": legacy, "keyRenames": renames,
		}
	}
	nonGit := make([]any, len(run.NonGit))
	for i, id := range run.NonGit {
		nonGit[i] = id
	}
	return map[string]any{
		"ranAt": model.FileTime(run.RanAt), "dryRun": run.DryRun, "repos": repos, "nonGit": nonGit,
		"unresolved": append([]any{}, run.Unresolved...),
	}
}
