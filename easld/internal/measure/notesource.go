package measure

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/twaldin/easl/easld/internal/model"
)

// Excerpt is a NoteExcerpt: what an anchored fence (or a code tile's range) shows.
type Excerpt struct {
	Path          string
	Range         *model.LineRange
	Lines         []string
	Status        AnchorStatus
	Diff          []DiffLine // proposals only
	HasDiff       bool
	FileLineCount int
	Missing       bool
	Applied       bool
}

// State is NoteExcerpt.state: live, relocated, stale, applied, missing.
func (e Excerpt) State() string {
	switch {
	case e.Missing:
		return "missing"
	case e.Applied:
		return "applied"
	case e.Status.Kind == "exact":
		return "live"
	}
	return e.Status.Kind
}

// StatusJSON is NoteExcerpt.statusJSON: state, the range, the range as written when it moved,
// why it is stale.
func (e Excerpt) StatusJSON() map[string]any {
	out := map[string]any{"state": e.State()}
	if e.Range != nil {
		out["range"] = e.Range.JSON()
	}
	switch e.Status.Kind {
	case "relocated":
		out["written"] = e.Status.From.JSON()
	case "stale":
		out["reason"] = e.Status.Reason
	}
	return out
}

// SourceError is a NoteSourceError, or a file read failure.
type SourceError struct {
	// Kind: "invalidRevision", "unknownCommit", "notAtCommit", "noSuchFile", "unreadable".
	Kind   string
	Commit string
}

func (e *SourceError) Error() string { return e.Kind + " " + e.Commit }

const (
	sourceMaxOutput = 32 << 20
	sourceTimeout   = 20 * time.Second
)

// ExcerptFor is NoteSource.excerpt: fence resolved against disk (or git at its commit) under
// root; captured is the range's text when it last resolved (nil: unknown); body the fence's own.
func ExcerptFor(fence Fence, root string, captured []string, body []string) Excerpt {
	var path string
	if fence.Path != nil {
		path = *fence.Path
	} else if fence.Symbol != nil {
		located, ok := locateSymbol(*fence.Symbol, root)
		if !ok {
			return Excerpt{Lines: orEmpty(captured), Status: stale("symbol " + *fence.Symbol + " not found in the workspace")}
		}
		path = located
	} else {
		symbol := ""
		return Excerpt{Lines: orEmpty(captured), Status: stale("symbol " + symbol + " not found in the workspace")}
	}
	failed := func(reason string, missing bool) Excerpt {
		return Excerpt{Path: path, Lines: orEmpty(captured), Status: stale(reason), Missing: missing}
	}
	text, err := ReadSource(path, fence.Commit, root)
	if err != nil {
		var se *SourceError
		errors.As(err, &se)
		switch se.Kind {
		case "invalidRevision":
			return failed("\""+se.Commit+"\" is not a commit", false)
		case "unknownCommit":
			return failed("unknown commit "+se.Commit, true)
		case "notAtCommit":
			return failed(path+" does not exist at "+se.Commit, true)
		case "noSuchFile":
			return failed("no file "+path, true)
		}
		place := path
		if fence.Commit != nil {
			place = path + " at " + *fence.Commit
		}
		return failed("cannot read "+place, false)
	}
	source := NoteLines(text)
	resolution := ResolveAnchor(fence, source, captured, body)
	var shown []string
	if resolution.Range != nil {
		shown = source[resolution.Range.Start-1 : resolution.Range.End]
	}
	if fence.Mode() == FencePropose {
		var starts *[2]int
		if resolution.Range != nil {
			starts = &[2]int{resolution.Range.Start - max(1, len(body)), resolution.Range.End - 1}
		}
		near := 1
		if resolution.Range != nil {
			near = resolution.Range.Start
		} else if fence.Lines != nil {
			near = fence.Lines.Start
		}
		original := captured
		if original == nil {
			original = shown
		}
		if at := AppliedRange(body, original, source, starts, near-1); at != nil {
			status := resolution.Status
			if resolution.Range == nil || *at != *resolution.Range {
				status = exact
				if fence.Lines != nil && *fence.Lines != *at {
					status = relocated(*fence.Lines)
				}
			}
			return Excerpt{Path: path, Range: at, Lines: append([]string(nil), source[at.Start-1:at.End]...), Status: status, FileLineCount: len(source), Applied: true}
		}
	}
	if resolution.Range == nil {
		return Excerpt{Path: path, Lines: orEmpty(captured), Status: resolution.Status, FileLineCount: len(source)}
	}
	out := Excerpt{Path: path, Range: resolution.Range, Lines: append([]string(nil), shown...), Status: resolution.Status, FileLineCount: len(source)}
	if fence.Mode() == FencePropose {
		out.Diff, out.HasDiff = DiffLines(shown, body), true
	}
	return out
}

func orEmpty(lines []string) []string {
	if lines == nil {
		return []string{}
	}
	return lines
}

// ReadSource is NoteSource.read: the file's text, at commit through `git show` when given.
func ReadSource(path string, commit *string, root string) (string, error) {
	file := path
	if !strings.HasPrefix(path, "/") {
		file = filepath.Join(root, path)
	}
	if commit == nil {
		data, err := os.ReadFile(file)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return "", &SourceError{Kind: "noSuchFile"}
			}
			return "", &SourceError{Kind: "unreadable"}
		}
		if !utf8.Valid(data) {
			return "", &SourceError{Kind: "unreadable"}
		}
		return string(data), nil
	}
	args, dir, err := showCommand(path, *commit, root)
	if err != nil {
		return "", err
	}
	data, err := RunGit(args, dir, nil, sourceMaxOutput, sourceTimeout)
	if err != nil {
		var ge *GitError
		if errors.As(err, &ge) && ge.Kind == "failed" {
			if _, err := RunGit([]string{"rev-parse", "--verify", "--quiet", "--end-of-options", *commit + "^{commit}"}, dir, nil, 0, sourceTimeout); err != nil {
				return "", &SourceError{Kind: "unknownCommit", Commit: *commit}
			}
			return "", &SourceError{Kind: "notAtCommit", Commit: *commit}
		}
		return "", &SourceError{Kind: "unreadable"}
	}
	if !utf8.Valid(data) {
		return "", &SourceError{Kind: "unreadable"}
	}
	return string(data), nil
}

func showCommand(path, commit, root string) ([]string, string, error) {
	if !IsRevision(commit) {
		return nil, "", &SourceError{Kind: "invalidRevision", Commit: commit}
	}
	file := path
	if !strings.HasPrefix(path, "/") {
		file = filepath.Join(root, path)
	}
	rootPath := StandardPath(root)
	absolute := StandardPath(file)
	if strings.HasPrefix(absolute, rootPath+"/") {
		return []string{"show", "--end-of-options", commit + ":./" + absolute[len(rootPath)+1:]}, root, nil
	}
	worktree := WorktreeContaining(absolute)
	if worktree == nil {
		return nil, "", &SourceError{Kind: "notAtCommit", Commit: commit}
	}
	relative, ok := worktree.RelativePath(absolute)
	if !ok {
		return nil, "", &SourceError{Kind: "notAtCommit", Commit: commit}
	}
	return []string{"show", "--end-of-options", commit + ":./" + relative}, worktree.Toplevel, nil
}

// IsRevision is NoteSource.isRevision: letters, numbers and `._~^/-`, not starting with `-`.
func IsRevision(text string) bool {
	if text == "" || text[0] == '-' {
		return false
	}
	for _, r := range text {
		if !(unicode.IsLetter(r) || unicode.IsNumber(r) || strings.ContainsRune("._~^/-", r)) {
			return false
		}
	}
	return true
}

// locateSymbol is NoteSource.locate: the first tracked file declaring symbol's last component.
func locateSymbol(symbol, root string) (string, bool) {
	parts := SplitLFOmittingEmpty(strings.ReplaceAll(symbol, ".", "\n"))
	if len(parts) == 0 {
		return "", false
	}
	name := parts[len(parts)-1]
	for _, r := range name {
		if !(unicode.IsLetter(r) || unicode.IsNumber(r) || r == '_' || r == '$') {
			return "", false
		}
	}
	pattern := "(^|[^[:alnum:]_.$])(" + keywordAlternation(declarationKinds, regexp.QuoteMeta) + ")[[:space:]]+([(][^)]*[)][[:space:]]*)?" +
		strings.ReplaceAll(name, "$", "\\$") + "([^[:alnum:]_$]|$)"
	data, err := RunGit([]string{"grep", "-l", "-I", "-E", "-e", pattern}, root, []int{0, 1}, sourceMaxOutput, sourceTimeout)
	if err != nil || !utf8.Valid(data) {
		return "", false
	}
	for _, candidate := range SplitLFOmittingEmpty(string(data)) {
		text, err := os.ReadFile(filepath.Join(root, candidate))
		if err != nil || !utf8.Valid(text) {
			continue
		}
		if SymbolRange(symbol, NoteLines(string(text))) != nil {
			return candidate, true
		}
	}
	return "", false
}
