# Vendored libghostty-spm

- Upstream: https://github.com/Lakr233/libghostty-spm (MIT, see `LICENSE`)
- Tag: `1.6.20260922` (commit `b7f888e3baf8585ea9d590ab1a45b49475e00d1c`)
- Kept: `Package.swift`, `LICENSE`, `Sources/**`, with the patches below and the upstream test target removed.
- Easl's vendored package is macOS-only. `GhosttyKit.xcframework` contains the rebuilt arm64 and x86_64 archive and its matching header. `PROVENANCE.json` records source revisions, the native patch hash, and every artifact file hash.
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

What this doesn't remove: libghostty's renderer still runs a
`CVDisplayLink` of its own per surface, and upstream's `syncDisplayLink` (`src/renderer/generic.zig`)
starts it when a frame has cell changes and stops it after the next draw that has none. Every
`CVDisplayLinkStart` spawns a new CoreVideo thread, so a visible shell printing every 400 ms still
shows about 20 display-link threads in a 5 s `sample` (30 before this patch). A standalone probe
(no window, one link started for 250 ms every 400 ms) measured one new thread per start, 22 µs to
start and 15 µs to stop, on the renderer's thread, none on the main thread; a paused
`CADisplayLink` made none. The native async-render patch preserves this behavior and `window-vsync`:
upstream warns of kernel panics on macOS 14.4+ with out-of-sync rendering.
The separate upstream fix is an idle grace period in `syncDisplayLink`: stop
the link only after it has fired some frames (or ~0.5 s) without cell changes, instead of after the
first idle draw.

### Completed worker frames

`patches/ghostty-async-rendering.patch` applies to Ghostty
`3c47ca159368eb4a860ffe5333abdf4a85b2767b` after the pinned wrapper's native patch stack.
It adds `ghostty_surface_set_async_rendering(surface, callback, userdata, generation)`.
A main-thread registration opts into worker rendering. Direct draw requests and native layer
display invalidations wake the worker instead of calling `drawFrame(true)`. An invalidation
also forces a frame when terminal cells have not changed.

The callback runs on main only after healthy GPU completion, layer-size acceptance, and
assignment of the completed IOSurface to `layer.contents`. It reports publication, not scanout.
Every accepted assignment notifies, including repeated use of the same IOSurface. CALayer KVO
cannot provide that guarantee because it suppresses same-pointer assignments.

The wrapper patch, `patches/libghostty-spm-async-rendering.patch`, installs a registration for
the exact surface, layer, and generation. Replacement and free unregister before releasing the
surface. Queued native publications retain their registration and reject retired callback
revisions without retaining the host view. `onPostRender` therefore enforces the attached layer's
scale before `surfaceDidDraw` counts the completed frame. UIKit's source draw path is unchanged.
Terminal renders and preview captures still use the existing session-text renderer.

App builds need Command Line Tools only. Rebuilding the native artifact needs Zig 0.16.0 and
Xcode's `metal` and `metallib` tools. From the easl root, build a new output directory:

```sh
scripts/build-ghostty.sh /tmp/GhosttyKit.xcframework
```

The script fetches exact source revisions, applies both patch stacks, builds with two jobs, and
packages the universal macOS archive with its header and provenance. The `Native Ghostty artifact`
workflow runs the same command. `Tests/TerminalFrames/run.py` checks completed pixels through
first paint, resize, surface replacement, and teardown.

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

To update, copy the new tag's wrapper files, reapply the local wrapper patches, and remove the
upstream test target. Update the pinned source revisions in `scripts/build-ghostty.sh`, port the
native patch after the wrapper's patch stack, and rebuild the whole xcframework. Replace the
archive, header, and provenance together. Never combine a new header with an old archive.
Run the native frame regression and guest terminal checks before accepting the update.
