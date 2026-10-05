package router

import (
	"sort"
	"strings"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
)

var batchMethods = []string{"layout.grid", "layout.place", "layout.stack", "layout.translate", "object.create", "object.delete", "object.update", "object.upsert"}

type upsertPlan struct {
	key, holder string
}

// batch is object.batch: every op applies or none does, as one board revision. Sizes are
// measured and upserts resolved before anything changes; `$n` names what op n created.
func (r *Router) batch(p map[string]any) (any, error) {
	ops, ok := p["ops"].([]any)
	if !ok || len(ops) == 0 {
		return nil, invalid("ops must be a non-empty array")
	}
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	prepared := func(method string, raw any) map[string]any {
		params := copyParams(asMap(raw))
		if method == "object.create" || method == "object.upsert" {
			params["board"] = b.ID()
		}
		if _, has := params["caller"]; !has {
			if c, ok := p["caller"]; ok {
				params["caller"] = c
			}
		}
		return params
	}
	pending := map[int]map[string]any{}
	var sizes []*board.Size
	plan := keyPlan{given: map[string]plannedHolder{}}
	upserts := map[int]upsertPlan{}
	updating := map[int]string{}
	names := make([]string, len(ops))
	for i, op := range ops {
		names[i], _ = asMap(op)["method"].(string)
	}
	resolvedOps := make([]map[string]any, len(ops))
	for index, op := range ops {
		method := names[index]
		if !contains(batchMethods, method) {
			return nil, invalid("op %d: method must be one of %s", index, strings.Join(batchMethods, ", "))
		}
		var params map[string]any
		err := func() error {
			opParams, present := asMap(op)["params"]
			if !present || opParams == nil {
				opParams = map[string]any{}
			}
			if err := checkParams(method, opParams); err != nil {
				return err
			}
			replaced, _ := replacingReferences(opParams, func(n int, _ string) (any, bool, error) {
				if id, ok := updating[n]; ok {
					return id, true, nil
				}
				return nil, false, nil
			})
			raw := prepared(method, replaced)
			if method == "object.upsert" {
				key, err := str(raw, "key")
				if err != nil {
					return err
				}
				m, resolved, err := r.upserted(raw, plan)
				if err != nil {
					return err
				}
				method, raw = m, resolved
				holder, ok := raw["id"].(string)
				if !ok {
					holder = "$" + itoa(index)
				}
				upserts[index] = upsertPlan{key, holder}
				if method == "object.update" {
					updating[index] = holder
				}
			}
			x, err := r.inCallersCheckout(method, raw, pending)
			if err != nil {
				return err
			}
			if x, err = r.referenced(method, x, pending); err != nil {
				return err
			}
			if x, err = r.anchored(method, x, pending); err != nil {
				return err
			}
			params = x
			resolvedOps[index] = map[string]any{"method": method, "params": params}
			size, err := r.fitSize(method, params, pending)
			if err != nil {
				return err
			}
			sizes = append(sizes, size)
			return nil
		}()
		if err != nil {
			return nil, labelled(err, index, names[index])
		}
		method = resolvedOps[index]["method"].(string)
		switch method {
		case "object.create":
			pending[index] = params
			if key, ok := board.Key(asMap(params["props"])); ok {
				if typ, ok := model.ParseObjectType(stringOf(params["type"])); ok {
					plan.given[key] = plannedHolder{"$" + itoa(index), typ}
				}
			}
		case "object.update":
			id, ok := params["id"].(string)
			value, has := asMap(params["props"])["key"]
			if !ok || !has {
				break
			}
			var typ model.ObjectType
			found := false
			if n, isRef := reference(id); isRef {
				if created, ok := pending[n]; ok {
					typ, found = model.ParseObjectType(stringOf(created["type"]))
				}
			} else if o, ok := b.Objects()[id]; ok {
				typ, found = o.Type, true
			}
			plan.drop(id)
			if key, ok := value.(string); ok && key != "" && found {
				plan.given[key] = plannedHolder{id, typ}
			}
		case "object.delete":
			if id, ok := params["id"].(string); ok {
				plan.drop(id)
			}
		}
	}
	var results []map[string]any
	err = b.Atomically(func() error {
		for index, op := range resolvedOps {
			method := op["method"].(string)
			err := func() error {
				resolved, err := r.resolve(op["params"], results, index)
				if err != nil {
					return err
				}
				params := prepared(method, resolved)
				if u, ok := upserts[index]; ok {
					planned := ""
					if u.holder != "$"+itoa(index) {
						v, err := r.resolve(u.holder, results, index)
						if err != nil {
							return err
						}
						planned, _ = v.(string)
					}
					holder := ""
					o, found, err := b.Holder(u.key)
					if err != nil {
						return err
					}
					if found {
						holder = o.ID
					}
					if holder != planned {
						now, then := holder, planned
						if now == "" {
							now = "nothing"
						}
						if then == "" {
							then = "nothing"
						}
						return board.Conflict("key \"%s\" is held by %s now, not %s as when the batch was planned; send it again", u.key, now, then)
					}
				}
				var named []string
				for _, k := range []string{"id", "near"} {
					if s, ok := params[k].(string); ok {
						named = append(named, s)
					}
				}
				named = append(named, strings_(params["ids"])...)
				if cells, ok := params["cells"].([]any); ok {
					for _, c := range cells {
						if s, ok := asMap(c)["id"].(string); ok {
							named = append(named, s)
						}
					}
				}
				for _, id := range named {
					if _, ok := b.Objects()[id]; !ok {
						return board.NotFound("object %s on board %s", id, b.ID())
					}
				}
				fitted, err := r.fitted(method, params, sizes[index])
				if err != nil {
					return err
				}
				res, err := r.dispatch(method, fitted)
				if err != nil {
					return err
				}
				result := res.(map[string]any)
				if _, ok := upserts[index]; ok {
					result["created"] = method == "object.create"
				}
				results = append(results, result)
				return nil
			}()
			if err != nil {
				return labelled(err, index, names[index])
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	for i := range results {
		if sizes[i] != nil {
			results[i] = r.withOverlaps(results[i], nil)
		}
	}
	var arrows []model.Object
	for _, res := range results {
		obj := asMap(res["object"])
		if obj["type"] != string(model.Arrow) {
			continue
		}
		if id, ok := obj["id"].(string); ok {
			if o, ok := b.Objects()[id]; ok {
				arrows = append(arrows, o)
			}
		}
	}
	if len(arrows) > 0 {
		frames := map[string]model.Frame{}
		for _, o := range b.Reported(arrows) {
			if _, seen := frames[o.ID]; !seen {
				frames[o.ID] = o.Frame
			}
		}
		for i, res := range results {
			obj := asMap(res["object"])
			id, _ := obj["id"].(string)
			f, ok := frames[id]
			if obj == nil || !ok {
				continue
			}
			updated := copyParams(obj)
			updated["frame"] = f.JSON()
			out := copyParams(res)
			out["object"] = updated
			results[i] = out
		}
	}
	list := make([]any, len(results))
	for i, res := range results {
		list[i] = res
	}
	revision := float64(b.Revision())
	for _, res := range results {
		r.reanchorCode(asMap(res["object"])["id"])
	}
	return map[string]any{"results": list, "revision": revision}, nil
}

// labelled names the op a failure came from, with the code it would have had on its own.
func labelled(err error, index int, method string) error {
	f := asFailure(err)
	return &Failure{f.Code, "op " + itoa(index) + " (" + method + "): " + f.Message}
}

// resolve replaces every "$n" in value with the id op n created (or an upsert updated).
func (r *Router) resolve(value any, results []map[string]any, index int) (any, error) {
	return replacingReferences(value, func(n int, text string) (any, bool, error) {
		if n >= 0 && n < index && n < len(results) {
			if id, ok := asMap(results[n]["object"])["id"]; ok {
				return id, true, nil
			}
		}
		return nil, false, invalid("%s must name an earlier create or upsert op", text)
	})
}

// replacingReferences is value with each string "$n" replaced by what replacement gives.
func replacingReferences(value any, replacement func(int, string) (any, bool, error)) (any, error) {
	switch x := value.(type) {
	case string:
		n, ok := reference(x)
		if !ok {
			return x, nil
		}
		v, replaced, err := replacement(n, x)
		if err != nil {
			return nil, err
		}
		if !replaced {
			return x, nil
		}
		return v, nil
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			v, err := replacingReferences(e, replacement)
			if err != nil {
				return nil, err
			}
			out[i] = v
		}
		return out, nil
	case map[string]any:
		out := make(map[string]any, len(x))
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			v, err := replacingReferences(x[k], replacement)
			if err != nil {
				return nil, err
			}
			out[k] = v
		}
		return out, nil
	}
	return value, nil
}
