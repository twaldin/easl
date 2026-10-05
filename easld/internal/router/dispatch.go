package router

import (
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/mention"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func (r *Router) dispatch(method string, p map[string]any) (any, error) {
	switch method {
	case "system.ping":
		return map[string]any{"version": float64(api.SchemaVersion), "app": "easl"}, nil
	case "board.get":
		return r.boardGet(p)
	case "board.history":
		return r.boardHistory(p)
	case "board.list":
		return r.boardList(), nil
	case "board.open":
		return r.boardOpen(p)
	case "board.export":
		b, err := r.boardOf(p)
		if err != nil {
			return nil, err
		}
		path, ok := optStr(p, "path")
		if !ok {
			path = ".easl/board.json"
		}
		out := store.Standardized(b.AbsolutePath(path))
		if err := store.Export(*b.Snapshot(), out); err != nil {
			return nil, fail(api.CodeUnavailable, "cannot write %s: %s", out, localizedDescription(err))
		}
		return map[string]any{"path": out, "objects": float64(len(b.Objects()))}, nil
	case "object.get":
		return r.objectGet(p)
	case "object.create":
		return r.create(p)
	case "object.update":
		return r.update(p)
	case "object.delete":
		id, err := str(p, "id")
		if err != nil {
			return nil, err
		}
		b, err := r.boardForObject(id)
		if err != nil {
			return nil, err
		}
		if err := b.Delete(id, r.callerOf(p)); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "layout.place":
		return r.layoutPlace(p)
	case "layout.stack":
		return r.layoutStack(p)
	case "layout.translate":
		return r.layoutTranslate(p)
	case "layout.grid":
		return r.layoutGrid(p)
	case "tray.list":
		b, err := r.boardOf(p)
		if err != nil {
			return nil, err
		}
		return map[string]any{"mentions": board.MentionsJSON(b.Tray())}, nil
	case "tray.stage":
		target, present := p["target"]
		if !present {
			return nil, invalid("missing target")
		}
		b, err := r.boardOf(p)
		if err != nil {
			return nil, err
		}
		canonical, err := mention.ValidateTarget(target)
		if err != nil {
			return nil, invalid("%s", err.Error())
		}
		m, err := b.Stage(canonical)
		if err != nil {
			return nil, err
		}
		return map[string]any{"mention": m.APIJSON()}, nil
	case "tray.unstage":
		id, err := str(p, "id")
		if err != nil {
			return nil, err
		}
		for _, b := range r.reg.SortedBoards() {
			for _, m := range b.Tray() {
				if m.ID == id {
					if err := b.Unstage(id); err != nil {
						return nil, err
					}
					return map[string]any{}, nil
				}
			}
		}
		return nil, board.NotFound("mention %s", id)
	case "tray.commit":
		b, err := r.boardOf(p)
		if err != nil {
			return nil, err
		}
		b.Commit(strings_(p["ids"]))
		return map[string]any{}, nil
	case "agent.report":
		tile, err := str(p, "tile")
		if err != nil {
			return nil, err
		}
		b, err := r.boardForObject(tile)
		if err != nil {
			return nil, err
		}
		if err := b.ReportParams(p); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "agent.report_session":
		tile, err := str(p, "tile")
		if err != nil {
			return nil, err
		}
		b, err := r.boardForObject(tile)
		if err != nil {
			return nil, err
		}
		kind, err := str(p, "kind")
		if err != nil {
			return nil, err
		}
		var sid, spath *string
		if s, ok := optStr(p, "sessionId"); ok {
			sid = &s
		}
		if s, ok := optStr(p, "sessionPath"); ok {
			spath = &s
		}
		if err := b.ReportSession(tile, kind, sid, spath); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "agent.release":
		tile, err := str(p, "tile")
		if err != nil {
			return nil, err
		}
		b, err := r.boardForObject(tile)
		if err != nil {
			return nil, err
		}
		if err := b.ReleaseAgent(tile); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "agent.list":
		agents := []any{}
		for _, b := range r.reg.SortedBoards() {
			ids := make([]string, 0)
			for id, o := range b.Objects() {
				if o.Type == model.Terminal {
					ids = append(ids, id)
				}
			}
			sort.Strings(ids)
			for _, id := range ids {
				agents = append(agents, agentEntry(b.Objects()[id], b))
			}
		}
		return map[string]any{"agents": agents}, nil
	case "follow.report":
		return r.followReport(p)
	case "view.attention":
		id, err := str(p, "id")
		if err != nil {
			return nil, err
		}
		b, err := r.boardForObject(id)
		if err != nil {
			return nil, err
		}
		if boolParam(p, "clear") {
			b.ClearAttention(id)
			return map[string]any{"id": id, "active": false}, nil
		}
		var message *string
		if s, ok := optStr(p, "message"); ok {
			message = &s
		}
		_, cleared, err := b.RaiseAttention(id, message, r.callerOf(p))
		if err != nil {
			return nil, err
		}
		result := map[string]any{"id": id, "active": true}
		if len(cleared) > 0 {
			list := make([]any, len(cleared))
			for i, c := range cleared {
				list[i] = c
			}
			result["cleared"] = list
		}
		return result, nil
	case "view.get":
		if _, err := r.boardOf(p); err != nil {
			return nil, err
		}
		return nil, fail(api.CodeUnsupported, "the viewport needs the app UI")
	}
	return nil, invalid("unknown method %s", method)
}

func localizedDescription(err error) string {
	if pe, ok := err.(*os.PathError); ok {
		return pe.Err.Error()
	}
	return err.Error()
}

// summarized trims heavy props in the manifest (board.get, object.find keyPrefix).
func summarized(o model.Object) model.Object {
	c := o
	if o.Type == model.HTML {
		if html, ok := o.Props["html"].(string); ok {
			c.Props = model.Merge(o.Props, map[string]any{"html": "(" + itoa(len(html)) + " bytes, use object.get)"}).(map[string]any)
		}
	}
	if o.Type == model.Note {
		if md, ok := o.Props["markdown"].(string); ok && utf8.RuneCountInString(md) > 400 {
			runes := []rune(md)
			c.Props = model.Merge(o.Props, map[string]any{"markdown": string(runes[:400]) + "…"}).(map[string]any)
		}
	}
	if o.Type == model.Code {
		if hist, ok := o.Props["history"].([]any); ok {
			c.Props = model.Merge(o.Props, map[string]any{"history": "(" + itoa(len(hist)) + " locations, use object.get)"}).(map[string]any)
		}
	}
	return c
}

func itoa(n int) string { return strconv.Itoa(n) }

func (r *Router) boardGet(p map[string]any) (any, error) {
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	snapshot := b.Snapshot().Objects
	var regions []string
	branch, hasBranch := optStr(p, "branch")
	if hasBranch {
		ids := b.ObjectsOfBranch(branch)
		var kept []model.Object
		for _, o := range snapshot {
			if ids[o.ID] {
				kept = append(kept, o)
			}
		}
		snapshot = kept
		regions = b.RegionsOfBranch(branch)
	}
	objects := []any{}
	for _, o := range b.Reported(snapshot) {
		objects = append(objects, objectJSON(summarized(o)))
	}
	result := map[string]any{"board": b.ID(), "root": b.Root(), "revision": float64(b.Revision()), "objects": objects}
	if hasBranch {
		list := []any{}
		for _, id := range regions {
			list = append(list, id)
		}
		result["regions"] = list
	}
	if since, ok := intParam(p, "since"); ok {
		changed := []any{}
		for _, id := range b.Changed(since) {
			changed = append(changed, id)
		}
		result["changed"] = changed
	}
	return result, nil
}

// parseISO8601 is Date(text, strategy: .iso8601).
func parseISO8601(text string) (time.Time, bool) {
	t, err := time.Parse("2006-01-02T15:04:05Z07:00", text)
	return t, err == nil
}

func (r *Router) boardHistory(p map[string]any) (any, error) {
	b, err := r.boardOf(p)
	if err != nil {
		return nil, err
	}
	var since board.Since
	switch v := p["since"].(type) {
	case float64:
		n := int(v)
		since.Seq = &n
	case string:
		t, ok := parseISO8601(v)
		if !ok {
			return nil, invalid("since must be a seq cursor or an ISO 8601 time")
		}
		since.Time = &t
	case nil:
	default:
		return nil, invalid("since must be a seq cursor or an ISO 8601 time")
	}
	limit := 100
	if n, ok := intParam(p, "limit"); ok {
		limit = n
	}
	limit = min(max(limit, 1), b.Activity.Capacity())
	var kinds map[string]bool
	if names, ok := p["kinds"].([]any); ok {
		kinds = map[string]bool{}
		for _, name := range names {
			s, ok := name.(string)
			known := false
			for _, k := range board.EntryKinds {
				if ok && k == s {
					known = true
				}
			}
			if !known {
				return nil, invalid("unknown history kind %s", describe(name))
			}
			kinds[s] = true
		}
	}
	page := b.Activity.Query(since, limit, kinds)
	entries := []any{}
	for _, e := range page.Entries {
		entries = append(entries, e.JSON())
	}
	return map[string]any{
		"board": b.ID(), "cursor": float64(page.Cursor), "entries": entries,
		"truncated": page.Truncated, "restarted": page.Restarted,
	}, nil
}

func (r *Router) boardList() any {
	stored := r.reg.Store.List()
	for _, b := range r.reg.SortedBoards() {
		index := -1
		for i, s := range stored {
			if s.ID == b.ID() {
				index = i
			}
		}
		if index < 0 {
			stored = append(stored, store.Stored{ID: b.ID()})
			index = len(stored) - 1
		}
		stored[index].Root = b.Root()
		stored[index].Archived = !store.IsDirectory(b.Root())
		stored[index].ObjectCount = len(b.Objects())
		stored[index].HasRepo = b.Repo != nil
		stored[index].Repo = ""
		stored[index].Worktrees = nil
		if b.Repo != nil {
			stored[index].Repo = b.Repo.CommonDir
			stored[index].Worktrees = b.Repo.WorktreeList(b.Objects())
		}
	}
	boards := []any{}
	for _, e := range stored {
		_, open := r.reg.Boards()[e.ID]
		info := map[string]any{"board": e.ID, "root": e.Root, "archived": e.Archived, "open": open, "objects": float64(e.ObjectCount)}
		if e.UpdatedAt != nil {
			info["updatedAt"] = model.FileTime(*e.UpdatedAt)
		}
		if e.HasRepo {
			info["repo"] = e.Repo
			list := []any{}
			for _, w := range e.Worktrees {
				list = append(list, w.JSON())
			}
			info["worktrees"] = list
		}
		boards = append(boards, info)
	}
	return map[string]any{"boards": boards}
}

func expandTilde(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return home + path[1:]
		}
	}
	return path
}

func (r *Router) boardOpen(p map[string]any) (any, error) {
	path, ok := optStr(p, "root")
	if !ok || path == "" {
		return nil, invalid("root is required")
	}
	expanded := expandTilde(path)
	if !strings.HasPrefix(expanded, "/") {
		return nil, invalid("root must be an absolute path (or start with ~)")
	}
	root := store.Standardized(expanded)
	if !store.IsDirectory(root) {
		return nil, board.NotFound("no directory at %s", root)
	}
	b := r.reg.Open(root)
	result := map[string]any{"board": b.ID(), "root": b.Root(), "objects": float64(len(b.Objects()))}
	if w := store.Containing(root); w != nil && b.Repo != nil && w.CommonDir == b.Repo.CommonDir {
		info := map[string]any{"path": w.Toplevel, "main": w.IsMain()}
		if branch, ok := w.Branch(); ok {
			info["branch"] = branch
		}
		if region := b.RegionFor(*w); region != "" {
			info["region"] = region
		}
		result["worktree"] = info
	}
	return result, nil
}

// --- layout ---

func (r *Router) layoutPlace(p map[string]any) (any, error) {
	id, err := str(p, "id")
	if err != nil {
		return nil, err
	}
	b, err := r.boardForObject(id)
	if err != nil {
		return nil, err
	}
	near, err := str(p, "near")
	if err != nil {
		return nil, err
	}
	if _, ok := b.Objects()[near]; !ok {
		return nil, board.NotFound("object %s on this board", near)
	}
	side, err := option(p, "side", board.LayoutSides, "right")
	if err != nil {
		return nil, err
	}
	gap, ok := num(p, "gap")
	if !ok {
		gap = board.DefaultLayoutGap
	}
	align, err := option(p, "align", board.LayoutAligns, "start")
	if err != nil {
		return nil, err
	}
	frames, err := b.PlaceNear(id, near, side, gap, align, r.callerOf(p))
	if err != nil {
		return nil, err
	}
	return map[string]any{"frames": board.FramesJSON(frames)}, nil
}

func (r *Router) idsOnOneBoard(p map[string]any) ([]string, *board.Board, error) {
	ids := strings_(p["ids"])
	if len(ids) == 0 {
		return nil, nil, invalid("ids must be a non-empty array of object ids")
	}
	return ids, nil, nil
}

func (r *Router) layoutStack(p map[string]any) (any, error) {
	ids, _, err := r.idsOnOneBoard(p)
	if err != nil {
		return nil, err
	}
	b, err := r.boardForObject(ids[0])
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		if _, ok := b.Objects()[id]; !ok {
			return nil, board.NotFound("object %s on this board", id)
		}
	}
	direction, err := option(p, "direction", board.LayoutDirections, "row")
	if err != nil {
		return nil, err
	}
	gap, ok := num(p, "gap")
	if !ok {
		gap = board.DefaultLayoutGap
	}
	var wrapAt *float64
	if w, ok := num(p, "wrapAt"); ok {
		wrapAt = &w
	}
	align, err := option(p, "align", board.LayoutAligns, "start")
	if err != nil {
		return nil, err
	}
	origin, err := point(p, "origin")
	if err != nil {
		return nil, err
	}
	frames, err := b.Stack(ids, direction, gap, wrapAt, align, origin, r.callerOf(p))
	if err != nil {
		return nil, err
	}
	return map[string]any{"frames": board.FramesJSON(frames)}, nil
}

func (r *Router) layoutTranslate(p map[string]any) (any, error) {
	ids, _, err := r.idsOnOneBoard(p)
	if err != nil {
		return nil, err
	}
	dx, ok1 := num(p, "dx")
	dy, ok2 := num(p, "dy")
	if !ok1 || !ok2 {
		return nil, invalid("dx and dy are required numbers")
	}
	b, err := r.boardForObject(ids[0])
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		if _, ok := b.Objects()[id]; !ok {
			return nil, board.NotFound("object %s on this board", id)
		}
	}
	frames, err := b.Translate(ids, dx, dy, r.callerOf(p))
	if err != nil {
		return nil, err
	}
	return map[string]any{"frames": board.FramesJSON(frames)}, nil
}

func (r *Router) layoutGrid(p map[string]any) (any, error) {
	raw, ok := p["cells"].([]any)
	if !ok || len(raw) == 0 {
		return nil, invalid("cells must be a non-empty array of {id, row, col}")
	}
	cells := make([]board.GridCell, len(raw))
	for i, c := range raw {
		m := asMap(c)
		id, ok1 := m["id"].(string)
		row, ok2 := board.TruncInt(m["row"])
		col, ok3 := board.TruncInt(m["col"])
		if !ok1 || !ok2 || !ok3 {
			return nil, invalid("each cell needs id, row, and col (integers)")
		}
		cells[i] = board.GridCell{ID: id, Row: row, Col: col}
	}
	b, err := r.boardForObject(cells[0].ID)
	if err != nil {
		return nil, err
	}
	for _, c := range cells {
		if _, ok := b.Objects()[c.ID]; !ok {
			return nil, board.NotFound("object %s on this board", c.ID)
		}
	}
	colGap, ok := num(p, "colGap")
	if !ok {
		colGap = board.DefaultLayoutGap
	}
	rowGap, ok := num(p, "rowGap")
	if !ok {
		rowGap = board.DefaultLayoutGap
	}
	colAlign, err := option(p, "colAlign", board.LayoutAligns, "start")
	if err != nil {
		return nil, err
	}
	rowAlign, err := option(p, "rowAlign", board.LayoutAligns, "start")
	if err != nil {
		return nil, err
	}
	origin, err := point(p, "origin")
	if err != nil {
		return nil, err
	}
	frames, grid, err := b.GridLayout(cells, colGap, rowGap, colAlign, rowAlign, origin, r.callerOf(p))
	if err != nil {
		return nil, err
	}
	columns, rows := []any{}, []any{}
	for _, t := range grid.Columns {
		columns = append(columns, map[string]any{"col": float64(t.Index), "x": t.Start, "w": t.Length})
	}
	for _, t := range grid.Rows {
		rows = append(rows, map[string]any{"row": float64(t.Index), "y": t.Start, "h": t.Length})
	}
	return map[string]any{"frames": board.FramesJSON(frames), "columns": columns, "rows": rows}, nil
}

// --- follow ---

func (r *Router) followReport(p map[string]any) (any, error) {
	tile, err := str(p, "tile")
	if err != nil {
		return nil, err
	}
	var rng *model.LineRange
	if v, present := p["range"]; present {
		lr, err := mention.DecodeLineRange(v)
		if err != nil {
			return nil, invalid("%s", err.Error())
		}
		rng = &lr
	}
	var changes []model.LineRange
	if v, present := p["changes"]; present {
		decoded, err := mention.DecodeLineRanges(v)
		if err != nil {
			return nil, invalid("%s", err.Error())
		}
		changes = decoded
	}
	b, err := r.boardForObject(tile)
	if err != nil {
		return nil, err
	}
	path, err := str(p, "path")
	if err != nil {
		return nil, err
	}
	action, err := str(p, "action")
	if err != nil {
		return nil, err
	}
	if _, _, err := b.Follow(tile, path, rng, changes, action); err != nil {
		return nil, err
	}
	return map[string]any{}, nil
}
