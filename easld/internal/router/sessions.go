package router

import (
	"regexp"
	"strings"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/session"
)

var mergedBoardID = regexp.MustCompile(`^[a-z]+_[0-9A-Za-z]+$`)

// hostCall answers session.spawn, .list and .kill (hosted terminals' zmx sessions) and
// relay.open (their way back to the board), outside the registry's lock: they touch no board,
// and zmx takes up to a second.
func (r *Router) hostCall(req any) (any, bool) {
	m, _ := req.(map[string]any)
	method, _ := m["method"].(string)
	if !strings.HasPrefix(method, "session.") && method != "relay.open" {
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
	var result any
	var err error
	if method == "relay.open" {
		result, err = r.openRelay(p)
	} else {
		result, err = r.session(method, p)
	}
	if err != nil {
		return errorReply(id, asFailure(err)), true
	}
	return okReply(id, result), true
}

func (r *Router) openRelay(p map[string]any) (any, error) {
	if r.Relays == nil {
		return nil, fail(api.CodeUnavailable, "this easld serves no relays")
	}
	instance, err := str(p, "instance")
	if err != nil {
		return nil, err
	}
	port, ok := p["port"].(float64)
	if !ok || port != float64(int(port)) {
		return nil, invalid("port must be an integer")
	}
	token, err := str(p, "token")
	if err != nil {
		return nil, err
	}
	paths, opened, err := r.Relays.Open(instance, int(port), token)
	if err != nil {
		return nil, err
	}
	return map[string]any{"easl": paths["easl"], "cmux": paths["cmux"], "opened": opened}, nil
}

func (r *Router) session(method string, p map[string]any) (any, error) {
	switch method {
	case "session.spawn":
		tile, err := str(p, "tile")
		if err != nil {
			return nil, err
		}
		req := session.SpawnRequest{Tile: tile, Command: strings_(p["command"]), Merged: strings_(p["merged"]), Env: map[string]string{}, Labels: map[string]string{}}
		if raw, present := p["command"]; present {
			if _, ok := raw.([]any); !ok || len(req.Command) != len(raw.([]any)) {
				return nil, invalid("command must be an array of strings")
			}
		}
		if raw, present := p["merged"]; present {
			if _, ok := raw.([]any); !ok || len(req.Merged) != len(raw.([]any)) {
				return nil, invalid("merged must be an array of strings")
			}
		}
		for _, id := range req.Merged {
			if !mergedBoardID.MatchString(id) {
				return nil, invalid("merged items must be ids matching ^[a-z]+_[0-9A-Za-z]+$")
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
