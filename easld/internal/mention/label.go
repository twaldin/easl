package mention

import (
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
)

// BoardView is what mentions read of a board. The app's hooks (terminal labels and screens,
// command block indexes, page elements) are absent, as in Swift without a window.
type BoardView interface {
	ID() string
	Root() string
	Objects() map[string]model.Object
}

func itoa(n int) string { return strconv.Itoa(n) }

// clip is MentionContext.clip: text on one line, cut to limit Characters with an ellipsis.
func clip(text string, limit int) string {
	flat := strings.ReplaceAll(text, "\n", " ")
	if measure.CharCount(flat) > limit {
		return measure.CharPrefix(flat, limit-1) + "…"
	}
	return flat
}

func str(props map[string]any, key string) (string, bool) {
	s, ok := props[key].(string)
	return s, ok
}

func nonEmpty(props map[string]any, key string) (string, bool) {
	s, ok := props[key].(string)
	return s, ok && s != ""
}

// sortedObjects are the board's objects in id order (Swift walks its dictionary in an order of
// its own; easld walks it by id, so ties break the same way every time).
func sortedObjects(b BoardView) []model.Object {
	objects := b.Objects()
	out := make([]model.Object, 0, len(objects))
	for _, o := range objects {
		out = append(out, o)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Title is MentionContext.title(of:): how mentions name an object.
func Title(o model.Object) string {
	p := o.Props
	switch o.Type {
	case model.Terminal:
		if s, ok := nonEmpty(p, "name"); ok {
			return s
		}
		if s, ok := nonEmpty(p, "title"); ok {
			return s
		}
		if agent, ok := p["agent"].(map[string]any); ok {
			if kind, ok := agent["kind"].(string); ok {
				return kind
			}
		}
		return "terminal"
	case model.Browser:
		if s, ok := nonEmpty(p, "title"); ok {
			return s
		}
		if s, ok := nonEmpty(p, "pageTitle"); ok {
			return s
		}
		s, _ := str(p, "url")
		return s
	case model.Code:
		s, _ := str(p, "path")
		return s
	case model.Note:
		if s, ok := nonEmpty(p, "title"); ok {
			return s
		}
		if markdown, ok := str(p, "markdown"); ok {
			if lines := measure.SplitLFOmittingEmpty(markdown); len(lines) > 0 {
				return PlainTextOfLine(lines[0])
			}
		}
		return ""
	case model.HTML:
		if s, ok := str(p, "title"); ok {
			return s
		}
		return "html"
	case model.Changes:
		if s, ok := str(p, "title"); ok {
			return s
		}
		return changesName(p)
	case model.Image:
		if s, ok := str(p, "title"); ok {
			return s
		}
		if s, ok := str(p, "path"); ok {
			return s
		}
		return "image"
	case model.Diagram:
		return diagramTitle(p)
	case model.Question:
		if s, ok := str(p, "question"); ok {
			return s
		}
		return "question"
	case model.Shape:
		if s, ok := str(p, "text"); ok {
			return s
		}
		s, _ := str(p, "kind")
		return s
	case model.Arrow:
		if s, ok := str(p, "label"); ok {
			return s
		}
		s, _ := str(p, "relation")
		return s
	case model.Group:
		s, _ := str(p, "title")
		return s
	}
	return ""
}

// changesBase is ChangesSpec.baseProp.
func changesBase(p map[string]any) string {
	if s, ok := nonEmpty(p, "base"); ok {
		return s
	}
	_, head := nonEmpty(p, "head")
	_, ref := nonEmpty(p, "ref")
	if head || ref {
		return "merge-base"
	}
	return "HEAD"
}

// changesName is ChangesSpec.name: `changes vs HEAD`, `changes fm/x vs merge-base`.
func changesName(p map[string]any) string {
	what := ""
	if s, ok := nonEmpty(p, "head"); ok {
		what = s + " "
	} else if s, ok := nonEmpty(p, "ref"); ok {
		what = s + " "
	}
	return "changes " + what + "vs " + changesBase(p)
}

// diffBaseName is DiffBase(prop:).name.
func diffBaseName(prop *string) string {
	if prop == nil || *prop == "merge-base" {
		return "merge-base"
	}
	if *prop == "head" || *prop == "HEAD" {
		return "HEAD"
	}
	return "commit"
}

// diagramTitle is DiagramSpec.title.
func diagramTitle(p map[string]any) string {
	if s, ok := nonEmpty(p, "title"); ok {
		return s
	}
	var root string
	if s, ok := nonEmpty(p, "symbol"); ok {
		root = s
	} else if graph, ok := measure.DecodeDiagramGraph(p["graph"]); ok && graph.Root != nil {
		if node, ok := graph.Node(*graph.Root); ok {
			root = node.QualifiedName()
		}
	}
	if root == "" {
		if path, ok := nonEmpty(p, "path"); ok {
			line := 1
			if l, ok := measure.JSONInt(p["line"]); ok && l >= 1 {
				line = l
			}
			root = measure.PathLabel(path) + ":" + itoa(line)
		} else {
			root = "?"
		}
	}
	switch p["direction"] {
	case "outgoing":
		return "Calls from " + root
	case "both":
		return "Calls around " + root
	}
	return "Callers of " + root
}

var tagPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9-]*`)

// tagOfSelector is MentionContext.tag(ofSelector:).
func tagOfSelector(selector string) string {
	last := selector
	if !strings.Contains(selector, "[") {
		parts := strings.Split(selector, " > ")
		last = parts[len(parts)-1]
	}
	return strings.ToLower(tagPattern.FindString(last))
}

func lineSpan(r model.LineRange) string {
	if r.Start == r.End {
		return itoa(r.Start)
	}
	return itoa(r.Start) + "-" + itoa(r.End)
}

// Label is MentionContext.label(for:on:): what `tray.stage` stores as the chip's words. target
// is a validated target (ValidateTarget).
func Label(target map[string]any, b BoardView) string {
	t, err := DecodeTarget(target)
	if err != nil {
		return ""
	}
	return label(t, b)
}

func label(t Target, b BoardView) string {
	objects := b.Objects()
	switch t.Kind {
	case "code":
		location := measure.PathLabel(t.Path) + ":" + lineSpan(t.Lines)
		if t.Side != nil && *t.Side == "old" {
			location += " (old)"
		}
		if t.Symbol != nil {
			return location + " " + *t.Symbol
		}
		return location
	case "dom":
		var parts []string
		if t.DOMText != nil {
			parts = append(parts, "\""+clip(*t.DOMText, 24)+"\"")
		}
		if tag := tagOfSelector(t.Selector); tag != "" {
			parts = append(parts, tag)
		}
		if t.Point != nil {
			parts = append(parts, "pixel "+itoa(t.Point.X)+","+itoa(t.Point.Y))
		}
		if tile, ok := objects[t.Object]; ok {
			parts = append(parts, clip(Title(tile), 24))
		}
		parts = append(parts, t.Selector)
		return strings.Join(parts, " · ")
	case "terminal":
		if t.Part == "command" {
			status := ""
			if t.Command != nil {
				if s := t.Command.Status(); s != nil {
					status = " · " + *s
				}
				if t.Command.Command != nil {
					return "$ " + clip(*t.Command.Command, 28) + status
				}
			}
			return "command output" + status
		}
		shown := t.Text
		if t.Part == "rows" {
			for _, row := range measure.SplitLFOmittingEmpty(t.Text) {
				if strings.HasPrefix(row, ">") {
					shown = strings.Join(measure.Chars(row)[min(2, measure.CharCount(row)):], "")
					break
				}
			}
		}
		return "terminal \"" + clip(measure.TrimWS(shown), 28) + "\""
	case "group":
		if t.Name != nil {
			return *t.Name
		}
		return itoa(len(t.Objects)) + " objects"
	case "image":
		return measure.PathLabel(t.Path) + " at (" + itoa(t.X) + ", " + itoa(t.Y) + ")"
	case "note":
		note := t.Object
		if tile, ok := objects[t.Object]; ok {
			note = clip(Title(tile), 14)
		}
		summary := t.Item.Summary()
		if summary == "" {
			return "note " + note + " › " + t.Item.Noun()
		}
		return "note " + note + " › " + clip(summary, 24)
	case "object":
		object, ok := objects[t.Object]
		if !ok {
			return t.Object
		}
		name := Title(object)
		if object.Type == model.Code {
			name = measure.PathLabel(name)
		}
		if name == string(object.Type) {
			return name
		}
		return string(object.Type) + " " + clip(name, 28)
	case "console":
		out := t.Entry.Noun() + " \"" + clip(t.Entry.Text, 32) + "\""
		if s := t.Entry.ShortSource(); s != nil {
			out += " · " + *s
		}
		return out
	}
	return ""
}
