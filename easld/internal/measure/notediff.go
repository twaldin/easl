package measure

// DiffLine is one row of NoteDiff.lines: kept (Old and New set), removed (Old), or added (New);
// indices 0-based, the other side -1.
type DiffLine struct {
	Old, New int
	Text     string
}

// Same reports a kept line.
func (l DiffLine) Same() bool { return l.Old >= 0 && l.New >= 0 }

const (
	diffMaxEdits = 1000
	diffMaxLines = 20000
)

type diffStep struct{ kind, i, j int } // kind 0 keep, 1 delete, 2 insert

// DiffLines is NoteDiff.lines: Myers' shortest edit script after trimming the common prefix
// and suffix, removals before additions within a changed run; past the edit budget the middle
// is replaced wholesale.
func DiffLines(old, new []string) []DiffLine {
	prefix := 0
	for prefix < len(old) && prefix < len(new) && old[prefix] == new[prefix] {
		prefix++
	}
	suffix := 0
	for suffix < len(old)-prefix && suffix < len(new)-prefix && old[len(old)-1-suffix] == new[len(new)-1-suffix] {
		suffix++
	}
	var out []DiffLine
	for i := range prefix {
		out = append(out, DiffLine{i, i, old[i]})
	}
	a := old[prefix : len(old)-suffix]
	b := new[prefix : len(new)-suffix]
	var removed, added []DiffLine
	flush := func() {
		out = append(out, removed...)
		out = append(out, added...)
		removed, added = nil, nil
	}
	var steps []diffStep
	ok := false
	if len(a)+len(b) <= diffMaxLines {
		steps, ok = diffScript(a, b, diffMaxEdits)
	}
	if !ok {
		steps = nil
		for i := range a {
			steps = append(steps, diffStep{1, i, 0})
		}
		for j := range b {
			steps = append(steps, diffStep{2, 0, j})
		}
	}
	for _, step := range steps {
		switch step.kind {
		case 0:
			flush()
			out = append(out, DiffLine{prefix + step.i, prefix + step.j, old[prefix+step.i]})
		case 1:
			removed = append(removed, DiffLine{prefix + step.i, -1, old[prefix+step.i]})
		case 2:
			added = append(added, DiffLine{-1, prefix + step.j, new[prefix+step.j]})
		}
	}
	flush()
	for k := range suffix {
		i := len(old) - suffix + k
		out = append(out, DiffLine{i, len(new) - suffix + k, old[i]})
	}
	return out
}

// KeptCount is NoteDiff.keptCount: lines the diff keeps.
func KeptCount(old, new []string) int {
	n := 0
	for _, l := range DiffLines(old, new) {
		if l.Same() {
			n++
		}
	}
	return n
}

func diffScript(a, b []string, maxEdits int) ([]diffStep, bool) {
	n, m := len(a), len(b)
	if n == 0 {
		steps := make([]diffStep, m)
		for j := range m {
			steps[j] = diffStep{2, 0, j}
		}
		return steps, true
	}
	if m == 0 {
		steps := make([]diffStep, n)
		for i := range n {
			steps[i] = diffStep{1, i, 0}
		}
		return steps, true
	}
	limit := min(n+m, maxEdits)
	offset := limit + 1
	v := make([]int, 2*limit+3)
	var trace [][]int
	found := false
search:
	for d := 0; d <= limit; d++ {
		trace = append(trace, append([]int(nil), v[offset-d:offset+d+1]...))
		for k := -d; k <= d; k += 2 {
			var x int
			if k == -d || (k != d && v[offset+k-1] < v[offset+k+1]) {
				x = v[offset+k+1]
			} else {
				x = v[offset+k-1] + 1
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[offset+k] = x
			if x >= n && y >= m {
				found = true
				break search
			}
		}
	}
	if !found {
		return nil, false
	}
	var steps []diffStep
	x, y := n, m
	for d := len(trace) - 1; d >= 0; d-- {
		saved := trace[d]
		at := func(k int) int { return saved[k+d] }
		k := x - y
		var previousK int
		if k == -d || (k != d && at(k-1) < at(k+1)) {
			previousK = k + 1
		} else {
			previousK = k - 1
		}
		previousX := 0
		if d != 0 {
			previousX = at(previousK)
		}
		previousY := previousX - previousK
		for x > previousX && y > previousY {
			x--
			y--
			steps = append(steps, diffStep{0, x, y})
		}
		if d == 0 {
			break
		}
		if x == previousX {
			y--
			steps = append(steps, diffStep{2, 0, y})
		} else {
			x--
			steps = append(steps, diffStep{1, x, 0})
		}
	}
	for i, j := 0, len(steps)-1; i < j; i, j = i+1, j-1 {
		steps[i], steps[j] = steps[j], steps[i]
	}
	return steps, true
}
