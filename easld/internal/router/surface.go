package router

import (
	"math"
	"regexp"
	"slices"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/surfaces"
)

var surfaceMethods = map[string]bool{"surface.stream": true, "surface.ack": true, "surface.progress": true, "surface.input": true, "surface.answer": true, "surface.stop": true}

var (
	objectIDPattern = regexp.MustCompile(`^obj_[0-9A-Za-z]+$`)
	streamIDPattern = regexp.MustCompile(`^str_[0-9A-Za-z]+$`)
)

const (
	maxSurfaceScale   = 2.0
	maxSurfaceBatch   = 128
	maxSurfaceInteger = 1 << 53
	maxSurfaceFiles   = 32
	maxSurfaceBytes   = 8 << 20
	maxSurfacePayload = 24 << 20
)

func (r *Router) surfaceCall(req any, c Conn) (any, bool) {
	m, _ := req.(map[string]any)
	method, _ := m["method"].(string)
	if !surfaceMethods[method] {
		return nil, false
	}
	id := m["id"]
	params, present := m["params"]
	if !present || params == nil {
		params = map[string]any{}
	}
	result, err := r.surface(method, params, c)
	if err != nil {
		return errorReply(id, asFailure(err)), true
	}
	return okReply(id, result), true
}

func (r *Router) surface(method string, raw any, c Conn) (any, error) {
	if err := checkParams(method, raw); err != nil {
		return nil, err
	}
	p, ok := raw.(map[string]any)
	if !ok {
		return nil, invalid("params must be an object")
	}
	if err := checkSurface(method, p); err != nil {
		return nil, err
	}
	viewer, _ := c.(surfaces.Viewer)
	if method == "surface.stream" {
		return r.openSurface(p, viewer)
	}
	return r.surfaces.Forward(viewer, method, p)
}

func (r *Router) openSurface(p map[string]any, viewer surfaces.Viewer) (any, error) {
	if viewer == nil {
		return nil, fail(api.CodeUnsupported, "this connection can't carry a browser stream")
	}
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	id := p["id"].(string)
	b, err := r.boardForObject(id)
	if err != nil {
		return nil, err
	}
	o := b.Objects()[id]
	if o.Type != model.Browser {
		return nil, fail(api.CodeNotFound, "%s is not a browser tile", id)
	}
	hears := r.reg.Hears(viewer, b.ID(), surfaces.Events)
	if !slices.Contains(hears, "surface.frame") {
		return nil, invalid("subscribe this connection to surface.frame on board %s (events.subscribe) before surface.stream", b.ID())
	}
	machine, host, ok := drawingOf(o)
	if !ok {
		return nil, noDrawingMac(id)
	}
	drawer := r.clients.ChooseExact(machine, b.ID(), "surface.stream")
	if drawer == nil {
		return nil, r.drawingUnavailable(machine, host, b.ID(), "surface.stream")
	}
	return r.surfaces.Open(&r.reg.Mu, surfaces.Key{Board: b, Tile: id, Machine: machine}, viewer, hears, drawer, p)
}

func (r *Router) surfaceEnds(k surfaces.Key, drawer *clients.Client) surfaces.Ended {
	if r.reg.Boards()[k.Board.ID()] != k.Board {
		return surfaces.BoardClosed
	}
	o, ok := k.Board.Objects()[k.Tile]
	if !ok || o.Type != model.Browser {
		return surfaces.TileClosed
	}
	if machine, _, _ := drawingOf(o); machine != k.Machine {
		return surfaces.DrawingMoved
	}
	if r.clients.ChooseExact(k.Machine, k.Board.ID(), "surface.stream") != drawer {
		return surfaces.DrawerOffline
	}
	return surfaces.Holds
}

func (r *Router) observeSurfaces(b *board.Board, e model.Event) {
	if e.Name != board.EventObjectUpdated && e.Name != board.EventObjectDeleted {
		return
	}
	if tile, _ := asMap(e.Data)["id"].(string); r.surfaces.Watches(b.ID(), tile) {
		r.surfaces.Recheck(b.ID())
	}
}

func checkSurface(method string, p map[string]any) error {
	budget := maxSurfacePayload
	if !surfaceFits(p, &budget) {
		return invalid("surface payload exceeds the 24 MiB encoded limit")
	}
	switch method {
	case "surface.stream":
		id, err := surfaceString(p, "id")
		if err != nil {
			return err
		}
		if !objectIDPattern.MatchString(id) {
			return invalid("id %s is not an object id", id)
		}
		if v, present := p["scale"]; present {
			scale, ok := v.(float64)
			if !ok {
				return invalid("scale must be a number")
			}
			if scale <= 0 || scale > maxSurfaceScale {
				return invalid("scale must be above 0 and at most 2.0")
			}
		}
		if v, present := p["format"]; present {
			format, ok := v.(string)
			if !ok {
				return invalid("format must be a string")
			}
			if format != "jpeg" && format != "png" && format != "h264" {
				return invalid("format must be jpeg, png or h264")
			}
		}
		return nil
	case "surface.ack":
		if err := surfaceStreamID(p); err != nil {
			return err
		}
		return surfaceInteger(p, "frame")
	case "surface.progress":
		if err := surfaceStreamID(p); err != nil {
			return err
		}
		if err := surfaceInteger(p, "frame"); err != nil {
			return err
		}
		if p["frame"].(float64) < 1 {
			return invalid("frame must be positive")
		}
		if err := surfaceInteger(p, "offset"); err != nil {
			return err
		}
		offset := p["offset"].(float64)
		if offset > 573440 || math.Mod(offset, 16384) != 0 {
			return invalid("offset must be aligned to 16384 bytes within the 576 KiB refresh limit")
		}
		return nil
	case "surface.input":
		events, ok := p["events"].([]any)
		if !ok {
			return invalid("events must be an array")
		}
		if len(events) < 1 || len(events) > maxSurfaceBatch {
			return invalid("events must hold 1 to %d events", maxSurfaceBatch)
		}
	case "surface.answer":
		if _, ok := p["accept"].(bool); !ok {
			return invalid("accept must be a boolean")
		}
		for _, key := range []string{"text", "user", "password"} {
			if v, present := p[key]; present {
				if _, ok := v.(string); !ok {
					return invalid("%s must be a string", key)
				}
			}
		}
		if _, present := p["choice"]; present {
			if err := surfaceInteger(p, "choice"); err != nil {
				return err
			}
		}
		if err := surfaceFiles(p); err != nil {
			return err
		}
		if err := surfaceStreamID(p); err != nil {
			return err
		}
		_, err := surfaceString(p, "dialog")
		return err
	}
	return surfaceStreamID(p)
}

func surfaceString(p map[string]any, key string) (string, error) {
	s, ok := p[key].(string)
	if !ok {
		return "", invalid("%s must be a string", key)
	}
	return s, nil
}

func surfaceStreamID(p map[string]any) error {
	id, err := surfaceString(p, "stream")
	if err != nil {
		return err
	}
	if !streamIDPattern.MatchString(id) {
		return invalid("stream %s is not a stream id", id)
	}
	return nil
}

func surfaceInteger(p map[string]any, key string) error {
	n, ok := p[key].(float64)
	if !ok || n != math.Round(n) || n < 0 || n > maxSurfaceInteger {
		return invalid("%s must be an integer from 0 to %d", key, maxSurfaceInteger)
	}
	return nil
}

func surfaceFiles(p map[string]any) error {
	raw, present := p["files"]
	if !present {
		return nil
	}
	files, ok := raw.([]any)
	if !ok || len(files) == 0 || len(files) > maxSurfaceFiles {
		return invalid("files must be an array of 1 to %d files", maxSurfaceFiles)
	}
	total := 0
	for _, raw := range files {
		file, ok := raw.(map[string]any)
		if !ok {
			return invalid("a file is {name, type, modified?, data}")
		}
		for key := range file {
			if key != "name" && key != "type" && key != "modified" && key != "data" {
				return invalid("a file is {name, type, modified?, data}")
			}
		}
		name, nameOK := file["name"].(string)
		kind, typeOK := file["type"].(string)
		data, dataOK := file["data"].(string)
		if !nameOK || !typeOK || !dataOK {
			return invalid("a file is {name, type, modified?, data}")
		}
		if len(name) < 1 || len(name) > 1024 || len(kind) > 256 {
			return invalid("file name must contain 1 to 1024 UTF-8 bytes and type at most 256")
		}
		if raw, present := file["modified"]; present {
			modified, ok := raw.(float64)
			if !ok {
				return invalid("file modified must be a number")
			}
			if math.IsNaN(modified) || math.IsInf(modified, 0) || modified < 0 {
				return invalid("file modified must be a finite nonnegative timestamp")
			}
		}
		if len(data) > ((maxSurfaceBytes+2)/3)*4 || len(data)%4 != 0 {
			return invalid("file data must be bounded base64")
		}
		padding := 0
		for i := range len(data) {
			b := data[i]
			if b == '=' {
				padding++
				if padding > 2 {
					return invalid("file data must be base64")
				}
			} else if padding != 0 || !(b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z' || b >= '0' && b <= '9' || b == '+' || b == '/') {
				return invalid("file data must be base64")
			}
		}
		total += len(data)/4*3 - padding
		if total > maxSurfaceBytes {
			return invalid("files exceed the 8 MiB upload limit")
		}
	}
	return nil
}

func surfaceFits(value any, remaining *int) bool {
	switch v := value.(type) {
	case string:
		*remaining -= 2 + len(v)
		if *remaining < 0 {
			return false
		}
		for i := range len(v) {
			switch {
			case v[i] < 0x20:
				*remaining -= 5
			case v[i] == '"' || v[i] == '\\' || v[i] == '/':
				*remaining -= 1
			}
			if *remaining < 0 {
				return false
			}
		}
	case map[string]any:
		*remaining -= 2 + 2*len(v)
		for key, item := range v {
			if !surfaceFits(key, remaining) || !surfaceFits(item, remaining) {
				return false
			}
		}
	case []any:
		*remaining -= 2 + len(v)
		for _, item := range v {
			if !surfaceFits(item, remaining) {
				return false
			}
		}
	default:
		*remaining -= 32
	}
	return *remaining >= 0
}
