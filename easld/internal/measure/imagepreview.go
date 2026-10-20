package measure

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"golang.org/x/image/draw"
	"golang.org/x/sys/unix"
)

const ImageFileLimit = 4 * 1024 * 1024

var boardImageRemoteURL = regexp.MustCompile(`(?i)^[a-z][a-z0-9+.-]*://`)

type ImageVersion struct {
	Root  string `json:"root"`
	Path  string `json:"path"`
	Stamp string `json:"stamp"`
}

type ImagePreview struct {
	NaturalWidth  int
	NaturalHeight int
	Width         int
	Height        int
	Data          []byte
	Version       ImageVersion
}

// BoardImagePreview reads only through HostFiles.boardImage's live-file policy.
// A nil preview explicitly selects the existing original-file transport.
func BoardImagePreview(root, input string, maxPixels int) (*ImagePreview, error) {
	path, err := boardImagePath(root, input)
	if err != nil {
		return nil, err
	}
	fd, err := openNoFollow(path)
	if err != nil {
		return nil, classifyOpenErr(err)
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	var before, after unix.Stat_t
	if unix.Fstat(fd, &before) != nil {
		return nil, &SourceError{Kind: "unreadable"}
	}
	if before.Mode&unix.S_IFMT != unix.S_IFREG {
		return nil, &SourceError{Kind: "noSuchFile"}
	}
	if before.Size > ImageFileLimit {
		return nil, &SourceError{Kind: "too_large"}
	}
	data, err := io.ReadAll(io.LimitReader(f, ImageFileLimit+1))
	if err != nil {
		return nil, &SourceError{Kind: "unreadable"}
	}
	if unix.Fstat(fd, &after) != nil || imageStamp(before) != imageStamp(after) {
		return nil, &SourceError{Kind: "unreadable"}
	}
	if len(data) > ImageFileLimit {
		return nil, &SourceError{Kind: "too_large"}
	}
	preview, err := rasterPreview(data, maxPixels)
	if preview != nil {
		preview.Version = ImageVersion{Root: cleanAbs(root), Path: path, Stamp: imageStamp(after)}
	}
	return preview, err
}

func imageStamp(st unix.Stat_t) string {
	return fmt.Sprintf("%d:%d:%d:%d:%d", st.Dev, st.Ino, st.Size, st.Mtim.Sec*1_000_000_000+st.Mtim.Nsec, st.Ctim.Sec*1_000_000_000+st.Ctim.Nsec)
}

func boardImagePath(root, input string) (string, error) {
	refused := func() (string, error) { return "", &SourceError{Kind: "refused"} }
	if input == "" || strings.ContainsRune(input, 0) || strings.HasPrefix(input, "~") {
		return refused()
	}
	if strings.HasPrefix(strings.ToLower(input), "file:") {
		u, err := url.Parse(input)
		if err != nil || !strings.EqualFold(u.Scheme, "file") || (u.Host != "" && u.Host != "localhost") || u.User != nil || !filepath.IsAbs(u.Path) {
			return refused()
		}
		input = u.Path
	} else if boardImageRemoteURL.MatchString(input) {
		return refused()
	}
	if strings.ContainsRune(input, 0) {
		return refused()
	}
	root = cleanAbs(root)
	requested := input
	if !filepath.IsAbs(requested) {
		requested = filepath.Join(root, requested)
	}
	requested = filepath.Clean(requested)
	if requested == root || !pathInside(root, requested) {
		return refused()
	}
	base := RealPath(root)
	candidate := RealPath(requested)
	if candidate == base || !pathInside(base, candidate) {
		return refused()
	}
	return candidate, nil
}

func rasterPreview(data []byte, maxPixels int) (*ImagePreview, error) {
	isPNG := bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n"))
	isJPEG := len(data) >= 2 && data[0] == 0xff && data[1] == 0xd8
	if !isPNG && !isJPEG {
		return nil, nil
	}
	w, h, orientation, ok := bitmapHeader(data)
	bad := func() (*ImagePreview, error) { return nil, &SourceError{Kind: "unreadable"} }
	if !ok || w <= 0 || h <= 0 {
		return bad()
	}
	var config image.Config
	var err error
	var unsupported jpeg.UnsupportedError
	if isPNG {
		config, err = png.DecodeConfig(bytes.NewReader(data))
	} else {
		config, err = jpeg.DecodeConfig(bytes.NewReader(data))
	}
	if errors.As(err, &unsupported) {
		return nil, nil
	}
	if err != nil || config.Width != w || config.Height != h {
		return bad()
	}
	if int64(w)*int64(h) > 16_000_000 || orientation != 1 || (isPNG && originalPNG(data)) || (isJPEG && profiledJPEG(data)) || max(w, h) <= maxPixels {
		return nil, nil
	}
	var source image.Image
	if isPNG {
		source, err = png.Decode(bytes.NewReader(data))
	} else {
		source, err = jpeg.Decode(bytes.NewReader(data))
	}
	if errors.As(err, &unsupported) {
		return nil, nil
	}
	if err != nil {
		return bad()
	}
	if _, cmyk := source.(*image.CMYK); cmyk {
		return nil, nil
	}
	width, height := maxPixels, maxPixels
	if w >= h {
		height = max(1, int(math.Round(float64(h)*float64(maxPixels)/float64(w))))
	} else {
		width = max(1, int(math.Round(float64(w)*float64(maxPixels)/float64(h))))
	}
	out := image.NewNRGBA(image.Rect(0, 0, width, height))
	draw.CatmullRom.Scale(out, out.Bounds(), source, source.Bounds(), draw.Src, nil)
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, out); err != nil {
		return bad()
	}
	if encoded.Len() >= len(data) {
		return nil, nil
	}
	return &ImagePreview{NaturalWidth: w, NaturalHeight: h, Width: width, Height: height, Data: encoded.Bytes()}, nil
}

func profiledJPEG(data []byte) bool {
	for at := 2; at+1 < len(data); {
		if data[at] != 0xff {
			return false
		}
		for at < len(data) && data[at] == 0xff {
			at++
		}
		if at >= len(data) {
			return false
		}
		marker := data[at]
		at++
		if marker == 0xda || marker == 0xd9 {
			return false
		}
		if marker == 1 || marker == 0xd8 || (marker >= 0xd0 && marker <= 0xd7) {
			continue
		}
		if at+2 > len(data) {
			return false
		}
		length := int(binary.BigEndian.Uint16(data[at : at+2]))
		if length < 2 || length > len(data)-at {
			return false
		}
		if marker == 0xe2 && bytes.HasPrefix(data[at+2:at+length], []byte("ICC_PROFILE\x00")) {
			return true
		}
		at += length
	}
	return false
}

func originalPNG(data []byte) bool {
	for at := 8; at+12 <= len(data); {
		length := int(binary.BigEndian.Uint32(data[at : at+4]))
		if length > len(data)-at-12 {
			return false
		}
		switch string(data[at+4 : at+8]) {
		case "acTL", "iCCP", "gAMA", "cHRM", "sRGB", "cICP", "eXIf":
			return true
		case "IDAT", "IEND":
			return false
		}
		at += length + 12
	}
	return false
}
