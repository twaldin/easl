# Tile scrolling and board panning

On local and remote boards, a new gesture scrolls content when it can move in the initial direction; empty board, fitting content, or a starting directional limit pans the board. One owner keeps both axes across tiles, content edges, resize, and momentum. Phaseless wheel events form one burst until a 250 ms gap. Tile frames, page viewport dimensions, and saved board layout stay unchanged.

Wheel and trackpad scrolling preserve selection and typing. A press inside an HTML or browser page, including its own scrollbar, is the one exception to the scroll rule: it selects the tile and gives it typing.

## Sub-features

- `scroll-wheel` checks content-first movement, initial-limit/fitting-content board panning, and START/END access on both axes with precise and line-based input.
- `scroll-ownership` keeps the original board or content owner across pointer crossings, resize, arrival, drift, edges, and momentum.
- `scroll-native` applies the directional rule before and after a click to terminal, rendered/editing note, code, changes, HTML, browser, question, image, video, diagram/detail, group header, and shape/text.
- `scroll-relay` scrolls a streamed browser in viewer B through its drawing viewer A, retaining phases and gesture identity.
- `space-pan` pans over every tile with board keys, without selecting it; Space with typing remains one ordinary typed space.

## How to get to it (user POV)

Point inside overflowing content and scroll in a direction with room. Content moves before any clipped browser edge is revealed. Start a new gesture at its content limit to pan the board. Cross onto another tile during either kind of gesture: its owner must not change. With board keys, hold Space and drag over a tile; with typing, Space must remain text. New Move-tool and Command-scroll gestures keep board pan and zoom.

## Driving it with dev.sh

Follow Launch and Doctor in the claimed guest. Use the frozen bundle, not an installed app. The standalone runners own disposable development homes; they do not use the long-lived viewer's home.

```sh
python3 "$R/Tests/BrowserScrolling/run.py" \
  --app "$G/frozen.app" --out "$G/proof/browser-scrolling"
python3 "$R/Tests/BrowserScrolling/resize.py" --app "$G/frozen.app"
python3 "$R/Tests/BrowserScrolling/resize.py" --app "$G/frozen.app" --arrival
python3 "$R/Tests/BrowserScrolling/resize.py" --app "$G/frozen.app" --drift
```

Retain each command's stdout/stderr under a distinct evidence name. `resize.py` has no `--out` and removes its temporary home. The main runner retains per-case captures and readbacks, exact-PID/window receipts, `pixels.json`, and `app.log` under `--out`. Inspect the actual PNGs, including the final END marker's coloured border clear of native chrome. It checks unchanged tile frame and WebKit viewport.

For manual replay in the health-checked viewer, measure `X`,`Y` inside the page body in content points. Match the intended board and exact own window in fresh `input state` and window-discovery receipts, then pass `--window "$WINDOW"` on every scroll. A stale window ID drops the input. Without that flag, replay uses the front board window; `selected:true` alone is ambiguous across window groups.

```sh
scripts/dev.sh input scroll "$X" "$Y" 0 -12 --lines --window "$WINDOW"
scripts/dev.sh input scroll "$X" "$Y" 0 -240 --window "$WINDOW"
scripts/dev.sh input scroll "$X" "$Y" 0 -120 --repeat 4 --interval 8 --gesture --window "$WINDOW"
```

These move toward the bottom. Use positive Y for top, negative X for right, and positive X for left. Repeat with bounded attempts until native START/END pixels and independent canvas/page readbacks prove each edge. Keep original frame/viewport readbacks for comparison. The runner uses at most 150 attempts and fails after three unchanged comparisons.

On the scratch remote board, establish [A's drawing identity and B's stream](browser-tiles.md) first. Record A's page offsets or visible markers before B's input. Require page movement in A and matching streamed pixels in B when content can move. At a starting page limit, only B's board pans. Crossings and momentum must retain that owner. Keep drawing-client and stream IDs, phase receipts, and separate A/B captures; two local pages are not relay proof.

## Gotchas

- This is a manual authorized-capture regression, **not a CI step**. `.github/workflows/ci.yml` runs `Tests/BrowserInitialAdmission`, not `Tests/BrowserScrolling`. Green CI does not prove native scroll visibility.
- Require Python 3, Swift/AppKit, and the already-authorized `/Applications/CuaDriver.app`. No Pillow or package installation is needed. Never request capture permission during an unattended run.
- These runners use synthetic AppKit replay, not HID or a physical trackpad. Phaseless precise deltas are not trackpad-phase proof. `--gesture` adds zero-motion begin/end events. Direct phased WebKit replay can drop later steps; phased ownership observations do not prove full-document page traversal.
- Replay emits no momentum. Complete qualification needs separately labelled CG scroll-phase and momentum-phase synthesis through the HID path, with native event receipts. Never substitute a viewport readback or Core test for that input proof.
- Resize and arrival use a 30-event phased burst; drift adds a small horizontal delta to vertical input. Wait for the burst's completion receipt in `app.log` before inspecting the result.
- Remote forwarding carries precise/line units, phase, momentum, and gesture identity. Hosts without scroll capability take the unknown-page board fallback. Local replay is not remote proof.
- Source entry points are `Sources/CanvasApp/CanvasWindowController.swift`, `Sources/CanvasCore/CanvasWheel.swift`, `Sources/CanvasApp/DevInput.swift`, and `Tests/BrowserScrolling/`. `docs/testing.md` documents capture colour conversion and runner limits.
- Pages use a pre-commit directional DOM extent query. Inaccessible or unknown content, failed queries, and timeouts pan the board rather than first committing page input and then chaining it.
- Terminal scrollback is directional and independent of typing. Without history, not typing pans the board; typing retains Ghostty's native program behavior. A short normal shell then moves nothing because pinned Ghostty has no active-screen or alternate-scroll getter. Mouse reporting never gets wheel input without typing.
