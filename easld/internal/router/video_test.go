package router

import (
	"encoding/binary"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/twaldin/easl/easld/internal/measure"
)

func TestVideoPropsSurviveUpdatesAndBoardReopen(t *testing.T) {
	f := newFixture(t)
	props := map[string]any{"path": "clip.mp4", "poster": "poster.png", "loop": true, "muted": false, "autoplay": false, "startTime": 1.25, "title": "Demo", "key": "demo"}
	created := f.result("object.create", map[string]any{"type": "video", "props": props})
	id := idOf(created)
	f.result("object.update", map[string]any{"id": id, "props": map[string]any{"startTime": 2.5, "title": "Edited"}})
	props["startTime"], props["title"] = 2.5, "Edited"
	f.result("board.close", map[string]any{"board": f.board.ID()})
	f.result("board.open", map[string]any{"root": f.board.Root()})
	got := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	if got["type"] != "video" || !reflect.DeepEqual(got["props"], props) {
		t.Fatalf("reopened video: %#v", got)
	}
}

func TestVideoRejectsInvalidPropsWithoutChangingTheObject(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", map[string]any{"type": "video", "props": map[string]any{"path": "clip.mp4"}}))
	for _, patch := range []map[string]any{
		{"startTime": -1.0}, {"startTime": "2"}, {"startTime": true}, {"loop": "true"}, {"muted": 1.0}, {"autoplay": "false"}, {"poster": 2.0}, {"title": false}, {"path": nil},
	} {
		code, _ := errorOf(f.call("object.update", map[string]any{"id": id, "props": patch}))
		if code != "invalid_params" {
			t.Fatalf("%#v: %s", patch, code)
		}
		creating := map[string]any{"path": "clip.mp4"}
		for key, value := range patch {
			creating[key] = value
		}
		code, _ = errorOf(f.call("object.create", map[string]any{"type": "video", "props": creating}))
		if code != "invalid_params" {
			t.Fatalf("create %#v: %s", patch, code)
		}
	}
	got := f.result("object.get", map[string]any{"id": id})["object"].(map[string]any)
	if !reflect.DeepEqual(got["props"], map[string]any{"path": "clip.mp4"}) {
		t.Fatal(got)
	}
}

func TestWorktreeVideoCreateAndReaimReadOriginalFileURIs(t *testing.T) {
	f := newFixture(t)
	root := f.board.Root()
	git(t, root, "init", "-q", "-b", "main")
	git(t, root, "commit", "-q", "--allow-empty", "-m", "seed")
	checkout := filepath.Join(t.TempDir(), "feature")
	git(t, root, "worktree", "add", "-q", "-b", "video-feature", checkout)
	caller := idOf(f.result("object.create", map[string]any{"type": "terminal", "props": map[string]any{"cwd": checkout}}))
	box := func(kind string, body []byte) []byte {
		value := make([]byte, len(body)+8)
		binary.BigEndian.PutUint32(value, uint32(len(value)))
		copy(value[4:], kind)
		copy(value[8:], body)
		return value
	}
	movie := func(width, height uint32) []byte {
		header := make([]byte, 84)
		binary.BigEndian.PutUint32(header[40:], 1<<16)
		binary.BigEndian.PutUint32(header[56:], 1<<16)
		binary.BigEndian.PutUint32(header[72:], 1<<30)
		binary.BigEndian.PutUint32(header[76:], width<<16)
		binary.BigEndian.PutUint32(header[80:], height<<16)
		handler := make([]byte, 12)
		copy(handler[8:], "vide")
		return box("moov", box("trak", append(box("tkhd", header), box("mdia", box("hdlr", handler))...)))
	}
	write := func(path string, bytes []byte) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, bytes, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	uri := func(path string) string { return (&url.URL{Scheme: "file", Path: path}).String() }
	clip := uri(filepath.Join(root, "clip space.mp4"))
	write(filepath.Join(root, "clip space.mp4"), movie(640, 360))
	write(filepath.Join(checkout, clip), movie(90, 160))
	write(filepath.Join(checkout, "relative.mp4"), movie(800, 600))
	for _, tc := range []struct {
		path string
		w, h float64
	}{
		{clip, 640, 360},
		{"FILE:" + clip[5:], 640, 360},
		{"relative.mp4", 800, 600},
	} {
		props := map[string]any{"path": tc.path}
		created := idOf(f.result("object.create", map[string]any{"type": "video", "caller": caller, "props": props}))
		reaimed := idOf(f.result("object.create", map[string]any{"type": "video", "props": map[string]any{"path": "before.mp4"}}))
		f.result("object.update", map[string]any{"id": reaimed, "caller": caller, "props": props})
		for _, id := range []string{created, reaimed} {
			stored := propsOf(f.result("object.get", map[string]any{"id": id})["object"].(map[string]any))
			w, h, err := measure.VideoNaturalSize(stored["path"].(string), root)
			if err != nil || w != tc.w || h != tc.h {
				t.Fatalf("video read %v x %v, %v; want %v x %v", w, h, err, tc.w, tc.h)
			}
		}
	}
	outside := filepath.Join(t.TempDir(), "outside.mp4")
	write(outside, movie(640, 360))
	for _, refused := range []string{uri(outside), "file://remote.example" + root + "/clip.mp4", "FILE://remote.example" + root + "/clip.mp4", "file://%zz" + root + "/clip.mp4"} {
		write(filepath.Join(checkout, refused), movie(90, 160))
		props := map[string]any{"path": refused}
		created := idOf(f.result("object.create", map[string]any{"type": "video", "caller": caller, "props": props}))
		reaimed := idOf(f.result("object.create", map[string]any{"type": "video", "props": map[string]any{"path": clip}}))
		f.result("object.update", map[string]any{"id": reaimed, "caller": caller, "props": props})
		for _, id := range []string{created, reaimed} {
			stored := propsOf(f.result("object.get", map[string]any{"id": id})["object"].(map[string]any))
			path := stored["path"].(string)
			_, _, err := measure.VideoNaturalSize(path, root)
			if failure, ok := err.(*measure.Failure); !ok || failure.Code != "invalid_params" {
				t.Fatalf("%q: got %v, want invalid_params", refused, err)
			}
		}
	}
}
