package router

import (
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
)

// attach is client.attach: the connection becomes a client serving `serves` for `boards`.
func (r *Router) attach(p map[string]any, c Conn) (any, error) {
	version, ok := p["version"].(float64)
	if !ok || version != float64(int(version)) {
		return nil, invalid("version must be the schema version the client was built from, an integer")
	}
	schema, err := str(p, "schema")
	if err != nil {
		return nil, err
	}
	app, _ := optStr(p, "app")
	host, _ := optStr(p, "host")
	serves, ok := p["serves"].([]any)
	if !ok {
		return nil, invalid("serves must be a list of method names")
	}
	a := clients.Attachment{Version: int(version), Schema: schema, App: app, Host: host}
	for _, m := range serves {
		if s, ok := m.(string); ok {
			a.Serves = append(a.Serves, s)
		}
	}
	if list, present := p["boards"]; present && list != nil {
		ids, ok := list.([]any)
		if !ok {
			return nil, invalid("boards must be a list of board ids")
		}
		for _, v := range ids {
			id, _ := v.(string)
			b, ok := r.reg.Board(id)
			if !ok {
				return nil, fail(api.CodeNotFound, "board %s is not open on this server: board.open it first", describeID(v))
			}
			a.Boards = append(a.Boards, b.ID())
		}
	}
	if focused, ok := optStr(p, "focused"); ok {
		a.Focused = focused
		if b, ok := r.reg.Board(focused); ok {
			a.Focused = b.ID()
		}
	}
	client, err := r.clients.Attach(c, a)
	if err != nil {
		return nil, err
	}
	return map[string]any{"client": client.ID, "version": float64(api.SchemaVersion), "schema": api.SchemaHash}, nil
}

func describeID(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return describe(v)
}

var textKinds = []string{"note", "text", "label", "arrowLabel", "caption"}

// textMeasure is text.measure: sizes from the client that serves it, else the glyph table's.
func (r *Router) textMeasure(p map[string]any) (any, error) {
	list, ok := p["items"].([]any)
	if !ok {
		return nil, invalid("items must be a list of {kind, text, width?, textSize?, root?}")
	}
	items := make([]measure.TextItem, len(list))
	for i, v := range list {
		m, ok := v.(map[string]any)
		if !ok {
			return nil, invalid("items[%d] must be {kind, text, width?, textSize?, root?}", i)
		}
		for k := range m {
			if !slices.Contains([]string{"kind", "text", "width", "textSize", "root"}, k) {
				return nil, invalid("items[%d]: unknown field %s; an item takes kind, text, width, textSize, root", i, k)
			}
		}
		kind, _ := m["kind"].(string)
		if !slices.Contains(textKinds, kind) {
			return nil, invalid("items[%d]: kind must be one of %s", i, strings.Join(textKinds, ", "))
		}
		text, ok := m["text"].(string)
		if !ok {
			return nil, invalid("items[%d] needs its text", i)
		}
		item := measure.TextItem{Kind: kind, Text: text}
		if v, present := m["width"]; present {
			w, ok := v.(float64)
			if !ok || w <= 0 {
				return nil, invalid("items[%d]: width must be a positive number", i)
			}
			item.Width = new(w)
		}
		if v, present := m["textSize"]; present {
			if _, ok := v.(float64); !ok {
				return nil, invalid("items[%d]: textSize must be a number", i)
			}
			item.TextSize = measure.ShapeTextSize(map[string]any{"textSize": v})
		}
		if v, present := m["root"]; present {
			root, ok := v.(string)
			if !ok {
				return nil, invalid("items[%d]: root must be a path", i)
			}
			item.Root = measure.ExpandTilde(root)
		} else if kind == "note" {
			b, err := r.boardOf(p)
			if err != nil {
				return nil, err
			}
			item.Root = b.Root()
		}
		items[i] = item
	}
	sizes := r.clients.MeasureText(items)
	out := make([]any, len(sizes))
	approximate := false
	for i, size := range sizes {
		out[i] = clients.SizeJSON(items[i], size)
		approximate = approximate || size.Approximate
	}
	result := map[string]any{"sizes": out}
	if approximate {
		result["approximate"] = true
	}
	return result, nil
}

// noClient is the `unavailable` a delegated call gets when no client shows its board, saying
// what the call needed.
func noClient(board, need string) error {
	return fail(api.CodeUnavailable, "no app shows board %s: %s", board, need)
}

// client is the client a delegated method on board goes to (clients.Registry.Choose).
func (r *Router) client(method, board, need string) (*clients.Client, error) {
	if c := r.clients.Choose(method, board); c != nil {
		return c, nil
	}
	return nil, noClient(board, need)
}

// await forwards a checked call to c and waits for its answer with the registry's lock released,
// so the boards stay usable (by c too) while c works. Whatever the caller read of the boards
// before may have changed when it returns.
func (r *Router) await(c *clients.Client, method string, params map[string]any, deadline time.Duration) (map[string]any, error) {
	r.reg.Mu.Unlock()
	result, failure := r.clients.Call(c, method, params, deadline)
	r.reg.Mu.Lock()
	if failure != nil {
		return nil, failure
	}
	m, ok := result.(map[string]any)
	if !ok {
		return nil, fail(api.CodeInternal, "%s answered %s with %s, not an object", c.Name(), method, describe(result))
	}
	return m, nil
}

// forward is client then await: the whole of a delegated call after easld's own checks.
func (r *Router) forward(method, board string, params map[string]any, deadline time.Duration, need string) (any, error) {
	c, err := r.client(method, board, need)
	if err != nil {
		return nil, err
	}
	result, err := r.await(c, method, params, deadline)
	if err != nil {
		return nil, err
	}
	return result, nil
}

func millis(n int) time.Duration { return time.Duration(max(0, n)) * time.Millisecond }

// promptMention is HandoffMention(json:).target(on:): an agent.prompt mention as the target it
// stages, what a Hyper-click on the same place stages.
func promptMention(v any, b *board.Board) (map[string]any, error) {
	fields, ok := v.(map[string]any)
	if !ok {
		return nil, invalid("a mention is {object, lines?, point?}, not %s", describe(v))
	}
	var unknown []string
	for k := range fields {
		if k != "object" && k != "lines" && k != "point" {
			unknown = append(unknown, k)
		}
	}
	if len(unknown) > 0 {
		slices.Sort(unknown)
		return nil, invalid("unknown mention field %s; a mention takes object, lines ({start, end}), point ({x, y})", strings.Join(unknown, ", "))
	}
	object, ok := fields["object"].(string)
	if !ok {
		return nil, invalid("a mention needs an object id")
	}
	var lines map[string]any
	if value, present := fields["lines"]; present {
		start, okS := board.TruncInt(asMap(value)["start"])
		end, okE := board.TruncInt(asMap(value)["end"])
		if !okS || !okE || start < 1 || end < start {
			return nil, invalid("mention lines are {start, end}, 1-based, end ≥ start")
		}
		lines = map[string]any{"start": float64(start), "end": float64(end)}
	}
	var point map[string]any
	if value, present := fields["point"]; present {
		x, okX := board.TruncInt(asMap(value)["x"])
		y, okY := board.TruncInt(asMap(value)["y"])
		if !okX || !okY || x < 0 || y < 0 {
			return nil, invalid("a mention point is {x, y}: pixels from the image's top-left")
		}
		point = map[string]any{"x": float64(x), "y": float64(y)}
	}
	tile, ok := b.Objects()[object]
	if !ok {
		return nil, board.NotFound("object %s is not on board %s, the target terminal's board", object, b.ID())
	}
	whole := map[string]any{"kind": "object", "object": object}
	switch {
	case tile.Type == model.Code && point == nil:
		rng := lines
		if rng == nil {
			if r, ok := asMap(tile.Props["range"])["start"]; ok && r != nil {
				start, okS := board.TruncInt(asMap(tile.Props["range"])["start"])
				end, okE := board.TruncInt(asMap(tile.Props["range"])["end"])
				if okS && okE {
					rng = map[string]any{"start": float64(start), "end": float64(end)}
				}
			}
		}
		path, ok := tile.Props["path"].(string)
		if !ok || rng == nil {
			return whole, nil
		}
		target := map[string]any{"kind": "code", "object": object, "lines": rng}
		commit, _ := tile.Props["pinnedCommit"].(string)
		// A branch-anchored tile: the file in the worktree that has the ref checked out, else
		// the SHA the tile last resolved it to.
		if ref := measure.RefOf(tile.Props); commit == "" && ref != "" {
			if live, ok := measure.LiveRoot(ref, b.Root()); ok {
				if !strings.HasPrefix(path, "/") {
					path = filepath.Join(live, path)
				}
				path = measure.RelativeToRoot(path, b.Root())
			} else if sha, ok := tile.Props["refSha"].(string); ok {
				commit = sha
			} else {
				commit = ref
			}
		}
		target["path"] = path
		if commit != "" {
			target["commit"] = commit
		}
		if symbol, ok := tile.Props["symbol"].(string); ok && lines == nil {
			target["symbol"] = symbol
		}
		return target, nil
	case tile.Type == model.Image && lines == nil:
		path, ok := tile.Props["path"].(string)
		if point == nil || !ok {
			return whole, nil
		}
		return map[string]any{"kind": "image", "object": object, "path": path, "x": point["x"], "y": point["y"]}, nil
	}
	if lines != nil || point != nil {
		return nil, invalid("lines take a code tile and point an image tile; mention %s %s by its id alone", tile.Type, object)
	}
	return whole, nil
}
