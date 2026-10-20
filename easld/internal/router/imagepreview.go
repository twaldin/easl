package router

import (
	"encoding/base64"
	"errors"
	"log"
	"math"
	"os"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/model"
)

type imagePreviewRead struct {
	requestID any
	object    string
	root      string
	path      string
	maxPixels int
}

func (r *Router) imagePreview(p map[string]any) (any, error) {
	pixels, ok := num(p, "maxPixels")
	if !ok || math.IsNaN(pixels) || math.IsInf(pixels, 0) || pixels != math.Trunc(pixels) || pixels < 64 || pixels > 2048 {
		return nil, invalid("maxPixels must be an integer from 64 through 2048")
	}
	id, err := str(p, "id")
	if err != nil {
		return nil, err
	}
	b, err := r.boardForObject(id)
	if err != nil {
		return nil, err
	}
	o, err := b.Object(id)
	if err != nil {
		return nil, err
	}
	if o.Type != model.Image {
		return nil, invalid("image.preview requires an image object")
	}
	path, ok := o.Props["path"].(string)
	if !ok {
		return nil, invalid("image path is required")
	}
	return imagePreviewRead{object: id, root: b.Root(), path: path, maxPixels: int(pixels)}, nil
}

func (read imagePreviewRead) run() (any, error) {
	start := time.Now()
	preview, err := measure.BoardImagePreview(read.root, read.path, read.maxPixels)
	if os.Getenv("EASL_DEV_HOST_READ_TRACE") == "1" {
		width, height, size := 0, 0, 0
		if preview != nil {
			width, height, size = preview.Width, preview.Height, len(preview.Data)
		}
		log.Printf("image.preview object=%s maxPixels=%d output=%dx%d PNG_payload_bytes=%d duration=%s", read.object, read.maxPixels, width, height, size, time.Since(start))
	}
	if err != nil {
		var source *measure.SourceError
		if errors.As(err, &source) {
			code := source.Kind
			if code == "noSuchFile" {
				code = "not_found"
			}
			if code == "too_large" {
				return nil, fail(code, "image exceeds the %d-byte host file limit", measure.ImageFileLimit)
			}
			return nil, fail(code, "image preview: %s", code)
		}
		return nil, fail(api.CodeUnavailable, "image preview unavailable")
	}
	if preview == nil {
		return map[string]any{"kind": "original"}, nil
	}
	return map[string]any{"kind": "preview", "naturalWidth": preview.NaturalWidth, "naturalHeight": preview.NaturalHeight, "width": preview.Width, "height": preview.Height, "data": base64.StdEncoding.EncodeToString(preview.Data), "version": preview.Version}, nil
}
