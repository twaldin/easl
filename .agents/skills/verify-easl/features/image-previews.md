# Remote image previews

Users see display-sized PNG and JPEG tiles without transferring the original image first. Zoom requests more detail. Local image rendering remains a separate control.

## Sub-features

- `image-preview` displays a host-sized preview with the original aspect ratio and transparency.
- `image-detail` upgrades resolution after settled zoom and can load original detail.
- `image-original` uses original bytes when the host explicitly declines preview encoding.
- `image-refresh` reloads changed sources without leaving stale pixels after parking.
- `image-old-host` records behavior when a host lacks `image.preview`.

## How to get to it (user POV)

Open a remote board containing PNG or JPEG image tiles. Bring a tile into view, then zoom to inspect more detail. Preview selection happens automatically; there is no preview menu.

## Driving it with dev.sh

Preconditions: matched candidate viewer and guest-local scratch easld, SSH forwarding, and `EASL_DEV_HOST_READ_TRACE=1` on the viewer. Record both artifact SHAs. Seed a large alpha PNG and JPEG with visible fine detail, plus small, animated, oriented, and color-tagged controls. Record fixture hashes and dimensions. Supply actual board and image IDs in every API call.

1. Show byte-identical fixtures on a local board, then the scratch remote board. Capture each tile through its exact native window. Require matching aspect ratio, transparent edges, and recognizable detail. Pair remote pixels with `host-image-preview` log entries containing requested pixels, output dimensions, and PNG payload bytes. A thumbnail alone does not prove original-transfer avoidance.
2. Zoom in, retain an intermediate capture, then capture settled detail. Require the larger preview or original read in logs and sharper fixture detail in pixels. Zoom beyond the preview limit to qualify original loading separately.
3. Exercise the control files. The host may return `{"kind":"original"}` for unsupported, animated, oriented, already-small, uneconomical, or color-sensitive files. Require their correct original rendering. Do not require every control to receive the same encoding decision on both host implementations.
4. Park an image, update its source path to a different fixture, then bring it back. Require the new pixels and source identity, not the departure snapshot. Separately render an offscreen image through the explicit board-render path and inspect the output. That export supplements, not replaces, native proof.
5. Point the candidate viewer at a guest-local v0.3.0 easld with the same image fixtures. Capture the tile and retain the host error and viewer logs. Release qualification requires usable images through original fallback. Record a missing-method image error as a release failure, not a successful fallback.

## Gotchas

- `Sources/CanvasApp/ImageTile.swift` chooses backing-pixel resolution, upgrades after zoom, and presents read failures.
- `Sources/CanvasCore/HostImagePreview.swift` requests and validates previews. `LocalImagePreview.swift` and `easld/internal/router/imagepreview.go` implement host selection.
- At the recorded 0.3.1 candidate, only an explicit `kind: original` selects fallback. Unknown-method, malformed-reply, authorization, and transport failures remain errors. Do not describe old-host fallback as implemented without live evidence.
- SSH compression is requested by `RemoteHost.swift`, `HostMaster.swift`, and `HostedTerminal.swift`. Retain negotiated compression diagnostics before claiming it was used; command arguments alone are insufficient.
- A scratch macOS easld qualifies that artifact and host OS. It does not prove Linux encoder parity or a physical-network transfer result.
