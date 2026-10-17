package router

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/server"
	"github.com/twaldin/easl/easld/internal/swiftjson"
	"github.com/twaldin/easl/easld/internal/weblink"
)

const renderOutputTooLarge = "inline view.render response exceeds the %d-byte output limit; omit inline or use out to write the image to a file"

// render is view.render. The client always draws inline and writes no file; easld checks
// the bytes and, unless the caller asked for inline, writes them here (out, or a new file
// under the temp easl-renders directory).
func (r *Router) render(id any, p map[string]any) (any, error) {
	inline, _ := p["inline"].(bool)
	if inline {
		if _, ok := p["out"]; ok {
			return nil, invalid("inline returns the image in the reply and out writes it to a file: pass one of them")
		}
	}
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
	format, ext := renderEncoding(p)
	timeout := 8000
	if n, ok := intParam(p, "timeoutMs"); ok {
		timeout = n
	}
	params := copyParams(p)
	params["board"] = b.ID()
	params["inline"] = true
	params["format"] = format
	delete(params, "out")
	c, err := r.client("view.render", b.ID(), "view.render is drawn by the app, as the user sees the board")
	if err != nil {
		return nil, err
	}
	result, err := r.await(c, "view.render", params, millis(timeout)+clients.RenderGrace)
	if err != nil {
		return nil, err
	}
	raw, _ := result["data"].(string)
	if inline && len(raw) > server.MaxPendingOutput {
		return nil, invalid(renderOutputTooLarge, server.MaxPendingOutput)
	}
	answered, _ := result["format"].(string)
	data, w, h, err := decodeRender(c, raw, answered, format, result["width"], result["height"], inline)
	if err != nil {
		return nil, err
	}
	reply := map[string]any{"format": format, "width": float64(w), "height": float64(h)}
	for _, k := range []string{"canvasRect", "scale", "objects"} {
		if v, ok := result[k]; ok {
			reply[k] = v
		}
	}
	if inline {
		reply["data"] = ""
		envelope, err := swiftjson.Encode(okReply(id, reply), false, true)
		if err != nil {
			if nf, ok := err.(swiftjson.NonFinite); ok {
				return nil, invalid("%s", nf.Debug())
			}
			return nil, err
		}
		// Decoded base64 admits only its alphabet and CR/LF. The wire escapes slashes
		// and CR/LF, so count those without encoding another copy of the image.
		size := len(envelope) + len(raw) + strings.Count(raw, "/") + strings.Count(raw, "\r") + strings.Count(raw, "\n") + 1
		if size > server.MaxPendingOutput {
			return nil, invalid(renderOutputTooLarge, server.MaxPendingOutput)
		}
		reply["data"] = raw
		return reply, nil
	}
	path, err := r.writeRender(p, ext, data)
	if err != nil {
		return nil, err
	}
	reply["path"] = path
	return reply, nil
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

// renderEncoding is the image the client must return: out's extension, else format, else png.
// A jpeg with no out is written as .jpg, matching the app's scratch names; an out of .jpeg stays .jpeg.
func renderEncoding(p map[string]any) (format, ext string) {
	if out, ok := optStr(p, "out"); ok {
		switch strings.ToLower(filepath.Ext(out)) {
		case ".jpg":
			return "jpeg", "jpg"
		case ".jpeg":
			return "jpeg", "jpeg"
		default:
			return "png", "png"
		}
	}
	if format, ok := optStr(p, "format"); ok && format == "jpeg" {
		return "jpeg", "jpg"
	}
	return "png", "png"
}

func decodeRender(c *clients.Client, raw, answered, format string, width, height any, inline bool) ([]byte, int, int, error) {
	if raw == "" {
		return nil, 0, 0, fail(api.CodeInternal, "%s answered view.render with no image data", c.Name())
	}
	if answered != "" && answered != format {
		return nil, 0, 0, fail(api.CodeInternal, "%s answered view.render with format %s, not %s", c.Name(), answered, format)
	}
	var data []byte
	var reader io.Reader
	if inline {
		// NewDecoder accepts separately padded blocks; a reply is one base64 value.
		if first := strings.IndexByte(raw, '='); first >= 0 {
			tail := raw[first:]
			if strings.Trim(tail, "=\r\n") != "" || strings.Count(tail, "=") > 2 {
				return nil, 0, 0, fail(api.CodeInternal, "%s answered view.render with image data that is not base64", c.Name())
			}
		}
		reader = base64.NewDecoder(base64.StdEncoding, strings.NewReader(raw))
	} else {
		var err error
		data, err = base64.StdEncoding.DecodeString(raw)
		if err != nil {
			return nil, 0, 0, fail(api.CodeInternal, "%s answered view.render with image data that is not base64", c.Name())
		}
		reader = bytes.NewReader(data)
	}
	config, imageErr := decodeRenderImage(reader, format)
	if inline {
		if _, err := io.Copy(io.Discard, reader); err != nil {
			return nil, 0, 0, fail(api.CodeInternal, "%s answered view.render with image data that is not base64", c.Name())
		}
	}
	if imageErr != nil {
		return nil, 0, 0, fail(api.CodeInternal, "%s answered view.render with image data that is not a %s", c.Name(), format)
	}
	w, h := config.Width, config.Height
	if !samePixel(width, w) || !samePixel(height, h) {
		return nil, 0, 0, fail(api.CodeInternal, "%s answered view.render with a %d×%d %s, not %v×%v", c.Name(), w, h, format, width, height)
	}
	return data, w, h, nil
}

func decodeRenderImage(reader io.Reader, format string) (image.Config, error) {
	switch format {
	case "png":
		return png.DecodeConfig(reader)
	case "jpeg":
		return jpeg.DecodeConfig(reader)
	default:
		return image.Config{}, fmt.Errorf("format %s", format)
	}
}

func samePixel(v any, px int) bool {
	n, ok := v.(float64)
	return ok && px > 0 && n == float64(px) && n == math.Trunc(n)
}

func (r *Router) writeRender(p map[string]any, ext string, data []byte) (string, error) {
	out, explicit := optStr(p, "out")
	if !explicit {
		r.renderScratch++
		out = filepath.Join(os.TempDir(), "easl-renders", fmt.Sprintf("render-%d-%d.%s", time.Now().UnixMilli(), r.renderScratch, ext))
	}
	r.reg.Mu.Unlock()
	err := writeRenderFile(out, data)
	r.reg.Mu.Lock()
	if err != nil {
		return "", fail(api.CodeUnavailable, "cannot write %s: %s", out, localizedDescription(err))
	}
	return out, nil
}

func writeRenderFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	scratch := filepath.Join(os.TempDir(), "easl-renders")
	if dir == scratch {
		if err := os.MkdirAll(scratch, 0o755); err != nil {
			return err
		}
	}
	tmp, err := os.CreateTemp(dir, ".render-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr != nil || cerr != nil {
		os.Remove(tmpName)
		if werr != nil {
			return werr
		}
		return cerr
	}
	if err := os.Rename(tmpName, path); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}

// snapshot is view.snapshot: a client's picture of the board's window.
func (r *Router) snapshot(p map[string]any) (any, error) {
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	if err := imageDestination(p); err != nil {
		return nil, err
	}
	params := copyParams(p)
	params["board"] = b.ID()
	return r.forward("view.snapshot", b.ID(), params, clients.SnapshotDeadline, "view.snapshot is a picture of its window")
}

// openURL is view.open_url: an http(s) address shown in a browser tile beside the caller's
// terminal (Board.OpenLink), or the tile already showing it. Revealing the tile is the window's
// (ApiRouter.showOpenedLink), and easld has none.
func (r *Router) openURL(p map[string]any, from Conn) (any, error) {
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	raw, err := str(p, "url")
	if err != nil {
		return nil, err
	}
	url, ok := weblink.Parse(raw)
	if !ok {
		return nil, invalid("view.open_url opens http and https addresses, not %s", raw)
	}
	caller := r.callerOf(p)
	source := ""
	if _, ok := b.Objects()[caller]; ok {
		source = caller
	}
	extra, err := r.withDrawing(b, nil, from)
	if err != nil {
		return nil, err
	}
	if _, ok := extra["drawingMachine"]; !ok {
		extra = nil
	}
	o, existing := b.OpenLink(url, source, caller, extra)
	return map[string]any{"object": objectJSON(b.ReportedOne(o)), "existing": existing}, nil
}

const reloadTimeoutMs = 15_000
const diagramTimeoutMs = 60_000

func (r *Router) reload(requestID any, p map[string]any) (any, error) {
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
		return r.reloadDiagram(requestID, b, o, timeout)
	}
	return r.reloadBrowser(b, o, p, timeout)
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
	w, h, approximate, err := r.measuredSize(typ, props, width, b, r.callerOf(p), nil)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"w": w, "h": h}
	if approximate {
		result["approximate"] = true
	}
	return result, nil
}
