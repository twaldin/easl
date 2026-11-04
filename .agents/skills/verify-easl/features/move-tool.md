# Move tool

Users drag tile bodies without focusing their content. Move also pans over live content instead of scrolling it.

## Sub-features

- `move-entry` selects Move through the toolbar, Drawing > Move, and the default M key.
- `move-body` moves a live terminal without delivering input or focus.
- `move-selection` moves a multi-selection or group as one undoable transaction.
- `move-cancel` cancels a held drag without committing frames.
- `move-pan` pans over live tiles and prevents parked content from regaining focus.

## How to get to it (user POV)

Choose Move in the drawing toolbar or Drawing > Move, or press the default M key with canvas focus. Drag a tile's body. V or Escape returns to Select.

## Driving it with dev.sh

Preconditions: a selected scratch board with a live terminal, a note, and a group. Activate only the private app inside the claimed guest with `open -a "$EASL_DEV_HOME/easl.app"`. Retain frames, revision, terminal readback, responder state, and fresh measured content-point coordinates. Run locally, then on scratch easld with a second viewer.

1. With canvas focus, select Move through its toolbar AX button. Repeat through `input mainmenu "Drawing/Move"` and `input shortcut m`. Capture the selected tool for each entry. Use default bindings for the key case.
2. Record selection and typing, then drag the terminal's live body with `input drag "$X" "$Y" "$TO_X" "$TO_Y" --window "$WINDOW"`. Require the new frame, unchanged terminal input, and exactly the prior selection and typing. Repeat moving an unselected note while another tile owns typing. A title-bar drag does not qualify the body case.
3. Shift-select another tile and drag both by a body. One Command-Z must restore both frames. Repeat with the group and check every member's delta. On the remote board, capture the committed result in both viewers.
4. Start `input drag "$X" "$Y" "$TO_X" "$TO_Y" --hold --window "$WINDOW"`. Capture the preview, press Escape, then `input release "$TO_X" "$TO_Y" --window "$WINDOW"`. Require Select, the original visible and committed frames, an unchanged revision, and no terminal byte.
5. In Move, `input scroll "$X" "$Y" 0 100 --window "$WINDOW"` over the terminal must pan, not scroll its history. Selection and typing must stay unchanged. Separately leave the terminal with Command-Escape, pan it out until it becomes a card, and pan back. Panning must not restore its typing. V or Escape returns to Select.

## Gotchas

- `Sources/CanvasApp/Drawing/ShapeLayer.swift` defines tools. Move gestures preserve the existing keyboard owner.
- `Sources/CanvasApp/CanvasView.swift` intercepts tile bodies and commits grouped movement.
- `Sources/CanvasApp/Drawing/ShapeLayer+Tools.swift` handles Escape cancellation.
- `Sources/CanvasApp/CanvasWindowController.swift` intercepts Move scrolling.
- Bare M in a text editor inserts text. Give the canvas focus before qualifying its shortcut.
- Qualify Escape with the private guest app active. Background replay can use the key-equivalent route instead of the active window's document responder. A background-only pass does not cover both.
- Target `drag`, `scroll`, and `release` with the recorded `--window "$WINDOW"`. Confirm its board in fresh `input state`; `selected:true` alone is ambiguous across window groups. Untargeted replay uses the front board window.
