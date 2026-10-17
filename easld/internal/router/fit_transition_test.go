package router

import (
	"math"
	"reflect"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

// Each character occupies ten pixels and each wrapped line is twenty pixels.
// The title bar is part of the returned frame, as it is for a real HTML tile.
type wrappingHTMLClient struct {
	router *Router
	asked  []map[string]any
	during func()
}

func (c *wrappingHTMLClient) Send(value any) bool {
	request := value.(map[string]any)
	if request["method"] != "object.measure" {
		return true
	}
	params := request["params"].(map[string]any)
	c.asked = append(c.asked, params)
	if c.during != nil {
		c.during()
	}
	width := 200.0
	if w, ok := params["width"].(float64); ok {
		width = w
	}
	body, _ := asMap(params["props"])["html"].(string)
	height := 26 + 20*math.Ceil(float64(len(body))*10/width)
	reply := sizeAnswer(width, height, nil)
	reply["id"] = request["id"]
	c.router.clients.Answer(c, reply)
	return true
}

func (c *wrappingHTMLClient) IsOpen() bool          { return true }
func (c *wrappingHTMLClient) Done() <-chan struct{} { return nil }

func fitOp(method string, params map[string]any) map[string]any {
	return map[string]any{"method": method, "params": params}
}

func TestHTMLCreateFitKeepsTheCallersBoardAfterCallerDeletion(t *testing.T) {
	f := newFixture(t)
	other, root := f.openBoard("caller-board")
	caller := idOf(f.result("object.create", map[string]any{
		"board": other, "type": "terminal", "props": map[string]any{},
		"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 400.0, "h": 300.0},
	}))
	app := &wrappingHTMLClient{router: f.router}
	app.during = func() {
		f.result("object.delete", map[string]any{"id": caller})
	}
	attachApp(f, app, map[string]any{"boards": []any{other}, "focused": other})
	created := f.result("object.create", map[string]any{
		"caller": caller, "type": "html", "props": htmlProps(strings.Repeat("x", 120)), "size": "fit",
		"frame": map[string]any{"x": 200.0, "y": 300.0, "w": 100.0},
	})
	id := idOf(created)
	if !reflect.DeepEqual(frameOf(f.result("object.get", map[string]any{"id": id})), map[string]any{"x": 200.0, "y": 300.0, "w": 100.0, "h": 266.0}) {
		t.Fatalf("committed frame = %v", frameOf(created))
	}
	if _, found := f.board.Objects()[id]; found {
		t.Fatal("the fitted page moved to the default board after its caller disappeared")
	}
	b, found := f.router.reg.Containing(id)
	if !found || b.ID() != other || b.Root() != root {
		t.Fatalf("committed destination = %v, want board %s rooted at %s", b, other, root)
	}
	if len(app.asked) != 1 || app.asked[0]["board"] != other || asMap(app.asked[0]["props"])["root"] != root {
		t.Fatalf("measurement destination = %v", app.asked)
	}
}

func TestHTMLBatchFitsSequentialContentAndWidth(t *testing.T) {
	for _, name := range []string{"existing", "pending", "pending-fit", "existing-upsert-alias", "pending-upsert-alias"} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			app := &wrappingHTMLClient{router: f.router}
			attachApp(f, app, nil)
			body := strings.Repeat("x", 120)
			frame := map[string]any{"x": 10.0, "y": 20.0, "w": 400.0, "h": 300.0}
			var ops []any
			var id string
			resultIndex := 0
			switch name {
			case "existing":
				id = idOf(f.result("object.create", htmlCreate("old", frame)))
				ops = []any{
					fitOp("object.update", map[string]any{"id": id, "props": htmlProps(body)}),
					fitOp("object.update", map[string]any{"id": id, "frame": map[string]any{"w": 100.0}}),
					fitOp("object.update", map[string]any{"id": id, "size": "fit"}),
				}
			case "pending":
				ops = []any{
					fitOp("object.create", htmlCreate("old", frame)),
					fitOp("object.update", map[string]any{"id": "$0", "props": htmlProps(body)}),
					fitOp("object.update", map[string]any{"id": "$0", "frame": map[string]any{"w": 100.0}}),
					fitOp("object.update", map[string]any{"id": "$0", "size": "fit"}),
				}
			case "pending-fit":
				ops = []any{
					fitOp("object.create", map[string]any{"type": "html", "props": htmlProps(body), "size": "fit", "frame": map[string]any{"x": 10.0, "y": 20.0}}),
					fitOp("object.update", map[string]any{"id": "$0", "size": "fit", "frame": map[string]any{"w": 100.0}}),
					fitOp("object.update", map[string]any{"id": "$0", "size": "fit"}),
				}
			case "existing-upsert-alias":
				props := htmlProps("old")
				props["key"] = "page"
				id = idOf(f.result("object.create", map[string]any{"type": "html", "props": props, "frame": frame}))
				ops = []any{
					fitOp("object.upsert", map[string]any{"key": "page", "type": "html", "props": htmlProps(body)}),
					fitOp("object.update", map[string]any{"id": "$0", "frame": map[string]any{"w": 100.0}}),
					fitOp("object.update", map[string]any{"id": "$0", "size": "fit"}),
				}
			case "pending-upsert-alias":
				ops = []any{
					fitOp("object.upsert", map[string]any{"key": "page", "type": "html", "props": htmlProps("old"), "frame": frame}),
					fitOp("object.upsert", map[string]any{"key": "page", "type": "html", "props": htmlProps(body)}),
					fitOp("object.update", map[string]any{"id": "$1", "frame": map[string]any{"w": 100.0}}),
					fitOp("object.update", map[string]any{"id": "$1", "size": "fit"}),
				}
				resultIndex = 1
			}
			revision := f.board.Revision()
			batch := f.result("object.batch", map[string]any{"ops": ops})
			results := batch["results"].([]any)
			if id == "" {
				id = idOf(results[resultIndex].(map[string]any))
			}
			got := f.result("object.get", map[string]any{"id": id})
			wantFrame := map[string]any{"x": 10.0, "y": 20.0, "w": 100.0, "h": 266.0}
			if !reflect.DeepEqual(frameOf(got), wantFrame) || asMap(asMap(got["object"])["props"])["html"] != body {
				t.Fatalf("committed object = %v, want latest content and frame %v", got, wantFrame)
			}
			if !reflect.DeepEqual(frameOf(results[len(results)-1].(map[string]any)), wantFrame) {
				t.Fatalf("fit result = %v", results[len(results)-1])
			}
			if f.board.Revision() != revision+1 || batch["revision"] != float64(revision+1) || len(f.board.Objects()) != 1 {
				t.Fatalf("batch did not commit one object in one revision: %v", batch)
			}
			if name == "pending-fit" {
				first := frameOf(results[0].(map[string]any))
				if first["w"] != 200.0 || first["h"] != 146.0 {
					t.Fatalf("initial fit = %v", first)
				}
			}
		})
	}
}

func TestHTMLBatchFitsAfterSequentialLayout(t *testing.T) {
	f := newFixture(t)
	app := &wrappingHTMLClient{router: f.router}
	attachApp(f, app, nil)
	batch := f.result("object.batch", map[string]any{"ops": []any{
		fitOp("object.create", htmlCreate("old", map[string]any{"x": 0.0, "y": 0.0, "w": 400.0, "h": 300.0})),
		fitOp("object.update", map[string]any{"id": "$0", "props": htmlProps(strings.Repeat("x", 120)), "frame": map[string]any{"w": 100.0}}),
		fitOp("object.create", htmlCreate(strings.Repeat("y", 30), map[string]any{"x": 800.0, "y": 0.0, "w": 80.0, "h": 60.0})),
		fitOp("layout.stack", map[string]any{"ids": []any{"$0", "$2"}, "origin": map[string]any{"x": 1000.0, "y": 2000.0}}),
		fitOp("object.update", map[string]any{"id": "$0", "size": "fit"}),
		fitOp("object.update", map[string]any{"id": "$2", "size": "fit"}),
	}})
	results := batch["results"].([]any)
	for _, expected := range []struct {
		index int
		frame map[string]any
	}{
		{0, map[string]any{"x": 1000.0, "y": 2000.0, "w": 100.0, "h": 266.0}},
		{2, map[string]any{"x": 1140.0, "y": 2000.0, "w": 80.0, "h": 106.0}},
	} {
		id := idOf(results[expected.index].(map[string]any))
		got := f.result("object.get", map[string]any{"id": id})
		if !reflect.DeepEqual(frameOf(got), expected.frame) {
			t.Fatalf("committed frame = %v, want %v", frameOf(got), expected.frame)
		}
	}
}

func TestHTMLBatchInvalidPrefixLeavesTheLiveObjectsUnchanged(t *testing.T) {
	for _, name := range []string{"invalid-frame", "deleted-existing", "deleted-pending-upsert"} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			id := idOf(f.result("object.create", htmlCreate("old", map[string]any{"x": 10.0, "y": 20.0, "w": 400.0, "h": 300.0})))
			app := &wrappingHTMLClient{router: f.router}
			attachApp(f, app, nil)
			var ops []any
			wantCode := "not_found"
			switch name {
			case "invalid-frame":
				wantCode = "invalid_params"
				ops = []any{
					fitOp("object.update", map[string]any{"id": id, "props": htmlProps("must not commit"), "frame": map[string]any{"w": "invalid"}}),
					fitOp("object.update", map[string]any{"id": id, "size": "fit"}),
				}
			case "deleted-existing":
				ops = []any{
					fitOp("object.delete", map[string]any{"id": id}),
					fitOp("object.update", map[string]any{"id": id, "size": "fit"}),
				}
			case "deleted-pending-upsert":
				ops = []any{
					fitOp("object.upsert", map[string]any{"key": "page", "type": "html", "props": htmlProps("pending"), "frame": map[string]any{"x": 1000.0, "y": 0.0, "w": 100.0, "h": 100.0}}),
					fitOp("object.upsert", map[string]any{"key": "page", "type": "html", "props": htmlProps("updated")}),
					fitOp("object.delete", map[string]any{"id": "$1"}),
					fitOp("object.update", map[string]any{"id": "$0", "size": "fit"}),
				}
			}
			code, message := errorOf(f.call("object.batch", map[string]any{"ops": ops}))
			if code != wantCode || !strings.Contains(message, "op ") {
				t.Fatalf("invalid prefix = %s %s, want %s", code, message, wantCode)
			}
			o := f.board.Objects()[id]
			if len(f.board.Objects()) != 1 || o.Props["html"] != "old" || o.Frame != (model.Frame{X: 10, Y: 20, W: 400, H: 300}) {
				t.Fatalf("failed batch changed the live board: %v", f.board.Objects())
			}
		})
	}
}

func TestHTMLBatchReadsConcurrentChangesBeforeTheFirstUseOfAnObject(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", htmlCreate("old", map[string]any{"x": 10.0, "y": 20.0, "w": 400.0, "h": 300.0})))
	app := &wrappingHTMLClient{router: f.router}
	changed := false
	app.during = func() {
		if !changed {
			changed = true
			f.result("object.update", map[string]any{"id": id, "props": htmlProps("external page")})
		}
	}
	attachApp(f, app, nil)
	batch := f.result("object.batch", map[string]any{"ops": []any{
		fitOp("object.create", map[string]any{"type": "html", "props": htmlProps("first"), "size": "fit", "frame": map[string]any{"x": 1000.0, "y": 0.0, "w": 100.0}}),
		fitOp("object.update", map[string]any{"id": id, "size": "fit"}),
	}})
	o := f.board.Objects()[id]
	if len(f.board.Objects()) != 2 || o.Props["html"] != "external page" || o.Frame != (model.Frame{X: 10, Y: 20, W: 400, H: 46}) {
		t.Fatalf("a later read used stale snapshot content: %v, objects %v", batch, f.board.Objects())
	}
}

func TestHTMLBatchSequentialPlanPreservesConcurrentWrites(t *testing.T) {
	for _, change := range []string{"unrelated", "read-object", "deleted-read-object"} {
		t.Run(change, func(t *testing.T) {
			f := newFixture(t)
			id := idOf(f.result("object.create", htmlCreate("old", map[string]any{"x": 10.0, "y": 20.0, "w": 400.0, "h": 300.0})))
			spare := idOf(f.result("object.create", note(1000, map[string]any{"markdown": "spare"})))
			app := &wrappingHTMLClient{router: f.router}
			app.during = func() {
				visible := f.result("object.get", map[string]any{"id": id})
				if frameOf(visible)["w"] != 400.0 || asMap(asMap(visible["object"])["props"])["html"] != "old" {
					t.Fatalf("the uncommitted batch was visible while measuring: %v", visible)
				}
				f.result("object.update", map[string]any{"id": spare, "props": map[string]any{"markdown": "external write"}})
				if change == "read-object" {
					f.result("object.update", map[string]any{"id": id, "props": htmlProps("external page")})
				} else if change == "deleted-read-object" {
					f.result("object.delete", map[string]any{"id": id})
				}
			}
			attachApp(f, app, nil)
			reply := f.call("object.batch", map[string]any{"ops": []any{
				fitOp("object.update", map[string]any{"id": id, "props": htmlProps(strings.Repeat("x", 120)), "frame": map[string]any{"w": 100.0}}),
				fitOp("object.update", map[string]any{"id": id, "size": "fit"}),
			}})
			if f.board.Objects()[spare].Props["markdown"] != "external write" {
				t.Fatalf("the batch discarded an unrelated external write: %v", reply)
			}
			switch change {
			case "unrelated":
				if reply["ok"] != true || f.board.Objects()[id].Frame != (model.Frame{X: 10, Y: 20, W: 100, H: 266}) {
					t.Fatalf("sequential fit did not preserve the unrelated write: %v", reply)
				}
			case "read-object":
				code, message := errorOf(reply)
				o := f.board.Objects()[id]
				if code != "conflict" || !strings.Contains(message, id) || o.Props["html"] != "external page" || o.Frame != (model.Frame{X: 10, Y: 20, W: 400, H: 300}) {
					t.Fatalf("stale plan overwrote the read object: %v, object %v", reply, o)
				}
			case "deleted-read-object":
				code, message := errorOf(reply)
				_, exists := f.board.Objects()[id]
				if code != "conflict" || !strings.Contains(message, id) || exists {
					t.Fatalf("stale plan restored the deleted object: %v", reply)
				}
			}
		})
	}
}
