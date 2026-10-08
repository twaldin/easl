package store

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Worktree is the git working tree a path lies in, found from the filesystem alone (no git
// process): the directory holding `.git`, the repository's common git directory (shared by
// every worktree of one repository, what `git rev-parse --git-common-dir` prints) and the
// worktree's own git directory. Port of GitWorktree.swift.
type Worktree struct {
	// Toplevel is the working tree's top-level directory as reached from the path (symlinks
	// unresolved).
	Toplevel string
	// CommonDir is the shared git directory, symlinks resolved.
	CommonDir string
	// GitDir is the worktree's own git directory (`.git` of the main checkout, or
	// `<common>/worktrees/<name>` of a linked one), symlinks resolved.
	GitDir string
}

// Standardized is URL(fileURLWithPath:).standardizedFileURL.path: `.` and `..` removed,
// symlinks kept.
func Standardized(path string) string {
	if path == "" {
		return path
	}
	if !strings.HasPrefix(path, "/") {
		if wd, err := os.Getwd(); err == nil {
			path = filepath.Join(wd, path)
		}
	}
	return filepath.Clean(path)
}

// Normalized is the form CommonDir is kept in (symlinks resolved), so a worktree reached as
// `/tmp/wt` and listed by git as `/private/tmp/wt` is one worktree
// (URL.resolvingSymlinksInPath: an existing path under /private loses that prefix).
func Normalized(path string) string {
	return resolved(Standardized(path))
}

func resolved(path string) string {
	out := realPath(path)
	if strings.HasPrefix(out, "/private/") {
		if stripped := strings.TrimPrefix(out, "/private"); exists(stripped) {
			return stripped
		}
	}
	return out
}

// realPath is GitDiffEngine.realPath: path with its symlinks resolved, also when its end doesn't
// exist (what exists is resolved, the rest kept as written); `/private` stays.
func realPath(path string) string {
	out, err := filepath.EvalSymlinks(path)
	if err == nil {
		return out
	}
	dir, rest := path, ""
	for {
		parent := filepath.Dir(dir)
		rest = filepath.Join(filepath.Base(dir), rest)
		if parent == dir {
			return path
		}
		dir = parent
		if r, err := filepath.EvalSymlinks(dir); err == nil {
			return filepath.Join(r, rest)
		}
	}
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// IsDirectory: something exists at path and it is a directory (following symlinks).
func IsDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// Containing is the worktree containing path (absolute; a file or directory, existing or
// not), or nil outside git.
func Containing(path string) *Worktree {
	dir := Standardized(path)
	for {
		dotGit := filepath.Join(dir, ".git")
		if info, err := os.Stat(dotGit); err == nil {
			if info.IsDir() {
				d := resolved(dotGit)
				return &Worktree{Toplevel: dir, CommonDir: d, GitDir: d}
			}
			gitDir, ok := linkedGitDir(dotGit)
			if !ok {
				return nil
			}
			return &Worktree{Toplevel: dir, CommonDir: resolved(commonDirOf(gitDir)), GitDir: resolved(gitDir)}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return nil
		}
		dir = parent
	}
}

// RelativePath is path relative to the top level, ok false when it isn't inside this worktree.
func (w Worktree) RelativePath(path string) (string, bool) {
	abs := Standardized(path)
	if strings.HasPrefix(abs, w.Toplevel+"/") {
		return abs[len(w.Toplevel)+1:], true
	}
	return "", false
}

// Name is the worktree's directory name.
func (w Worktree) Name() string { return filepath.Base(w.Toplevel) }

// IsMain: the repository's main checkout (its git directory is the common one), not a linked
// worktree.
func (w Worktree) IsMain() bool { return w.GitDir == w.CommonDir }

// Branch is the branch checked out (HEAD's refs/heads/…), "" when detached or unreadable.
func (w Worktree) Branch() (string, bool) {
	data, err := os.ReadFile(filepath.Join(w.GitDir, "HEAD"))
	if err != nil {
		return "", false
	}
	head := strings.TrimSpace(string(data))
	const prefix = "ref: refs/heads/"
	if strings.HasPrefix(head, prefix) {
		return head[len(prefix):], true
	}
	return "", false
}

// SameRepository: two paths lie in worktrees of one repository.
func SameRepository(a, b string) bool {
	first, second := Containing(a), Containing(b)
	return first != nil && second != nil && first.CommonDir == second.CommonDir
}

// Counterpart is root (a directory in one checkout) at its place in the other worktree of its
// repository that path lies in; ok false when path lies in root's own checkout, another
// repository, or outside git.
func Counterpart(root, toward string) (string, bool) {
	own, other := Containing(root), Containing(toward)
	if own == nil || other == nil || own.CommonDir != other.CommonDir || own.GitDir == other.GitDir {
		return "", false
	}
	if rel, ok := own.RelativePath(root); ok {
		return other.Toplevel + "/" + rel, true
	}
	return other.Toplevel, true
}

// CanonicalRoot is where a repository's board is rooted, whichever worktree opened it.
func (w Worktree) CanonicalRoot() string {
	if w.IsMain() {
		return w.Toplevel
	}
	return CanonicalRoot(w.CommonDir)
}

// CanonicalRoot is the main checkout of the repository at commonDir, else (a bare repository)
// the common directory's parent.
func CanonicalRoot(commonDir string) string {
	parent := filepath.Dir(commonDir)
	if filepath.Base(commonDir) == ".git" {
		if main := Containing(parent); main != nil && main.CommonDir == commonDir {
			return main.Toplevel
		}
	}
	return parent
}

// Worktrees lists every worktree of the repository whose common git directory is commonDir:
// the main checkout first, then linked ones by directory name; gone ones left out.
func Worktrees(commonDir string) []Worktree {
	var found []Worktree
	if filepath.Base(commonDir) == ".git" {
		if main := Containing(filepath.Dir(commonDir)); main != nil && main.CommonDir == commonDir {
			found = append(found, *main)
		}
	}
	linked := filepath.Join(commonDir, "worktrees")
	entries, _ := os.ReadDir(linked)
	var others []Worktree
	for _, e := range entries {
		data, err := os.ReadFile(filepath.Join(linked, e.Name(), "gitdir"))
		if err != nil {
			continue
		}
		dotGit := Standardized(strings.TrimSpace(string(data)))
		top := filepath.Dir(dotGit)
		if !exists(dotGit) {
			continue
		}
		wt := Containing(top)
		if wt == nil || wt.CommonDir != commonDir {
			continue
		}
		dup := false
		for _, f := range found {
			if f.GitDir == wt.GitDir {
				dup = true
			}
		}
		if !dup {
			others = append(others, *wt)
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
	line := strings.SplitN(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n", 2)[0]
	if !strings.HasPrefix(line, "gitdir:") {
		return "", false
	}
	target := strings.TrimSpace(strings.TrimPrefix(line, "gitdir:"))
	if target == "" {
		return "", false
	}
	if strings.HasPrefix(target, "/") {
		return Standardized(target), true
	}
	return Standardized(filepath.Join(filepath.Dir(file), target)), true
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
		return Standardized(target)
	}
	return Standardized(filepath.Join(gitDir, target))
}
