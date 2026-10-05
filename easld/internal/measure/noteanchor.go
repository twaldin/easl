package measure

import (
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/dlclark/regexp2"
	"github.com/twaldin/easl/easld/internal/model"
)

// AnchorStatus is NoteAnchor.Status: exact, relocated (From: the range as written), or stale.
type AnchorStatus struct {
	Kind   string // "exact", "relocated", "stale"
	From   model.LineRange
	Reason string
}

var exact = AnchorStatus{Kind: "exact"}

func relocated(from model.LineRange) AnchorStatus { return AnchorStatus{Kind: "relocated", From: from} }
func stale(reason string) AnchorStatus            { return AnchorStatus{Kind: "stale", Reason: reason} }

// Resolution is NoteAnchor.Resolution.
type Resolution struct {
	Range  *model.LineRange
	Status AnchorStatus
}

const (
	maxSymbolLines     = 400
	maxPlacementLines  = 400
	maxNominees        = 32
	maxReplacementLead = 4
)

// ResolveAnchor is NoteAnchor.resolve: where fence's range lands in source, re-found by the text
// it captured (nil: unknown), its anchor, or its body.
func ResolveAnchor(fence Fence, source []string, captured []string, body []string) Resolution {
	if fence.Symbol != nil {
		if r := SymbolRange(*fence.Symbol, source); r != nil {
			return Resolution{r, exact}
		}
		if fence.Lines == nil {
			return Resolution{nil, stale("symbol " + *fence.Symbol + " not found")}
		}
	}
	if fence.Lines == nil {
		return Resolution{&model.LineRange{Start: 1, End: max(1, len(source))}, exact}
	}
	lines := *fence.Lines
	length := lines.End - lines.Start
	written := lines.Start - 1
	resolution := func(start int, expected []string) Resolution {
		fixed := min(start+length, len(source)-1)
		end := fixed
		if len(expected) > 1 {
			if e, ok := trackedEnd(expected, source, start); ok {
				end = e
			}
		}
		r := &model.LineRange{Start: start + 1, End: end + 1}
		if start == written && end == fixed {
			return Resolution{r, exact}
		}
		return Resolution{r, relocated(lines)}
	}
	expected := expectedText(fence.Anchor, captured)
	offset, key, ok := firstKey(expected)
	if !ok {
		moved, ok := placement(body, source, written, length+1)
		if !ok {
			if lines.Start > len(source) {
				return Resolution{nil, stale(fmt.Sprintf("lines %d-%d are past the end of the file (%d lines)", lines.Start, lines.End, len(source)))}
			}
			return resolution(written, nil)
		}
		return resolution(moved, nil)
	}
	type candidate struct{ start, score, distance int }
	var candidates []candidate
	for index, line := range source {
		if normalized(line) != key {
			continue
		}
		start := index - offset
		if start < 0 {
			continue
		}
		score := 0
		for k, line := range expected[:min(len(expected), maxPlacementLines)] {
			if k != offset && start+k < len(source) && normalized(source[start+k]) == normalized(line) {
				score++
			}
		}
		candidates = append(candidates, candidate{start, score, absInt(start - written)})
	}
	substantive := 0
	for _, e := range expected {
		if normalized(e) != "" {
			substantive++
		}
	}
	if len(expected) > 1 && len(expected) <= maxPlacementLines && len(candidates) > 0 {
		near := append([]candidate(nil), candidates...)
		sort.SliceStable(near, func(i, j int) bool { return near[i].distance < near[j].distance })
		near = near[:min(len(near), maxNominees)]
		matching := append([]candidate(nil), candidates...)
		sort.SliceStable(matching, func(i, j int) bool {
			if matching[i].score != matching[j].score {
				return matching[i].score > matching[j].score
			}
			return -matching[i].distance > -matching[j].distance
		})
		matching = matching[:min(len(matching), 8)]
		wanted := normalizedAll(expected)
		seen := map[int]bool{}
		type scored struct{ start, kept, end, distance int }
		var all []scored
		for _, c := range append(near, matching...) {
			if seen[c.start] {
				continue
			}
			seen[c.start] = true
			kept, end := fit(wanted, source, c.start)
			all = append(all, scored{c.start, kept, end, absInt(c.start - written)})
		}
		best := all[0]
		for _, s := range all[1:] {
			less := false
			switch {
			case s.kept != best.kept:
				less = s.kept > best.kept
			case s.end-s.start != best.end-best.start:
				less = s.end-s.start < best.end-best.start
			case s.distance != best.distance:
				less = s.distance < best.distance
			default:
				less = s.start < best.start
			}
			if less {
				best = s
			}
		}
		if best.start == written || best.kept*2 > substantive {
			return resolution(best.start, expected)
		}
	} else if len(candidates) > 0 {
		best := candidates[0]
		for _, c := range candidates[1:] {
			if c.distance < best.distance || (c.distance == best.distance && c.start < best.start) {
				best = c
			}
		}
		return resolution(best.start, expected)
	}
	if len(expected) > 1 {
		if start, _, ok := bestPlacement(expected, source, written, len(expected)); ok {
			if kept, _ := fit(normalizedAll(expected), source, start); kept >= 2 && kept*2 > substantive {
				return resolution(start, expected)
			}
		}
	}
	reason := "no longer hold the code they showed"
	if len(candidates) == 0 {
		reason = "no longer contain \"" + anchorClip(key) + "\""
	}
	return Resolution{nil, stale(fmt.Sprintf("lines %d-%d %s", lines.Start, lines.End, reason))}
}

func absInt(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func normalized(line string) string { return TrimWS(line) }

func normalizedAll(lines []string) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		out[i] = normalized(l)
	}
	return out
}

func expectedText(anchor *string, captured []string) []string {
	if captured != nil {
		if offset, key, ok := firstKey(captured); ok && (anchor == nil || (offset == 0 && normalized(*anchor) == key)) {
			return captured
		}
	}
	if anchor != nil {
		return []string{*anchor}
	}
	return captured
}

func firstKey(lines []string) (int, string, bool) {
	for i, l := range lines {
		if n := normalized(l); n != "" {
			return i, n, true
		}
	}
	return 0, "", false
}

func trackedEnd(captured, source []string, start int) (int, bool) {
	if len(captured) > maxPlacementLines || start >= len(source) {
		return 0, false
	}
	wanted := normalizedAll(captured)
	kept, end := fit(wanted, source, start)
	substantive := 0
	for _, w := range wanted {
		if w != "" {
			substantive++
		}
	}
	if kept*2 <= substantive {
		return 0, false
	}
	shown := normalizedAll(source[start : end+1])
	lastKept := -1
	for _, line := range DiffLines(nonBlank(wanted, "c"), nonBlank(shown, "s")) {
		if line.Same() {
			lastKept = max(lastKept, line.Old)
		}
	}
replacing:
	for _, replaced := range wanted[min(len(wanted), lastKept+1):] {
		if end+1 >= len(source) {
			break
		}
		if replaced == "" {
			if normalized(source[end+1]) != "" {
				break
			}
			end++
			continue
		}
		for candidate := end + 1; candidate < min(len(source), end+2+maxReplacementLead); candidate++ {
			next := normalized(source[candidate])
			if next == "" {
				break
			}
			if similar(replaced, next) {
				end = candidate
				continue replacing
			}
		}
		break
	}
	return end, true
}

func fit(wanted, source []string, start int) (kept, end int) {
	substantive := 0
	for _, w := range wanted {
		if w != "" {
			substantive++
		}
	}
	if start+len(wanted) <= len(source) {
		all := true
		for i, w := range wanted {
			if normalized(source[start+i]) != w {
				all = false
				break
			}
		}
		if all {
			return substantive, start + max(0, len(wanted)-1)
		}
	}
	window := nonBlank(normalizedAll(source[start:min(len(source), start+len(wanted)+max(20, len(wanted)))]), "s")
	tokens := nonBlank(wanted, "c")
	most := KeptCount(tokens, window)
	low, high := 1, max(1, len(window))
	for low < high {
		mid := (low + high) / 2
		if KeptCount(tokens, window[:mid]) >= most {
			high = mid
		} else {
			low = mid + 1
		}
	}
	return most, start + low - 1
}

func nonBlank(lines []string, side string) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		if l == "" {
			out[i] = fmt.Sprintf("\x00%s%d", side, i)
		} else {
			out[i] = l
		}
	}
	return out
}

func similar(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	if strings.HasPrefix(a, b) || strings.HasPrefix(b, a) {
		return true
	}
	ca, cb := Chars(a), Chars(b)
	shared := 0
	for shared < len(ca) && shared < len(cb) && ca[shared] == cb[shared] {
		shared++
	}
	return shared*2 >= max(len(ca), len(cb))
}

func placement(body, source []string, written, length int) (int, bool) {
	start, bestKept, ok := bestPlacement(body, source, written, length)
	if !ok {
		return 0, false
	}
	wanted := 0
	for _, b := range body {
		if normalized(b) != "" {
			wanted++
		}
	}
	if start == written || bestKept <= keptAt(body, source, written, length) || bestKept < min(2, wanted) {
		return 0, false
	}
	return start, true
}

func bestPlacement(body, source []string, written, length int) (start, kept int, ok bool) {
	if len(body) > maxPlacementLines || length > maxPlacementLines {
		return 0, 0, false
	}
	type keyed struct {
		offset int
		key    string
	}
	var wanted []keyed
	keys := map[string]bool{}
	for i, b := range body {
		if n := normalized(b); n != "" {
			wanted = append(wanted, keyed{i, n})
			keys[n] = true
		}
	}
	if len(wanted) == 0 {
		return 0, 0, false
	}
	positions := map[string][]int{}
	for i, line := range source {
		if k := normalized(line); keys[k] {
			positions[k] = append(positions[k], i)
		}
	}
	nomineeSet := map[int]bool{}
	for _, w := range wanted {
		for _, index := range positions[w.key] {
			if index >= w.offset {
				nomineeSet[index-w.offset] = true
			}
		}
	}
	nominees := make([]int, 0, len(nomineeSet))
	for n := range nomineeSet {
		nominees = append(nominees, n)
	}
	sort.Slice(nominees, func(i, j int) bool {
		di, dj := absInt(nominees[i]-written), absInt(nominees[j]-written)
		if di != dj {
			return di < dj
		}
		return nominees[i] < nominees[j]
	})
	found := false
	for _, s := range nominees[:min(len(nominees), maxNominees)] {
		score := keptAt(body, source, s, length)
		if !found || score > kept {
			start, kept, found = s, score, true
		}
	}
	return start, kept, found
}

func keptAt(body, source []string, start, length int) int {
	if start < 0 || start >= len(source) {
		return 0
	}
	return KeptCount(normalizedAll(source[start:min(len(source), start+length)]), normalizedAll(body))
}

// AppliedRange is NoteAnchor.applied: where source already reads a proposal's body.
func AppliedRange(body, original, source []string, starts *[2]int, near int) *model.LineRange {
	wanted := normalizedAll(body)
	substantive := 0
	for _, w := range wanted {
		if w != "" {
			substantive++
		}
	}
	if substantive == 0 || len(wanted) > len(source) || len(wanted) > maxPlacementLines {
		return nil
	}
	reads := func(lines []string, at int) bool {
		if at < 0 || at+len(lines) > len(source) {
			return false
		}
		for i, l := range lines {
			if normalized(source[at+i]) != l {
				return false
			}
		}
		return true
	}
	lower, upper := 0, len(source)-len(wanted)
	if starts != nil {
		lower = max(0, starts[0])
		upper = min(len(source)-len(wanted), starts[1])
	}
	if lower > upper {
		return nil
	}
	var found []int
	for at := lower; at <= upper; at++ {
		if reads(wanted, at) {
			found = append(found, at)
		}
	}
	if len(found) == 0 {
		return nil
	}
	start := found[0]
	for _, f := range found[1:] {
		if absInt(f-near) < absInt(start-near) {
			start = f
		}
	}
	if starts == nil && len(found) > 1 && substantive < 2 {
		return nil
	}
	old := normalizedAll(original)
	if len(old) > len(wanted) {
		for at := max(0, start+len(wanted)-len(old)); at <= start; at++ {
			if reads(old, at) {
				return nil
			}
		}
	}
	return &model.LineRange{Start: start + 1, End: start + len(wanted)}
}

// MARK: Symbols

// SymbolRange is NoteAnchor.symbolRange: a best-effort declaration search; `Outer.inner` finds
// inner inside Outer's whole extent.
func SymbolRange(symbol string, source []string) *model.LineRange {
	var names []string
	for _, n := range strings.Split(symbol, ".") {
		if n != "" {
			names = append(names, n)
		}
	}
	scopeLow, scopeHigh := 0, len(source)
	var found *model.LineRange
	for index, name := range names {
		searchFrom := scopeLow
		if found != nil {
			searchFrom = found.Start
		}
		if searchFrom > scopeHigh {
			return nil
		}
		line, ok := declarationLine(name, source, searchFrom, scopeHigh)
		if !ok {
			return nil
		}
		limit := -1
		if index == len(names)-1 {
			limit = maxSymbolLines
		}
		end := extentEnd(line, source, limit)
		found = &model.LineRange{Start: line + 1, End: end + 1}
		scopeLow, scopeHigh = line, end+1
	}
	return found
}

var declarationKinds = []string{
	"function", "function*", "def", "func", "fun", "fn", "class", "record", "object", "interface", "protocol", "trait",
	"type", "typealias", "enum", "struct", "union", "actor", "module", "namespace", "mod", "package", "extension",
	"macro", "macro_rules!", "impl", "const", "let", "var", "val",
}

var declarationBindings = map[string]bool{"const": true, "let": true, "var": true, "val": true}

// keywordAlternation is DeclarationKeywords.alternation: longest first, ties by reverse order.
func keywordAlternation(words []string, quote func(string) string) string {
	sorted := append([]string(nil), words...)
	sort.Slice(sorted, func(i, j int) bool {
		if CharCount(sorted[i]) != CharCount(sorted[j]) {
			return CharCount(sorted[i]) > CharCount(sorted[j])
		}
		return sorted[i] > sorted[j]
	})
	for i, w := range sorted {
		sorted[i] = quote(w)
	}
	return strings.Join(sorted, "|")
}

func nonBindingKeywords() []string {
	var out []string
	for _, k := range declarationKinds {
		if !declarationBindings[k] {
			out = append(out, k)
		}
	}
	return out
}

func bindingKeywords() []string { return []string{"const", "let", "var", "val"} }

var declarationTemplates = func() []string {
	keywords := keywordAlternation(nonBindingKeywords(), regexp2.Escape)
	bindings := keywordAlternation(bindingKeywords(), regexp2.Escape)
	return []string{
		`(?:^|[^\w.$])(?:` + keywords + `)\s+(?:\([^)]*\)\s*)?\*?\s*%@(?![\w$])`,
		`(?:^|[^\w.$])(?:` + bindings + `)\s+%@\s*[:=]`,
		`^\s*(?:(?:export|public|private|protected|static|async|override|default)\s+)*%@\s*(?:[:=]\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*(?::[^=]*)?=>|\w+\s*=>)|\([^)]*\)?\s*(?::[^{]*)?\{\s*$)`,
		`^\s*(?!(?:return|else|if|while|for|switch|case|await|throw|new|yield|print)\b)[A-Za-z_][\w<>,:*&\s\[\]]*[\s*&]%@\s*\([^;]*$`,
	}
}()

var declarationCache sync.Map // name → []*regexp2.Regexp

func declarationRegexes(name string) []*regexp2.Regexp {
	if cached, ok := declarationCache.Load(name); ok {
		return cached.([]*regexp2.Regexp)
	}
	escaped := regexp2.Escape(name)
	var out []*regexp2.Regexp
	for _, template := range declarationTemplates {
		re, err := regexp2.Compile(strings.ReplaceAll(template, "%@", escaped), regexp2.None)
		if err == nil {
			out = append(out, re)
		}
	}
	declarationCache.Store(name, out)
	return out
}

func declarationLine(name string, source []string, low, high int) (int, bool) {
	for _, re := range declarationRegexes(name) {
		for index := low; index < high; index++ {
			if ok, _ := re.MatchString(source[index]); ok {
				return index, true
			}
		}
	}
	return 0, false
}

// extentEnd is NoteAnchor.extentEnd; limit < 0: unlimited.
func extentEnd(start int, source []string, limit int) int {
	stop := len(source)
	if limit >= 0 {
		stop = min(len(source), start+limit)
	}
	depth, parens := 0, 0
	opened := false
	signatureEnd := -1
	for index := start; index < stop; index++ {
		for _, c := range strippedLine(source[index]) {
			switch {
			case c == "{" && (opened || parens == 0):
				depth++
				opened = true
			case c == "}" && opened:
				depth--
			case c == "(":
				parens++
			case c == ")":
				parens = max(0, parens-1)
			}
		}
		if opened && depth <= 0 {
			return index
		}
		if !opened && parens == 0 {
			if signatureEnd < 0 {
				signatureEnd = index
			}
			trimmed := TrimWS(source[index])
			if strings.HasSuffix(trimmed, ";") {
				return index
			}
			if index-signatureEnd >= 3 || strings.HasSuffix(trimmed, ":") {
				break
			}
		}
	}
	if opened {
		return stop - 1
	}
	base := lineIndent(source[start])
	end := start
	if signatureEnd >= 0 {
		end = signatureEnd
	}
	for index := end + 1; index < stop; index++ {
		line := source[index]
		if TrimWS(line) == "" {
			continue
		}
		if lineIndent(line) > base {
			end = index
		} else {
			if lineIndent(line) == base && strings.HasPrefix(TrimWS(line), "end") && end > start {
				end = index
			}
			break
		}
	}
	return end
}

func strippedLine(line string) []string {
	var out []string
	quote := ""
	escaped := false
	previous := ""
	for _, c := range Chars(line) {
		switch {
		case quote != "":
			if escaped {
				escaped = false
			} else if c == "\\" {
				escaped = true
			} else if c == quote {
				quote = ""
			}
		case c == "\"" || c == "'" || c == "`":
			quote = c
		case c == "/" && previous == "/":
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
			return out
		default:
			out = append(out, c)
		}
		previous = c
	}
	return out
}

func lineIndent(line string) int {
	width := 0
	for _, c := range line {
		switch c {
		case ' ':
			width++
		case '\t':
			width += 4
		default:
			return width
		}
	}
	return width
}

func anchorClip(text string) string {
	if CharCount(text) > 40 {
		return CharPrefix(text, 39) + "…"
	}
	return text
}
