package measure

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
)

// pathRefused is the stale reason for a note fence the board file policy will not read.
// It reuses the existing stale status so object.get grows no new state.
const pathRefused = "path refused"

// NoteExcerpt is a note fence read under the board file policy (HostNotes.noteFile).
// Code tile display keeps ExcerptFor: its local reads are intentionally broader.
func (r LinkReading) NoteExcerpt(fence Fence, body []string) Excerpt {
	fence = r.Fence(fence)
	areas := boardAreas(r.Board)
	if areaOf(areas, r.Root) == nil {
		return refusedExcerpt(fencePath(fence))
	}
	// An option-like commit fails before the path check, as BoardAreas.read does, and reads nothing.
	if fence.Commit != nil && *fence.Commit != "" && !IsRevision(*fence.Commit) {
		return excerptFailure(fencePath(fence), fence.Commit, nil, &SourceError{Kind: "invalidRevision", Commit: *fence.Commit})
	}
	path, err := r.notePath(fence, areas)
	if err != nil {
		if errors.Is(err, errSymbolMissing) {
			symbol := ""
			if fence.Symbol != nil {
				symbol = *fence.Symbol
			}
			return Excerpt{Lines: []string{}, Status: stale("symbol " + symbol + " not found in the workspace")}
		}
		return excerptFailure(fencePath(fence), fence.Commit, nil, err)
	}
	text, err := readNoteFile(path, fence.Commit, r.Root, areas)
	if err != nil {
		return excerptFailure(path, fence.Commit, nil, err)
	}
	return interpretExcerpt(fence, path, text, nil, body)
}

func fencePath(fence Fence) string {
	if fence.Path != nil {
		return *fence.Path
	}
	return ""
}

func refusedExcerpt(path string) Excerpt {
	return Excerpt{Path: path, Lines: []string{}, Status: stale(pathRefused)}
}

var errSymbolMissing = errors.New("symbol missing")

func (r LinkReading) notePath(fence Fence, areas []boardArea) (string, error) {
	if fence.Path != nil {
		return *fence.Path, nil
	}
	if fence.Symbol == nil {
		return "", errSymbolMissing
	}
	path, refused, ok := noteLocate(*fence.Symbol, r.Root, areas)
	if ok {
		return path, nil
	}
	if refused {
		return "", &SourceError{Kind: "refused"}
	}
	return "", errSymbolMissing
}

// noteLocate is locateSymbol for a note: candidates are read only through the board policy.
// refused is set when a hit was outside that policy and no allowed file declared the symbol.
func noteLocate(symbol, root string, areas []boardArea) (path string, refused, found bool) {
	pattern, ok := symbolGrepPattern(symbol)
	if !ok {
		return "", false, false
	}
	data, err := RunGit([]string{"grep", "-l", "-I", "-E", "-e", pattern}, root, []int{0, 1}, sourceMaxOutput, sourceTimeout)
	if err != nil || !utf8.Valid(data) {
		return "", false, false
	}
	for _, candidate := range SplitLFOmittingEmpty(string(data)) {
		text, err := readNoteFile(candidate, nil, root, areas)
		if err != nil {
			var se *SourceError
			if errors.As(err, &se) && se.Kind == "refused" {
				refused = true
			}
			continue
		}
		if SymbolRange(symbol, NoteLines(text)) != nil {
			return candidate, false, true
		}
	}
	return "", refused, false
}

func readNoteFile(path string, commit *string, root string, areas []boardArea) (string, error) {
	if refusedInput(path) {
		return "", &SourceError{Kind: "refused"}
	}
	requested := path
	if !filepath.IsAbs(path) {
		requested = filepath.Join(root, path)
	}
	requested = StandardPath(requested)
	if commit != nil && *commit != "" {
		if !IsRevision(*commit) {
			return "", &SourceError{Kind: "invalidRevision", Commit: *commit}
		}
		area := writtenAreaOf(areas, requested)
		if area == nil {
			return "", &SourceError{Kind: "refused"}
		}
		return readPinned(requested, *commit, area)
	}
	area := areaOf(areas, requested)
	if area == nil {
		return "", &SourceError{Kind: "refused"}
	}
	return readLive(requested, area)
}

func refusedInput(path string) bool {
	return path == "" || strings.ContainsRune(path, 0) || strings.ContainsAny(path, "\n\r") || strings.HasPrefix(path, "~")
}

// readLive opens the resolved path. The lexical path may be an inside symlink, which is
// allowed; opening that resolved path with no-follow refuses a directory swapped for a
// symlink between the check and the read.
func readLive(requested string, area *boardArea) (string, error) {
	resolved := RealPath(requested)
	if !pathInside(area.Real, resolved) {
		return "", &SourceError{Kind: "refused"}
	}
	data, err := readRegular(resolved)
	if err != nil {
		return "", err
	}
	if !utf8.Valid(data) {
		return "", &SourceError{Kind: "unreadable"}
	}
	return string(data), nil
}

func readPinned(requested, commit string, area *boardArea) (string, error) {
	sha, err := resolveCommit(commit, area.Real)
	if err != nil {
		return "", err
	}
	prefix := area.Real
	if pathInside(area.Lex, requested) {
		prefix = area.Lex
	}
	rel, err := filepath.Rel(prefix, requested)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") || filepath.IsAbs(rel) || strings.ContainsAny(rel, "\n\r") {
		return "", &SourceError{Kind: "refused"}
	}
	if rel == "." {
		return "", &SourceError{Kind: "notAtCommit", Commit: commit}
	}
	rel = filepath.ToSlash(rel)
	entry, err := RunGit([]string{"--literal-pathspecs", "ls-tree", "-z", sha, "--", rel}, area.Real, nil, 1<<20, sourceTimeout)
	if err != nil || len(entry) == 0 {
		return "", &SourceError{Kind: "notAtCommit", Commit: commit}
	}
	record := strings.TrimRight(string(entry), "\x00")
	if strings.HasPrefix(record, "120000 ") {
		return "", &SourceError{Kind: "refused"}
	}
	if !strings.HasPrefix(record, "100644 ") && !strings.HasPrefix(record, "100755 ") {
		return "", &SourceError{Kind: "notAtCommit", Commit: commit}
	}
	data, err := RunGit([]string{"show", "--end-of-options", sha + ":./" + rel}, area.Real, nil, sourceMaxOutput, sourceTimeout)
	if err != nil {
		return "", &SourceError{Kind: "notAtCommit", Commit: commit}
	}
	if !utf8.Valid(data) {
		return "", &SourceError{Kind: "unreadable"}
	}
	return string(data), nil
}

func resolveCommit(commit, dir string) (string, error) {
	if !IsRevision(commit) {
		return "", &SourceError{Kind: "invalidRevision", Commit: commit}
	}
	sha, ok := revCommit(commit, dir)
	if !ok {
		return "", &SourceError{Kind: "unknownCommit", Commit: commit}
	}
	return sha, nil
}

type boardArea struct {
	Lex  string
	Real string
}

// boardAreas is HostFiles.boardAreas: the board root, plus that same subdirectory in each
// registered worktree, and only when the counterpart resolves to that place.
func boardAreas(boardRoot string) []boardArea {
	lex := cleanAbs(boardRoot)
	if lex == "" {
		return nil
	}
	areas := []boardArea{{Lex: lex, Real: RealPath(lex)}}
	here := WorktreeContaining(areas[0].Real)
	if here == nil {
		return areas
	}
	place, err := filepath.Rel(RealPath(here.Toplevel), areas[0].Real)
	if err != nil || place == ".." || strings.HasPrefix(place, "../") || filepath.IsAbs(place) {
		return areas
	}
	if place == "." {
		place = ""
	}
	for _, w := range here.Siblings() {
		entryReal := RealPath(w.Toplevel)
		if entryReal == "" {
			continue
		}
		canonical := filepath.Join(entryReal, place)
		aliases := []string{
			filepath.Join(w.Toplevel, place),
			cleanAbs(filepath.Join(lex, relPath(areas[0].Real, canonical))),
		}
		for _, alias := range aliases {
			alias = StandardPath(alias)
			if alias == "" || RealPath(alias) != canonical || areaLex(areas, alias) {
				continue
			}
			areas = append(areas, boardArea{Lex: alias, Real: canonical})
		}
	}
	return areas
}

func relPath(base, target string) string {
	rel, err := filepath.Rel(base, target)
	if err != nil {
		return target
	}
	return rel
}

func areaLex(areas []boardArea, lex string) bool {
	for _, a := range areas {
		if a.Lex == lex {
			return true
		}
	}
	return false
}

func cleanAbs(path string) string {
	path = StandardPath(path)
	if path == "" || filepath.IsAbs(path) {
		return path
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return abs
}

// areaOf is a live path in an area: lexical membership, and the resolved path inside the
// area's real directory. writtenAreaOf is lexical only, for a pinned blob.
func areaOf(areas []boardArea, path string) *boardArea {
	path = StandardPath(path)
	resolved := RealPath(path)
	for i := range areas {
		a := &areas[i]
		if (pathInside(a.Lex, path) || pathInside(a.Real, path)) && pathInside(a.Real, resolved) {
			return a
		}
	}
	return nil
}

func writtenAreaOf(areas []boardArea, path string) *boardArea {
	path = StandardPath(path)
	for i := range areas {
		a := &areas[i]
		if pathInside(a.Lex, path) || pathInside(a.Real, path) {
			return a
		}
	}
	return nil
}

func pathInside(dir, path string) bool {
	dir = StandardPath(dir)
	path = StandardPath(path)
	if dir == "" || path == "" {
		return false
	}
	if dir == "/" {
		return strings.HasPrefix(path, "/")
	}
	return path == dir || strings.HasPrefix(path, dir+"/")
}

// readRegular reads a regular file by opening each component from the filesystem root
// without following symlinks. A directory replaced by a symlink after a realpath check
// cannot redirect the read.
func readRegular(path string) ([]byte, error) {
	fd, err := openNoFollow(path)
	if err != nil {
		return nil, classifyOpenErr(err)
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return nil, &SourceError{Kind: "unreadable"}
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return nil, &SourceError{Kind: "noSuchFile"}
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, &SourceError{Kind: "unreadable"}
	}
	return data, nil
}

func classifyOpenErr(err error) error {
	if errors.Is(err, syscall.ENOENT) {
		return &SourceError{Kind: "noSuchFile"}
	}
	if errors.Is(err, syscall.ELOOP) || errors.Is(err, syscall.ENOTDIR) {
		return &SourceError{Kind: "refused"}
	}
	return &SourceError{Kind: "unreadable"}
}
