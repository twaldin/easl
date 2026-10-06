# Vendored libghostty-spm

- Upstream: https://github.com/Lakr233/libghostty-spm (MIT, see `LICENSE`)
- Tag: `1.6.20260922` (commit `b7f888e3baf8585ea9d590ab1a45b49475e00d1c`)
- Kept: `Package.swift`, `LICENSE`, `Sources/**`, unchanged except the test target and the patches
  below. The `libghostty` xcframework stays a remote `binaryTarget` with upstream's URL and
  checksum.
- Dropped: `Example/`, `Tests/`, `docs/`, `Script/`, `Patches/`, `build.sh`, `Ghostty.build`,
  `Ghostty.ref`, `Package.local.swift`, `Package.swift.template`, `.github/`, `.gitattributes`,
  `.gitignore`, `.root`, `README.md`, `AGENTS.md`, `CLAUDE.md`, and the `GhosttyKitTest` test
  target in `Package.swift`.

## Patch

`Sources/GhosttyTerminal/Configuration/GhosttyRuntimeResources.swift` looks for
`GhosttyKit_GhosttyTerminal.bundle` in `Bundle.main.resourceURL` first and falls back to
`Bundle.module`. SwiftPM's generated `Bundle.module` accessor checks only the app's root and the
absolute build directory baked in at compile time, and traps when neither exists. An app
assembled from `swift build` output keeps resource bundles in `Contents/Resources` (codesign
rejects them at the app's root), so without the patch the first terminal crashes Canvas on any
machine without the build directory.

The same change as a unified diff against upstream: `patches/libghostty-spm-resources.patch` at
the Canvas repo root (`git apply` in an upstream checkout). To update, copy the new tag's files as
above, reapply the patch, and drop the test target again.

## Patch: private clipboard writes

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
