package router

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"image"
	"image/png"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/api"
	"github.com/twaldin/easl/easld/internal/server"
	"github.com/twaldin/easl/easld/internal/swiftjson"
)

func TestViewRenderInlineWireLimitKeepsTheCallerAndFileOutputUsable(t *testing.T) {
	f := newFixture(t)
	id := idOf(f.result("object.create", note(0, map[string]any{"markdown": "draw"})))
	dir, err := os.MkdirTemp("", "render-limit-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	srv, err := server.Listen(filepath.Join(dir, "s.sock"), f.router.Handle, f.router.Answer, f.router.Push)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	dial := func() net.Conn {
		t.Helper()
		nc, err := net.Dial("unix", srv.Path())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { nc.Close() })
		if err := nc.SetDeadline(time.Now().Add(time.Minute)); err != nil {
			t.Fatal(err)
		}
		return nc
	}
	write := func(nc net.Conn, v any) int {
		t.Helper()
		wire, err := swiftjson.Encode(v, false, true)
		if err != nil {
			t.Fatal(err)
		}
		n, err := nc.Write(append(wire, '\n'))
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	read := func(lines *bufio.Reader) (map[string]any, int) {
		t.Helper()
		wire, err := lines.ReadBytes('\n')
		if err != nil {
			t.Fatalf("caller or renderer connection ended instead of answering: %v", err)
		}
		var reply map[string]any
		if err := json.Unmarshal(wire, &reply); err != nil {
			t.Fatal(err)
		}
		return reply, len(wire)
	}

	renderer, caller := dial(), dial()
	rendererLines, callerLines := bufio.NewReader(renderer), bufio.NewReader(caller)
	write(renderer, map[string]any{"id": "attach", "method": "client.attach", "params": map[string]any{
		"version": float64(api.SchemaVersion), "schema": api.SchemaHash,
		"serves": []any{"view.render"}, "boards": []any{f.board.ID()},
	}})
	if attached, _ := read(rendererLines); attached["ok"] != true {
		t.Fatalf("client.attach: %v", attached)
	}

	// An ancillary PNG chunk keeps the image valid while producing many base64 slashes.
	var pixel bytes.Buffer
	if err := png.Encode(&pixel, image.NewRGBA(image.Rect(0, 0, 1, 1))); err != nil {
		t.Fatal(err)
	}
	original := pixel.Bytes()
	var picture bytes.Buffer
	picture.Write(original[:len(original)-12])
	chunk := append([]byte("raNd"), bytes.Repeat([]byte{0xff}, (12<<20)-4096)...)
	if err := binary.Write(&picture, binary.BigEndian, uint32(len(chunk)-4)); err != nil {
		t.Fatal(err)
	}
	picture.Write(chunk)
	if err := binary.Write(&picture, binary.BigEndian, crc32.ChecksumIEEE(chunk)); err != nil {
		t.Fatal(err)
	}
	picture.Write(original[len(original)-12:])
	data := picture.Bytes()
	if _, err := png.Decode(bytes.NewReader(data)); err != nil {
		t.Fatalf("large renderer image is not a valid PNG: %v", err)
	}
	raw := base64.StdEncoding.EncodeToString(data)
	raw = raw[:16] + "\r\n" + raw[16:]
	const requestID = "/\n"
	result := map[string]any{
		"data": raw, "format": "png", "width": 1.0, "height": 1.0, "scale": 2.0,
		"canvasRect": map[string]any{"x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0},
		"objects":    []any{"/\n\""},
	}
	wire, err := swiftjson.Encode(map[string]any{"id": requestID, "ok": true, "result": result}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	padding := server.MaxPendingOutput - len(wire) - 1
	if padding < 0 {
		t.Fatal("image leaves no space for boundary metadata")
	}
	wire = nil
	metadata := "/\n\"" + strings.Repeat("x", padding)

	for _, extra := range []int{0, 1} {
		result["objects"] = []any{metadata + strings.Repeat("x", extra)}
		write(caller, map[string]any{"id": requestID, "method": "view.render", "params": map[string]any{
			"target": id, "inline": true,
		}})
		request, _ := read(rendererLines)
		inbound := write(renderer, map[string]any{"id": request["id"], "ok": true, "result": result})
		if inbound <= server.MaxPendingOutput {
			t.Fatalf("renderer frame = %d bytes, want a frame above the caller output limit", inbound)
		}
		reply, size := read(callerLines)
		if reply["id"] != requestID {
			t.Fatalf("response lost its escaped request id: %q", reply["id"])
		}
		if extra == 0 {
			if reply["ok"] != true || size != server.MaxPendingOutput || !reflect.DeepEqual(reply["result"], result) {
				t.Fatalf("exact-limit inline response has ok=%v and %d bytes, want the full %d-byte image response", reply["ok"], size, server.MaxPendingOutput)
			}
		} else {
			want := map[string]any{"id": requestID, "ok": false, "error": map[string]any{
				"code":    "invalid_params",
				"message": "inline view.render response exceeds the 33554432-byte output limit; omit inline or use out to write the image to a file",
			}}
			if !reflect.DeepEqual(reply, want) {
				code, message := errorOf(reply)
				t.Fatalf("oversize inline response has %d bytes and error %s %s, want only the bounded API error", size, code, message)
			}
		}
	}

	write(caller, map[string]any{"id": "still-open", "method": "board.get", "params": map[string]any{"board": f.board.ID()}})
	if reply, _ := read(callerLines); reply["ok"] != true || reply["result"].(map[string]any)["board"] != f.board.ID() {
		t.Fatalf("caller is not usable after the inline limit error: %v", reply)
	}

	out := filepath.Join(dir, "large.png")
	write(caller, map[string]any{"id": "file", "method": "view.render", "params": map[string]any{"target": id, "out": out}})
	request, _ := read(rendererLines)
	write(renderer, map[string]any{"id": request["id"], "ok": true, "result": result})
	reply, _ := read(callerLines)
	if reply["ok"] != true {
		t.Fatalf("file output rejected a renderer image above the inline limit: %v", reply)
	}
	fileResult := reply["result"].(map[string]any)
	if fileResult["path"] != out || fileResult["data"] != nil || fileResult["format"] != "png" || !reflect.DeepEqual(fileResult["objects"], result["objects"]) {
		t.Fatalf("file response lost its path or metadata")
	}
	written, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(written, data) {
		t.Fatalf("file output changed the renderer image: got %d bytes, want %d", len(written), len(data))
	}
}
