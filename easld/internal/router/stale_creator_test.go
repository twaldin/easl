package router

import (
	"reflect"
	"testing"
)

func TestBoardStaleCreatedByFiltersCreatorTile(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	alpha := idOf(f.result("object.create", terminal(map[string]any{"name": "alpha"})))
	beta := idOf(f.result("object.create", terminal(map[string]any{"name": "beta"})))
	owned := map[string]string{}
	for _, creator := range []string{alpha, beta} {
		p := note(0, map[string]any{"markdown": "Owned by " + creator})
		p["caller"] = creator
		owned[creator] = idOf(f.result("object.create", p))
	}
	f.result("object.create", note(0, map[string]any{"markdown": "User-owned"}))
	assertOnly := func(params map[string]any, id string, reasons []any) {
		t.Helper()
		objects := f.result("board.stale", params)["objects"].([]any)
		if len(objects) != 1 || objects[0].(map[string]any)["id"] != id || !reflect.DeepEqual(objects[0].(map[string]any)["reasons"], reasons) {
			t.Fatalf("filtered stale %v = %v, want only %s (%v)", params, objects, id, reasons)
		}
	}
	assertOnly(map[string]any{"olderThan": "0s", "createdBy": alpha}, owned[alpha], []any{"untouched"})
	assertOnly(map[string]any{"olderThan": "0s", "createdBy": beta}, owned[beta], []any{"untouched"})
	f.result("object.delete", map[string]any{"id": alpha})
	assertOnly(map[string]any{"createdBy": alpha}, owned[alpha], []any{"creator-gone"})
	for _, creator := range []string{"", "obj_never_existed", beta} {
		if got := f.result("board.stale", map[string]any{"createdBy": creator})["objects"]; !reflect.DeepEqual(got, []any{}) {
			t.Fatalf("creator %q unexpectedly matched: %v", creator, got)
		}
	}
}

func TestBoardStaleCreatedByRejectsNonStringsIncludingNull(t *testing.T) {
	f := newFixture(t)
	cleanupExpiryFixture(t, f)
	for _, value := range []any{nil, false, 1.0, []any{}, map[string]any{"tile": "obj_agent"}} {
		if code, _ := errorOf(f.call("board.stale", map[string]any{"createdBy": value})); code != "invalid_params" {
			t.Fatalf("createdBy %v was not rejected: %s", value, code)
		}
	}
}
