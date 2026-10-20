package measure

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func TestBoardImagePreviewPreservesGammaBySelectingOriginal(t *testing.T) {
	root := t.TempDir()
	source := image.NewNRGBA(image.Rect(0, 0, 512, 256))
	for y := range 256 {
		for x := range 512 {
			source.SetNRGBA(x, y, color.NRGBA{uint8(x*17 + y), uint8(x + y*37), uint8(x * y), 255})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, source); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "gamma.png")
	if err := os.WriteFile(path, encoded.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	plain, err := BoardImagePreview(root, "gamma.png", 64)
	if err != nil || plain == nil {
		t.Fatalf("plain preview=%v err=%v", plain, err)
	}
	chunk := make([]byte, 16)
	binary.BigEndian.PutUint32(chunk[:4], 4)
	copy(chunk[4:8], "gAMA")
	binary.BigEndian.PutUint32(chunk[8:12], 100000)
	binary.BigEndian.PutUint32(chunk[12:16], crc32.ChecksumIEEE(chunk[4:12]))
	data := encoded.Bytes()
	profiled := append(append(append([]byte{}, data[:33]...), chunk...), data[33:]...)
	if _, err := png.Decode(bytes.NewReader(profiled)); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, profiled, 0600); err != nil {
		t.Fatal(err)
	}
	preview, err := BoardImagePreview(root, "gamma.png", 64)
	if err != nil || preview != nil {
		t.Fatalf("gamma-tagged source must retain original bytes: preview=%v err=%v", preview, err)
	}
}

func TestBoardImagePreviewRetainsLexicalRootAndResolvedPath(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "real")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(dir, "alias")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	im := image.NewNRGBA(image.Rect(0, 0, 512, 256))
	for y := range 256 {
		for x := range 512 {
			im.Set(x, y, color.NRGBA{uint8(x*17 + y), uint8(x + y*37), uint8(x * y), 127})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, im); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "source.png")
	if err := os.WriteFile(path, encoded.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	preview, err := BoardImagePreview(alias, "source.png", 64)
	if err != nil || preview == nil {
		t.Fatalf("preview=%v err=%v", preview, err)
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	if preview.Version.Root != alias || preview.Version.Path != resolved {
		t.Fatalf("version=%+v", preview.Version)
	}
}

func TestBoardImagePreviewAllocationLimitAndSizeGrowth(t *testing.T) {
	root := t.TempDir()
	im := image.NewRGBA(image.Rect(0, 0, 128, 128))
	for y := range 128 {
		for x := range 128 {
			im.Set(x, y, color.RGBA{uint8(x*17 + y*53), uint8(x*73 + y*29), uint8(x * y * 13), 255})
		}
	}
	var jpegData bytes.Buffer
	if err := jpeg.Encode(&jpegData, im, &jpeg.Options{Quality: 1}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "growth.jpg"), jpegData.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	preview, err := BoardImagePreview(root, "growth.jpg", 64)
	if err != nil || preview != nil {
		t.Fatalf("size-growing preview=%v err=%v", preview, err)
	}

	var pngData bytes.Buffer
	if err := png.Encode(&pngData, image.NewRGBA(image.Rect(0, 0, 1, 1))); err != nil {
		t.Fatal(err)
	}
	large := pngData.Bytes()
	binary.BigEndian.PutUint32(large[16:20], 16000001)
	binary.BigEndian.PutUint32(large[29:33], crc32.ChecksumIEEE(large[12:29]))
	if err := os.WriteFile(filepath.Join(root, "huge.png"), large, 0600); err != nil {
		t.Fatal(err)
	}
	preview, err = BoardImagePreview(root, "huge.png", 64)
	if err != nil || preview != nil {
		t.Fatalf("oversized header must select original without raster allocation: preview=%v err=%v", preview, err)
	}
}

func TestBoardImagePreviewJPEGOrientationAndMalformedSegment(t *testing.T) {
	root := t.TempDir()
	var jpegData bytes.Buffer
	if err := jpeg.Encode(&jpegData, image.NewRGBA(image.Rect(0, 0, 512, 256)), nil); err != nil {
		t.Fatal(err)
	}
	exif := []byte{'E', 'x', 'i', 'f', 0, 0, 'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0}
	segment := []byte{0xff, 0xe1, 0, byte(len(exif) + 2)}
	segment = append(segment, exif...)
	original := jpegData.Bytes()
	oriented := append(append(append([]byte{}, original[:2]...), segment...), original[2:]...)
	if err := os.WriteFile(filepath.Join(root, "turned.jpg"), oriented, 0600); err != nil {
		t.Fatal(err)
	}
	preview, err := BoardImagePreview(root, "turned.jpg", 64)
	if err != nil || preview != nil {
		t.Fatalf("oriented JPEG preview=%v err=%v", preview, err)
	}
	if err := os.WriteFile(filepath.Join(root, "broken.jpg"), []byte{0xff, 0xd8, 0xff, 0xe1, 0, 0}, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := BoardImagePreview(root, "broken.jpg", 64); err == nil {
		t.Fatal("malformed segment succeeded")
	}
}

func TestBoardImagePreviewAveragesFineDetailWithoutAliasing(t *testing.T) {
	root := t.TempDir()
	source := image.NewNRGBA(image.Rect(0, 0, 512, 256))
	for y := range 256 {
		for x := range 512 {
			value := uint8(((x + y) % 2) * 255)
			source.SetNRGBA(x, y, color.NRGBA{value, value, value, 255})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, source); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "detail.png"), encoded.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	preview, err := BoardImagePreview(root, "detail.png", 64)
	if err != nil || preview == nil {
		t.Fatalf("preview=%v err=%v", preview, err)
	}
	decoded, err := png.Decode(bytes.NewReader(preview.Data))
	if err != nil {
		t.Fatal(err)
	}
	for y := 4; y < 28; y++ {
		for x := 4; x < 60; x++ {
			r, g, b, a := decoded.At(x, y).RGBA()
			if r < 115*257 || r > 140*257 || g != r || b != r || a != 65535 {
				t.Fatalf("fine detail aliased at %d,%d: rgba=%d,%d,%d,%d", x, y, r, g, b, a)
			}
		}
	}
}
