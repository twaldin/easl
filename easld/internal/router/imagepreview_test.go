package router

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"github.com/twaldin/easl/easld/internal/measure"
	"golang.org/x/sys/unix"
)

func previewPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	im := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := range h {
		for x := range w {
			alpha := uint8(127)
			if x < w/2 {
				alpha = 0
			}
			im.SetNRGBA(x, y, color.NRGBA{uint8(x*19 + y*37), uint8(x*41 + y*7), uint8(x * y), alpha})
		}
	}
	var b bytes.Buffer
	if err := (&png.Encoder{CompressionLevel: png.NoCompression}).Encode(&b, im); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func previewObject(t *testing.T, f *fixture, path string) string {
	t.Helper()
	return idOf(f.result("object.create", map[string]any{"type": "image", "props": map[string]any{"path": path}, "frame": map[string]any{"x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0}}))
}

func TestImagePreviewConsumerDimensionsAlphaAndVersion(t *testing.T) {
	for _, size := range [][4]int{{641, 319, 128, 64}, {319, 641, 64, 128}, {1024, 1, 128, 1}} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			f := newFixture(t)
			path := filepath.Join(f.board.Root(), "preview.png")
			data := previewPNG(t, size[0], size[1])
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			id := previewObject(t, f, "preview.png")
			p := map[string]any{"id": id, "maxPixels": 128.0}
			got := f.result("image.preview", p)
			if got["kind"] != "preview" || got["naturalWidth"] != size[0] || got["naturalHeight"] != size[1] || got["width"] != size[2] || got["height"] != size[3] {
				t.Fatalf("preview dimensions: %v", got)
			}
			encoded, err := base64.StdEncoding.DecodeString(got["data"].(string))
			if err != nil || len(encoded) >= len(data) {
				t.Fatalf("preview payload: bytes=%d original=%d err=%v", len(encoded), len(data), err)
			}
			decoded, err := png.Decode(bytes.NewReader(encoded))
			if err != nil {
				t.Fatal(err)
			}
			if decoded.Bounds().Dx() != size[2] || decoded.Bounds().Dy() != size[3] {
				t.Fatal(decoded.Bounds())
			}
			_, _, _, alpha := decoded.At(0, 0).RGBA()
			if alpha != 0 {
				t.Fatalf("transparent pixel became opaque: %d", alpha)
			}
			_, _, _, alpha = decoded.At(size[2]-1, 0).RGBA()
			if alpha != 127*257 {
				t.Fatalf("partial alpha changed: %d", alpha)
			}
			version := got["version"].(measure.ImageVersion)
			var st unix.Stat_t
			if err := unix.Stat(path, &st); err != nil {
				t.Fatal(err)
			}
			stamp := fmt.Sprintf("%d:%d:%d:%d:%d", st.Dev, st.Ino, st.Size, st.Mtim.Sec*1_000_000_000+st.Mtim.Nsec, st.Ctim.Sec*1_000_000_000+st.Ctim.Nsec)
			if version.Root != f.board.Root() || version.Path != path || version.Stamp != stamp {
				t.Fatalf("version=%+v expected stamp=%s", version, stamp)
			}
			if err := os.WriteFile(path, append(data, 0), 0600); err != nil {
				t.Fatal(err)
			}
			next := f.result("image.preview", p)["version"].(measure.ImageVersion)
			if next.Stamp == version.Stamp {
				t.Fatal("changed source reused old version")
			}
		})
	}
}

func previewChunk(kind string, data []byte) []byte {
	chunk := make([]byte, len(data)+12)
	binary.BigEndian.PutUint32(chunk, uint32(len(data)))
	copy(chunk[4:], kind)
	copy(chunk[8:], data)
	binary.BigEndian.PutUint32(chunk[len(chunk)-4:], crc32.ChecksumIEEE(chunk[4:len(chunk)-4]))
	return chunk
}

func TestImagePreviewOriginalSelectionAndCorruptRaster(t *testing.T) {
	large := previewPNG(t, 512, 256)
	animation := append(append(append([]byte{}, large[:33]...), previewChunk("acTL", []byte{0, 0, 0, 2, 0, 0, 0, 0})...), large[33:]...)
	exif := []byte{'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0}
	oriented := append(append(append([]byte{}, large[:33]...), previewChunk("eXIf", exif)...), large[33:]...)
	var smallJPEG bytes.Buffer
	if err := jpeg.Encode(&smallJPEG, image.NewRGBA(image.Rect(0, 0, 128, 128)), &jpeg.Options{Quality: 1}); err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{"animation": animation, "orientation": oriented, "fullsize": previewPNG(t, 32, 32), "unsupported": []byte("<svg/>"), "jpeg": smallJPEG.Bytes()} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			if err := os.WriteFile(filepath.Join(f.board.Root(), "source"), data, 0600); err != nil {
				t.Fatal(err)
			}
			id := previewObject(t, f, "source")
			got := f.result("image.preview", map[string]any{"id": id, "maxPixels": 128.0})
			if got["kind"] != "original" || len(got) != 1 {
				t.Fatalf("expected explicit original: %v", got)
			}
		})
	}
	f := newFixture(t)
	if err := os.WriteFile(filepath.Join(f.board.Root(), "broken"), large[:45], 0600); err != nil {
		t.Fatal(err)
	}
	id := previewObject(t, f, "broken")
	if code, _ := errorOf(f.call("image.preview", map[string]any{"id": id, "maxPixels": 128.0})); code != "unreadable" {
		t.Fatalf("corrupt raster code=%s", code)
	}
}

func TestImagePreviewAuthorizationAndRequestErrors(t *testing.T) {
	f := newFixture(t)
	outside := filepath.Join(t.TempDir(), "outside.png")
	if err := os.WriteFile(outside, previewPNG(t, 512, 256), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(f.board.Root(), "escape.png")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{outside, "escape.png", "../outside.png", "~/secret", "https://example.com/image.png", "file://elsewhere/secret"} {
		id := previewObject(t, f, path)
		if code, _ := errorOf(f.call("image.preview", map[string]any{"id": id, "maxPixels": 128.0})); code != "refused" {
			t.Errorf("%s code=%s", path, code)
		}
	}
	missing := previewObject(t, f, "missing.png")
	for _, value := range []any{nil, "128", true, 63.0, 2049.0, 128.5} {
		if code, _ := errorOf(f.call("image.preview", map[string]any{"id": missing, "maxPixels": value})); code != "invalid_params" {
			t.Errorf("pixels=%v code=%s", value, code)
		}
	}
	if code, _ := errorOf(f.call("image.preview", map[string]any{"id": missing, "maxPixels": 128.0})); code != "not_found" {
		t.Fatal(code)
	}
	wrong := idOf(f.result("object.create", note(0, map[string]any{"text": "not an image"})))
	if code, _ := errorOf(f.call("image.preview", map[string]any{"id": wrong, "maxPixels": 128.0})); code != "invalid_params" {
		t.Fatal(code)
	}
	big := filepath.Join(f.board.Root(), "big.png")
	file, err := os.Create(big)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(measure.ImageFileLimit + 1); err != nil {
		t.Fatal(err)
	}
	file.Close()
	id := previewObject(t, f, "big.png")
	if code, _ := errorOf(f.call("image.preview", map[string]any{"id": id, "maxPixels": 128.0})); code != "too_large" {
		t.Fatal(code)
	}
}
