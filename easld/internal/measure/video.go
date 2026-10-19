package measure

import (
	"encoding/binary"
	"errors"
	"io"
	"math"
	"net/url"
	"os"
	"strings"
)

func VideoProblem(props map[string]any) string {
	if path, ok := props["path"].(string); !ok || path == "" {
		return "a video needs props.path"
	}
	for _, key := range []string{"poster", "title"} {
		if value, exists := props[key]; exists {
			if _, ok := value.(string); !ok {
				return "video props." + key + " must be a string"
			}
		}
	}
	for _, key := range []string{"loop", "muted", "autoplay"} {
		if value, exists := props[key]; exists {
			if _, ok := value.(bool); !ok {
				return "video props." + key + " must be a boolean"
			}
		}
	}
	if value, exists := props["startTime"]; exists {
		n, ok := value.(float64)
		if !ok || math.IsNaN(n) || math.IsInf(n, 0) || n < 0 {
			return "video props.startTime must be a nonnegative number"
		}
	}
	return ""
}

func VideoNaturalSize(path, root string) (float64, float64, error) {
	if len(path) >= 5 && strings.EqualFold(path[:5], "file:") {
		value, err := url.Parse(path)
		if err != nil || value.Opaque != "" || (value.Host != "" && value.Host != "localhost") {
			return 0, 0, &Failure{"invalid_params", "video path refused"}
		}
		path = value.Path
	}
	source, err := authorizeNoteFile(path, nil, root, boardAreas(root))
	if err != nil {
		return 0, 0, &Failure{"invalid_params", "video path refused"}
	}
	fd, err := openNoFollow(source.path)
	if err != nil {
		return 0, 0, &Failure{"not_found", "no readable video at " + path}
	}
	file := os.NewFile(uintptr(fd), source.path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return 0, 0, &Failure{"unavailable", "video is not a regular file"}
	}
	budget := 8192
	tracks, err := videoBoxes(file, 0, info.Size(), 0, &budget)
	if err == nil {
		for _, track := range tracks {
			if track.video && track.w > 0 && track.h > 0 {
				return track.w, track.h, nil
			}
		}
	}
	return 0, 0, &Failure{"unavailable", "video dimensions unavailable: a readable MP4 or MOV video track is required"}
}

type videoTrack struct {
	w, h  float64
	video bool
}

var errVideoHeader = errors.New("invalid or excessive video metadata")

func videoBoxes(file io.ReaderAt, start, end int64, depth int, budget *int) ([]videoTrack, error) {
	if depth > 4 {
		return nil, errVideoHeader
	}
	var tracks []videoTrack
	var current videoTrack
	for offset := start; offset < end; {
		if end-offset < 8 || *budget <= 0 {
			return nil, errVideoHeader
		}
		*budget--
		var header [16]byte
		if _, err := file.ReadAt(header[:8], offset); err != nil {
			return nil, err
		}
		size := uint64(binary.BigEndian.Uint32(header[:4]))
		headerSize := int64(8)
		if size == 1 {
			if end-offset < 16 {
				return nil, errVideoHeader
			}
			if _, err := file.ReadAt(header[8:], offset+8); err != nil {
				return nil, err
			}
			size, headerSize = binary.BigEndian.Uint64(header[8:]), 16
		} else if size == 0 {
			size = uint64(end - offset)
		}
		if size < uint64(headerSize) || size > uint64(end-offset) {
			return nil, errVideoHeader
		}
		body, next := offset+headerSize, offset+int64(size)
		switch string(header[4:8]) {
		case "moov", "trak", "mdia":
			children, err := videoBoxes(file, body, next, depth+1, budget)
			if err != nil {
				return nil, err
			}
			for _, child := range children {
				if child.video && child.w > 0 && child.h > 0 {
					return []videoTrack{child}, nil
				}
			}
			if string(header[4:8]) != "mdia" {
				tracks = append(tracks, children...)
			} else {
				for _, child := range children {
					if child.w > 0 {
						current.w, current.h = child.w, child.h
					}
					current.video = current.video || child.video
				}
			}
		case "hdlr":
			if next-body < 12 {
				return nil, errVideoHeader
			}
			var handler [12]byte
			if _, err := file.ReadAt(handler[:], body); err != nil {
				return nil, err
			}
			current.video = string(handler[8:12]) == "vide"
		case "tkhd":
			if next-body < 84 {
				return nil, errVideoHeader
			}
			var data [96]byte
			if _, err := file.ReadAt(data[:84], body); err != nil {
				return nil, err
			}
			matrix, dimensions := 40, 76
			if data[0] == 1 {
				if next-body < 96 {
					return nil, errVideoHeader
				}
				if _, err := file.ReadAt(data[84:], body+84); err != nil {
					return nil, err
				}
				matrix, dimensions = 52, 88
			} else if data[0] != 0 {
				return nil, errVideoHeader
			}
			fixed := func(at int) float64 { return float64(int32(binary.BigEndian.Uint32(data[at:at+4]))) / 65536 }
			w := float64(binary.BigEndian.Uint32(data[dimensions:dimensions+4])) / 65536
			h := float64(binary.BigEndian.Uint32(data[dimensions+4:dimensions+8])) / 65536
			current.w = math.Abs(fixed(matrix))*w + math.Abs(fixed(matrix+12))*h
			current.h = math.Abs(fixed(matrix+4))*w + math.Abs(fixed(matrix+16))*h
		}
		if current.video && current.w > 0 && current.h > 0 {
			return []videoTrack{current}, nil
		}
		offset = next
	}
	if current.video || current.w > 0 {
		tracks = append(tracks, current)
	}
	return tracks, nil
}
