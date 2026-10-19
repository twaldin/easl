package router

import (
	"strings"
	"testing"
	"time"
)

func TestOversizedSurfacePayloadCannotDisconnectDrawingClient(t *testing.T) {
	f := newFixture(t)
	drawer := attachDrawer(t, f, "mch_home")
	viewer := newSurfaceViewer(t, f, allSurfaceEvents...)
	liveSurface(t, f, viewer, drawer, surfaceTile(f, "mch_home"), "str_payload")
	payload := strings.Repeat("/", 16<<20)
	for _, tc := range []struct {
		method string
		params map[string]any
	}{
		{"surface.input", map[string]any{"stream": "str_payload", "events": []any{map[string]any{"kind": "text", "seq": 1.0, "text": payload}}}},
		{"surface.answer", map[string]any{"stream": "str_payload", "dialog": "dlg_payload", "accept": true, "text": payload}},
		{"surface.ack", map[string]any{"stream": "str_payload", "frame": 0.0, "extra": payload}},
	} {
		t.Run(tc.method, func(t *testing.T) {
			done := f.onSurface(viewer, tc.method, tc.params)
			select {
			case request := <-drawer.incoming:
				answerSurface(f, drawer, request, map[string]any{})
				t.Fatal("oversized request reached drawing client")
			case reply := <-done:
				if code, _ := errorOf(reply); code != "invalid_params" {
					t.Fatalf("oversized request returned %s", code)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("oversized request did not finish")
			}
			if !drawer.IsOpen() || f.router.clients.ChooseExact("mch_home", f.board.ID(), "surface.ack") == nil {
				t.Fatal("oversized request detached drawing client")
			}
			f.router.surfaces.Push(drawer, []byte(surfaceFrame(f.board.ID(), "str_payload")))
			if got := viewer.relayed(); len(got) != 1 || got[0] != surfaceFrame(f.board.ID(), "str_payload") {
				t.Fatalf("live stream failed after rejection: %v", got)
			}
		})
	}
}
