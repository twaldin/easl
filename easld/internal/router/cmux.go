package router

import (
	"net/url"
	"path/filepath"
	"sort"
	"strings"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/server"
)

type cmuxSocket struct {
	path string
	srv  *server.Server
}

const canvasScheme = "canvas:"

func (r *Router) ensureCmux(tile string) (string, bool) {
	if r.Owns == nil || tile == "" || strings.Contains(tile, "/") || strings.Contains(tile, "..") {
		return "", false
	}
	path := filepath.Join(r.Owns.Home, "cmux", tile+".sock")
	r.cmuxMu.Lock()
	defer r.cmuxMu.Unlock()
	if s, ok := r.cmux[tile]; ok {
		return s.path, true
	}
	srv, err := server.ListenText(path, r.cmuxHandler(tile), cmuxText)
	if err != nil {
		return "", false
	}
	if r.cmux == nil {
		r.cmux = map[string]*cmuxSocket{}
	}
	r.cmux[tile] = &cmuxSocket{path: path, srv: srv}
	return path, true
}

func (r *Router) removeCmux(tile string) {
	r.cmuxMu.Lock()
	s := r.cmux[tile]
	delete(r.cmux, tile)
	r.cmuxMu.Unlock()
	if s != nil {
		s.srv.Close()
	}
}

// CloseOwnedSockets closes every owned cmux listener. Daemon shutdown calls it.
func (r *Router) CloseOwnedSockets() {
	r.cmuxMu.Lock()
	sockets := r.cmux
	r.cmux = map[string]*cmuxSocket{}
	r.cmuxMu.Unlock()
	for _, s := range sockets {
		s.srv.Close()
	}
}

func cmuxEnv(env map[string]string, path, tile, board string) map[string]string {
	if env == nil {
		env = map[string]string{}
	}
	env["CMUX_SOCKET_PATH"] = path
	env["CMUX_SURFACE_ID"] = tile
	env["CMUX_WORKSPACE_ID"] = board
	return env
}

func cmuxText(line string, _ *server.Conn) string {
	parts := strings.SplitN(strings.TrimRight(line, "\r"), " ", 2)
	cmd := ""
	if len(parts) > 0 {
		cmd = parts[0]
	}
	if cmd != "auth" {
		return "ERROR: Unknown command '" + cmd + "'"
	}
	return "OK: No password required"
}

func (r *Router) cmuxHandler(tile string) server.Handler {
	return func(req any, _ *server.Conn) any {
		m, _ := req.(map[string]any)
		var id any
		if m != nil {
			id = m["id"]
		}
		method, _ := m["method"].(string)
		if method == "" {
			return cmuxFail(id, "invalid_params", "missing method")
		}
		params, _ := m["params"].(map[string]any)
		if raw, present := m["params"]; present && raw != nil && params == nil {
			return cmuxFail(id, "invalid_params", "params must be an object")
		}
		if params == nil {
			params = map[string]any{}
		}
		r.reg.Mu.Lock()
		defer r.reg.Mu.Unlock()
		result, err := r.cmuxDispatch(tile, method, params)
		if err != nil {
			f := asFailure(err)
			return cmuxFail(id, f.Code, f.Message)
		}
		return map[string]any{"id": id, "ok": true, "result": result}
	}
}

func cmuxFail(id any, code, message string) map[string]any {
	return map[string]any{"id": id, "ok": false, "error": map[string]any{"code": code, "message": message}}
}

func (r *Router) cmuxDispatch(tile, method string, params map[string]any) (map[string]any, error) {
	switch method {
	case "browser.open_split":
		return r.cmuxOpenSplit(tile, params)
	case "surface.list":
		return r.cmuxList(tile, params)
	case "surface.close":
		return r.cmuxClose(tile, params)
	default:
		if !pageMethods[method] {
			return nil, fail("method_not_found", "%s is not part of the cmux subset this socket serves", method)
		}
		return r.cmuxPage(tile, method, params)
	}
}

func (r *Router) cmuxBoard(tile string) (*board.Board, model.Object, error) {
	b, ok := r.reg.Containing(tile)
	if !ok {
		return nil, model.Object{}, fail("not_found", "surface %s not found", tile)
	}
	o, ok := b.Objects()[tile]
	if !ok || o.Type != model.Terminal {
		return nil, model.Object{}, fail("not_found", "surface %s not found", tile)
	}
	return b, o, nil
}

func (r *Router) cmuxOpenSplit(tile string, params map[string]any) (map[string]any, error) {
	b, terminal, err := r.cmuxBoard(tile)
	if err != nil {
		return nil, err
	}
	raw, _ := params["url"].(string)
	if raw == "" {
		raw = "about:blank"
	}
	if strings.HasPrefix(raw, canvasScheme) {
		id := strings.TrimPrefix(raw, canvasScheme)
		id = strings.TrimPrefix(id, "//")
		return r.cmuxAdopt(id, terminal.ID)
	}
	normalized, ok := normalizeBrowserURL(raw)
	if !ok {
		return nil, invalid("not a URL: %s", raw)
	}
	props, err := r.withDrawing(b, map[string]any{"url": normalized}, nil)
	if err != nil {
		return nil, err
	}
	o := b.Create(model.Browser, props, nil, "", terminal.ID)
	return map[string]any{
		"surface_id":         o.ID,
		"workspace_id":       b.ID(),
		"url":                normalized,
		"created_split":      true,
		"placement_strategy": "beside_caller",
	}, nil
}

func (r *Router) cmuxAdopt(id, anchor string) (map[string]any, error) {
	b, browser, err := r.browserSurface(id)
	if err != nil {
		return nil, err
	}
	r.adopted[browser.ID]++
	url, _ := browser.Props["url"].(string)
	if url == "" {
		url = "about:blank"
	}
	return map[string]any{
		"surface_id":         browser.ID,
		"workspace_id":       b.ID(),
		"url":                url,
		"created_split":      false,
		"placement_strategy": "existing",
	}, nil
}

func (r *Router) cmuxList(tile string, params map[string]any) (map[string]any, error) {
	b, err := r.cmuxListBoard(tile, params)
	if err != nil {
		return nil, err
	}
	var surfaces []model.Object
	for _, o := range b.Objects() {
		if o.Type == model.Terminal || o.Type == model.Browser {
			surfaces = append(surfaces, o)
		}
	}
	sort.Slice(surfaces, func(i, j int) bool {
		return surfaces[i].Z < surfaces[j].Z || (surfaces[i].Z == surfaces[j].Z && surfaces[i].ID < surfaces[j].ID)
	})
	rows := make([]any, len(surfaces))
	for i, o := range surfaces {
		row := map[string]any{"id": o.ID, "type": string(o.Type)}
		if title, ok := o.Props["pageTitle"].(string); ok && title != "" {
			row["title"] = title
		} else if title, ok := o.Props["title"].(string); ok && title != "" {
			row["title"] = title
		}
		if o.Type == model.Browser {
			if u, ok := o.Props["url"].(string); ok {
				row["url"] = u
			}
		}
		rows[i] = row
	}
	return map[string]any{"workspace_id": b.ID(), "window_id": nil, "surfaces": rows}, nil
}

func (r *Router) cmuxListBoard(tile string, params map[string]any) (*board.Board, error) {
	if id, ok := params["surface_id"].(string); ok && id != "" {
		b, ok := r.reg.Containing(id)
		if !ok {
			return nil, fail("not_found", "surface %s not found", id)
		}
		return b, nil
	}
	if id, ok := params["workspace_id"].(string); ok && id != "" {
		b, ok := r.reg.Board(id)
		if !ok {
			return nil, fail("not_found", "workspace %s not found", id)
		}
		return b, nil
	}
	b, _, err := r.cmuxBoard(tile)
	return b, err
}

func (r *Router) cmuxClose(tile string, params map[string]any) (map[string]any, error) {
	id, _ := params["surface_id"].(string)
	b, browser, err := r.browserSurface(id)
	if err != nil {
		return nil, err
	}
	if opens := r.adopted[browser.ID]; opens > 0 {
		if opens > 1 {
			r.adopted[browser.ID] = opens - 1
		} else {
			delete(r.adopted, browser.ID)
		}
	} else if err := b.Delete(browser.ID, r.browserDriver(tile, browser, b)); err != nil {
		return nil, err
	}
	return map[string]any{"surface_id": browser.ID, "workspace_id": b.ID()}, nil
}

func (r *Router) cmuxPage(tile, method string, params map[string]any) (map[string]any, error) {
	id, _ := params["surface_id"].(string)
	b, browser, err := r.browserSurface(id)
	if err != nil {
		return nil, err
	}
	machine, host, has := drawingOf(browser)
	if !has {
		return nil, noDrawingMac(browser.ID)
	}
	c := r.clients.ChooseExact(machine, b.ID(), "browser.call")
	if c == nil {
		return nil, r.drawingUnavailable(machine, host, b.ID(), "browser.call")
	}
	forwardParams := map[string]any{}
	for k, v := range params {
		if k == "surface_id" || k == "workspace_id" || k == "focus" {
			continue
		}
		forwardParams[k] = v
	}
	forward := map[string]any{"id": browser.ID, "method": method, "params": forwardParams}
	if driver := r.browserDriver(tile, browser, b); driver != "" {
		forward["caller"] = driver
	}
	result, err := r.await(c, b.ID(), "browser.call", forward, browserDeadline(method, forwardParams))
	if err != nil {
		return nil, err
	}
	result["surface_id"] = browser.ID
	return result, nil
}

func (r *Router) browserSurface(id string) (*board.Board, model.Object, error) {
	if id == "" {
		return nil, model.Object{}, invalid("surface_id is required")
	}
	b, ok := r.reg.Containing(id)
	if !ok {
		return nil, model.Object{}, fail("not_found", "surface %s not found", id)
	}
	o, ok := b.Objects()[id]
	if !ok {
		return nil, model.Object{}, fail("not_found", "surface %s not found", id)
	}
	if o.Type != model.Browser {
		return nil, model.Object{}, invalid("surface %s is a %s tile, not a browser", id, o.Type)
	}
	return b, o, nil
}

func (r *Router) browserDriver(tile string, browser model.Object, b *board.Board) string {
	if callerBoard, ok := r.reg.Containing(tile); ok && callerBoard.Objects()[tile].Type == model.Terminal {
		return tile
	}
	if browser.CreatedBy.Kind == "agent" {
		if o, ok := b.Objects()[browser.CreatedBy.Tile]; ok && o.Type == model.Terminal {
			return browser.CreatedBy.Tile
		}
	}
	return ""
}

func normalizeBrowserURL(input string) (string, bool) {
	text := strings.TrimSpace(input)
	if text == "" || strings.ContainsAny(text, " \t\r\n") {
		return "", false
	}
	if u, err := url.Parse(text); err == nil {
		scheme := strings.ToLower(u.Scheme)
		if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" || scheme == "data" {
			if scheme == "about" || scheme == "data" || u.Host != "" || scheme == "file" {
				return u.String(), true
			}
			return "", false
		}
	}
	candidate, err := url.Parse("http://" + text)
	if err != nil || candidate.Host == "" {
		return "", false
	}
	host := strings.ToLower(candidate.Hostname())
	local := host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || numericHost(host) || strings.HasPrefix(host, "[")
	if !local && !strings.Contains(host, ".") {
		if candidate.Port() == "" {
			return "", false
		}
		return candidate.String(), true
	}
	if local {
		return candidate.String(), true
	}
	https, err := url.Parse("https://" + text)
	if err != nil {
		return "", false
	}
	return https.String(), true
}

func numericHost(host string) bool {
	if host == "" {
		return false
	}
	for _, c := range host {
		if (c < '0' || c > '9') && c != '.' {
			return false
		}
	}
	return true
}
