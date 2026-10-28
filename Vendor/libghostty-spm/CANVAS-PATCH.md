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
frame is owed, never recreated. UIKit, and macOS 13, keep MSDisplayLink. `AppTerminalView.surfaceDidDraw()`
is called after each drawn frame for the host to count (easl's `terminal.draw` metric). Diff:
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

### Private clipboard writes

For easl's client mode (a remote board's terminal shows another Mac's text, which must not stay on
this one):

- `TerminalSurfaceClipboardPrivacyDelegate` (`Surface/TerminalSurfaceViewDelegate.swift`): a
  surface delegate answering `terminalClipboardWritesArePrivate = true` gets every write that lands
  (`TerminalController+Callbacks.swift` `writeClipboard`: copy bindings, allowed program writes)
  written with `.currentHostOnly` (no Universal Clipboard) plus the empty
  `org.nspasteboard.TransientType` and `org.nspasteboard.ConcealedType` markers; on UIKit,
  `.localOnly`. `TerminalCallbackBridge.clipboardWritesArePrivate` asks the delegate.
- `TerminalClipboardRequestKind.kittyWrite`: under `clipboard-write = ask` a Kitty clipboard
  protocol (OSC 5522) write reaches the confirmation delegate like an OSC 52 write, instead of
  being denied as an unrecognized request.

### Paste override

`AppTerminalView+Input.swift` makes the `paste(_:)` action `open`, like `copy(_:)`.
easl overrides it to copy pasted images to the terminal's host before pasting their paths.
The default Ghostty paste action is unchanged for other hosts and ordinary text.

The existing AppKit `TerminalPasteboardContent.text(from:)` reader is public so easl can snapshot
queued text pastes at the keypress. It retains the same URL precedence and shell escaping as
Ghostty's clipboard callback without changing the pasteboard.

### Surface lifetime and attachment-aware input

The #205 changes touch four files:

- `Surface/TerminalSurfaceCoordinator.swift` drains the retiring controller with `tick()` after
  freeing the old surface, clearing wrapper state, and removing its callback bridge, but before
  the detach callback or replacement allocation. Ghostty queues child-exit messages with a raw
  surface pointer and validates that pointer by membership, not generation. If a replacement
  reuses the freed address before the queue drains, Ghostty accepts the stale exit for the live
  replacement. The next encoded key dismisses that supposedly exited surface instead of reaching
  its PTY, even though Ghostty reports the key as accepted.
- `Surface/TerminalSurface.swift` exposes `isProcessRunning`, which reads Ghostty's exited flag
  and returns false after free, and `requestClose()`, which requests closure only while a raw
  surface exists. The flag is not an independent OS process-liveness check.
- `Platform/AppKit/AppTerminalView.swift` makes the current `surface` public so hosts can bind a
  complete input submission to one wrapper identity rather than accidentally target a replacement.
- `Platform/AppKit/AppTerminalView+Input.swift` makes `keyIsBinding(_:on:)` public so hosts can
  preserve Copy, selection, and font bindings on exited screens while refusing process input.

The standalone diff contains only these #205 changes, not the earlier resource, frame-link,
clipboard, or paste changes: `patches/libghostty-spm-surface-lifetime.patch`. It applies directly
to the pinned upstream tag and composes with the existing resource and frame-link patches.
It does not change the prebuilt Ghostty binary or make key acceptance a PTY-delivery guarantee.

To update, copy the new tag's files as above, reapply the patches, and drop the test target again.
