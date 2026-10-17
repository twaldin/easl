package router

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestCodeAnchorsStayWithinBoardPolicyOnWrites(t *testing.T) {
	f := newFixture(t)
	const marker = "DO_NOT_SHOW_OUTSIDE_HOST_68c1"
	outside := filepath.Join(filepath.Dir(f.board.Root()), "outside.rs")
	if err := os.WriteFile(outside, []byte(marker+"\nsecond outside line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(f.board.Root(), "escape.rs")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.board.Root(), "inside.rs"), []byte("inside anchor\ninside second\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{outside, "../outside.rs", "escape.rs"} {
		for _, authored := range []any{nil, "  " + marker + "  "} {
			props := map[string]any{"path": path, "range": model.LineRange{Start: 1, End: 1}.JSON()}
			if authored != nil {
				props["anchor"] = authored
			}
			created := f.result("object.create", codeAnchorCreate(props))
			id := idOf(created)
			assertCodeAnchorReplies(t, f, id, path, 1, authored)
			f.result("object.update", map[string]any{"id": id, "props": map[string]any{"range": model.LineRange{Start: 2, End: 2}.JSON(), "anchor": authored}})
			assertCodeAnchorReplies(t, f, id, path, 2, authored)
			f.result("object.update", map[string]any{"id": id, "props": map[string]any{"range": model.LineRange{Start: 1, End: 1}.JSON(), "anchor": "authored value"}})
			assertCodeAnchorReplies(t, f, id, path, 1, "authored value")
		}
		inside := idOf(f.result("object.create", codeAnchorCreate(map[string]any{"path": "inside.rs", "range": model.LineRange{Start: 1, End: 1}.JSON()})))
		assertCodeAnchorReplies(t, f, inside, "inside.rs", 1, "inside anchor")
		f.result("object.update", map[string]any{"id": inside, "props": map[string]any{"path": path, "anchor": nil}})
		assertCodeAnchorReplies(t, f, inside, path, 1, nil)
		f.result("object.update", map[string]any{"id": inside, "props": map[string]any{"path": "inside.rs", "anchor": nil}})
		assertCodeAnchorReplies(t, f, inside, "inside.rs", 1, "inside anchor")
	}
	inside := idOf(f.result("object.create", codeAnchorCreate(map[string]any{"path": "inside.rs", "range": model.LineRange{Start: 1, End: 1}.JSON()})))
	if err := os.WriteFile(filepath.Join(f.board.Root(), "inside.rs"), []byte("inserted\ninside anchor\ninside second\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.result("object.update", map[string]any{"id": inside, "props": map[string]any{"caption": "refresh"}})
	assertCodeAnchorReplies(t, f, inside, "inside.rs", 2, "inside anchor")
}

func TestCodeAnchorsStayWithinBoardPolicyOnUpsertAndBatch(t *testing.T) {
	f := newFixture(t)
	outside := filepath.Join(t.TempDir(), "outside.rs")
	if err := os.WriteFile(outside, []byte("outside anchor\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.board.Root(), "inside.rs"), []byte("inside anchor\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	params := codeAnchorCreate(map[string]any{"path": outside, "range": model.LineRange{Start: 1, End: 1}.JSON()})
	params["key"] = "code-policy"
	id := idOf(f.result("object.upsert", params))
	assertCodeAnchorReplies(t, f, id, outside, 1, nil)
	params["props"] = map[string]any{"path": "inside.rs", "range": model.LineRange{Start: 1, End: 1}.JSON(), "anchor": nil}
	f.result("object.upsert", params)
	assertCodeAnchorReplies(t, f, id, "inside.rs", 1, "inside anchor")
	batch := f.result("object.batch", map[string]any{"ops": []any{
		map[string]any{"method": "object.create", "params": codeAnchorCreate(map[string]any{"path": outside, "range": model.LineRange{Start: 1, End: 1}.JSON()})},
		map[string]any{"method": "object.update", "params": map[string]any{"id": id, "props": map[string]any{"path": outside, "anchor": "authored value"}}},
		map[string]any{"method": "object.create", "params": codeAnchorCreate(map[string]any{"path": "inside.rs", "range": model.LineRange{Start: 1, End: 1}.JSON()})},
	}})
	results := batch["results"].([]any)
	assertCodeAnchorReplies(t, f, idOf(results[0].(map[string]any)), outside, 1, nil)
	assertCodeAnchorReplies(t, f, id, outside, 1, "authored value")
	assertCodeAnchorReplies(t, f, idOf(results[2].(map[string]any)), "inside.rs", 1, "inside anchor")
}

func codeAnchorCreate(props map[string]any) map[string]any {
	return map[string]any{
		"type": "code", "props": props,
		"frame": map[string]any{"x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0},
	}
}

func assertCodeAnchorReplies(t *testing.T, f *fixture, id, path string, line int, anchor any) {
	t.Helper()
	object := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	objects := []map[string]any{object}
	found := false
	for _, raw := range f.result("board.get", map[string]any{})["objects"].([]any) {
		o := raw.(map[string]any)
		if o["id"] == id {
			objects = append(objects, o)
			found = true
		}
	}
	if !found {
		t.Fatalf("board.get did not return %s", id)
	}
	for _, o := range objects {
		props := o["props"].(map[string]any)
		if props["path"] != path || props["anchor"] != anchor || !model.Equal(props["range"], model.LineRange{Start: line, End: line}.JSON()) {
			t.Errorf("persisted %s props %v, want path %q range %d anchor %v", id, props, path, line, anchor)
		}
	}
}
