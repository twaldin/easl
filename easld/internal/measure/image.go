package measure

import (
	"bytes"
	"encoding/binary"
	"io"
	"math"
	"net/url"
	"os"
	"os/user"
	"path/filepath"
	"strings"
)

// Image tile constants (LocalImage.swift).
const (
	ImageDefaultMaxWidth = 960.0
	ImageCaptionHeight   = 24.0
)

// NeedsApp is the failure for what only the app can measure: AppKit/TextKit text layout,
// WebKit, image formats ImageIO decodes that easld doesn't parse. The router decides what
// a call that needs it answers.
type NeedsApp struct{ What string }

func (e *NeedsApp) Error() string { return e.What + " is measured by the app" }

// ImageFile is LocalImage.tileFile: the file an image tile's path names (board-relative,
// absolute, `~/…`, or a file:// URL).
func ImageFile(path, root string) string {
	if u, err := url.Parse(path); err == nil && u.Scheme == "file" && !strings.ContainsAny(path, " \t\n") {
		return StandardPath(u.Path)
	}
	expanded := ExpandTilde(path)
	if strings.HasPrefix(expanded, "/") {
		return StandardPath(expanded)
	}
	return StandardPath(filepath.Join(root, path))
}

// ExpandTilde is NSString.expandingTildeInPath.
func ExpandTilde(path string) string {
	if !strings.HasPrefix(path, "~") {
		return path
	}
	rest := path[1:]
	name, tail, _ := strings.Cut(rest, "/")
	var home string
	if name == "" {
		home, _ = os.UserHomeDir()
	} else if u, err := user.Lookup(name); err == nil {
		home = u.HomeDir
	} else {
		return path
	}
	if tail == "" && !strings.Contains(rest, "/") {
		return home
	}
	return strings.TrimSuffix(home, "/") + "/" + tail
}

// FittedImage is LocalImage.fitted: the image scaled down (never up) to maxWidth, whole points.
func FittedImage(w, h, maxWidth float64) (float64, float64) {
	width := min(w, maxWidth)
	return max(1, math.Round(width)), max(1, math.Round(h*width/w))
}

// ImageNaturalSize is LocalImage.naturalSize for the bitmap formats whose header easld reads
// (PNG, JPEG, GIF, BMP, WebP, TIFF): pixel size, a quarter-turn EXIF orientation (5–8) swapping
// it. ok false when the file isn't a readable image; a *NeedsApp error for formats only the
// app's ImageIO/NSImage read (SVG, PDF, HEIC/AVIF, ICO, PSD, ICNS, JPEG 2000).
func ImageNaturalSize(file string) (w, h float64, ok bool, err error) {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(file), "."))
	f, openErr := os.Open(file)
	if openErr != nil {
		return 0, 0, false, nil
	}
	defer f.Close()
	if ext == "svg" || ext == "pdf" {
		if info, statErr := f.Stat(); statErr == nil && !info.IsDir() {
			return 0, 0, false, &NeedsApp{What: "an ." + ext + " image's size"}
		}
		return 0, 0, false, nil
	}
	data, readErr := io.ReadAll(io.LimitReader(f, 64<<20))
	if readErr != nil {
		return 0, 0, false, nil
	}
	width, height, orientation, known := bitmapHeader(data)
	if !known {
		if needsImageIO(data) {
			return 0, 0, false, &NeedsApp{What: "this image format's size"}
		}
		return 0, 0, false, nil
	}
	if width <= 0 || height <= 0 {
		return 0, 0, false, nil
	}
	if orientation >= 5 {
		return float64(height), float64(width), true, nil
	}
	return float64(width), float64(height), true, nil
}

func needsImageIO(d []byte) bool {
	switch {
	case len(d) >= 12 && string(d[4:8]) == "ftyp": // HEIC, HEIF, AVIF
		return true
	case bytes.HasPrefix(d, []byte("%PDF")), bytes.HasPrefix(d, []byte("8BPS")), bytes.HasPrefix(d, []byte("icns")),
		bytes.HasPrefix(d, []byte{0, 0, 1, 0}), bytes.HasPrefix(d, []byte{0, 0, 0, 0x0c, 'j', 'P', ' ', ' '}),
		bytes.HasPrefix(d, []byte{0xff, 0x4f, 0xff, 0x51}):
		return true
	}
	trimmed := bytes.TrimLeft(d, " \t\r\n\xef\xbb\xbf")
	return bytes.HasPrefix(trimmed, []byte("<svg")) || (bytes.HasPrefix(trimmed, []byte("<?xml")) && bytes.Contains(d[:min(len(d), 4096)], []byte("<svg")))
}

func bitmapHeader(d []byte) (w, h int, orientation int, ok bool) {
	switch {
	case len(d) >= 24 && bytes.HasPrefix(d, []byte("\x89PNG\r\n\x1a\n")) && string(d[12:16]) == "IHDR":
		return int(binary.BigEndian.Uint32(d[16:20])), int(binary.BigEndian.Uint32(d[20:24])), pngOrientation(d), true
	case len(d) >= 4 && d[0] == 0xFF && d[1] == 0xD8:
		return jpegHeader(d)
	case len(d) >= 10 && (bytes.HasPrefix(d, []byte("GIF87a")) || bytes.HasPrefix(d, []byte("GIF89a"))):
		return int(binary.LittleEndian.Uint16(d[6:8])), int(binary.LittleEndian.Uint16(d[8:10])), 1, true
	case len(d) >= 26 && d[0] == 'B' && d[1] == 'M':
		if binary.LittleEndian.Uint32(d[14:18]) == 12 {
			return int(int16(binary.LittleEndian.Uint16(d[18:20]))), abs(int(int16(binary.LittleEndian.Uint16(d[20:22])))), 1, true
		}
		return int(int32(binary.LittleEndian.Uint32(d[18:22]))), abs(int(int32(binary.LittleEndian.Uint32(d[22:26])))), 1, true
	case len(d) >= 30 && string(d[0:4]) == "RIFF" && string(d[8:12]) == "WEBP":
		return webpHeader(d)
	case len(d) >= 8 && (bytes.HasPrefix(d, []byte("II*\x00")) || bytes.HasPrefix(d, []byte("MM\x00*"))):
		return tiffHeader(d)
	}
	return 0, 0, 0, false
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func pngOrientation(d []byte) int {
	at := 8
	for at+8 <= len(d) {
		length := int(binary.BigEndian.Uint32(d[at : at+4]))
		kind := string(d[at+4 : at+8])
		if kind == "IDAT" || kind == "IEND" || length < 0 || at+8+length > len(d) {
			break
		}
		if kind == "eXIf" {
			return exifOrientation(d[at+8 : at+8+length])
		}
		at += 12 + length
	}
	return 1
}

func jpegHeader(d []byte) (w, h, orientation int, ok bool) {
	orientation = 1
	at := 2
	for at+4 <= len(d) {
		if d[at] != 0xFF {
			at++
			continue
		}
		marker := d[at+1]
		if marker == 0xFF {
			at++
			continue
		}
		if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
			at += 2
			continue
		}
		if marker == 0xD9 || marker == 0xDA {
			break
		}
		length := int(binary.BigEndian.Uint16(d[at+2 : at+4]))
		segment := d[at+4 : min(len(d), at+2+length)]
		switch {
		case marker == 0xE1 && len(segment) >= 6 && string(segment[:6]) == "Exif\x00\x00":
			orientation = exifOrientation(segment[6:])
		case marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC:
			if len(segment) >= 5 {
				return int(binary.BigEndian.Uint16(segment[3:5])), int(binary.BigEndian.Uint16(segment[1:3])), orientation, true
			}
			return 0, 0, 0, false
		}
		at += 2 + length
	}
	return 0, 0, 0, false
}

func webpHeader(d []byte) (w, h, orientation int, ok bool) {
	orientation = 1
	switch string(d[12:16]) {
	case "VP8 ":
		if d[23] != 0x9d || d[24] != 0x01 || d[25] != 0x2a {
			return 0, 0, 0, false
		}
		return int(binary.LittleEndian.Uint16(d[26:28]) & 0x3fff), int(binary.LittleEndian.Uint16(d[28:30]) & 0x3fff), 1, true
	case "VP8L":
		if d[20] != 0x2f {
			return 0, 0, 0, false
		}
		bits := binary.LittleEndian.Uint32(d[21:25])
		return int(bits&0x3fff) + 1, int((bits>>14)&0x3fff) + 1, 1, true
	case "VP8X":
		w = int(uint32(d[24])|uint32(d[25])<<8|uint32(d[26])<<16) + 1
		h = int(uint32(d[27])|uint32(d[28])<<8|uint32(d[29])<<16) + 1
		at := 12
		for at+8 <= len(d) {
			size := int(binary.LittleEndian.Uint32(d[at+4 : at+8]))
			if string(d[at:at+4]) == "EXIF" && at+8+size <= len(d) {
				exif := d[at+8 : at+8+size]
				if bytes.HasPrefix(exif, []byte("Exif\x00\x00")) {
					exif = exif[6:]
				}
				orientation = exifOrientation(exif)
				break
			}
			at += 8 + size + size%2
		}
		return w, h, orientation, true
	}
	return 0, 0, 0, false
}

// tiffIFD0 reads IFD0's SHORT/LONG tags of a TIFF stream.
func tiffIFD0(d []byte) (map[uint16]int, bool) {
	if len(d) < 8 {
		return nil, false
	}
	var order binary.ByteOrder
	switch string(d[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return nil, false
	}
	at := int(order.Uint32(d[4:8]))
	if at+2 > len(d) {
		return nil, false
	}
	count := int(order.Uint16(d[at : at+2]))
	tags := map[uint16]int{}
	for i := range count {
		entry := at + 2 + i*12
		if entry+12 > len(d) {
			break
		}
		tag := order.Uint16(d[entry : entry+2])
		switch order.Uint16(d[entry+2 : entry+4]) {
		case 3:
			tags[tag] = int(order.Uint16(d[entry+8 : entry+10]))
		case 4:
			tags[tag] = int(order.Uint32(d[entry+8 : entry+12]))
		}
	}
	return tags, true
}

func exifOrientation(tiff []byte) int {
	tags, ok := tiffIFD0(tiff)
	if !ok {
		return 1
	}
	if o, ok := tags[274]; ok && o >= 1 && o <= 8 {
		return o
	}
	return 1
}

func tiffHeader(d []byte) (w, h, orientation int, ok bool) {
	tags, ok := tiffIFD0(d)
	if !ok {
		return 0, 0, 0, false
	}
	orientation = 1
	if o, ok := tags[274]; ok && o >= 1 && o <= 8 {
		orientation = o
	}
	return tags[256], tags[257], orientation, true
}
