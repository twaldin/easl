package router

import (
	"math"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestSurfaceAnswerRejectsInvalidUploadsWithoutDisturbingDrawingStreams(t *testing.T) {
	f := newFixture(t)
	drawer := attachDrawer(t, f, "mch_home")
	viewer := newSurfaceViewer(t, f, allSurfaceEvents...)
	other := newSurfaceViewer(t, f, allSurfaceEvents...)
	liveSurface(t, f, viewer, drawer, surfaceTile(f, "mch_home"), "str_upload")
	liveSurface(t, f, other, drawer, surfaceTile(f, "mch_home"), "str_other")
	client := f.router.clients.ChooseExact("mch_home", f.board.ID(), "surface.answer")
	file := func(data string) map[string]any {
		return map[string]any{"name": "upload.bin", "type": "application/octet-stream", "data": data}
	}
	with := func(key string, value any) map[string]any {
		fields := file("")
		fields[key] = value
		return fields
	}
	tooMany := make([]any, 33)
	for i := range tooMany {
		tooMany[i] = file("")
	}
	cases := []struct {
		name  string
		files any
	}{
		{"null", nil},
		{"object", map[string]any{}},
		{"empty selection", []any{}},
		{"too many files", tooMany},
		{"nonobject file", []any{"upload.bin"}},
		{"missing fields", []any{map[string]any{"name": "upload.bin"}}},
		{"unknown field", []any{with("path", "/tmp/upload.bin")}},
		{"nonstring data", []any{with("data", 0.0)}},
		{"nonstring name", []any{with("name", false)}},
		{"nonstring type", []any{with("type", nil)}},
		{"empty name", []any{with("name", "")}},
		{"name UTF-8 limit", []any{with("name", strings.Repeat("é", 513))}},
		{"type UTF-8 limit", []any{with("type", strings.Repeat("é", 129))}},
		{"null modified", []any{with("modified", nil)}},
		{"string modified", []any{with("modified", "0")}},
		{"negative modified", []any{with("modified", -1.0)}},
		{"infinite modified", []any{with("modified", math.Inf(1))}},
		{"NaN modified", []any{with("modified", math.NaN())}},
		{"unpadded base64", []any{file("Zg")}},
		{"base64 whitespace", []any{file("Zg\n=")}},
		{"base64 URL alphabet", []any{file("____")}},
		{"base64 Unicode", []any{file("é==")}},
		{"embedded padding", []any{file("Z=g=")}},
		{"excess padding", []any{file("Z===")}},
		{"12 MiB slash payload", []any{file(strings.Repeat("/", 16<<20))}},
		{"one byte over limit", []any{file(strings.Repeat("/", 11184812))}},
		{"aggregate over limit", []any{file(strings.Repeat("/", 5592404) + "/w=="), file(strings.Repeat("/", 5592404) + "/w=="), file("/w==")}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			params := map[string]any{"stream": "str_upload", "dialog": "dlg_upload", "accept": true, "files": tc.files}
			done := f.onSurface(viewer, "surface.answer", params)
			select {
			case request := <-drawer.incoming:
				answerSurface(f, drawer, request, map[string]any{})
				t.Fatalf("invalid upload was delegated as %v", request["method"])
			case reply := <-done:
				if code, _ := errorOf(reply); code != "invalid_params" {
					t.Fatalf("upload answered %s, want invalid_params", code)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("invalid upload neither rejected nor delegated")
			}
			if len(drawer.incoming) != 0 {
				t.Fatal("rejected upload sent a request to the drawing Mac")
			}
			if got := f.router.clients.ChooseExact("mch_home", f.board.ID(), "surface.answer"); got != client || !drawer.IsOpen() {
				t.Fatal("rejected upload detached the drawing Mac")
			}
			for _, stream := range []string{"str_upload", "str_other"} {
				f.router.surfaces.Push(drawer, []byte(surfaceFrame(f.board.ID(), stream)))
			}
			if got := viewer.relayed(); !reflect.DeepEqual(got, []string{surfaceFrame(f.board.ID(), "str_upload")}) {
				t.Fatalf("upload stream frames after rejection: %v", got)
			}
			if got := other.relayed(); !reflect.DeepEqual(got, []string{surfaceFrame(f.board.ID(), "str_other")}) {
				t.Fatalf("other stream frames after rejection: %v", got)
			}
			if len(viewer.closed()) != 0 || len(other.closed()) != 0 {
				t.Fatal("rejected upload closed a stream")
			}
		})
	}
}

func TestSurfaceAnswerAcceptsUploadBoundaries(t *testing.T) {
	f := newFixture(t)
	drawer := attachDrawer(t, f, "mch_home")
	viewer := newSurfaceViewer(t, f, allSurfaceEvents...)
	liveSurface(t, f, viewer, drawer, surfaceTile(f, "mch_home"), "str_upload")
	file := func(data string) map[string]any {
		return map[string]any{"name": "upload.bin", "type": "application/octet-stream", "data": data}
	}
	many := make([]any, 32)
	for i := range many {
		many[i] = file("")
	}
	metadata := map[string]any{"name": strings.Repeat("é", 512), "type": strings.Repeat("é", 128), "modified": 0.0, "data": "AA=="}
	for _, tc := range []struct {
		name  string
		files []any
	}{
		{"omitted", nil},
		{"32 files", many},
		{"metadata boundaries", []any{metadata}},
		{"8 MiB worst slash boundary", []any{file(strings.Repeat("/", 11184810) + "8=")}},
		{"8 MiB aggregate boundary", []any{file(strings.Repeat("/", 5592404) + "/w=="), file(strings.Repeat("/", 5592404) + "/w==")}},
		{"Swift-compatible nonzero pad bits", []any{file("/x==")}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			params := map[string]any{"stream": "str_upload", "dialog": "dlg_upload", "accept": true}
			if tc.files != nil {
				params["files"] = tc.files
			}
			done := f.onSurface(viewer, "surface.answer", params)
			var request map[string]any
			select {
			case request = <-drawer.incoming:
			case reply := <-done:
				t.Fatalf("valid upload was not delegated: %v", reply)
			case <-time.After(5 * time.Second):
				t.Fatal("valid upload was not delegated")
			}
			answerSurface(f, drawer, request, map[string]any{})
			if reply := surfaceReply(t, done); reply["ok"] != true {
				t.Fatalf("upload answer: %v", reply)
			}
		})
	}
}
