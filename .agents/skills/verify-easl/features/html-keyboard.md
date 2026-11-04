# HTML keyboard ownership

Users give an HTML tile typing with a single user selection or a real body mouse-down. Native ownership changes synchronously before later keys. Page autofocus alone cannot take native typing.

## Sub-features

- `html-keyboard-return` enters a selected tile with Return.
- `html-keyboard-click` enters through any real body click and keeps immediate keys away from the previous responder.
- `html-keyboard-release` returns ownership to the canvas with Command-Escape, an unhandled plain Escape, or a board click.
- `html-keyboard-autofocus` refuses keyboard capture from load-time page focus.
- `html-keyboard-document` revokes the old document's grant when HTML changes.

## How to get to it (user POV)

Select an HTML tile by its title or click anywhere in its body. A field click places its native caret. Command-Escape leaves typing without changing selection. Plain Escape stays with the page when handled there.

## Driving it with dev.sh

Preconditions: follow Launch and Doctor. Run on a local board and a real remote board served by guest-local scratch easld. Use actual native fields and `canvasKit.setState` readback, not direct DOM value assignment.

1. Seed an HTML tile with labelled Answer input and Notes textarea. On load, restore each value with `await canvasKit.getState(id)`. On input, call `canvasKit.setState(id, field.value)`. Call `answer.focus()` on load. Include a visible saved-state label.
2. Leave the board holding typing and navigate programmatically to the tile. Capture the loaded fields. Press native M and require the Move tool while `props.state` remains unchanged. Load-time DOM focus is not a keyboard grant. Return to Select with V.
3. Click the title once. Type `title-path` in Answer. Require visible text and `props.state.answer`. Independently use Command-Escape and Return to qualify reentry.
4. Press Command-Escape. Require `CanvasDocumentView`, unchanged selection, and native M selecting Move without changing either field. Return to Select. Test plain Escape separately with both page-handled and unhandled events.
5. Derive the Notes field's content-point coordinates from a fresh exact-window capture. Click inside it and type `click-path`. Require visible text and `props.state.notes`. Press Command-Escape and verify canvas ownership again.
6. Independently reacquire the page, then click empty board space while it still has the keyboard. Require release. A board click after Escape does not qualify this transition.
7. Regrant the old page and prove it receives a native key. While it still owns the keyboard, replace the tile's HTML with a visibly marked new document. Wait for that marker, then type digits without another Return or field click. Require no replacement-page key receipt. Press V to select the canvas's Select tool before granting the page again. Require new input after that grant and read saved state after reload.

## Supplemental regression modes

The existing `Tests/HtmlKeyboard/run.py --bin-path "$BIN_PATH"` links and runs the default AppKit regression. It accepts no mode flags. Run focused modes on the linked `HtmlKeyboard` executable in the guest, with the environment `run.py` sets: temporary `EASL_HOME`, `CFFIXED_USER_HOME`, and `XDG_CONFIG_HOME`, `EASL_NO_ACTIVATE=1`, and no `EASL_ROOT`.

- `--hostile-clicks` checks that delayed or patched page getters cannot redirect typing after a native click or override a later native action.
- `--dom-clicks` covers `--clobbered-click` and `--stale-focus-click` using actual page fields and native clicks.
- `--document-grants` rejects old grants after HTML replacement, then accepts a fresh field click.
- `--missing-selector` hides the private focus-suppression selector and exercises the independent native gate.

## Gotchas

- AppKit runners supplement exact-window captures. Their constructed remote source is not proof against a live remote daemon.
- The default runner's editable fixture uses textareas. Qualify input, select, contenteditable, clipboard, and IME separately before claiming those paths.
- Test Tab, Delete, blur followed by page keys, and a page-handled first Escape when changing keyboard routing. Require no canvas action while the page retains ownership.
- Navigation, asset reload, WebContent crash, and activation changes need their own exercised transitions. Do not infer them from HTML replacement.
- Source entry points are `Sources/CanvasApp/Html/HtmlWeb.swift`, `Sources/CanvasApp/Html/HtmlTile.swift`, and `Tests/HtmlKeyboard/HtmlKeyboard.swift`.
