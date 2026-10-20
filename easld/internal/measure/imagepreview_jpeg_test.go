package measure

import (
	"bytes"
	"errors"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"
)

func TestBoardImagePreviewUnsupportedJPEGSelectsOriginal(t *testing.T) {
	for _, tc := range []struct {
		name              string
		precision         byte
		components        byte
		unsupportedConfig bool
	}{
		{name: "12-bit extended sequential", precision: 12, components: 1, unsupportedConfig: true},
		{name: "CMYK without Adobe metadata", precision: 8, components: 4},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data := constantPreviewJPEG(tc.precision, tc.components)
			_, configErr := jpeg.DecodeConfig(bytes.NewReader(data))
			var unsupported jpeg.UnsupportedError
			if tc.unsupportedConfig {
				if !errors.As(configErr, &unsupported) {
					t.Fatalf("fixture must exercise unsupported DecodeConfig: %v", configErr)
				}
			} else {
				if configErr != nil {
					t.Fatalf("fixture configuration must be supported: %v", configErr)
				}
				if _, err := jpeg.Decode(bytes.NewReader(data)); !errors.As(err, &unsupported) {
					t.Fatalf("fixture must exercise unsupported Decode: %v", err)
				}
				adobe := []byte{0xff, 0xee, 0, 14, 'A', 'd', 'o', 'b', 'e', 0, 100, 0, 0, 0, 0, 0}
				tagged := append(append(append([]byte{}, data[:2]...), adobe...), data[2:]...)
				if _, err := jpeg.Decode(bytes.NewReader(tagged)); err != nil {
					t.Fatalf("CMYK fixture with Adobe metadata must decode: %v", err)
				}
			}
			root := t.TempDir()
			if err := os.WriteFile(filepath.Join(root, "source.jpg"), data, 0600); err != nil {
				t.Fatal(err)
			}
			preview, err := BoardImagePreview(root, "source.jpg", 64)
			if err != nil || preview != nil {
				t.Fatalf("unsupported JPEG must select original: preview=%v err=%v", preview, err)
			}
		})
	}
}

func TestBoardImagePreviewJPEGCorruptionRemainsUnreadable(t *testing.T) {
	data := constantPreviewJPEG(8, 1)
	if _, err := jpeg.Decode(bytes.NewReader(data)); err != nil {
		t.Fatalf("uncorrupted fixture must decode: %v", err)
	}
	corrupt := append([]byte{}, data...)
	frame := bytes.Index(corrupt, []byte{0xff, 0xc0})
	corrupt[frame+11] = 0
	for _, tc := range []struct {
		name string
		data []byte
	}{
		{name: "invalid sampling", data: corrupt},
		{name: "truncated frame", data: data[:frame+8]},
		{name: "truncated scan", data: data[:len(data)-3]},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			if err := os.WriteFile(filepath.Join(root, "broken.jpg"), tc.data, 0600); err != nil {
				t.Fatal(err)
			}
			preview, err := BoardImagePreview(root, "broken.jpg", 64)
			var sourceErr *SourceError
			if preview != nil || !errors.As(err, &sourceErr) || sourceErr.Kind != "unreadable" {
				t.Fatalf("corrupt JPEG must remain unreadable: preview=%v err=%v", preview, err)
			}
		})
	}
}

func constantPreviewJPEG(precision, components byte) []byte {
	data := []byte{0xff, 0xd8}
	segment := func(marker byte, payload []byte) {
		length := len(payload) + 2
		data = append(data, 0xff, marker, byte(length>>8), byte(length))
		data = append(data, payload...)
	}
	quantization := make([]byte, 65)
	for i := 1; i < len(quantization); i++ {
		quantization[i] = 1
	}
	segment(0xdb, quantization)
	// A zero DC difference and AC end-of-block each have the one-bit code 0.
	huffman := make([]byte, 18)
	huffman[1] = 1
	segment(0xc4, huffman)
	huffman[0] = 0x10
	segment(0xc4, huffman)
	frame := []byte{precision, 0, 8, 0, 128, components}
	scan := []byte{components}
	for component := byte(1); component <= components; component++ {
		frame = append(frame, component, 0x11, 0)
		scan = append(scan, component, 0)
	}
	marker := byte(0xc0)
	if precision == 12 {
		marker = 0xc1
	}
	segment(marker, frame)
	scan = append(scan, 0, 63, 0)
	segment(0xda, scan)
	// Sixteen constant blocks per component need 32 zero bits, at either precision.
	data = append(data, make([]byte, 4*int(components))...)
	return append(data, 0xff, 0xd9)
}
