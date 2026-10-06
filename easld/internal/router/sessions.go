package router

import (
	"errors"
	"strings"

	"github.com/twaldin/easl/easld/internal/session"
)

// sessionCall answers session.spawn, .list and .kill (hosted terminals' zmx sessions), outside
// the registry's lock: they touch no board, and zmx takes up to a second.
func (r *Router) sessionCall(req any) (any, bool) {
	m, _ := req.(map[string]any)
	method, _ := m["method"].(string)
	if !strings.HasPrefix(method, "session.") {
		return nil, false
	}
	id := m["id"]
	params, present := m["params"]
	if !present || params == nil {
		params = map[string]any{}
	}
	if err := checkParams(method, params); err != nil {
		return errorReply(id, asFailure(err)), true
	}
	p, _ := params.(map[string]any)
	result, err := r.session(method, p)
	if err != nil {
		var se *session.Error
		if errors.As(err, &se) {
			return errorReply(id, &Failure{se.Code, se.Message}), true
		}
		return errorReply(id, asFailure(err)), true
	}
	return okReply(id, result), true
}

func (r *Router) session(method string, p map[string]any) (any, error) {
	switch method {
	case "session.spawn":
		tile, err := str(p, "tile")
		if err != nil {
			return nil, err
		}
		req := session.SpawnRequest{Tile: tile, Command: strings_(p["command"]), Env: map[string]string{}, Labels: map[string]string{}}
		if raw, present := p["command"]; present {
			if _, ok := raw.([]any); !ok || len(req.Command) != len(raw.([]any)) {
				return nil, invalid("command must be an array of strings")
			}
		}
		if raw, present := p["cwd"]; present {
			cwd, ok := raw.(string)
			if !ok {
				return nil, invalid("cwd must be a string")
			}
			req.Cwd = cwd
		}
		for key, into := range map[string]map[string]string{"env": req.Env, "labels": req.Labels} {
			raw, present := p[key]
			if !present {
				continue
			}
			object, ok := raw.(map[string]any)
			if !ok {
				return nil, invalid("%s must be an object of strings", key)
			}
			for name, value := range object {
				text, ok := value.(string)
				if !ok {
					return nil, invalid("%s.%s must be a string", key, name)
				}
				into[name] = text
			}
		}
		name, created, err := r.Sessions.Spawn(req)
		if err != nil {
			return nil, err
		}
		return map[string]any{"session": name, "created": created}, nil
	case "session.list":
		list, err := r.Sessions.List()
		if err != nil {
			return nil, err
		}
		sessions := make([]any, len(list))
		for i, s := range list {
			labels := map[string]any{}
			for k, v := range s.Labels {
				labels[k] = v
			}
			entry := map[string]any{"session": s.Name, "tile": s.Tile, "labels": labels}
			if s.PID > 0 {
				entry["pid"] = float64(s.PID)
				entry["clients"] = float64(s.Clients)
			}
			if s.Unreachable {
				entry["unreachable"] = true
			}
			sessions[i] = entry
		}
		return map[string]any{"sessions": sessions}, nil
	case "session.kill":
		tile, err := str(p, "tile")
		if err != nil {
			return nil, err
		}
		home, _ := optStr(p, "home")
		killed, err := r.Sessions.Kill(tile, home)
		if err != nil {
			return nil, err
		}
		return map[string]any{"killed": killed}, nil
	}
	return nil, invalid("unknown method %s", method)
}
