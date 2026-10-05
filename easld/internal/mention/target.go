// Package mention ports what tray mentions need beyond board bookkeeping: decoding a
// MentionTarget as Swift's Codable does (and its error texts), the label `tray.stage` stores
// (MentionContext.label), whether an update edits a mention (MentionTarget.isEdited), and
// `tray.drain`'s resolution of each mention into the `<canvas-mentions>` context block
// (MentionContext.resolve/render), with the note markdown, code excerpt and drawing graph
// reading those need.
package mention

import (
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
)

// Point is ElementPoint: where a Hyper-click fell on a picture element, in its own pixels.
type Point struct{ X, Y, W, H int }

// Target is a decoded MentionTarget.
type Target struct {
	// Kind: object, code, dom, terminal, group, image, note, console.
	Kind   string
	Object string
	// code
	Path                       string
	Lines                      model.LineRange
	Side, Symbol, Commit, Diff *string
	// dom (Text also a terminal's), console (URL)
	URL      string
	Selector string
	DOMText  *string
	Point    *Point
	// terminal
	Text    string
	Part    string // selection, rows, command
	Command *TerminalCommand
	// group
	Objects []string
	Name    *string
	// image
	X, Y int
	// note
	Item NoteItem
	// console
	Entry PageLogEntry
}

// ObjectIDs are the objects the mention depends on.
func (t Target) ObjectIDs() []string {
	if t.Kind == "group" {
		return t.Objects
	}
	return []string{t.Object}
}

// DecodeTarget decodes a MentionTarget as `JSONValue.decode(MentionTarget.self)` does; the error
// text is Swift's String(describing: DecodingError).
func DecodeTarget(v any) (Target, error) {
	var t Target
	c, err := measure.DecodeKeyed(v, nil)
	if err != nil {
		return t, err
	}
	if t.Kind, err = c.String("kind"); err != nil {
		return t, err
	}
	switch t.Kind {
	case "code":
		if t.Object, err = c.String("object"); err != nil {
			return t, err
		}
		if t.Path, err = c.String("path"); err != nil {
			return t, err
		}
		if t.Lines.Start, t.Lines.End, err = c.LineRange("lines"); err != nil {
			return t, err
		}
		for _, field := range []struct {
			key  string
			into **string
		}{{"side", &t.Side}, {"symbol", &t.Symbol}, {"commit", &t.Commit}, {"diff", &t.Diff}} {
			if *field.into, err = c.StringIfPresent(field.key); err != nil {
				return t, err
			}
		}
	case "dom":
		if t.Object, err = c.String("object"); err != nil {
			return t, err
		}
		if t.URL, err = c.String("url"); err != nil {
			return t, err
		}
		if t.Selector, err = c.String("selector"); err != nil {
			return t, err
		}
		if t.DOMText, err = c.StringIfPresent("text"); err != nil {
			return t, err
		}
		p, ok, err := c.NestedIfPresent("point")
		if err != nil {
			return t, err
		}
		if ok {
			var point Point
			for _, field := range []struct {
				key  string
				into *int
			}{{"x", &point.X}, {"y", &point.Y}, {"w", &point.W}, {"h", &point.H}} {
				if *field.into, err = p.Int(field.key); err != nil {
					return t, err
				}
			}
			t.Point = &point
		}
	case "terminal":
		if t.Object, err = c.String("object"); err != nil {
			return t, err
		}
		if t.Text, err = c.String("text"); err != nil {
			return t, err
		}
		part, err := c.EnumIfPresent("part", "TerminalPart", "selection", "rows", "command")
		if err != nil {
			return t, err
		}
		t.Part = "selection"
		if part != nil {
			t.Part = *part
		}
		cmd, ok, err := c.NestedIfPresent("command")
		if err != nil {
			return t, err
		}
		if ok {
			var command TerminalCommand
			if command.Command, err = cmd.StringIfPresent("command"); err != nil {
				return t, err
			}
			if command.Exit, err = cmd.IntIfPresent("exit"); err != nil {
				return t, err
			}
			if command.DurationMs, err = cmd.IntIfPresent("durationMs"); err != nil {
				return t, err
			}
			t.Command = &command
		}
	case "group":
		if t.Objects, err = c.Strings("objects"); err != nil {
			return t, err
		}
		if t.Name, err = c.StringIfPresent("name"); err != nil {
			return t, err
		}
	case "image":
		if t.Object, err = c.String("object"); err != nil {
			return t, err
		}
		if t.Path, err = c.String("path"); err != nil {
			return t, err
		}
		if t.X, err = c.Int("x"); err != nil {
			return t, err
		}
		if t.Y, err = c.Int("y"); err != nil {
			return t, err
		}
	case "note":
		if t.Object, err = c.String("object"); err != nil {
			return t, err
		}
		if t.Item.Kind, err = c.Enum("block", "Kind", noteItemKinds...); err != nil {
			return t, err
		}
		if t.Item.Headings, err = c.Strings("headings"); err != nil {
			return t, err
		}
		if t.Item.Lines.Start, t.Item.Lines.End, err = c.LineRange("lines"); err != nil {
			return t, err
		}
		if t.Item.Text, err = c.String("text"); err != nil {
			return t, err
		}
	case "console":
		if t.Object, err = c.String("object"); err != nil {
			return t, err
		}
		if t.URL, err = c.String("url"); err != nil {
			return t, err
		}
		e, err := c.Nested("entry")
		if err != nil {
			return t, err
		}
		if t.Entry, err = decodeEntry(e); err != nil {
			return t, err
		}
	case "object":
		if t.Object, err = c.String("object"); err != nil {
			return t, err
		}
	default:
		return t, measure.DataCorrupted(measure.CodingPath{"kind"}, "unknown mention kind "+t.Kind)
	}
	return t, nil
}

func decodeEntry(e measure.Keyed) (PageLogEntry, error) {
	var entry PageLogEntry
	var err error
	if entry.Seq, err = e.Int("seq"); err != nil {
		return entry, err
	}
	if entry.Time, err = e.String("time"); err != nil {
		return entry, err
	}
	if entry.Kind, err = e.Enum("kind", "Kind", "console", "exception", "request"); err != nil {
		return entry, err
	}
	if entry.Level, err = e.String("level"); err != nil {
		return entry, err
	}
	if entry.Text, err = e.String("text"); err != nil {
		return entry, err
	}
	for _, field := range []struct {
		key  string
		into **string
	}{{"source", &entry.Source}, {"stack", &entry.Stack}, {"method", &entry.Method}, {"url", &entry.URL}} {
		if *field.into, err = e.StringIfPresent(field.key); err != nil {
			return entry, err
		}
	}
	if entry.Status, err = e.IntIfPresent("status"); err != nil {
		return entry, err
	}
	if entry.Resource, err = e.StringIfPresent("resource"); err != nil {
		return entry, err
	}
	return entry, nil
}

func num(n int) float64 { return float64(n) }

func putString(m map[string]any, key string, s *string) {
	if s != nil {
		m[key] = *s
	}
}

// JSON is the target as MentionTarget.encode writes it (the API's and the board file's form).
func (t Target) JSON() map[string]any {
	m := map[string]any{"kind": t.Kind}
	switch t.Kind {
	case "object":
		m["object"] = t.Object
	case "code":
		m["object"], m["path"], m["lines"] = t.Object, t.Path, t.Lines.JSON()
		putString(m, "side", t.Side)
		putString(m, "symbol", t.Symbol)
		putString(m, "commit", t.Commit)
		putString(m, "diff", t.Diff)
	case "dom":
		m["object"], m["url"], m["selector"] = t.Object, t.URL, t.Selector
		putString(m, "text", t.DOMText)
		if t.Point != nil {
			m["point"] = map[string]any{"x": num(t.Point.X), "y": num(t.Point.Y), "w": num(t.Point.W), "h": num(t.Point.H)}
		}
	case "terminal":
		m["object"], m["text"] = t.Object, t.Text
		if t.Part != "selection" {
			m["part"] = t.Part
		}
		if t.Command != nil {
			cmd := map[string]any{}
			putString(cmd, "command", t.Command.Command)
			if t.Command.Exit != nil {
				cmd["exit"] = num(*t.Command.Exit)
			}
			if t.Command.DurationMs != nil {
				cmd["durationMs"] = num(*t.Command.DurationMs)
			}
			m["command"] = cmd
		}
	case "group":
		objects := make([]any, len(t.Objects))
		for i, o := range t.Objects {
			objects[i] = o
		}
		m["objects"] = objects
		putString(m, "name", t.Name)
	case "image":
		m["object"], m["path"], m["x"], m["y"] = t.Object, t.Path, num(t.X), num(t.Y)
	case "note":
		headings := make([]any, len(t.Item.Headings))
		for i, h := range t.Item.Headings {
			headings[i] = h
		}
		m["object"], m["block"], m["headings"], m["lines"], m["text"] = t.Object, t.Item.Kind, headings, t.Item.Lines.JSON(), t.Item.Text
	case "console":
		e := t.Entry
		entry := map[string]any{"seq": num(e.Seq), "time": e.Time, "kind": e.Kind, "level": e.Level, "text": e.Text}
		putString(entry, "source", e.Source)
		putString(entry, "stack", e.Stack)
		putString(entry, "method", e.Method)
		putString(entry, "url", e.URL)
		if e.Status != nil {
			entry["status"] = num(*e.Status)
		}
		putString(entry, "resource", e.Resource)
		m["object"], m["url"], m["entry"] = t.Object, t.URL, entry
	}
	return m
}

// ValidateTarget decodes a `tray.stage` target as Swift does and returns it re-encoded as
// MentionTarget.encode writes it (unknown keys dropped, a terminal's `part` omitted when it is
// the selection). Two targets are the same mention when their encodings are model.Equal.
func ValidateTarget(v any) (map[string]any, error) {
	t, err := DecodeTarget(v)
	if err != nil {
		return nil, err
	}
	return t.JSON(), nil
}

// DecodeLineRange decodes a LineRange at path (keys; "" for the top level) with Swift's error text.
func DecodeLineRange(v any, path ...string) (model.LineRange, error) {
	k, err := measure.DecodeKeyed(v, measure.CodingPath(path))
	if err != nil {
		return model.LineRange{}, err
	}
	start, end, err := measure.DecodeLineRangeIn(k)
	return model.LineRange{Start: start, End: end}, err
}

// DecodeLineRanges decodes a top-level [LineRange] with Swift's error text.
func DecodeLineRanges(v any) ([]model.LineRange, error) {
	items, err := measure.DecodeArray(v, nil)
	if err != nil {
		return nil, err
	}
	out := make([]model.LineRange, 0, len(items))
	for i, item := range items {
		r, err := DecodeLineRange(item, "["+itoa(i)+"]")
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, nil
}
