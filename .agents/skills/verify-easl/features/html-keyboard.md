# HTML keyboard ownership

Users give an HTML tile the keyboard with Return or a click in an editable field. Page autofocus alone cannot take native keyboard ownership.

## Sub-features

- `html-keyboard-return` enters a selected tile with Return.
- `html-keyboard-click` enters through a real field click.
- `html-keyboard-release` returns ownership to the canvas with an unhandled Escape or a board click.
- `html-keyboard-autofocus` refuses keyboard capture from load-time page focus.
- `html-keyboard-document` revokes the old document's grant when HTML changes.

## How to get to it (user POV)

Select an HTML tile by its title, then press Return. Click an input, textarea, select, or contenteditable element to enter directly. Press Escape to return to the canvas, unless the page handles that Escape.

## Driving it with dev.sh

Preconditions: follow Launch and Doctor. Run on a local board and a real remote board served by guest-local scratch easld. Use actual native fields and `canvasKit.setState` readback, not direct DOM value assignment.

1. Seed an HTML tile with labelled Answer input and Notes textarea. On load, restore each value with `await canvasKit.getState(id)`. On input, call `canvasKit.setState(id, field.value)`. Call `answer.focus()` on load. Include a visible saved-state label.
2. Navigate to the tile without entering it. Capture the loaded fields. Press native M and require the Move tool while `props.state` remains unchanged. Load-time DOM focus is not a keyboard grant. Return to Select with V.
3. Select the title and press native Return. Type `return-path` in Answer. Require its visible value and `props.state.answer`. Capture the native responder receipt and field pixels before and after.
4. Press Escape. Require `CanvasDocumentView`, the same selected tile, and native M selecting Move without changing either field. Return to Select.
5. Derive the Notes field's content-point coordinates from a fresh exact-window capture. Click inside it and type `click-path`. Require visible text and `props.state.notes`. Press Escape and verify canvas ownership again.
6. Independently reacquire the page, then click empty board space while it still has the keyboard. Require release. A board click after Escape does not qualify this transition.
7. Regrant the old page and prove it receives a native key. While it still owns the keyboard, replace the tile's HTML with a visibly marked new document. Wait for that marker, then type digits without another Return or field click. Require no replacement-page key receipt. Press V to select the canvas's Select tool before granting the page again. Require new input after that grant and read saved state after reload.

## Supplemental regression modes

The existing `Tests/HtmlKeyboard/run.py --bin-path "$BIN_PATH"` links and runs the default AppKit regression. It accepts no mode flags. Run focused modes on the linked `HtmlKeyboard` executable in the guest, with the environment `run.py` sets: temporary `EASL_HOME`, `CFFIXED_USER_HOME`, and `XDG_CONFIG_HOME`, `EASL_NO_ACTIVATE=1`, and no `EASL_ROOT`.

- `--hostile-clicks` rejects delayed promises, patched page-world getters, and focus-away-and-back or later-click grants.
- `--dom-clicks` covers both `--clobbered-click` and `--stale-focus-click` checks against real DOM getters and click containment.
- `--document-grants` rejects old grants after HTML replacement, then accepts a fresh field click.
- `--missing-selector` hides the private focus-suppression selector and exercises the independent native gate.

## Gotchas

- AppKit runners supplement exact-window captures. Their constructed remote source is not proof against a live remote daemon.
- The default runner's editable fixture uses textareas. Qualify input, select, contenteditable, clipboard, and IME separately before claiming those paths.
- Test Tab, Delete, blur followed by page keys, and a page-handled first Escape when changing keyboard routing. Require no canvas action while the page retains ownership.
- Navigation, asset reload, WebContent crash, activation changes, and pending-click expiry need their own exercised transitions. Do not infer them from HTML replacement.
- Source entry points are `Sources/CanvasApp/Html/HtmlWeb.swift`, `Sources/CanvasApp/Html/HtmlTile.swift`, and `Tests/HtmlKeyboard/HtmlKeyboard.swift`.
