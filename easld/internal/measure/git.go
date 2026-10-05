package measure

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// GitError is why `RunGit` failed (GitRunner.swift GitError).
type GitError struct {
	// Kind: "launch", "failed", "outputTooLarge", "timedOut".
	Kind   string
	Status int
	Stderr string
}

func (e *GitError) Error() string {
	switch e.Kind {
	case "failed":
		return fmt.Sprintf("git failed (%d): %s", e.Status, e.Stderr)
	case "launch":
		return "git did not start: " + e.Stderr
	}
	return "git " + e.Kind
}

// gitSlots caps concurrent git processes, as GitRunner.shared does (two app-wide).
var gitSlots = make(chan struct{}, 2)

// RunGit is GitRunner.run: stdout of `git -c core.quotepath=off --no-pager <args>` in dir, with
// optional locks, prompts and lazy fetches off. Exit codes outside allowed (default 0) fail with
// git's stderr; more than maxOutput bytes (0: no limit) or running past timeout (0: none) stop git.
func RunGit(args []string, dir string, allowed []int, maxOutput int, timeout time.Duration) ([]byte, error) {
	gitSlots <- struct{}{}
	defer func() { <-gitSlots }()
	ctx := context.Background()
	var cancel context.CancelFunc
	if timeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, "git", append([]string{"-c", "core.quotepath=off", "--no-pager"}, args...)...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "GIT_NO_LAZY_FETCH=1")
	var stdout limitedBuffer
	stdout.limit = maxOutput
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if stdout.over {
		return nil, &GitError{Kind: "outputTooLarge"}
	}
	if ctx.Err() == context.DeadlineExceeded {
		return nil, &GitError{Kind: "timedOut"}
	}
	status := 0
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			return nil, &GitError{Kind: "launch", Stderr: err.Error()}
		}
		status = exit.ExitCode()
	}
	if allowed == nil {
		allowed = []int{0}
	}
	for _, a := range allowed {
		if a == status {
			return stdout.buf.Bytes(), nil
		}
	}
	return nil, &GitError{Kind: "failed", Status: status, Stderr: strings.TrimSpace(stderr.String())}
}

type limitedBuffer struct {
	buf   bytes.Buffer
	limit int
	over  bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.limit > 0 && b.buf.Len()+len(p) > b.limit {
		b.over = true
		return 0, errors.New("output too large")
	}
	return b.buf.Write(p)
}

// StandardPath is a path as URL(fileURLWithPath:).standardizedFileURL.path gives it: `.` and `..`
// components resolved lexically, no trailing slash.
func StandardPath(path string) string {
	if path == "" {
		return path
	}
	return filepath.Clean(path)
}

// ResolvedPath is URL.resolvingSymlinksInPath().path: symlinks resolved (as far as the path
// exists), with a leading /private dropped when the path without it exists too.
func ResolvedPath(path string) string {
	p := StandardPath(path)
	if real, err := filepath.EvalSymlinks(p); err == nil {
		p = real
	}
	if strings.HasPrefix(p, "/private/") {
		if _, err := os.Stat(strings.TrimPrefix(p, "/private")); err == nil {
			p = strings.TrimPrefix(p, "/private")
		}
	}
	return p
}

// RealPath is GitDiffEngine.realPath: realpath(3) of the longest existing prefix, the missing
// components appended (git reports /private/var where the path says /var).
func RealPath(path string) string {
	existing := StandardPath(path)
	var missing []string
	for {
		if _, err := os.Lstat(existing); err == nil || existing == "/" {
			break
		}
		missing = append([]string{filepath.Base(existing)}, missing...)
		existing = filepath.Dir(existing)
	}
	real, err := filepath.EvalSymlinks(existing)
	if err != nil {
		return StandardPath(path)
	}
	return filepath.Join(append([]string{real}, missing...)...)
}

// Worktree is GitWorktree: the git working tree a path lies in, from the filesystem alone.
type Worktree struct {
	Toplevel  string
	CommonDir string
	GitDir    string
}

// WorktreeContaining is GitWorktree.containing: the worktree holding path, nil outside git.
func WorktreeContaining(path string) *Worktree {
	directory := StandardPath(path)
	for {
		dotGit := filepath.Join(directory, ".git")
		if info, err := os.Stat(dotGit); err == nil {
			if info.IsDir() {
				dir := ResolvedPath(dotGit)
				return &Worktree{Toplevel: directory, CommonDir: dir, GitDir: dir}
			}
			gitDir, ok := linkedGitDir(dotGit)
			if !ok {
				return nil
			}
			return &Worktree{Toplevel: directory, CommonDir: ResolvedPath(commonDirOf(gitDir)), GitDir: ResolvedPath(gitDir)}
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			return nil
		}
		directory = parent
	}
}

// RelativePath is path relative to the top level; ok false outside this worktree.
func (w *Worktree) RelativePath(path string) (string, bool) {
	absolute := StandardPath(path)
	if strings.HasPrefix(absolute, w.Toplevel+"/") {
		return absolute[len(w.Toplevel)+1:], true
	}
	return "", false
}

// Name is the worktree's directory name.
func (w *Worktree) Name() string { return filepath.Base(w.Toplevel) }

// Branch is the branch checked out; "" when detached.
func (w *Worktree) Branch() string {
	data, err := os.ReadFile(filepath.Join(w.GitDir, "HEAD"))
	if err != nil {
		return ""
	}
	head := strings.TrimSpace(string(data))
	const prefix = "ref: refs/heads/"
	if strings.HasPrefix(head, prefix) {
		return head[len(prefix):]
	}
	return ""
}

// DefaultBranch is origin/HEAD's target, else main, else master; "" when none.
func (w *Worktree) DefaultBranch() string {
	if data, err := os.ReadFile(filepath.Join(w.CommonDir, "refs/remotes/origin/HEAD")); err == nil {
		ref := strings.TrimSpace(string(data))
		if strings.HasPrefix(ref, "ref: refs/remotes/") {
			return ref[len("ref: refs/remotes/"):]
		}
	}
	packed, _ := os.ReadFile(filepath.Join(w.CommonDir, "packed-refs"))
	lines := splitNewlines(string(packed))
	for _, name := range []string{"main", "master"} {
		if _, err := os.Stat(filepath.Join(w.CommonDir, "refs/heads", name)); err == nil {
			return name
		}
		for _, line := range lines {
			if strings.HasSuffix(line, " refs/heads/"+name) {
				return name
			}
		}
	}
	return ""
}

// Siblings is every worktree of the repository, the main checkout first, then linked ones by name.
func (w *Worktree) Siblings() []*Worktree {
	var found []*Worktree
	common := w.CommonDir
	if filepath.Base(common) == ".git" {
		if main := WorktreeContaining(filepath.Dir(common)); main != nil && main.CommonDir == common {
			found = append(found, main)
		}
	}
	linked := filepath.Join(common, "worktrees")
	entries, _ := os.ReadDir(linked)
	var others []*Worktree
	for _, entry := range entries {
		data, err := os.ReadFile(filepath.Join(linked, entry.Name(), "gitdir"))
		if err != nil {
			continue
		}
		dotGit := StandardPath(strings.TrimSpace(string(data)))
		if _, err := os.Stat(dotGit); err != nil {
			continue
		}
		worktree := WorktreeContaining(filepath.Dir(dotGit))
		if worktree == nil || worktree.CommonDir != common {
			continue
		}
		dup := false
		for _, f := range found {
			if f.GitDir == worktree.GitDir {
				dup = true
			}
		}
		if !dup {
			others = append(others, worktree)
		}
	}
	sort.SliceStable(others, func(i, j int) bool { return others[i].Name() < others[j].Name() })
	return append(found, others...)
}

func linkedGitDir(file string) (string, bool) {
	data, err := os.ReadFile(file)
	if err != nil {
		return "", false
	}
	lines := splitNewlines(string(data))
	if len(lines) == 0 || !strings.HasPrefix(lines[0], "gitdir:") {
		return "", false
	}
	target := strings.Trim(lines[0][len("gitdir:"):], " \t")
	if target == "" {
		return "", false
	}
	if strings.HasPrefix(target, "/") {
		return target, true
	}
	return filepath.Join(filepath.Dir(file), target), true
}

func commonDirOf(gitDir string) string {
	data, err := os.ReadFile(filepath.Join(gitDir, "commondir"))
	if err != nil {
		return gitDir
	}
	target := strings.TrimSpace(string(data))
	if target == "" {
		return gitDir
	}
	if strings.HasPrefix(target, "/") {
		return target
	}
	return filepath.Join(gitDir, target)
}

// splitNewlines splits like Swift's split(whereSeparator: \.isNewline): runs of line breaks
// leave no empty pieces.
func splitNewlines(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool {
		return r == '\n' || r == '\r' || r == '\v' || r == '\f' || r == 0x85 || r == 0x2028 || r == 0x2029
	})
}

// PathLabel is PathLabel.short: a path outside the board root (absolute) as
// `<worktree>/<repo-relative path>`; anything else as it is.
func PathLabel(path string) string {
	if !strings.HasPrefix(path, "/") {
		return path
	}
	worktree := WorktreeContaining(path)
	if worktree == nil {
		return path
	}
	relative, ok := worktree.RelativePath(path)
	if !ok {
		return path
	}
	return worktree.Name() + "/" + relative
}

// RelativeToRoot is Board.relativePath(_:root:): path relative to root when under it, else absolute.
func RelativeToRoot(path, root string) string {
	var absolute string
	if strings.HasPrefix(path, "/") {
		absolute = StandardPath(path)
	} else {
		absolute = StandardPath(filepath.Join(root, path))
	}
	rootPath := StandardPath(root)
	if strings.HasPrefix(absolute, rootPath+"/") {
		return absolute[len(rootPath)+1:]
	}
	real, realRoot := RealPath(absolute), RealPath(rootPath)
	if strings.HasPrefix(real, realRoot+"/") {
		return real[len(realRoot)+1:]
	}
	return absolute
}
