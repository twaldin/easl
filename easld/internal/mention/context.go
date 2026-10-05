package mention

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
)

// Resolved is MentionContext.Resolved: one mention as the context gives it.
type Resolved struct {
	ID, Ref, Label, Summary string
}

// JSON is how `tray.drain` returns it.
func (r Resolved) JSON() map[string]any {
	return map[string]any{"id": r.ID, "ref": r.Ref, "label": r.Label, "summary": r.Summary}
}

const (
	maxExcerptLines   = 12
	contextLines      = 3
	maxNoteLines      = 80
	maxNoteCharacters = 4000
	terminalHead      = 10
	terminalTail      = 30
	maxGroupLines     = 120
	groupExcerptLines = 6
	groupLineChars    = 200
	maxGroupArrows    = 40
	maxStackLines     = 8
)

// Resolve is MentionContext.resolve: the mention numbered index at its objects' current
// revision. caller is the terminal the context goes to ("" for none): a mention of it says
// `(your terminal)`.
func Resolve(m model.Mention, index int, b BoardView, caller string) Resolved {
	t, err := DecodeTarget(m.Target)
	if err != nil {
		return Resolved{ID: m.ID, Ref: "canvas:" + m.ID, Label: m.Label}
	}
	objects := b.Objects()
	edited := ""
	if m.Edited {
		edited = " (edited)"
	}
	n := "[" + itoa(index) + "]"
	var lines []string
	switch t.Kind {
	case "code":
		symbol, diff := "", ""
		if t.Symbol != nil {
			symbol = " (symbol " + *t.Symbol + ")"
		}
		if t.Diff != nil {
			diff = " · " + *t.Diff
		}
		lines = append(lines, fmt.Sprintf("%s code %s:%d-%d%s · tile %s%s%s%s", n, t.Path, t.Lines.Start, t.Lines.End, symbol, t.Object,
			provenance(t.Object, t.Side, t.Commit, t.Diff != nil, b), diff, edited))
		text, failure := codeText(t.Path, t.Side, t.Commit, b)
		if text != nil {
			lines = append(lines, excerpt(text, t.Lines, maxExcerptLines, "")...)
		} else {
			lines = append(lines, failure)
		}
	case "dom":
		textPart, pointPart := "", ""
		if t.DOMText != nil {
			textPart = " \"" + clip(*t.DOMText, 80) + "\""
		}
		if t.Point != nil {
			pointPart = fmt.Sprintf(" · pixel (%d, %d) of %d×%d, from its top-left", t.Point.X, t.Point.Y, t.Point.W, t.Point.H)
		}
		kind := "browser"
		if o, ok := objects[t.Object]; ok {
			kind = string(o.Type)
		}
		lines = append(lines, fmt.Sprintf("%s dom %s · %s%s%s · %s tile %s%s", n, t.URL, t.Selector, textPart, pointPart, kind, t.Object, edited))
	case "terminal":
		name := terminalName(t.Object, b, caller)
		switch t.Part {
		case "selection":
			lines = append(lines, n+" terminal tile "+t.Object+name+" · selected text"+edited)
		case "rows":
			lines = append(lines, n+" terminal tile "+t.Object+name+" · screen rows around the click (> marks it)"+edited)
		case "command":
			parts := []string{"command output"}
			if t.Command != nil {
				if t.Command.Command != nil {
					parts[0] = "command `" + clip(*t.Command.Command, 120) + "`"
				}
				if t.Command.Exit != nil {
					parts = append(parts, "exit "+itoa(*t.Command.Exit))
				}
				if t.Command.DurationMs != nil {
					parts = append(parts, Duration(*t.Command.DurationMs))
				}
			}
			// The block's index (`read it: …`) is the app's terminal log's to say; without it, none.
			lines = append(lines, n+" "+strings.Join(parts, " · ")+" · output of terminal tile "+t.Object+name+edited)
		}
		var text []string
		if t.Part == "rows" {
			text = measure.SplitLF(t.Text)
		} else {
			text = terminalExcerptLines(t.Text)
		}
		lines = append(lines, terminalLines(text)...)
	case "group":
		lines = append(lines, groupLines(t.Objects, t.Name, index, edited, b, caller)...)
	case "image":
		file := measure.ImageFile(t.Path, b.Root())
		extent := " (file unreadable)"
		if w, h, ok, _ := measure.ImageNaturalSize(file); ok {
			extent = fmt.Sprintf(" of %d×%d", int(w), int(h))
		}
		lines = append(lines, fmt.Sprintf("%s image %s · pixel (%d, %d)%s, from its top-left · tile %s%s", n, t.Path, t.X, t.Y, extent, t.Object, edited))
	case "note":
		lines = append(lines, noteItemLines(t.Item, t.Object, index, edited, b)...)
	case "console":
		lines = append(lines, consoleLines(t.Entry, t.Object, t.URL, index, edited, b)...)
	case "object":
		object, ok := objects[t.Object]
		if !ok {
			lines = append(lines, n+" object "+t.Object+" (deleted)")
			break
		}
		lines = append(lines, n+" "+describe(object, b, caller, nil)+edited)
		if markdown, ok := str(object.Props, "markdown"); ok && object.Type == model.Note {
			lines = append(lines, noteLines(markdown, t.Object, maxNoteLines, maxNoteCharacters, "    ")...)
		}
		// A terminal's screen and the page elements under a shape are the app's to read.
	}
	rev := ""
	if ids := t.ObjectIDs(); len(ids) > 0 {
		if o, ok := objects[ids[0]]; ok {
			rev = "@rev" + itoa(o.Rev)
		}
	}
	return Resolved{ID: m.ID, Ref: "canvas:" + m.ID + rev, Label: m.Label, Summary: strings.Join(lines, "\n")}
}

// Render is MentionContext.render: the `<canvas-mentions>` block around resolved mentions.
// targets are the mentions' targets; from and header ("" for none) name another agent's
// attachments (agent.prompt `mentions`).
func Render(resolved []Resolved, b BoardView, targets []map[string]any, from, header string) string {
	if len(resolved) == 0 {
		return ""
	}
	open := "<canvas-mentions board=\"" + b.ID() + "\" root=\"" + b.Root() + "\""
	if from != "" {
		open += " from=\"" + from + "\""
	}
	out := []string{open + ">"}
	if header != "" {
		out = append(out, header)
	}
	for _, r := range resolved {
		out = append(out, r.Summary)
	}
	objects := b.Objects()
	anyTerminal, anyOther := false, false
	for _, target := range targets {
		isTerminal := false
		switch target["kind"] {
		case "terminal":
			isTerminal = true
		case "object":
			id, _ := target["object"].(string)
			o, ok := objects[id]
			isTerminal = ok && o.Type == model.Terminal
		}
		if isTerminal {
			anyTerminal = true
		} else {
			anyOther = true
		}
	}
	if anyOther || len(targets) == 0 {
		out = append(out, "Read more with the easl SDK or CLI: easl get <id> --as graph; look with easl render <id>")
	}
	if anyTerminal {
		out = append(out, "Read more of a terminal: easl agent.read --target <id> (--block -1: its last command's output, -2 the one before)")
	}
	out = append(out, "</canvas-mentions>")
	return strings.Join(out, "\n")
}

func terminalLines(lines []string) []string {
	trimmed := trimTerminal(lines, terminalHead, terminalTail)
	out := make([]string, len(trimmed))
	for i, l := range trimmed {
		out[i] = "    " + l
	}
	return out
}

func terminalName(id string, b BoardView, caller string) string {
	if id == caller {
		return " (your terminal)"
	}
	o, ok := b.Objects()[id]
	if !ok {
		return ""
	}
	return " \"" + clip(Title(o), 60) + "\""
}

// provenance is MentionContext.provenance: where a code mention's lines come from.
func provenance(object string, side, commit *string, explicit bool, b BoardView) string {
	old := side != nil && *side == "old"
	if commit == nil {
		if old {
			return " · old side of diff"
		}
		return ""
	}
	sha := measure.CharPrefix(*commit, 7)
	if side == nil {
		return " · at " + sha
	}
	kind := ""
	if tile, ok := b.Objects()[object]; ok {
		switch tile.Type {
		case model.Code:
			var prop *string
			if s, ok := str(tile.Props, "diffBase"); ok {
				prop = &s
			}
			kind = diffBaseName(prop) + " "
		case model.Changes:
			base := changesBase(tile.Props)
			kind = diffBaseName(&base) + " "
		}
	}
	which := ""
	switch {
	case old && explicit:
		which = ", old side (base)"
	case old:
		which = ", old side"
	case explicit:
		which = ", new side (working tree)"
	}
	return " · diff vs " + kind + sha + which
}

// excerpt is MentionContext.excerpt: the mentioned lines marked `>`, with up to contextLines
// unmarked lines around them while the whole fits in limit lines.
func excerpt(text []string, r model.LineRange, limit int, indent string) []string {
	count := len(text)
	start, end := max(1, r.Start), min(count, r.End)
	if start > end {
		return []string{fmt.Sprintf("%s    (range %d-%d is outside the file)", indent, r.Start, r.End)}
	}
	pad := min(contextLines, max(0, limit-(end-start+1))/2)
	from := max(1, start-pad)
	to := min(count, end+pad, from+limit-1)
	var lines []string
	for number := from; number <= to; number++ {
		marker := "    "
		if number >= start && number <= end {
			marker = "  > "
		}
		label := itoa(number)
		if len(label) < 5 {
			label += strings.Repeat(" ", 5-len(label))
		} else {
			label = label[:5]
		}
		lines = append(lines, indent+marker+label+text[number-1])
	}
	if r.End > to {
		lines = append(lines, indent+"    …")
	}
	return lines
}

// absolutePath is Board.absoluteURL(path).path.
func absolutePath(path, root string) string {
	if strings.HasPrefix(path, "/") {
		return path
	}
	return strings.TrimSuffix(root, "/") + "/" + path
}

// codeText is MentionContext.codeText: the file a code mention reads (its lines), at commit
// when the mention names one (old side or pinned), else the working tree; else why not.
func codeText(path string, side, commit *string, b BoardView) ([]string, string) {
	file := absolutePath(path, b.Root())
	if commit != nil && (side == nil || *side != "new") {
		if text, ok := textAtCommit(file, *commit); ok {
			return measure.SideLines(text), ""
		}
		return nil, "    (" + path + " is not readable at " + measure.CharPrefix(*commit, 7) + ")"
	}
	data, err := os.ReadFile(file)
	if err != nil || !utf8.Valid(data) {
		return nil, "    (file unreadable: " + file + ")"
	}
	return measure.SideLines(string(data)), ""
}

// textAtCommit is GitDiffEngine.text(of:at:): file as of commit (`git cat-file blob`).
func textAtCommit(file, commit string) (string, bool) {
	directory := filepath.Dir(measure.StandardPath(file))
	for {
		if info, err := os.Stat(directory); (err == nil && info.IsDir()) || directory == "/" {
			break
		}
		directory = filepath.Dir(directory)
	}
	out, err := measure.RunGit([]string{"rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"}, directory, nil, 0, 0)
	if err != nil {
		return "", false
	}
	lines := measure.SplitLFOmittingEmpty(string(out))
	if len(lines) != 3 {
		return "", false
	}
	toplevel := strings.TrimSuffix(lines[0], "/") + "/"
	real := measure.RealPath(file)
	relative := real
	if strings.HasPrefix(real, toplevel) {
		relative = real[len(toplevel):]
	}
	data, err := measure.RunGit([]string{"cat-file", "blob", "--end-of-options", commit + ":" + relative}, lines[0], nil, 4<<20, 0)
	if err != nil {
		return "", false
	}
	return strings.ToValidUTF8(string(data), "\uFFFD"), true
}

// noteLines is MentionContext.noteLines: a whole note up to limit lines and characters.
func noteLines(markdown, id string, limit, characters int, indent string) []string {
	var lines []string
	count := 0
	source := measure.NoteLines(markdown)
	for _, line := range source[:min(len(source), limit)] {
		n := measure.CharCount(line)
		if count+n > characters {
			break
		}
		lines = append(lines, indent+line)
		count += n + 1
	}
	if len(source) > len(lines) {
		lines = append(lines, fmt.Sprintf("%s… %d more lines (easl get %s)", indent, len(source)-len(lines), id))
	}
	return lines
}

// noteItemLines is MentionContext.noteItemLines: a note block as the note reads now.
func noteItemLines(item NoteItem, id string, index int, edited string, b BoardView) []string {
	note, ok := b.Objects()[id]
	if !ok {
		return []string{fmt.Sprintf("[%d] note %s (deleted)", index, id)}
	}
	markdown, _ := str(note.Props, "markdown")
	found, unchanged, isFound := FindNoteItem(item.Text, item.Lines.Start, markdown)
	current := item
	if isFound {
		current = found
	}
	where := fmt.Sprintf("lines %d-%d", current.Lines.Start, current.Lines.End)
	if current.Lines.Start == current.Lines.End {
		where = fmt.Sprintf("line %d", current.Lines.Start)
	}
	path := ""
	if len(current.Headings) > 0 {
		path = " · in " + strings.Join(current.Headings, " › ")
	}
	lines := []string{fmt.Sprintf("[%d] note %s \"%s\" · %s, markdown %s%s%s", index, id, clip(Title(note), 60), current.Noun(), where, path, edited)}
	switch {
	case !isFound:
		lines = append(lines, "    (no longer in the note; as it read when mentioned:)")
	case !unchanged:
		lines = append(lines, "    (changed since it was mentioned; as it reads now:)")
	}
	for _, l := range measure.NoteLines(current.Text) {
		lines = append(lines, "    "+l)
	}
	if omitted := current.OmittedLines(); omitted > 0 {
		lines = append(lines, fmt.Sprintf("    … %d more lines (easl get %s)", omitted, id))
	}
	return lines
}

// consoleLines is MentionContext.consoleLines: a page's message, error or failed request.
func consoleLines(entry PageLogEntry, id, url string, index int, edited string, b BoardView) []string {
	tile := ""
	if o, ok := b.Objects()[id]; ok {
		tile = " \"" + clip(Title(o), 60) + "\""
	}
	when := ""
	if c := entry.ClockTime(); c != nil {
		when = " · at " + *c
	}
	lines := []string{fmt.Sprintf("[%d] page %s · browser tile %s%s · page %s%s%s", index, entry.Noun(), id, tile, url, when, edited)}
	text := measure.SplitLF(entry.Text)
	for _, l := range text[:min(len(text), maxExcerptLines)] {
		lines = append(lines, "    "+l)
	}
	if entry.Source != nil {
		lines = append(lines, "    source: "+*entry.Source)
	}
	frames := entry.Frames()
	if len(frames) > 0 {
		lines = append(lines, "    stack:")
	}
	for _, f := range frames[:min(len(frames), maxStackLines)] {
		lines = append(lines, "      "+f)
	}
	if len(frames) > maxStackLines {
		lines = append(lines, fmt.Sprintf("      … %d more frames", len(frames)-maxStackLines))
	}
	return lines
}

// MARK: Drawings

type binding struct {
	object   string
	isObject bool
	lines    *model.LineRange
	selector *string
	node     *string
	x, y     float64
}

func parseBinding(v any) (binding, bool) {
	m, _ := v.(map[string]any)
	if id, ok := m["object"].(string); ok {
		b := binding{object: id, isObject: true}
		if l, ok := m["lines"]; ok {
			if r, err := DecodeLineRange(l); err == nil {
				b.lines = &r
			}
		}
		if s, ok := m["selector"].(string); ok {
			b.selector = &s
		}
		if s, ok := m["node"].(string); ok {
			b.node = &s
		}
		return b, true
	}
	list, _ := m["point"].([]any)
	var values []float64
	for _, v := range list {
		if f, ok := v.(float64); ok {
			values = append(values, f)
		}
	}
	if len(values) == 2 {
		return binding{x: values[0], y: values[1]}, true
	}
	return binding{}, false
}

type arrowSpec struct {
	from, to binding
	relation *string
	label    *string
}

func parseArrow(props map[string]any) (arrowSpec, bool) {
	from, ok1 := parseBinding(props["from"])
	to, ok2 := parseBinding(props["to"])
	if !ok1 || !ok2 {
		return arrowSpec{}, false
	}
	spec := arrowSpec{from: from, to: to}
	if s, ok := props["relation"].(string); ok {
		spec.relation = &s
	}
	if s, ok := props["label"].(string); ok {
		spec.label = &s
	}
	return spec, true
}

func relationText(relation *string) string {
	if relation == nil {
		return ""
	}
	return " (" + *relation + ")"
}

// endName is MentionContext.endName.
func endName(b binding) string {
	if !b.isObject {
		return fmt.Sprintf("(%.0f, %.0f)", b.x, b.y)
	}
	switch {
	case b.lines != nil:
		return fmt.Sprintf("%s:%d-%d", b.object, b.lines.Start, b.lines.End)
	case b.node != nil:
		return b.object + " node " + *b.node
	case b.selector != nil:
		return b.object + " " + *b.selector
	}
	return b.object
}

// groupMembers is GroupSpec.members; ok false without a members array.
func groupMembers(props map[string]any) ([]string, bool) {
	list, ok := props["members"].([]any)
	if !ok {
		return nil, false
	}
	var out []string
	for _, v := range list {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out, true
}

// enclosed is Board.enclosed(by:): objects other than arrows lying wholly inside object.
func enclosed(object model.Object, b BoardView) []model.Object {
	var out []model.Object
	for _, o := range sortedObjects(b) {
		if o.ID != object.ID && o.Type != model.Arrow && object.Frame.Contains(o.Frame) {
			out = append(out, o)
		}
	}
	return out
}

func rectContainsPoint(f model.Frame, x, y float64) bool {
	return x >= f.X && x < f.MaxX() && y >= f.Y && y < f.MaxY()
}

// arrowsEnclosed is Board.arrows(enclosedBy:): arrows with both ends inside object.
func arrowsEnclosed(object model.Object, b BoardView) []arrowSpec {
	inside := map[string]bool{}
	for _, o := range enclosed(object, b) {
		inside[o.ID] = true
	}
	within := func(e binding) bool {
		if e.isObject {
			return inside[e.object]
		}
		return rectContainsPoint(object.Frame, e.x, e.y)
	}
	var out []arrowSpec
	for _, o := range sortedObjects(b) {
		if o.Type != model.Arrow || o.ID == object.ID {
			continue
		}
		if spec, ok := parseArrow(o.Props); ok && within(spec.from) && within(spec.to) {
			out = append(out, spec)
		}
	}
	return out
}

func intersection(a, b model.Frame) (model.Frame, bool) {
	x0, y0 := max(a.X, b.X), max(a.Y, b.Y)
	x1, y1 := min(a.MaxX(), b.MaxX()), min(a.MaxY(), b.MaxY())
	if x1 < x0 || y1 < y0 {
		return model.Frame{}, false
	}
	return model.Frame{X: x0, Y: y0, W: x1 - x0, H: y1 - y0}, true
}

// host is MentionContext.host(of:): what a drawn shape lies on, and the part over it.
func host(object model.Object, b BoardView) (model.Object, model.Frame, bool, bool) {
	if object.Type != model.Shape {
		return model.Object{}, model.Frame{}, false, false
	}
	region := object.Frame
	var under []model.Object
	for _, o := range sortedObjects(b) {
		if o.Type != model.Arrow && o.Type != model.Group && o.ID != object.ID && o.Z < object.Z {
			under = append(under, o)
		}
	}
	topmost := func(match func(model.Object) bool) (model.Object, bool) {
		var best model.Object
		found := false
		for _, o := range under {
			if match(o) && (!found || o.Z > best.Z) {
				best, found = o, true
			}
		}
		return best, found
	}
	if h, ok := topmost(func(o model.Object) bool { return o.Frame.Contains(region) }); ok {
		return h, region, false, true
	}
	area := region.W * region.H
	if area <= 0 {
		return model.Object{}, model.Frame{}, false, false
	}
	h, ok := topmost(func(o model.Object) bool {
		part, ok := intersection(o.Frame, region)
		return ok && part.W*part.H > area/2
	})
	if !ok {
		return model.Object{}, model.Frame{}, false, false
	}
	part, _ := intersection(h.Frame, region)
	return h, part, true, true
}

// describe is MentionContext.describe: one line with an object's spatial relations; omitting
// are arrows said elsewhere.
func describe(object model.Object, b BoardView, caller string, omitting map[string]bool) string {
	parts := []string{string(object.Type) + " " + object.ID}
	title := Title(object)
	if title != "" {
		if object.Type == model.Shape {
			parts = append(parts, "\""+strings.ReplaceAll(title, "\n", "\\n")+"\"")
		} else {
			parts = append(parts, "\""+clip(title, 60)+"\"")
		}
	}
	if object.Type == model.Terminal && object.ID == caller {
		parts = append(parts, "(your terminal)")
	}
	if object.Type == model.Shape {
		if object.CreatedBy.Kind == "agent" {
			parts = append(parts, "(by agent)")
		} else {
			parts = append(parts, "(drawn by user)")
		}
		var inside []string
		for _, o := range enclosed(object, b) {
			inside = append(inside, o.ID)
		}
		if len(inside) > 0 {
			parts = append(parts, "· encloses "+strings.Join(inside, ", "))
		}
		for _, spec := range arrowsEnclosed(object, b) {
			parts = append(parts, "· inner arrow "+endName(spec.from)+" → "+endName(spec.to)+relationText(spec.relation))
		}
		if h, region, partly, ok := host(object, b); ok {
			zoom := measure.ObjectZoom(h)
			title := 0.0
			if h.Type.IsTile() {
				title = measure.TitleHeight
			}
			prefix := ""
			if partly {
				prefix = "partly "
			}
			parts = append(parts, fmt.Sprintf("· %sover %s %s at (%.0f, %.0f) %.0f×%.0f", prefix, h.Type, h.ID,
				(region.X-h.Frame.X)/zoom, (region.Y-h.Frame.Y-title)/zoom, region.W/zoom, region.H/zoom))
		}
	}
	for _, arrow := range sortedObjects(b) {
		if arrow.Type != model.Arrow || omitting[arrow.ID] {
			continue
		}
		relation := ""
		if r, ok := str(arrow.Props, "relation"); ok {
			relation = " (" + r + ")"
		}
		from, _ := arrow.Props["from"].(map[string]any)
		to, _ := arrow.Props["to"].(map[string]any)
		fromID, fromOK := from["object"].(string)
		toID, toOK := to["object"].(string)
		if fromOK && fromID == object.ID && toOK {
			parts = append(parts, "· arrow → "+toID+relation)
		} else if toOK && toID == object.ID && fromOK {
			parts = append(parts, "· arrow ← "+fromID+relation)
		}
	}
	if object.Type == model.Arrow {
		if spec, ok := parseArrow(object.Props); ok {
			parts = append(parts, "· "+endName(spec.from)+" → "+endName(spec.to)+relationText(spec.relation))
		}
	}
	return strings.Join(parts, " ")
}

// groupTarget is GroupMention.target: a group's members still on the board; ok false for
// anything but a group with members.
func groupTarget(id string, b BoardView) ([]string, bool) {
	objects := b.Objects()
	o, ok := objects[id]
	if !ok || o.Type != model.Group {
		return nil, false
	}
	members, ok := groupMembers(o.Props)
	if !ok {
		return nil, false
	}
	var present []string
	for _, m := range members {
		if _, ok := objects[m]; ok {
			present = append(present, m)
		}
	}
	return present, len(present) > 0
}

// groupLines is MentionContext.groupLines: each member (nested groups' members under it) with
// a cut of its content, then the arrows among them.
func groupLines(ids []string, name *string, index int, edited string, b BoardView, caller string) []string {
	objects := b.Objects()
	var group *model.Object
	for _, o := range sortedObjects(b) {
		if o.Type != model.Group {
			continue
		}
		if members, ok := groupTarget(o.ID, b); ok && equalLines(members, ids) {
			group = &o
			break
		}
	}
	head := fmt.Sprintf("[%d] group ", index)
	if name != nil {
		head += "\"" + *name + "\" "
	}
	head += fmt.Sprintf("of %d objects", len(ids))
	if group != nil {
		head += " · group " + group.ID
	}
	lines := []string{head + edited}

	type entry struct {
		object model.Object
		depth  int
	}
	var entries []entry
	seen := map[string]bool{}
	var walk func(ids []string, depth int)
	walk = func(ids []string, depth int) {
		for _, id := range ids {
			if seen[id] {
				continue
			}
			seen[id] = true
			o, ok := objects[id]
			if !ok {
				continue
			}
			entries = append(entries, entry{o, depth})
			if o.Type == model.Group {
				if members, ok := groupMembers(o.Props); ok {
					walk(members, depth+1)
				}
			}
		}
	}
	walk(ids, 0)
	order := map[string]int{}
	for i, e := range entries {
		if _, ok := order[e.object.ID]; !ok {
			order[e.object.ID] = i
		}
	}
	type arrowEntry struct {
		arrow model.Object
		spec  arrowSpec
	}
	const far = int(^uint(0) >> 1)
	position := func(e binding) int {
		if e.isObject {
			if i, ok := order[e.object]; ok {
				return i
			}
		}
		return far
	}
	var arrows []arrowEntry
	for _, o := range sortedObjects(b) {
		if o.Type != model.Arrow {
			continue
		}
		spec, ok := parseArrow(o.Props)
		if !ok {
			continue
		}
		_, member := order[o.ID]
		if member || (position(spec.from) != far && position(spec.to) != far) {
			arrows = append(arrows, arrowEntry{o, spec})
		}
	}
	sort.SliceStable(arrows, func(i, j int) bool {
		a, c := arrows[i], arrows[j]
		if position(a.spec.from) != position(c.spec.from) {
			return position(a.spec.from) < position(c.spec.from)
		}
		if position(a.spec.to) != position(c.spec.to) {
			return position(a.spec.to) < position(c.spec.to)
		}
		return a.arrow.ID < c.arrow.ID
	})
	arrowIDs := map[string]bool{}
	for _, a := range arrows {
		arrowIDs[a.arrow.ID] = true
	}
	var arrowLines []string
	for _, a := range arrows[:min(len(arrows), maxGroupArrows)] {
		arrowLines = append(arrowLines, "      "+arrowLine(a.arrow, a.spec, b))
	}
	if len(arrows) > maxGroupArrows {
		arrowLines = append(arrowLines, fmt.Sprintf("      … %d more arrows", len(arrows)-maxGroupArrows))
	}
	budget := max(maxGroupLines-len(arrowLines)-1, maxGroupLines/2)
	var listed []entry
	for _, e := range entries {
		if !arrowIDs[e.object.ID] {
			listed = append(listed, e)
		}
	}
	shown := listed[:min(len(listed), budget)]
	room := budget - len(shown)
	cutTexts := 0
	for _, e := range shown {
		indent := "    " + strings.Repeat("  ", e.depth)
		suffix, detail := memberDetail(e.object, indent, b)
		lines = append(lines, indent+"- "+describe(e.object, b, caller, arrowIDs)+suffix)
		if len(detail) <= room {
			for _, d := range detail {
				lines = append(lines, clip(d, groupLineChars))
			}
			room -= len(detail)
		} else {
			cutTexts++
		}
	}
	cutMembers := len(listed) - len(shown)
	if len(arrowLines) > 0 {
		lines = append(lines, "    arrows among them:")
		lines = append(lines, arrowLines...)
	}
	var cut []string
	if cutTexts > 0 {
		cut = append(cut, fmt.Sprintf("the text of %d member%s", cutTexts, plural(cutTexts)))
	}
	if cutMembers > 0 {
		cut = append(cut, fmt.Sprintf("%d more member%s", cutMembers, plural(cutMembers)))
	}
	if len(cut) > 0 {
		more := "easl get <id>"
		if group != nil {
			more = "easl get " + group.ID + " --as graph"
		}
		lines = append(lines, "    (left out to keep this short: "+strings.Join(cut, " and ")+"; read them with "+more+")")
	}
	return lines
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// arrowLine is MentionContext.arrowLine: `from "title" → to "title" · "label" (relation) · arrow id`.
func arrowLine(arrow model.Object, spec arrowSpec, b BoardView) string {
	end := func(e binding) string {
		name := ""
		if e.isObject {
			if o, ok := b.Objects()[e.object]; ok {
				name = Title(o)
			}
		}
		if name == "" {
			return endName(e)
		}
		return endName(e) + " \"" + clip(name, 40) + "\""
	}
	label := ""
	if spec.label != nil && *spec.label != "" {
		label = " · \"" + clip(*spec.label, 60) + "\""
	}
	return end(spec.from) + " → " + end(spec.to) + label + relationText(spec.relation) + " · arrow " + arrow.ID
}

// memberDetail is MentionContext.memberDetail: what a group mention adds to a member's line
// (suffix) and under it.
func memberDetail(object model.Object, indent string, b BoardView) (string, []string) {
	switch object.Type {
	case model.Code:
		if path, r, commit, ok := codeMentionOf(object, b.Root()); ok {
			text, failure := codeText(path, nil, commit, b)
			suffix := fmt.Sprintf(" · lines %d-%d%s", r.Start, r.End, provenance(object.ID, nil, commit, false, b))
			if text == nil {
				return suffix, []string{indent + failure}
			}
			return suffix, excerpt(text, r, groupExcerptLines, indent)
		}
		path, ok := nonEmpty(object.Props, "path")
		if !ok {
			return "", nil
		}
		var commit *string
		if c, ok := nonEmpty(object.Props, "pinnedCommit"); ok {
			commit = &c
		}
		text, failure := codeText(path, nil, commit, b)
		if text == nil {
			return "", []string{indent + failure}
		}
		return "", excerpt(text, model.LineRange{Start: 1, End: max(1, len(text))}, groupExcerptLines, indent)
	case model.Note:
		markdown, ok := str(object.Props, "markdown")
		if !ok {
			return "", nil
		}
		source := measure.NoteLines(markdown)
		titled := len(source) > 0 && PlainTextOfLine(source[0]) == Title(object)
		if titled {
			source = source[1:]
		}
		var body []string
		for _, l := range source {
			if measure.TrimWS(l) != "" {
				body = append(body, l)
			}
		}
		return "", noteLines(strings.Join(body, "\n"), object.ID, groupExcerptLines, groupExcerptLines*groupLineChars, indent+"  ")
	case model.Browser:
		u, ok := nonEmpty(object.Props, "url")
		if !ok || u == Title(object) {
			return "", nil
		}
		return " · " + u, nil
	case model.Group:
		members, _ := groupMembers(object.Props)
		return fmt.Sprintf(" of %d objects", len(members)), nil
	}
	// A shape's page elements are the app's to read.
	return "", nil
}

// codeMentionOf is what HandoffMention(object:).target(on:) gives a code tile with a range: a
// code mention of its file's lines at its pinned commit, or its ref's.
func codeMentionOf(tile model.Object, root string) (string, model.LineRange, *string, bool) {
	raw, ok := tile.Props["range"]
	if !ok {
		return "", model.LineRange{}, nil, false
	}
	r, err := DecodeLineRange(raw)
	path, isString := str(tile.Props, "path")
	if err != nil || !isString {
		return "", model.LineRange{}, nil, false
	}
	var commit *string
	if c, ok := nonEmpty(tile.Props, "pinnedCommit"); ok {
		commit = &c
	}
	if commit == nil {
		if ref := measure.RefOf(tile.Props); ref != "" {
			if live, ok := measure.LiveRoot(ref, root); ok {
				if !strings.HasPrefix(path, "/") {
					path = filepath.Join(live, path)
				}
				path = measure.RelativeToRoot(path, root)
			} else if sha, ok := str(tile.Props, "refSha"); ok {
				commit = &sha
			} else {
				commit = &ref
			}
		}
	}
	return path, r, commit, true
}
