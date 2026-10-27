# Native browser scrolling

Plain scrolling over an oversized live browser first reveals the canvas-clipped edge in the scroll direction, clear of the toolbar and tray. Later wheel steps scroll the page. Tile frames, page viewport dimensions, and saved board layout stay unchanged.

## Sub-features

- `scroll-wheel` reaches START and END on both axes with precise and line-based wheel input.
- `scroll-gesture` reveals clipped edges while retaining one owner through a phased gesture.
- `scroll-ownership` keeps ownership across resize, browser arrival under the pointer, and minor horizontal drift.
- `scroll-relay` reveals a streamed browser in viewer B and forwards subsequent page scrolling to drawing viewer A.

## How to get to it (user POV)

Open an oversized browser tile with a document longer and wider than its viewport. Point inside the visible page body and scroll toward a clipped edge. Start a new trackpad gesture after revealing an edge to scroll the page. Move-tool panning and Command-scroll zoom keep their separate behavior.

## Driving it with dev.sh

Follow Launch and Doctor in the claimed guest. Use the frozen bundle, not an installed app. The standalone runners own disposable development homes; they do not use the long-lived viewer's home.

```sh
python3 "$R/Tests/BrowserScrolling/run.py" \
  --app "$G/frozen.app" --out "$G/proof/browser-scrolling"
python3 "$R/Tests/BrowserScrolling/resize.py" --app "$G/frozen.app"
python3 "$R/Tests/BrowserScrolling/resize.py" --app "$G/frozen.app" --arrival
python3 "$R/Tests/BrowserScrolling/resize.py" --app "$G/frozen.app" --drift
```

Retain each command's stdout/stderr under a distinct evidence name. `resize.py` has no `--out` and removes its temporary home. The main runner retains initial, reached-edge, final, and failed clipped-window captures, exact-PID/window receipts, `pixels.json`, and `app.log` under `--out`. Inspect the actual PNGs, including the final END marker's coloured border clear of native chrome. It checks unchanged tile frame and WebKit viewport.

For manual replay in the health-checked viewer, measure `X`,`Y` inside the page body in content points. Confirm the selected window through a fresh `input state`. The scroll command targets the selected board; unlike click/key, it does not select an arbitrary window from `--window`.

```sh
scripts/dev.sh input scroll "$X" "$Y" 0 -12 --lines
scripts/dev.sh input scroll "$X" "$Y" 0 -240
scripts/dev.sh input scroll "$X" "$Y" 0 -120 --repeat 4 --interval 8 --gesture
```

These move toward the bottom. Use positive Y for top, negative X for right, and positive X for left. Repeat with bounded attempts until native START/END pixels and independent canvas/page readbacks prove each edge. Keep original frame/viewport readbacks for comparison. The runner uses at most 150 attempts and fails after three unchanged comparisons.

On the scratch remote board, establish [A's drawing identity and B's stream](browser-tiles.md) first. Repeat native edge reveal and page scroll in B, capturing B and A separately. Two local pages are not relay proof.

## Gotchas

- This is a manual authorized-capture regression, **not a CI step**. `.github/workflows/ci.yml` runs `Tests/BrowserInitialAdmission`, not `Tests/BrowserScrolling`. Green CI does not prove native scroll visibility.
- Require Python 3, Swift/AppKit, and the already-authorized `/Applications/CuaDriver.app`. No Pillow or package installation is needed. Never request capture permission during an unattended run.
- Phaseless precise deltas are not trackpad-phase proof. `--gesture` adds zero-motion begin/end events; `--repeat 4` has two moving steps. Direct phased WebKit replay can drop later steps, so the runner checks phased canvas reveal with a viewport-sized document, not full-document traversal.
- Replay emits no momentum sequence. Physical-trackpad momentum still needs physical input proof. The production gesture model retains its first owner through momentum.
- Resize and arrival use a 30-event phased burst; drift adds a small horizontal delta to vertical input. Wait for the burst's completion receipt in `app.log` before inspecting the result.
- Remote page forwarding preserves precise-versus-line units but is phaseless. Do not claim remote physical-trackpad coverage from local replay.
- Source entry points are `Sources/CanvasApp/CanvasWindowController.swift`, `Sources/CanvasCore/CanvasWheel.swift`, `Sources/CanvasApp/DevInput.swift`, and `Tests/BrowserScrolling/`. `docs/testing.md` documents capture colour conversion and runner limits.
