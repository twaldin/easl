package mention

import (
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/twaldin/easl/easld/internal/measure"
)

// TerminalCommand is what a terminal command block mention says ran (TerminalCommands.swift).
type TerminalCommand struct {
	Command    *string
	Exit       *int
	DurationMs *int
}

// Status is TerminalCommand.status: `exit 1 · 42 s` after a failure or a long run, else nil.
func (c TerminalCommand) Status() *string {
	failed := c.Exit != nil && *c.Exit != 0
	long := c.DurationMs != nil && *c.DurationMs >= 10_000
	if !failed && !long {
		return nil
	}
	var parts []string
	if failed {
		parts = append(parts, "exit "+strconv.Itoa(*c.Exit))
	}
	if c.DurationMs != nil && (long || *c.DurationMs >= 1000) {
		parts = append(parts, Duration(*c.DurationMs))
	}
	return new(strings.Join(parts, " · "))
}

// Duration is TerminalCommand.duration: `0.4 s`, `42 s`, `3 min 2 s`, `1 h 5 min`.
func Duration(ms int) string {
	if ms < 10_000 {
		return fmt.Sprintf("%.1f s", float64(ms)/1000)
	}
	seconds := ms / 1000
	if seconds < 60 {
		return strconv.Itoa(seconds) + " s"
	}
	if seconds < 3600 {
		if seconds%60 == 0 {
			return strconv.Itoa(seconds/60) + " min"
		}
		return fmt.Sprintf("%d min %d s", seconds/60, seconds%60)
	}
	return fmt.Sprintf("%d h %d min", seconds/3600, seconds%3600/60)
}

// trimmedRow is TerminalTail.trimmed: trailing whitespace off.
func trimmedRow(row string) string {
	return strings.TrimRightFunc(row, func(r rune) bool { return unicode.IsSpace(r) || r == 0x2028 || r == 0x2029 })
}

// terminalExcerptLines is TerminalExcerpt.lines: rows trimmed, blank lines at either end dropped.
func terminalExcerptLines(text string) []string {
	lines := measure.SplitLF(text)
	for i, l := range lines {
		lines[i] = trimmedRow(l)
	}
	for len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	for len(lines) > 0 && lines[0] == "" {
		lines = lines[1:]
	}
	return lines
}

var (
	outcomesPattern = regexp.MustCompile(`^\s*(?:\S+\.py\s+)?([.FEsxX]+)\s*(\[\s*\d{1,3}%\])?$`)
	barPattern      = regexp.MustCompile(`[█▉▊▋▌▍▎▏━■░▒▓#]{4,}.*\b\d{1,3}(?:\.\d+)?%`)
	failurePattern  = regexp.MustCompile(`^E(?:\s|$)|^>\s|^_{3,} .+ _{3,}$|^={3,} .+ ={3,}$|\b(?:FAILED|FAIL|ERROR)\b|(?:Error|Exception)\b|\berror(?:\[\w+\])?:|Traceback \(most recent call last\)|^\s*File ".+", line \d+|panicked at|^\s*(?:-->|:::)\s+\S+:\d+:\d+|^\s*at\s.*\S:\d+:\d+\)?$`)
)

func isProgress(line string) bool {
	if measure.TrimWS(line) == "..." {
		return false
	}
	if m := outcomesPattern.FindStringSubmatchIndex(line); m != nil {
		marks := line[m[2]:m[3]]
		return m[4] >= 0 || (len(marks) >= 3 && strings.Contains(marks, "."))
	}
	return barPattern.MatchString(line)
}

func isFailure(line string) bool { return failurePattern.MatchString(line) }

// trimTerminal is TerminalExcerpt.trim: lines whole when they fit in head + tail, else what
// matters, each gap saying what it left out.
func trimTerminal(lines []string, head, tail int) []string {
	if len(lines) <= head+tail+1 {
		return lines
	}
	progress := map[int]bool{}
	var kept []int
	for i, l := range lines {
		if isProgress(l) {
			progress[i] = true
		} else {
			kept = append(kept, i)
		}
	}
	budget := head + tail
	chosen := map[int]bool{}
	if len(kept) <= budget+1 {
		for _, i := range kept {
			chosen[i] = true
		}
	} else {
		for _, i := range kept[:min(head, 3)] {
			chosen[i] = true
		}
		for _, i := range kept[len(kept)-min(tail, 10):] {
			chosen[i] = true
		}
		for _, i := range kept {
			if len(chosen) < budget && isFailure(lines[i]) {
				chosen[i] = true
			}
		}
		for _, i := range kept[:min(head, len(kept))] {
			if len(chosen) < budget {
				chosen[i] = true
			}
		}
		for j := len(kept) - 1; j >= 0; j-- {
			if len(chosen) < budget {
				chosen[kept[j]] = true
			}
		}
	}
	order := make([]int, 0, len(chosen))
	for i := range chosen {
		order = append(order, i)
	}
	sort.Ints(order)
	var trimmed []string
	next := 0
	gap := func(end int) {
		count := end - next
		if count == 1 && !progress[next] {
			trimmed = append(trimmed, lines[next])
		} else if count > 0 {
			allProgress := true
			for i := next; i < end; i++ {
				if !progress[i] {
					allProgress = false
				}
			}
			kind := ""
			if allProgress {
				kind = "progress "
			}
			plural := "s"
			if count == 1 {
				plural = ""
			}
			trimmed = append(trimmed, fmt.Sprintf("… %d %sline%s omitted …", count, kind, plural))
		}
	}
	for _, i := range order {
		gap(i)
		trimmed = append(trimmed, lines[i])
		next = i + 1
	}
	gap(len(lines))
	return trimmed
}

// PageLogEntry is what a browser tile's page reported (PageLog.swift).
type PageLogEntry struct {
	Seq      int
	Time     string
	Kind     string // console, exception, request
	Level    string
	Text     string
	Source   *string
	Stack    *string
	Method   *string
	URL      *string
	Status   *int
	Resource *string
}

// Noun is `error`, `warning`, `failed request`, `console.log`….
func (e PageLogEntry) Noun() string {
	switch e.Kind {
	case "exception":
		return "error"
	case "request":
		return "failed request"
	}
	switch e.Level {
	case "error":
		return "console error"
	case "warn":
		return "warning"
	}
	return "console." + e.Level
}

var schemePrefix = regexp.MustCompile(`^[a-z]+://`)

// ShortSource is `app.js:12` for `http://localhost:3000/static/app.js?v=3:12:5`.
func (e PageLogEntry) ShortSource() *string {
	if e.Source == nil {
		return nil
	}
	source := *e.Source
	parts := strings.Split(source, ":")
	if len(parts) < 3 {
		return new(measure.PathLabel(source))
	}
	line, err1 := strconv.Atoi(parts[len(parts)-2])
	_, err2 := strconv.Atoi(parts[len(parts)-1])
	if err1 != nil || err2 != nil {
		return new(measure.PathLabel(source))
	}
	file := strings.Join(parts[:len(parts)-2], ":")
	path := file
	if u, err := url.Parse(file); err == nil {
		path = u.Path
	}
	var name string
	if pieces := strings.FieldsFunc(path, func(r rune) bool { return r == '/' }); len(pieces) > 0 {
		name = pieces[len(pieces)-1]
	} else {
		name = schemePrefix.ReplaceAllString(file, "")
	}
	return new(name + ":" + strconv.Itoa(line))
}

// Frames are the stack's frames without easl's own.
func (e PageLogEntry) Frames() []string {
	if e.Stack == nil {
		return nil
	}
	var out []string
	for _, f := range measure.SplitLFOmittingEmpty(*e.Stack) {
		f = measure.TrimWS(f)
		if f != "" && !strings.Contains(f, "canvas-page-log.js") && !strings.HasPrefix(f, "user-script:") && !strings.Contains(f, "@user-script:") {
			out = append(out, f)
		}
	}
	return out
}

var isoFractional = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+(Z|[+-]\d{2}:?\d{2})$`)

// ClockTime is the time of day it happened (`14:03:05`), local time.
func (e PageLogEntry) ClockTime() *string {
	if !isoFractional.MatchString(e.Time) {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, e.Time)
	if err != nil {
		return nil
	}
	return new(t.Local().Format("15:04:05"))
}
