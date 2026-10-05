package router

import (
	"path/filepath"
	"strings"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
)

// render is view.render: its params are checked as the app checks them; drawing needs the app.
func (r *Router) render(p map[string]any) (any, error) {
	var b *board.Board
	var ids []string
	var err error
	_, hasBoard := p["board"]
	switch target := p["target"].(type) {
	case string:
		if hasBoard {
			b, err = r.boardOf(p)
		} else {
			b, err = r.boardForObject(target)
		}
		ids = []string{target}
	case []any:
		ids = strings_(target)
		if len(ids) == 0 || len(ids) != len(target) {
			return nil, invalid("target list must be object ids")
		}
		if hasBoard {
			b, err = r.boardOf(p)
		} else {
			b, err = r.boardForObject(ids[0])
		}
	case map[string]any:
		if b, err = r.boardOf(p); err != nil {
			return nil, err
		}
		rect, ok := decodeFrame(target)
		if !ok {
			return nil, invalid("%s", frameDecodeError(target))
		}
		if rect.W <= 0 || rect.H <= 0 {
			return nil, invalid("target rect must have a positive size")
		}
	default:
		return nil, invalid("target must be an object id, a list of ids, or a rect {x, y, w, h}")
	}
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		if _, ok := b.Objects()[id]; !ok {
			return nil, fail(api.CodeNotFound, "object %s is not on board %s", id, b.ID())
		}
	}
	scale := 1.0
	if s, ok := num(p, "scale"); ok {
		scale = s
	}
	if scale < 0.1 || scale > 4 {
		return nil, invalid("scale must be between 0.1 and 4")
	}
	if list, ok := p["exclude"].([]any); ok {
		for _, entry := range list {
			s, isString := entry.(string)
			if _, isType := model.ParseObjectType(s); isString && isType {
				continue
			}
			if _, onBoard := b.Objects()[s]; isString && onBoard {
				continue
			}
			named := describe(entry)
			if isString {
				named = "\"" + s + "\""
			}
			return nil, invalid("exclude takes object types or ids of objects on this board, not %s", named)
		}
	}
	if err := imageDestination(p); err != nil {
		return nil, err
	}
	return nil, fail(api.CodeUnsupported, "rendering needs the app UI")
}

func decodeFrame(m map[string]any) (model.Frame, bool) {
	var f model.Frame
	for _, k := range []string{"x", "y", "w", "h"} {
		if _, ok := m[k].(float64); !ok {
			return f, false
		}
	}
	return model.FrameFromJSON(m), true
}

// frameDecodeError is the DecodingError text a malformed rect gives.
func frameDecodeError(m map[string]any) string {
	for _, k := range []string{"x", "y", "w", "h"} {
		v, present := m[k]
		if !present || v == nil {
			return "DecodingError.keyNotFound: Key '" + k + "' not found in keyed decoding container. Debug description: No value associated with key CodingKeys(stringValue: \"" + k + "\", intValue: nil) (\"" + k + "\")."
		}
		if _, ok := v.(float64); !ok {
			return "DecodingError.typeMismatch: Expected to decode Double but found " + swiftTypeName(v) + " instead. Path: " + k + ". Debug description: Expected to decode Double but found " + swiftTypeName(v) + " instead."
		}
	}
	return ""
}

func swiftTypeName(v any) string {
	switch v.(type) {
	case string:
		return "a string"
	case bool:
		return "bool"
	case []any:
		return "an array"
	case map[string]any:
		return "a dictionary"
	}
	return "number"
}

// imageDestination checks `out` and `format` as the app does before drawing.
func imageDestination(p map[string]any) error {
	if out, ok := optStr(p, "out"); ok {
		if !strings.HasPrefix(out, "/") {
			return invalid("out must be an absolute path (clients resolve relative paths)")
		}
		switch strings.ToLower(strings.TrimPrefix(filepath.Ext(out), ".")) {
		case "png", "jpg", "jpeg":
		default:
			return invalid("out must end in .png, .jpg, or .jpeg")
		}
		return nil
	}
	if format, ok := optStr(p, "format"); ok && format != "png" && format != "jpeg" {
		return invalid("format must be png or jpeg")
	}
	return nil
}

// snapshot is view.snapshot: it needs the board's window.
func (r *Router) snapshot(p map[string]any) (any, error) {
	if _, err := r.boardOf(p); err != nil {
		return nil, err
	}
	if err := imageDestination(p); err != nil {
		return nil, err
	}
	return nil, fail(api.CodeUnsupported, "snapshots need the app UI")
}

const reloadTimeoutMs = 15_000
const diagramTimeoutMs = 60_000

// reload is object.reload: a browser's page and a diagram's language-server graph both need the
// app.
func (r *Router) reload(p map[string]any) (any, error) {
	id, err := str(p, "id")
	if err != nil {
		return nil, err
	}
	b, err := r.boardForObject(id)
	if err != nil {
		return nil, err
	}
	o, ok := b.Objects()[id]
	if !ok {
		return nil, fail(api.CodeNotFound, "no object %s", id)
	}
	if o.Type != model.Browser && o.Type != model.Diagram {
		return nil, invalid("%s is a %s tile: only browser and diagram tiles reload (code, note and changes tiles follow their files by themselves; an HTML tile re-renders when its props change)", id, o.Type)
	}
	timeout := reloadTimeoutMs
	if o.Type == model.Diagram {
		timeout = diagramTimeoutMs
	}
	if n, ok := intParam(p, "timeoutMs"); ok {
		timeout = n
	}
	if timeout < 0 {
		return nil, invalid("timeoutMs must be 0 or more")
	}
	if o.Type == model.Diagram {
		return nil, fail(api.CodeUnsupported, "computing diagrams needs the app")
	}
	return nil, fail(api.CodeUnsupported, "reloading pages needs the app UI")
}

// measure is object.measure: the intrinsic frame size for a type and props.
func (r *Router) measure(p map[string]any) (any, error) {
	typeName, err := str(p, "type")
	if err != nil {
		return nil, err
	}
	typ, ok := model.ParseObjectType(typeName)
	if !ok {
		return nil, invalid("unknown object type")
	}
	if err := checkProps(p); err != nil {
		return nil, err
	}
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	props := asMap(p["props"])
	if props == nil {
		props = map[string]any{}
	}
	props = b.InCallersCheckout(props, typ, r.callerOf(p), nil)
	var width *float64
	if w, ok := num(p, "width"); ok {
		width = &w
	}
	w, h, err := measure.Size(typ, props, width, pathRoot(b, typ, props))
	if err != nil {
		return nil, err
	}
	return map[string]any{"w": w, "h": h}, nil
}
