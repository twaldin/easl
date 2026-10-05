# Vendored libghostty-spm

- Upstream: https://github.com/Lakr233/libghostty-spm (MIT, see `LICENSE`)
- Tag: `1.6.20260922` (commit `b7f888e3baf8585ea9d590ab1a45b49475e00d1c`)
- Kept: `Package.swift`, `LICENSE`, `Sources/**`, unchanged except the test target and the
  patches below. The `libghostty` xcframework stays a remote `binaryTarget` with upstream's URL and
  checksum.
- Dropped: `Example/`, `Tests/`, `docs/`, `Script/`, `Patches/`, `build.sh`, `Ghostty.build`,
  `Ghostty.ref`, `Package.local.swift`, `Package.swift.template`, `.github/`, `.gitattributes`,
  `.gitignore`, `.root`, `README.md`, `AGENTS.md`, `CLAUDE.md`, and the `GhosttyKitTest` test
  target in `Package.swift`.

## Patches

### Resource bundle

`Sources/GhosttyTerminal/Configuration/GhosttyRuntimeResources.swift` looks for
`GhosttyKit_GhosttyTerminal.bundle` in `Bundle.main.resourceURL` first and falls back to
`Bundle.module`. SwiftPM's generated `Bundle.module` accessor checks only the app's root and the
absolute build directory baked in at compile time, and traps when neither exists. An app
assembled from `swift build` output keeps resource bundles in `Contents/Resources` (codesign
rejects them at the app's root), so without the patch the first terminal crashes Canvas on any
machine without the build directory.

The same change as a unified diff against upstream: `patches/libghostty-spm-resources.patch` at
the Canvas repo root (`git apply` in an upstream checkout).

### Frame link per terminal view

`TerminalSurfaceCoordinator` paces draws with MSDisplayLink, held while frames are owed and
released after 30 idle frames. On macOS MSDisplayLink's driver creates a new `CVDisplayLink`, and
with it a new thread, every time the link starts again, so a visible terminal printing a line every
few hundred milliseconds started one per line (133 display-link threads in 5 s on a real board).
The coordinator now takes a frame clock from its platform view (`makeFrameLink`,
`TerminalFrameLink`): `AppTerminalView` gives it its own `NSView.displayLink` (macOS 14+), which
fires on the main run loop, follows the view's screen, and is paused when idle and resumed when a
frame is owed, never recreated. UIKit, and macOS 13, keep MSDisplayLink. Diff:
`patches/libghostty-spm-frame-link.patch`.

What this doesn't remove: libghostty's own renderer (the prebuilt xcframework) runs a
`CVDisplayLink` of its own per surface, and upstream's `syncDisplayLink` (`src/renderer/generic.zig`)
starts it when a frame has cell changes and stops it after the next draw that has none. Every
`CVDisplayLinkStart` spawns a new CoreVideo thread, so a visible shell printing every 400 ms still
shows about 20 display-link threads in a 5 s `sample` (30 before this patch). A standalone probe
(no window, one link started for 250 ms every 400 ms) measured one new thread per start, 22 µs to
start and 15 µs to stop, on the renderer's thread, none on the main thread; a paused
`CADisplayLink` made none. We keep upstream's binary: `window-vsync = false` would remove the link
but upstream warns of kernel panics on macOS 14.4+ with out-of-sync rendering, and patching it means
building libghostty ourselves. The upstream fix is an idle grace period in `syncDisplayLink`: stop
the link only after it has fired some frames (or ~0.5 s) without cell changes, instead of after the
first idle draw.

To update, copy the new tag's files as above, reapply both patches, and drop the test target again.
