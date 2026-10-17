package router

import (
	"math"
	"regexp"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/clients"
	"github.com/twaldin/easl/easld/internal/model"
)

var idPattern = regexp.MustCompile(`^[a-z]+_[0-9A-Za-z]+$`)

var pageMethods = map[string]bool{
	"browser.navigate": true, "browser.back": true, "browser.forward": true, "browser.reload": true,
	"browser.url.get": true, "browser.eval": true, "browser.snapshot": true, "browser.screenshot": true,
	"browser.click": true, "browser.dblclick": true, "browser.hover": true, "browser.focus": true,
	"browser.check": true, "browser.uncheck": true, "browser.scroll_into_view": true,
	"browser.type": true, "browser.fill": true, "browser.press": true, "browser.scroll": true,
	"browser.wait": true,
}

const (
	defaultBrowserWaitMs = 30_000
	maxBrowserWaitMs     = 600_000
)

func (r *Router) announceClients(boards []string) {
	if len(boards) == 0 {
		return
	}
	listed := r.clients.List()
	for _, id := range boards {
		b, ok := r.reg.Board(id)
		if !ok {
			continue
		}
		b.Announce("client.changed", map[string]any{"clients": clientEntries(listed, b.ID())})
	}
}

func (r *Router) clientsChanged(boards []string) {
	r.reg.Mu.Lock()
	defer r.reg.Mu.Unlock()
	r.announceClients(boards)
}

func clientEntries(listed []clients.ListedClient, board string) []any {
	out := []any{}
	for _, c := range listed {
		serves := false
		for _, id := range c.Boards {
			if id == board {
				serves = true
				break
			}
		}
		if !serves {
			continue
		}
		entry := map[string]any{"id": c.ID, "boards": c.Boards, "serves": c.Serves}
		if c.Identity != "" {
			entry["identity"] = c.Identity
		}
		if c.App != "" {
			entry["app"] = c.App
		}
		if c.Host != "" {
			entry["host"] = c.Host
		}
		if c.Focused != "" {
			entry["focused"] = c.Focused
		}
		out = append(out, entry)
	}
	return out
}

func (r *Router) fillMissingOwners(boards []string) {
	for _, id := range boards {
		b, ok := r.reg.Board(id)
		if !ok {
			continue
		}
		owner, ok := r.clients.Earliest(b.ID())
		if !ok {
			continue
		}
		machine := map[string]any{"id": owner.Identity, "host": owner.Host}
		for _, o := range b.Objects() {
			if o.Type != model.Browser {
				continue
			}
			if _, has := o.Props["drawingMachine"]; has {
				continue
			}
			_ = b.WriteQuiet(o.ID, map[string]any{"drawingMachine": machine})
		}
	}
}

func (r *Router) drawingOwner(b *board.Board, from Conn) (clients.Owner, bool) {
	if from != nil {
		if owner, ok := r.clients.Eligible(from, b.ID()); ok {
			return owner, true
		}
	}
	return r.clients.Earliest(b.ID())
}

func (r *Router) withDrawing(b *board.Board, props map[string]any, from Conn) (map[string]any, error) {
	if props == nil {
		props = map[string]any{}
	}
	if err := validateDrawing(props["drawingMachine"]); err != nil {
		return nil, err
	}
	if _, ok := props["drawingMachine"].(map[string]any); ok {
		return props, nil
	}
	owner, ok := r.drawingOwner(b, from)
	if !ok {
		return props, nil
	}
	out := copyParams(props)
	out["drawingMachine"] = map[string]any{"id": owner.Identity, "host": owner.Host}
	return out, nil
}

func validateDrawing(v any) error {
	if v == nil {
		return nil
	}
	m, ok := v.(map[string]any)
	if !ok {
		return invalid("drawingMachine must be {id, host}")
	}
	for k := range m {
		if k != "id" && k != "host" {
			return invalid("drawingMachine must be {id, host}")
		}
	}
	id, idOK := m["id"].(string)
	_, hostOK := m["host"].(string)
	if !idOK || !hostOK || !idPattern.MatchString(id) {
		return invalid("drawingMachine must be {id, host}, id an Id")
	}
	return nil
}

func drawingOf(o model.Object) (id, host string, ok bool) {
	m, isMap := o.Props["drawingMachine"].(map[string]any)
	if !isMap {
		return "", "", false
	}
	id, _ = m["id"].(string)
	host, _ = m["host"].(string)
	if id == "" {
		return "", "", false
	}
	return id, host, true
}

func machineLabel(host, id string) string {
	if host != "" {
		return host
	}
	return id
}

func noDrawingMac(id string) error {
	return fail(api.CodeUnavailable, "%s has no drawing Mac yet", id)
}

func (r *Router) drawingUnavailable(id, host, board, method string) error {
	label := machineLabel(host, id)
	if r.clients.HasIdentity(id, board) {
		return fail(api.CodeUnavailable, "draws on %s, which does not serve %s", label, method)
	}
	return fail(api.CodeUnavailable, "draws on %s, which is offline", label)
}

func (r *Router) browserTile(id string) (*board.Board, model.Object, error) {
	b, err := r.boardForObject(id)
	if err != nil {
		return nil, model.Object{}, err
	}
	o, ok := b.Objects()[id]
	if !ok {
		return nil, model.Object{}, fail(api.CodeNotFound, "no object %s", id)
	}
	if o.Type != model.Browser {
		return nil, model.Object{}, invalid("%s is a %s tile, not a browser", id, o.Type)
	}
	return b, o, nil
}

func browserDeadline(method string, params map[string]any) time.Duration {
	ms := defaultBrowserWaitMs
	if method == "browser.wait" {
		if n, ok := params["timeout_ms"].(float64); ok && n >= 0 {
			ms = int(math.Min(math.Round(n), maxBrowserWaitMs))
		}
	}
	return time.Duration(ms)*time.Millisecond + clients.ReloadGrace
}

func (r *Router) browserCall(p map[string]any) (any, error) {
	id, err := str(p, "id")
	if err != nil {
		return nil, err
	}
	method, err := str(p, "method")
	if err != nil {
		return nil, err
	}
	if !pageMethods[method] {
		return nil, invalid("method must be a page-scoped browser command")
	}
	params, ok := p["params"].(map[string]any)
	if !ok || params == nil {
		return nil, invalid("params must be an object")
	}
	b, o, err := r.browserTile(id)
	if err != nil {
		return nil, err
	}
	machine, host, has := drawingOf(o)
	if !has {
		return nil, noDrawingMac(id)
	}
	c := r.clients.ChooseExact(machine, b.ID(), "browser.call")
	if c == nil {
		return nil, r.drawingUnavailable(machine, host, b.ID(), "browser.call")
	}
	forward := map[string]any{"id": id, "method": method, "params": params}
	caller, _ := optStr(p, "caller")
	if driver := r.browserDriver(caller, o, b); driver != "" {
		forward["caller"] = driver
	}
	return r.await(c, "browser.call", forward, browserDeadline(method, params))
}

func (r *Router) browserReport(p map[string]any, c Conn) (any, error) {
	id, err := str(p, "id")
	if err != nil {
		return nil, err
	}
	b, o, err := r.browserTile(id)
	if err != nil {
		return nil, err
	}
	machine, _, has := drawingOf(o)
	if !has {
		return nil, noDrawingMac(id)
	}
	identity, boards, attached := r.clients.Reporter(c)
	if !attached || identity != machine || !boards[b.ID()] {
		return nil, fail(api.CodeUnavailable, "only the drawing Mac may report %s", id)
	}
	_, hasCaller := p["caller"]
	_, hasActor := p["actor"]
	if hasCaller && hasActor {
		return nil, invalid("caller and actor are mutually exclusive")
	}
	caller := ""
	if hasCaller {
		caller, err = str(p, "caller")
		if err != nil {
			return nil, err
		}
		terminal, ok := b.Objects()[caller]
		if !ok || terminal.Type != model.Terminal {
			return nil, invalid("caller must be a terminal tile on this board")
		}
	}
	actor := board.SystemActor
	if hasActor {
		name, err := str(p, "actor")
		if err != nil {
			return nil, err
		}
		switch name {
		case "user":
			actor = board.UserActor
		case "system":
			actor = board.SystemActor
		default:
			return nil, invalid("actor must be user or system")
		}
	}
	if hasCaller {
		actor = ""
	}
	title, hasTitle := p["pageTitle"]
	if hasTitle && title != nil {
		if _, ok := title.(string); !ok {
			return nil, invalid("pageTitle must be a string or null")
		}
	}
	updated := o
	if _, present := p["url"]; present {
		url, ok := p["url"].(string)
		if !ok {
			return nil, invalid("url must be a string")
		}
		updated, err = b.Update(id, nil, nil, nil, map[string]any{"url": url}, caller, actor)
		if err != nil {
			return nil, err
		}
	}
	if hasTitle {
		if err := b.WriteBookkeeping(id, map[string]any{"pageTitle": title}); err != nil {
			return nil, err
		}
		updated, err = b.Object(id)
		if err != nil {
			return nil, err
		}
	}
	return map[string]any{"object": objectJSON(b.ReportedOne(updated))}, nil
}

func (r *Router) reloadBrowser(b *board.Board, o model.Object, p map[string]any, timeout int) (any, error) {
	machine, host, has := drawingOf(o)
	if !has {
		return nil, noDrawingMac(o.ID)
	}
	c := r.clients.ChooseExact(machine, b.ID(), "object.reload")
	if c == nil {
		return nil, r.drawingUnavailable(machine, host, b.ID(), "object.reload")
	}
	caller, _ := optStr(p, "caller")
	delete(p, "caller")
	if driver := r.browserDriver(caller, o, b); driver != "" {
		p["caller"] = driver
	}
	return r.await(c, "object.reload", p, millis(timeout)+clients.ReloadGrace)
}
