# Tile scrolling and board panning

On local and remote boards, the first directional event's dominant axis chooses content that can move that way, otherwise the board, subject to the two exceptions below. One owner keeps both axes across tiles, content edges, resize, and momentum. Zero-delta setup does not choose an axis. Phaseless wheel events form one burst until a 250 ms gap. Command, Shift, and Move eligibility are read at the first event. Tile frames, page viewport dimensions, and saved board layout stay unchanged.

Pages get input first. Only the matching first-event WebKit unhandled callback can transfer the gesture to the board. JavaScript pages that call `preventDefault` keep their gesture even at a bound. Typing terminals without scrollback retain Ghostty's program behavior, so a short normal shell moves nothing. These are the two accepted exceptions. Missing required private WebKit selectors or older remote hosts keep pages page-first with no handoff. Pages lose native edge bounce.

Wheel and trackpad scrolling preserve selection and typing. A press inside an HTML or browser page, including its own scrollbar, is the one exception to selection and typing preservation: it selects the tile and gives it typing.

## Sub-features

- `scroll-wheel` checks content-first movement, initial-limit/fitting-content board panning, and START/END access on both axes with precise and line-based input.
- `scroll-ownership` keeps the original board or content owner across pointer crossings, resize, arrival, drift, edges, and momentum.
- `scroll-native` applies the directional rule before and after a click to terminal, rendered/editing note, code, changes, HTML, browser, question, image, video, diagram/detail, group header, and shape/text.
- `scroll-relay` scrolls a streamed browser in viewer B through its drawing viewer A, retaining phases and gesture identity.
- `space-pan` pans over every tile with board keys, without selecting it; Space with typing remains one ordinary typed space.

## How to get to it (user POV)

Point inside overflowing content and scroll in a direction with room. Content moves before any clipped browser edge is revealed. Start a new gesture at its content limit to pan the board, except for the accepted page and terminal cases above. Cross onto another tile during either kind of gesture: its owner must not change. With board keys, hold Space and drag over a tile; with typing, Space must remain text without delay or replay. Both Space and middle presses without a drag must replay the original click. New Move-tool and Command-scroll gestures keep board pan and zoom.

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

On the scratch remote board, establish [A's drawing identity and B's stream](browser-tiles.md) first. Record A's page offsets or visible markers before B's input. Require page movement in A and matching streamed pixels in B when content can move. At an unhandled starting page limit, only B's board pans after A's matching reply. Crossings and momentum must retain that owner. Keep drawing-client and stream IDs, phase receipts, and separate A/B captures; two local pages are not relay proof. Require first-forward delivery without a blocking capability wait, no `browser.eval`, no navigation credit or drive effects, and rejection of stale replies. Measure page first-movement and board-fallback latency separately over the home–deckbox link; do not infer either from relay correctness.

## Required matrix and evidence

- Run every tile row on both local and remote boards, before and after a click, with both real HID wheel input and separately labelled synthetic phased plus momentum input. Include terminal typing and not typing, normal and alternate screens, scrollback room and limits, and mouse reporting. Include rendered and editing notes, code, changes, HTML, browser, streamed browser, question, image, video, diagram and detail, group header, shape, and text.
- Test native controls both inside and outside tile bodies. Include code hover documentation, references panels, browser address controls, and question text fields. A native scroll view with room must scroll; its directional limit must pan on a new gesture. A panel inside a page tile but outside its web view must not route to the page.
- Test long plain pages, custom-element content, cross-origin iframes, still-loading pages, fitting pages, JavaScript `preventDefault` map-style handlers, and `overflow: hidden` editor-style handlers. Test both edges with phaseless and phased plus momentum input, locally and streamed. Preserve the JavaScript exception at the page's own bound.
- Exercise a zero-delta begin, dominant-axis choice, both-axis drift, pointer crossings, content edges, resize, and momentum end. Change Command, Shift, and Move mid-burst and require the first-event owner to remain. Direct board ownership keeps per-event Command zoom and Shift pan; page handoff keeps pan with initial Shift. Test phaseless gaps below and at 250 ms. Lose window focus while a page reply is pending and require wheel ownership to survive.
- Test Space-drag over every tile only with board keys. With typing, require one unchanged space in the program or field and no board pan. Test both Space and middle non-drag click replay, including a page click that gives typing. Retain selection, typing-owner, page-offset, board-origin, and terminal-program-byte readbacks.
- Record selector qualification for `_rubberBandingEnabled`, `_setRubberBandingEnabled:`, and `_webView:didNotHandleWheelEvent:`. Require mask `0`, no native edge bounce, and page-first/no-handoff behavior when a required selector is unavailable. An absent callback or timeout must never pan the board. DOM observations may measure movement but must never choose its owner.
- Retain the exact head and frozen bundle identity, fixture and board IDs, exact window receipts, live monotonic event timestamps, units, phase and momentum fields, raw readbacks, stdout/stderr, and screenshots or clips. Label CuaDriver targeted phaseless legs **real HID wheel** and `sendEvent` phased/momentum legs **synthetic, AppKit dispatch**. Never label synthetic momentum as a physical-trackpad run.
- Keep fail-before/pass-after native regression evidence and the five paired 200-tile performance blocks required by the lane brief. Retain main-thread stretch, idle CPU, and wakeup observations. Recipes are requirements, not a record of a passing run.

## Gotchas

- This is a manual authorized-capture regression, **not a CI step**. `.github/workflows/ci.yml` runs `Tests/BrowserInitialAdmission`, not `Tests/BrowserScrolling`. Green CI does not prove native scroll visibility.
- Require Python 3, Swift/AppKit, and the already-authorized `/Applications/CuaDriver.app`. No Pillow or package installation is needed. Never request capture permission during an unattended run.
- These runners use synthetic AppKit replay, not HID or a physical trackpad. Phaseless precise deltas are not trackpad-phase proof. `--gesture` adds zero-motion begin/end events. Direct phased WebKit replay can drop later steps; phased ownership observations do not prove full-document page traversal.
- These browser replay runners emit no momentum. Separately qualify a complete scroll began/changed/ended then momentum began/changed/ended sequence through the real `CanvasWindow` with `NSApp.sendEvent` or `window.sendEvent`. Every momentum event must have nonzero precise deltas and a live monotonic timestamp. Retain native window, point, phase, delta and movement receipts; a viewport readback or Core test alone is not input proof.
- Resize and arrival use a 30-event phased burst; drift adds a small horizontal delta to vertical input. Wait for the burst's completion receipt in `app.log` before inspecting the result.
- Remote forwarding always carries precise/line units, phase, and momentum. It adds gesture identity only with advertised gesture support. Older hosts stay page-first without handoff. Local replay is not remote proof.
- Source entry points are `Sources/CanvasApp/CanvasWindowController.swift`, `Sources/CanvasCore/CanvasWheel.swift`, `Sources/CanvasApp/DevInput.swift`, and `Tests/BrowserScrolling/`. `docs/testing.md` documents capture colour conversion and runner limits.
- Pages use WebKit's first-event unhandled result, never a pre-commit DOM query, `browser.eval`, timeout, or absent callback. Missing selectors leave page-first delivery without handoff.
- Terminal scrollback is directional and independent of typing. Without history, not typing pans the board; typing retains Ghostty's native program behavior. A short normal shell then moves nothing because pinned Ghostty has no active-screen or alternate-scroll getter. Mouse reporting never gets wheel input without typing. Horizontal terminal gestures pan the board.
