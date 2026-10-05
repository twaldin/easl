package router

import (
	"errors"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/mention"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/route"
	"github.com/twaldin/easl/easld/internal/store"
)

// write is object.create/update/upsert as ApiRouter.handle runs them: an upsert resolved to its
// create or update, paths taken into the caller's checkout, refs resolved, note ranges
// anchored, a duplicate changes tile reused, `size: "fit"` measured, overlaps reported.
func (r *Router) write(method string, p map[string]any) (any, error) {
	result, err := r.writeObject(method, p)
	if err == nil {
		r.reanchorCode(asMap(asMap(result)["object"])["id"])
	}
	return result, err
}

// reanchorCode is the code tile's write-back after it loads its file (CodeTile.reanchor): its
// range re-found by content and the first line it is anchored by, as bookkeeping.
func (r *Router) reanchorCode(id any) {
	s, ok := id.(string)
	if !ok {
		return
	}
	b, ok := r.reg.Containing(s)
	if !ok || b.Objects()[s].Type != model.Code {
		return
	}
	if rng, anchor, changed := measure.Reanchor(b.Objects()[s].Props, b.Root()); changed {
		_ = b.Reanchor(s, rng, anchor)
	}
}

func (r *Router) writeObject(method string, p map[string]any) (any, error) {
	upsert := method == "object.upsert"
	params := p
	if upsert {
		var err error
		method, params, err = r.upserted(p, keyPlan{})
		if err != nil {
			return nil, err
		}
	}
	params, err := r.inCallersCheckout(method, params, nil)
	if err != nil {
		return nil, err
	}
	if params, err = r.referenced(method, params, nil); err != nil {
		return nil, err
	}
	if params, err = r.anchored(method, params, nil); err != nil {
		return nil, err
	}
	if method == "object.create" {
		if _, keyed := board.Key(asMap(params["props"])); !keyed {
			reused, err := r.reusableChanges(params)
			if err != nil {
				return nil, err
			}
			if reused != nil {
				size, err := r.fitSize("object.update", reused, nil)
				if err != nil {
					return nil, err
				}
				fitted, err := r.fitted("object.update", reused, size)
				if err != nil {
					return nil, err
				}
				res, err := r.dispatch("object.update", fitted)
				if err != nil {
					return nil, err
				}
				result := res.(map[string]any)
				result["reused"] = true
				if size == nil {
					return result, nil
				}
				return r.withOverlaps(result, nil), nil
			}
		}
	}
	size, err := r.fitSize(method, params, nil)
	if err != nil {
		return nil, err
	}
	var covered map[string]bool
	if _, framed := params["frame"]; method == "object.update" && size == nil && framed {
		if id, ok := params["id"].(string); ok {
			if b, err := r.boardForObject(id); err == nil {
				covered = map[string]bool{}
				for _, o := range b.Overlaps(id) {
					covered[o] = true
				}
			}
		}
	}
	fitted, err := r.fitted(method, params, size)
	if err != nil {
		return nil, err
	}
	res, err := r.dispatch(method, fitted)
	if err != nil {
		return nil, err
	}
	result := res.(map[string]any)
	if size != nil || covered != nil {
		result = r.withOverlaps(result, covered)
	}
	if upsert {
		result["created"] = method == "object.create"
	}
	return result, nil
}

func (r *Router) create(p map[string]any) (any, error) {
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	typeName, err := str(p, "type")
	if err != nil {
		return nil, err
	}
	typ, ok := model.ParseObjectType(typeName)
	if !ok {
		return nil, invalid("unknown object type")
	}
	props, ok := p["props"].(map[string]any)
	if !ok {
		return nil, invalid("props must be an object")
	}
	if err := checkProps(p); err != nil {
		return nil, err
	}
	caller := r.callerOf(p)
	var frame *model.Frame
	if value, present := p["frame"]; present {
		m := asMap(value)
		_, hasX := m["x"].(float64)
		_, hasY := m["y"].(float64)
		w, hasW := m["w"].(float64)
		h, hasH := m["h"].(float64)
		if !hasX && !hasY && hasW && hasH {
			f := b.Place(w, h, caller, nil, true)
			frame = &f
		} else {
			f, err := parseFrame(value, nil)
			if err != nil {
				return nil, err
			}
			frame = &f
		}
	}
	if typ == model.Note || typ == model.HTML {
		if root, ok := props["root"].(string); ok && root != "" {
			if err := b.CheckLinkRoot(root); err != nil {
				return nil, err
			}
		}
	}
	if err := b.CheckKey(props, ""); err != nil {
		return nil, err
	}
	if typ == model.Diagram {
		if problem, bad := diagramProblem(props); bad {
			return nil, invalid("%s", problem)
		}
	}
	parent, _ := optStr(p, "parent")
	o := b.Create(typ, props, frame, parent, caller)
	return withWarnings(map[string]any{"object": objectJSON(b.ReportedOne(o))}, typ.UnknownPropWarnings(props)), nil
}

func (r *Router) update(p map[string]any) (any, error) {
	id, err := str(p, "id")
	if err != nil {
		return nil, err
	}
	b, err := r.boardForObject(id)
	if err != nil {
		return nil, err
	}
	if err := checkProps(p); err != nil {
		return nil, err
	}
	current, err := b.Object(id)
	if err != nil {
		return nil, err
	}
	var frame *model.Frame
	if value, present := p["frame"]; present {
		f, err := parseFrame(value, &current.Frame)
		if err != nil {
			return nil, err
		}
		frame = &f
	}
	props := asMap(p["props"])
	if root, ok := props["root"].(string); ok && root != "" && (current.Type == model.Note || current.Type == model.HTML) {
		if err := b.CheckLinkRoot(root); err != nil {
			return nil, err
		}
	}
	if props != nil && current.Type == model.Diagram {
		if problem, bad := diagramProblem(model.Merge(current.Props, props).(map[string]any)); bad {
			return nil, invalid("%s", problem)
		}
	}
	var rev *int
	if n, ok := intParam(p, "rev"); ok {
		rev = &n
	}
	o, err := b.Update(id, rev, frame, nil, props, r.callerOf(p), "")
	if err != nil {
		return nil, err
	}
	return withWarnings(map[string]any{"object": objectJSON(b.ReportedOne(o))}, o.Type.UnknownPropWarnings(props)), nil
}

// parseFrame is a `frame` param: all of x, y, w, h, or (onto base) any of them.
func parseFrame(value any, base *model.Frame) (model.Frame, error) {
	m, ok := value.(map[string]any)
	if !ok {
		return model.Frame{}, invalid("frame must be an object with x, y, w, h")
	}
	side := func(key string, current *float64) (float64, error) {
		if given, present := m[key]; present && given != nil {
			n, ok := given.(float64)
			if !ok {
				return 0, invalid("frame.%s must be a number", key)
			}
			return n, nil
		}
		if current == nil {
			return 0, invalid("frame needs x, y, w, and h (missing %s); w and h alone place it automatically; with size: \"fit\", x and y (and w) are enough", key)
		}
		return *current, nil
	}
	var bx, by, bw, bh *float64
	if base != nil {
		bx, by, bw, bh = &base.X, &base.Y, &base.W, &base.H
	}
	x, err := side("x", bx)
	if err != nil {
		return model.Frame{}, err
	}
	y, err := side("y", by)
	if err != nil {
		return model.Frame{}, err
	}
	w, err := side("w", bw)
	if err != nil {
		return model.Frame{}, err
	}
	h, err := side("h", bh)
	if err != nil {
		return model.Frame{}, err
	}
	return model.Frame{X: x, Y: y, W: w, H: h}, nil
}

// checkProps rejects a retired `props.scale` (ObjectZoom.retiredProblem).
func checkProps(p map[string]any) error {
	if _, ok := asMap(p["props"])["scale"]; ok {
		return invalid("props.scale is gone: a tile's content zoom is props.zoom (the frame keeps its size; 1.5 is 150%%), a text shape's font size props.textSize")
	}
	return nil
}

// diagramProblem is DiagramSpec.problem.
func diagramProblem(props map[string]any) (string, bool) {
	if kind, ok := props["kind"]; ok && kind != "calls" {
		return "diagram kind must be one of calls", true
	}
	if d, ok := props["direction"]; ok && d != "incoming" && d != "outgoing" && d != "both" {
		return "direction must be one of incoming, outgoing, both", true
	}
	if v, ok := props["depth"]; ok {
		n, isNum := board.TruncInt(v)
		if !isNum || n < 1 || n > 4 {
			return "depth must be an integer from 1 to 4", true
		}
	}
	if v, ok := props["line"]; ok {
		n, isNum := board.TruncInt(v)
		if !isNum || n < 1 {
			return "line is 1-based: an integer of at least 1", true
		}
	}
	if v, ok := props["expanded"]; ok {
		list, isList := v.([]any)
		allStrings := isList
		for _, x := range list {
			if _, s := x.(string); !s {
				allStrings = false
			}
		}
		if !allStrings {
			return "expanded is an array of node ids", true
		}
	}
	symbol, _ := props["symbol"].(string)
	path, _ := props["path"].(string)
	line := 0
	if n, ok := board.TruncInt(props["line"]); ok && n >= 1 {
		line = n
	}
	if symbol == "" && path == "" {
		return "a calls diagram needs props.symbol (e.g. \"SocketServer.start\"), or props.path with a line or symbol", true
	}
	if symbol == "" && line == 0 {
		in := path
		if in == "" {
			in = "the file"
		}
		return "a calls diagram needs props.symbol or props.line to name its root function in " + in, true
	}
	return "", false
}

// withOverlaps adds `overlaps`, the objects the result's object now covers, when it covers any
// beyond before.
func (r *Router) withOverlaps(result map[string]any, before map[string]bool) map[string]any {
	id, ok := asMap(result["object"])["id"].(string)
	if !ok {
		return result
	}
	b, err := r.boardForObject(id)
	if err != nil {
		return result
	}
	covered := b.Overlaps(id)
	beyond := false
	for _, c := range covered {
		if !before[c] {
			beyond = true
		}
	}
	if !beyond {
		return result
	}
	list := make([]any, len(covered))
	for i, c := range covered {
		list[i] = c
	}
	out := map[string]any{}
	for k, v := range result {
		out[k] = v
	}
	out["overlaps"] = list
	return out
}

// --- object.get / find ---

func (r *Router) objectGet(p map[string]any) (any, error) {
	id, err := str(p, "id")
	if err != nil {
		return nil, err
	}
	b, err := r.boardForObject(id)
	if err != nil {
		return nil, err
	}
	o, err := b.Object(id)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"object": objectJSON(b.ReportedOne(o))}
	as := "raw"
	if s, ok := optStr(p, "as"); ok {
		as = s
	}
	switch as {
	case "graph":
		result["graph"] = graph(o, b)
	case "raw":
	case "image":
		return nil, invalid("object.get no longer renders images: use view.render with target %s", id)
	default:
		return nil, invalid("unknown as: %s", as)
	}
	return result, nil
}

// get is object.get with what some tiles add: a note's `fences`, a code tile's `rangeStatus`.
// A browser's page report, a terminal's last command (app closures) and a changes tile's
// `changes` (git diff, ChangeSet) aren't there.
func (r *Router) get(p map[string]any) (any, error) {
	res, err := r.dispatch("object.get", p)
	if err != nil {
		return nil, err
	}
	result := res.(map[string]any)
	id, _ := optStr(p, "id")
	b, ok := r.reg.Containing(id)
	if !ok {
		return result, nil
	}
	o := b.Objects()[id]
	switch o.Type {
	case model.Note:
		markdown, _ := o.Props["markdown"].(string)
		reading := measure.ReadingFor(o.Props, b.Root())
		if reading.Ref != nil {
			b.RecordRefSha(id, reading.Ref.Ref, reading.Ref.SHA)
		}
		result["fences"] = mention.NoteFences(markdown, reading)
	case model.Code:
		status, ok := measure.CodeRangeStatus(o.Props, b.Root())
		if !ok {
			return result, nil
		}
		current, err := r.dispatch("object.get", p)
		if err != nil {
			return nil, err
		}
		out := current.(map[string]any)
		out["rangeStatus"] = status
		return out, nil
	}
	return result, nil
}

func (r *Router) find(p map[string]any) (any, error) {
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	key, hasKey := optStr(p, "key")
	prefix, hasPrefix := optStr(p, "keyPrefix")
	switch {
	case hasKey && !hasPrefix:
		o, ok, err := b.Holder(key)
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, board.NotFound("no object on board %s has key \"%s\"", b.ID(), key)
		}
		params := map[string]any{"id": o.ID}
		if view, present := p["as"]; present {
			params["as"] = view
		}
		return r.get(params)
	case !hasKey && hasPrefix:
		objects := []any{}
		for _, o := range b.Reported(b.ObjectsWithKeyPrefix(prefix)) {
			objects = append(objects, objectJSON(summarized(o)))
		}
		return map[string]any{"objects": objects}, nil
	}
	return nil, invalid("object.find takes key or keyPrefix, one of them")
}

// graph is object.get `as: graph` (DrawingGraph.swift): what the object encloses, what
// encloses it, what it overlaps, its arrows, and the arrows drawn inside it.
func graph(o model.Object, b *board.Board) map[string]any {
	objects := b.Objects()
	ids := make([]string, 0, len(objects))
	for id := range objects {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var encloses, enclosedBy, overlaps []any
	inside := map[string]bool{}
	for _, id := range ids {
		x := objects[id]
		if x.ID != o.ID && x.Type != model.Arrow && o.Frame.Contains(x.Frame) {
			encloses = append(encloses, id)
			inside[id] = true
		}
	}
	containers := map[string]bool{}
	for _, id := range ids {
		x := objects[id]
		if x.ID != o.ID && x.Type != model.Arrow && x.Frame.Contains(o.Frame) {
			enclosedBy = append(enclosedBy, id)
			containers[id] = true
		}
	}
	for _, id := range ids {
		x := objects[id]
		if x.ID != o.ID && x.Type != model.Arrow && x.Frame.Intersects(o.Frame) && !inside[id] && !containers[id] {
			overlaps = append(overlaps, id)
		}
	}
	var out, in, drawn []any
	region := route.RectOf(o.Frame)
	within := func(bnd route.Binding) bool {
		if bnd.IsPoint() {
			return region.Contains(bnd.Point)
		}
		return inside[bnd.Object]
	}
	for _, id := range ids {
		a := objects[id]
		if a.Type != model.Arrow {
			continue
		}
		relation, hasRelation := a.Props["relation"]
		if !hasRelation {
			relation = nil
		}
		from, _ := asMap(a.Props["from"])["object"].(string)
		to, _ := asMap(a.Props["to"])["object"].(string)
		if from == o.ID && to != "" {
			out = append(out, map[string]any{"arrow": a.ID, "to": to, "relation": relation})
		}
		if to == o.ID && from != "" {
			in = append(in, map[string]any{"arrow": a.ID, "from": from, "relation": relation})
		}
		if a.ID == o.ID {
			continue
		}
		if spec, ok := route.ParseArrow(a.Props); ok && within(spec.From) && within(spec.To) {
			entry := map[string]any{"arrow": a.ID, "from": spec.From.JSON(), "to": spec.To.JSON(), "relation": nil, "label": nil}
			if spec.Relation != nil {
				entry["relation"] = *spec.Relation
			}
			if spec.Label != nil {
				entry["label"] = *spec.Label
			}
			drawn = append(drawn, entry)
		}
	}
	g := map[string]any{
		"encloses": orEmptyList(encloses), "enclosedBy": orEmptyList(enclosedBy), "overlaps": orEmptyList(overlaps),
		"arrowsOut": orEmptyList(out), "arrowsIn": orEmptyList(in), "arrows": orEmptyList(drawn),
	}
	if o.Type == model.Arrow {
		if spec, ok := route.ParseArrow(o.Props); ok {
			g["from"] = spec.From.JSON()
			g["to"] = spec.To.JSON()
		}
	}
	return g
}

func orEmptyList(list []any) []any {
	if list == nil {
		return []any{}
	}
	return list
}

// --- upsert ---

// keyPlan is what the ops of a batch before an upsert do to keys.
type keyPlan struct {
	given   map[string]plannedHolder
	dropped map[string]bool
}

type plannedHolder struct {
	id  string
	typ model.ObjectType
}

func (k *keyPlan) drop(id string) {
	if k.dropped == nil {
		k.dropped = map[string]bool{}
	}
	k.dropped[id] = true
	for key, h := range k.given {
		if h.id == id {
			delete(k.given, key)
		}
	}
}

// upserted is object.upsert's params as the create or update they are now.
func (r *Router) upserted(p map[string]any, plan keyPlan) (string, map[string]any, error) {
	key, err := str(p, "key")
	if err != nil {
		return "", nil, err
	}
	if key == "" {
		return "", nil, invalid("key must not be empty")
	}
	typeName, err := str(p, "type")
	if err != nil {
		return "", nil, err
	}
	typ, ok := model.ParseObjectType(typeName)
	if !ok {
		return "", nil, invalid("unknown object type")
	}
	props, ok := p["props"].(map[string]any)
	if !ok {
		return "", nil, invalid("props must be an object")
	}
	if given, present := props["key"]; present && given != key {
		return "", nil, invalid("props.key, when given, must be key")
	}
	b, err := r.boardOf(p)
	if err != nil {
		return "", nil, err
	}
	holder, found := plan.given[key]
	if !found {
		o, ok, err := b.Holder(key)
		if err != nil {
			return "", nil, err
		}
		if ok && !plan.dropped[o.ID] {
			holder, found = plannedHolder{o.ID, o.Type}, true
		}
	}
	params := map[string]any{}
	for k, v := range p {
		if k != "key" {
			params[k] = v
		}
	}
	if !found {
		params["board"] = b.ID()
		params["props"] = model.Merge(props, map[string]any{"key": key})
		return "object.create", params, nil
	}
	if holder.typ != typ {
		return "", nil, board.Conflict("key \"%s\" is held by %s, a %s, not a %s", key, holder.id, holder.typ, typ)
	}
	delete(params, "type")
	delete(params, "board")
	params["id"] = holder.id
	return "object.update", params, nil
}

// --- changes tiles ---

type changesSpec struct {
	root, base, head, ref string
	paths                 []string
}

func parseChangesSpec(props map[string]any) changesSpec {
	nonEmpty := func(k string) string { s, _ := props[k].(string); return s }
	s := changesSpec{root: nonEmpty("root"), head: nonEmpty("head"), ref: nonEmpty("ref"), base: nonEmpty("base")}
	if s.base == "" {
		if s.head != "" || s.ref != "" {
			s.base = "merge-base"
		} else {
			s.base = "HEAD"
		}
	}
	s.paths = []string{}
	if list, ok := props["paths"].([]any); ok {
		for _, x := range list {
			if p, ok := x.(string); ok && p != "" {
				s.paths = append(s.paths, p)
			}
		}
	}
	return s
}

// directory is ChangesSpec.directory(boardRoot:).
func (s changesSpec) directory(boardRoot string) string {
	if s.ref != "" && s.root == "" {
		own := measure.WorktreeContaining(boardRoot)
		if own == nil {
			return boardRoot
		}
		found := measure.LiveWorktree(s.ref, own)
		if found == nil || found.GitDir == own.GitDir {
			return boardRoot
		}
		return found.Toplevel
	}
	if s.root == "" {
		return boardRoot
	}
	if strings.HasPrefix(s.root, "/") {
		return store.Standardized(s.root)
	}
	return store.Standardized(filepath.Join(boardRoot, s.root))
}

// reusableChanges is the update that hands an agent back the changes tile it already made for
// the same review, nil for anything else.
func (r *Router) reusableChanges(p map[string]any) (map[string]any, error) {
	props, ok := p["props"].(map[string]any)
	if p["type"] != string(model.Changes) || !ok {
		return nil, nil
	}
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	caller := r.callerOf(p)
	if caller == "" {
		return nil, nil
	}
	spec := parseChangesSpec(props)
	root := spec.directory(b.Root())
	var existing *model.Object
	for _, o := range b.Objects() {
		if o.Type != model.Changes || o.CreatedBy.Kind != "agent" || o.CreatedBy.Tile != caller {
			continue
		}
		other := parseChangesSpec(o.Props)
		if other.base != spec.base || other.head != spec.head || other.ref != spec.ref || strings.Join(other.paths, "\x00") != strings.Join(spec.paths, "\x00") || len(other.paths) != len(spec.paths) {
			continue
		}
		if other.directory(b.Root()) != root {
			continue
		}
		if existing == nil || o.Z > existing.Z {
			c := o
			existing = &c
		}
	}
	if existing == nil {
		return nil, nil
	}
	update := map[string]any{"id": existing.ID, "caller": caller}
	given := map[string]any{}
	for k, v := range props {
		switch k {
		case "root", "base", "head", "ref", "paths":
		default:
			given[k] = v
		}
	}
	if len(given) > 0 {
		update["props"] = given
	}
	if f, ok := p["frame"]; ok {
		update["frame"] = f
	}
	if s, ok := p["size"]; ok {
		update["size"] = s
	}
	return update, nil
}

// --- paths, refs, anchors ---

// reference is "$n" → n, the index of an earlier batch op: Swift's `Int(text.dropFirst())`, an
// optional sign and decimal digits that fit an Int ("$-1" is a reference naming no op; one
// that overflows is just a string).
func reference(text string) (int, bool) {
	if !strings.HasPrefix(text, "$") {
		return 0, false
	}
	n, err := strconv.Atoi(text[1:])
	if err != nil {
		return 0, false
	}
	return n, true
}

func (r *Router) inCallersCheckout(method string, p map[string]any, pending map[int]map[string]any) (map[string]any, error) {
	props, ok := p["props"].(map[string]any)
	caller := r.callerOf(p)
	if !ok || caller == "" {
		return p, nil
	}
	params := copyParams(p)
	switch method {
	case "object.create":
		typ, ok := model.ParseObjectType(stringOf(p["type"]))
		if !ok {
			return p, nil
		}
		b, err := r.boardOf(p)
		if err != nil {
			return nil, err
		}
		params["props"] = b.InCallersCheckout(props, typ, caller, nil)
	case "object.update":
		id, ok := p["id"].(string)
		if !ok {
			return p, nil
		}
		if index, isRef := reference(id); isRef {
			created, ok := pending[index]
			typ, ok2 := model.ParseObjectType(stringOf(created["type"]))
			if !ok || !ok2 {
				return p, nil
			}
			b, err := r.boardOf(created)
			if err != nil {
				return nil, err
			}
			existing := asMap(created["props"])
			if existing == nil {
				existing = map[string]any{}
			}
			params["props"] = b.InCallersCheckout(props, typ, caller, existing)
		} else {
			b, ok := r.reg.Containing(id)
			if !ok {
				return p, nil
			}
			o := b.Objects()[id]
			params["props"] = b.InCallersCheckout(props, o.Type, caller, o.Props)
		}
	default:
		return p, nil
	}
	return params, nil
}

func stringOf(v any) string { s, _ := v.(string); return s }

func copyParams(p map[string]any) map[string]any {
	out := make(map[string]any, len(p))
	for k, v := range p {
		out[k] = v
	}
	return out
}

// referenced resolves a create's or update's `ref` on a code, note, HTML or changes tile now:
// `refSha` records the SHA, a ref that resolves to nothing fails, clearing the ref clears refSha.
func (r *Router) referenced(method string, p map[string]any, pending map[int]map[string]any) (map[string]any, error) {
	props, ok := p["props"].(map[string]any)
	if !ok {
		return p, nil
	}
	value, present := props["ref"]
	if !present {
		return p, nil
	}
	var b *board.Board
	var typ model.ObjectType
	var existing map[string]any
	if method == "object.create" {
		var err error
		if b, err = r.boardOf(p); err != nil {
			return nil, err
		}
		typ, _ = model.ParseObjectType(stringOf(p["type"]))
		existing = map[string]any{}
	} else {
		id, err := str(p, "id")
		if err != nil {
			return nil, err
		}
		if index, isRef := reference(id); isRef {
			created, ok := pending[index]
			if !ok {
				return p, nil
			}
			if b, err = r.boardOf(created); err != nil {
				return nil, err
			}
			typ, _ = model.ParseObjectType(stringOf(created["type"]))
			existing = asMap(created["props"])
		} else {
			if b, err = r.boardForObject(id); err != nil {
				return nil, err
			}
			o, err := b.Object(id)
			if err != nil {
				return nil, err
			}
			typ, existing = o.Type, o.Props
		}
	}
	if typ != model.Code && typ != model.Note && typ != model.HTML && typ != model.Changes {
		return p, nil
	}
	params := copyParams(p)
	fields := copyParams(props)
	ref, isString := value.(string)
	if !isString || ref == "" {
		if value != nil && !(isString && ref == "") {
			return nil, invalid("ref must be a branch or other ref name")
		}
		fields["refSha"] = nil
		params["props"] = fields
		return params, nil
	}
	if existing == nil {
		existing = map[string]any{}
	}
	merged := model.Merge(existing, props).(map[string]any)
	if typ == model.Code {
		if pinned, ok := merged["pinnedCommit"].(string); ok && pinned != "" {
			return p, nil
		}
	}
	known, _ := props["refSha"].(string)
	if existing["ref"] == ref {
		known, _ = merged["refSha"].(string)
	}
	source, err := measure.ResolveRef(ref, known, b.Root())
	if err != nil {
		var failure *measure.RefFailure
		if errors.As(err, &failure) {
			switch failure.Kind {
			case "notRevision":
				return nil, invalid("%s", measure.DescribeRefFailure(err, ref))
			case "notRepository":
				return nil, invalid("ref needs a board in a git repository")
			}
		}
		if typ != model.Changes {
			return nil, fail(api.CodeNotFound, "%s", measure.DescribeRefFailure(err, ref))
		}
		return nil, fail(api.CodeNotFound, "%s", missingCommit(ref, existingAncestor(b.Root())))
	}
	fields["refSha"] = source.SHA
	params["props"] = fields
	return params, nil
}

func existingAncestor(dir string) string {
	current := store.Standardized(dir)
	for current != "/" && !store.IsDirectory(current) {
		current = filepath.Dir(current)
	}
	return current
}

// missingCommit is ChangeSet.missing: the `git fetch` after which ref names a commit here.
func missingCommit(ref, toplevel string) string {
	var remotes []string
	if out, err := measure.RunGit([]string{"remote"}, toplevel, nil, 0, 0); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if line != "" {
				remotes = append(remotes, line)
			}
		}
	}
	return "no commit " + ref + " here; fetch it: " + fetchCommand(ref, remotes)
}

func fetchCommand(ref string, remotes []string) string {
	remote := "origin"
	if !contains(remotes, "origin") && len(remotes) > 0 {
		remote = remotes[0]
	}
	if strings.HasPrefix(ref, "pull/") || strings.HasPrefix(ref, "refs/pull/") {
		name := strings.TrimPrefix(ref, "refs/")
		return "git fetch " + remote + " " + name + ":refs/" + name
	}
	if strings.HasPrefix(ref, "refs/heads/") {
		branch := strings.TrimPrefix(ref, "refs/heads/")
		return "git fetch " + remote + " " + branch + ":refs/heads/" + branch
	}
	tracking := strings.TrimPrefix(ref, "refs/remotes/")
	if slash := strings.Index(tracking, "/"); slash >= 0 && contains(remotes, tracking[:slash]) {
		return "git fetch " + tracking[:slash] + " " + tracking[slash+1:]
	}
	if n := len([]rune(ref)); n >= 7 && n <= 40 && strings.IndexFunc(ref, func(c rune) bool { return !unicode.Is(unicode.ASCII_Hex_Digit, c) }) < 0 {
		return "git fetch " + remote + " " + ref
	}
	return "git fetch " + remote + " " + ref + ":refs/heads/" + ref
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// anchored is params with a note's markdown anchored the way its tile writes it back
// (NoteMarkdown.anchoringRanges), so the result's rev is the one the next update needs.
func (r *Router) anchored(method string, p map[string]any, pending map[int]map[string]any) (map[string]any, error) {
	props, ok := p["props"].(map[string]any)
	if !ok {
		return p, nil
	}
	markdown, ok := props["markdown"].(string)
	if !ok {
		return p, nil
	}
	var b *board.Board
	var merged map[string]any
	if method == "object.create" {
		if p["type"] != string(model.Note) {
			return p, nil
		}
		var err error
		if b, err = r.boardOf(p); err != nil {
			return nil, err
		}
		merged = props
	} else {
		id, err := str(p, "id")
		if err != nil {
			return nil, err
		}
		if index, isRef := reference(id); isRef {
			created, ok := pending[index]
			if !ok || created["type"] != string(model.Note) {
				return p, nil
			}
			if b, err = r.boardOf(created); err != nil {
				return nil, err
			}
			base := asMap(created["props"])
			if base == nil {
				base = map[string]any{}
			}
			merged = model.Merge(base, props).(map[string]any)
		} else {
			found, ok := r.reg.Containing(id)
			if !ok {
				return p, nil
			}
			note := found.Objects()[id]
			if note.Type != model.Note {
				return p, nil
			}
			b = found
			merged = model.Merge(note.Props, props).(map[string]any)
		}
	}
	linkRoot := b.LinkRoot(merged)
	var reading measure.LinkReading
	if _, hasRef := board.RefOf(merged); hasRef {
		reading = measure.ReadingFor(merged, b.Root())
	} else {
		reading = measure.LinkReading{Root: linkRoot}
	}
	text := mention.AnchoringRanges(markdown, reading)
	if text == markdown {
		return p, nil
	}
	params := copyParams(p)
	fields := copyParams(props)
	fields["markdown"] = text
	params["props"] = fields
	return params, nil
}

// pathRoot is the directory a create's or update's paths resolve against: a note's or HTML
// tile's link root, else the board root.
func pathRoot(b *board.Board, typ model.ObjectType, props map[string]any) string {
	if typ == model.Note || typ == model.HTML {
		return b.LinkRoot(props)
	}
	return b.Root()
}

// fitSize is the measured size an object.create/update with `size: "fit"` gets, or a note or
// image created without a frame height; nil otherwise.
func (r *Router) fitSize(method string, p map[string]any, pending map[int]map[string]any) (*board.Size, error) {
	frame := asMap(p["frame"])
	_, hasH := frame["h"]
	fitsNote := method == "object.create" && (p["type"] == string(model.Note) || p["type"] == string(model.Image)) && !hasH
	size, present := p["size"]
	if !present {
		if !fitsNote {
			return nil, nil
		}
		size = "fit"
	}
	if size != "fit" {
		return nil, invalid("size must be \"fit\"")
	}
	var width *float64
	if w, ok := frame["w"].(float64); ok {
		width = &w
	}
	if method == "object.create" {
		typeName, err := str(p, "type")
		if err != nil {
			return nil, err
		}
		typ, ok := model.ParseObjectType(typeName)
		if !ok {
			return nil, invalid("unknown object type")
		}
		props := asMap(p["props"])
		if props == nil {
			props = map[string]any{}
		}
		b, err := r.boardOf(p)
		if err != nil {
			return nil, err
		}
		w, h, err := measure.Size(typ, props, width, pathRoot(b, typ, props))
		if err != nil {
			return nil, err
		}
		return &board.Size{W: w, H: h}, nil
	}
	id, err := str(p, "id")
	if err != nil {
		return nil, err
	}
	var typ model.ObjectType
	var props map[string]any
	var baseWidth *float64
	var root string
	if index, isRef := reference(id); isRef {
		created, ok := pending[index]
		if !ok {
			return nil, invalid("%s must name an earlier create op", id)
		}
		typeName, err := str(created, "type")
		if err != nil {
			return nil, err
		}
		t, ok := model.ParseObjectType(typeName)
		if !ok {
			return nil, invalid("%s must name an earlier create op", id)
		}
		typ = t
		props = asMap(created["props"])
		if props == nil {
			props = map[string]any{}
		}
		if patch, ok := p["props"]; ok {
			props, _ = model.Merge(props, patch).(map[string]any)
		}
		if w, ok := asMap(created["frame"])["w"].(float64); ok {
			baseWidth = &w
		}
		b, err := r.boardOf(created)
		if err != nil {
			return nil, err
		}
		root = pathRoot(b, typ, props)
	} else {
		b, err := r.boardForObject(id)
		if err != nil {
			return nil, err
		}
		o, err := b.Object(id)
		if err != nil {
			return nil, err
		}
		typ, props = o.Type, o.Props
		if patch, ok := p["props"]; ok {
			props, _ = model.Merge(props, patch).(map[string]any)
		}
		w := o.Frame.W
		baseWidth = &w
		root = pathRoot(b, typ, props)
	}
	if width == nil && typ != model.Code && typ != model.Image {
		width = baseWidth
	}
	w, h, err := measure.Size(typ, props, width, root)
	if err != nil {
		return nil, err
	}
	return &board.Size{W: w, H: h}, nil
}

// fitted resolves `size: "fit"` into a whole frame: the measured size at the given (or
// placed) origin; an update without an origin re-fits clear of what it didn't cover.
func (r *Router) fitted(method string, p map[string]any, size *board.Size) (map[string]any, error) {
	if size == nil {
		return p, nil
	}
	params := copyParams(p)
	delete(params, "size")
	frame := asMap(p["frame"])
	fx, hasX := frame["x"].(float64)
	fy, hasY := frame["y"].(float64)
	var x, y float64
	if method == "object.update" {
		id, err := str(p, "id")
		if err != nil {
			return nil, err
		}
		b, err := r.boardForObject(id)
		if err != nil {
			return nil, err
		}
		if !hasX && !hasY {
			f, err := b.RefitFrame(id, size.W, size.H)
			if err != nil {
				return nil, err
			}
			params["frame"] = f.JSON()
			return params, nil
		}
		current, err := b.Object(id)
		if err != nil {
			return nil, err
		}
		x, y = current.Frame.X, current.Frame.Y
		if hasX {
			x = fx
		}
		if hasY {
			y = fy
		}
	} else if hasX && hasY {
		x, y = fx, fy
	} else {
		b, err := r.boardOf(p)
		if err != nil {
			return nil, err
		}
		placed := b.Place(size.W, size.H, r.callerOf(p), nil, true)
		x, y = placed.X, placed.Y
	}
	params["frame"] = model.Frame{X: x, Y: y, W: size.W, H: size.H}.JSON()
	return params, nil
}
