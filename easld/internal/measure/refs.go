package measure

import (
	"errors"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// RefFailure is GitRefs.Failure.
type RefFailure struct {
	Kind string // "notRevision", "notRepository", "unknownRef"
	Ref  string
}

func (e *RefFailure) Error() string { return e.Kind + " " + e.Ref }

// RefSource is where a branch-anchored tile (`props.ref`) reads right now (RefSource.swift).
type RefSource struct {
	Ref string
	// SHA is the commit read: the ref's (or the live worktree's HEAD), else the last known SHA.
	SHA string
	// State: "live", "objects", "merged", "missing"; Merge is the merging commit when merged.
	State string
	Merge string
	// Worktree is the live worktree's top level ("" unless live).
	Worktree string
	// Root is where relative paths resolve; Toplevel the checkout Root lies in.
	Root     string
	Toplevel string
	// Commit is what files are read at: nil while live.
	Commit *string
}

// RefOf is RefSource.ref(of:): props.ref when set.
func RefOf(props map[string]any) string {
	ref, _ := props["ref"].(string)
	return ref
}

// ResolveRef is RefSource.resolve: ref in the repository of boardRoot, falling back to
// lastKnownSha ("" for none) once the ref is gone. Errors are *RefFailure.
func ResolveRef(ref, lastKnownSha, boardRoot string) (*RefSource, error) {
	if !IsRevision(ref) {
		return nil, &RefFailure{Kind: "notRevision", Ref: ref}
	}
	board := StandardPath(boardRoot)
	here := WorktreeContaining(board)
	if here == nil {
		return nil, &RefFailure{Kind: "notRepository", Ref: ref}
	}
	source := &RefSource{Ref: ref}
	resolved := false
	if live := LiveWorktree(ref, here); live != nil {
		if sha, ok := revCommit("HEAD", live.Toplevel); ok {
			source.SHA, source.State, source.Worktree, resolved = sha, "live", live.Toplevel, true
		}
	}
	if !resolved {
		if sha, ok := revCommit(ref, here.Toplevel); ok {
			source.SHA, source.State, resolved = sha, "objects", true
		}
	}
	if !resolved {
		if lastKnownSha == "" || !IsRevision(lastKnownSha) {
			return nil, &RefFailure{Kind: "unknownRef", Ref: ref}
		}
		sha, ok := revCommit(lastKnownSha, here.Toplevel)
		if !ok {
			return nil, &RefFailure{Kind: "unknownRef", Ref: ref}
		}
		source.SHA = sha
		if merge, ok := mergeCommit(sha, here.DefaultBranch(), here.Toplevel); ok {
			source.State, source.Merge = "merged", merge
		} else {
			source.State = "missing"
		}
	}
	switch source.State {
	case "objects", "missing":
		source.Commit = new(source.SHA)
	case "merged":
		source.Commit = new(source.Merge)
	}
	checkout := WorktreeContaining(board)
	if source.Worktree == "" || checkout == nil {
		source.Root, source.Toplevel = board, board
		if checkout != nil {
			source.Toplevel = checkout.Toplevel
		}
		return source, nil
	}
	source.Root, source.Toplevel = source.Worktree, source.Worktree
	if place, ok := checkout.RelativePath(board); ok {
		source.Root = filepath.Join(source.Worktree, place)
	}
	return source, nil
}

// DescribeRefFailure is RefSource.describe: why a ref can't be read, in the API's words.
func DescribeRefFailure(err error, ref string) string {
	var failure *RefFailure
	if errors.As(err, &failure) {
		switch failure.Kind {
		case "notRevision":
			return "\"" + ref + "\" is not a ref"
		case "notRepository":
			return "not in a git repository"
		}
	}
	return "unknown ref " + ref
}

// LiveWorktree is GitRefs.liveWorktree: the worktree of checkout's repository that has branch
// ref checked out.
func LiveWorktree(ref string, checkout *Worktree) *Worktree {
	branch := strings.TrimPrefix(ref, "refs/heads/")
	for _, w := range checkout.Siblings() {
		if b := w.Branch(); b != "" && b == branch {
			return w
		}
	}
	return nil
}

// LiveRoot is RefSource.liveRoot: the board root's place in the worktree that has ref checked
// out; ok false when none has.
func LiveRoot(ref, boardRoot string) (string, bool) {
	board := StandardPath(boardRoot)
	checkout := WorktreeContaining(board)
	if checkout == nil {
		return "", false
	}
	live := LiveWorktree(ref, checkout)
	if live == nil {
		return "", false
	}
	if place, ok := checkout.RelativePath(board); ok {
		return filepath.Join(live.Toplevel, place), true
	}
	return live.Toplevel, true
}

// URLFor is RefSource.url(for:): a relative path under Root, an absolute one in any worktree of
// the repository at the same place under Toplevel.
func (s *RefSource) URLFor(path string) string {
	if !strings.HasPrefix(path, "/") {
		return filepath.Join(s.Root, path)
	}
	abs := StandardPath(path)
	worktree := WorktreeContaining(abs)
	if worktree == nil {
		return abs
	}
	relative, ok := worktree.RelativePath(abs)
	here := WorktreeContaining(s.Toplevel)
	if !ok || here == nil || here.CommonDir != worktree.CommonDir {
		return abs
	}
	return filepath.Join(s.Toplevel, relative)
}

// Fence is RefSource.fence: fence read under this ref.
func (s *RefSource) Fence(f Fence) Fence {
	if f.Path != nil && strings.HasPrefix(*f.Path, "/") {
		f.Path = new(s.URLFor(*f.Path))
	}
	if f.Commit == nil || *f.Commit == "" {
		f.Commit = s.Commit
	}
	return f
}

func revCommit(revision, dir string) (string, bool) {
	data, err := RunGit([]string{"rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"}, dir, nil, 0, 0)
	if err != nil {
		return "", false
	}
	sha := strings.TrimSpace(string(data))
	return sha, sha != ""
}

func mergeCommit(sha, branch, dir string) (string, bool) {
	if branch == "" {
		return "", false
	}
	tip, ok := revCommit(branch, dir)
	if !ok {
		return "", false
	}
	if _, err := RunGit([]string{"merge-base", "--is-ancestor", sha, tip}, dir, nil, 0, 0); err != nil {
		return "", false
	}
	if sha == tip {
		return sha, true
	}
	data, err := RunGit([]string{"rev-list", "--first-parent", "--ancestry-path", "--reverse", "--parents", sha + ".." + tip}, dir, nil, 0, 0)
	if err != nil || !utf8.Valid(data) {
		return "", false
	}
	lines := splitNewlines(string(data))
	if len(lines) == 0 {
		return "", false
	}
	shas := strings.Fields(lines[0])
	if len(shas) == 0 {
		return "", false
	}
	if len(shas) > 1 && shas[1] == sha {
		return sha, true
	}
	return shas[0], true
}

// LinkReading is where a note's (or HTML tile's) referenced files are read (Board.linkSource).
type LinkReading struct {
	Root string
	Ref  *RefSource
	// FailedRef is a ref that can't be read; its fences read at the ref's name and fail.
	FailedRef string
}

// ReadingFor is Board.linkSource(props:): props' link root, or its ref resolved now.
func ReadingFor(props map[string]any, boardRoot string) LinkReading {
	ref := RefOf(props)
	if ref == "" {
		return LinkReading{Root: LinkRoot(props, boardRoot)}
	}
	refSha, _ := props["refSha"].(string)
	source, err := ResolveRef(ref, refSha, boardRoot)
	if err != nil {
		return LinkReading{Root: boardRoot, FailedRef: ref}
	}
	return LinkReading{Root: source.Root, Ref: source}
}

// LinkRoot is Board.linkRoot(props:).
func LinkRoot(props map[string]any, boardRoot string) string {
	if ref := RefOf(props); ref != "" {
		if live, ok := LiveRoot(ref, boardRoot); ok {
			return live
		}
		return boardRoot
	}
	value, _ := props["root"].(string)
	if value == "" {
		return boardRoot
	}
	if strings.HasPrefix(value, "/") {
		return StandardPath(value)
	}
	return StandardPath(filepath.Join(boardRoot, value))
}

// Commit is LinkReading.commit: what files without their own commit are read at.
func (r LinkReading) Commit() *string {
	if r.Ref != nil {
		return r.Ref.Commit
	}
	if r.FailedRef != "" {
		return new(r.FailedRef)
	}
	return nil
}

// Fence is LinkReading.fences for one fence.
func (r LinkReading) Fence(f Fence) Fence {
	if r.Ref != nil {
		return r.Ref.Fence(f)
	}
	if r.FailedRef != "" && (f.Commit == nil || *f.Commit == "") {
		f.Commit = new(r.FailedRef)
	}
	return f
}

// Read is LinkReading.read: the text of path as read here.
func (r LinkReading) Read(path string) (string, error) {
	file := path
	if strings.HasPrefix(path, "/") && r.Ref != nil {
		file = r.Ref.URLFor(path)
	}
	return ReadSource(file, r.Commit(), r.Root)
}

// CodeExcerptSource is the code tile's range read as object.get's rangeStatus reads it: through
// its ref when it has one (a ref that can't be read is a missing excerpt saying why).
func CodeExcerptSource(fence Fence, props map[string]any, boardRoot string) Excerpt {
	ref := RefOf(props)
	if ref == "" {
		return ExcerptFor(fence, boardRoot, nil, nil)
	}
	refSha, _ := props["refSha"].(string)
	source, err := ResolveRef(ref, refSha, boardRoot)
	if err != nil {
		path := ""
		if fence.Path != nil {
			path = *fence.Path
		}
		return Excerpt{Path: path, Lines: []string{}, Status: stale(DescribeRefFailure(err, ref)), Missing: true}
	}
	return ExcerptFor(source.Fence(fence), source.Root, nil, nil)
}

// CodeRangeStatus is object.get's `rangeStatus` for a code tile whose range anchors (without
// the app's live tile): ok false for one that doesn't (CodeAnchor.fence nil).
func CodeRangeStatus(props map[string]any, boardRoot string) (map[string]any, bool) {
	fence, ok := CodeAnchorFence(props)
	if !ok {
		return nil, false
	}
	return CodeExcerptSource(fence, props, boardRoot).StatusJSON(), true
}
