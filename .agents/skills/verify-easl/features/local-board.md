# Local board basics

Users create tiles and drawings on a folder's board, arrange them, and undo changes without sending input into live tile content.

## Sub-features

- `board-create` creates a note through the menu and keyboard.
- `board-move-undo` moves a selection and restores it with one undo.
- `board-draw` creates rectangles, ellipses, arrows, text, and ink through the drawing tools.
- `board-middle-pan-cancel` consumes a cancelled middle-button sequence without sending its release to a terminal.

## How to get to it (user POV)

Open a folder with File > Open Board… or New Board Tab…. Choose File > New Note or press Command-N. Choose drawing tools in the toolbar or use V, M, R, O, A, T, and P with the canvas holding the keyboard.

## Driving it with dev.sh

Preconditions: the isolated local board is selected, Get Started is closed, and the current PID/window passed Doctor. Obtain fresh content-point coordinates from native pixels and `view.get` before every gesture.

- Create a note with `scripts/dev.sh input mainmenu "File/New Note"`. Enter distinct text with `input text`, then commit with `input key escape`. Capture rendered text and retain `scripts/dev.sh cli board.get`. Repeat with `input shortcut n --mods cmd`, committing that note too. Require both distinct Markdown values in the board.
- Leave text editing with `input key escape`. Select a note by its title or measured bounds, drag its title with `input drag "$X" "$Y" "$TO_X" "$TO_Y"`, and retain the old and new frames through `object.get --id "$NOTE"`. `input shortcut z --mods cmd` must restore the original frame in the API and pixels.
- With canvas focus, use `input mainmenu "Drawing/Rectangle"` and drag on empty canvas. Repeat for Ellipse and Arrow. Use Text, click empty canvas, and type a label. Commit it with `input key escape` before inspecting the object or choosing Draw. Use Draw and drag a stroke. Capture each tool's visible result and confirm its object in `board.get`. Undo each completed drawing once. Also select the same tools from their toolbar accessibility buttons when qualifying toolbar interaction.
- For body drags, grouped movement, cancellation, and content input isolation, run the separate [Move tool journey](move-tool.md).

### Middle-pan cancellation

Use a raw-mode terminal consumer that enables SGR mouse reporting with `ESC[?1000h ESC[?1006h` and records received bytes. Keep all activation changes inside the claimed guest.

1. Send `input drag "$X" "$Y" "$X" "$Y" --middle` over the terminal body. Require one SGR middle-button press/release pair as a positive control.
2. Send `input drag "$X" "$Y" "$TO_X" "$Y" --middle --hold`, with `TO_X` 120 points to the right. Confirm the viewport moved.
3. Activate another guest app, then reactivate the private easl PID without another middle press. Confirm both frontmost-PID changes.
4. Send `input release "$TO_X" "$Y" --middle`. Require no new consumer bytes. The old bug appends a release ending in `m` without a press ending in `M`.
5. Send another still middle click. Require a new complete pair, proving the next gesture still works.
6. Repeat cancellation with a held press that has not moved. Require no new bytes.

Retain raw bytes and exact-window captures. A pending press alone does not reproduce the old bug reliably. The positive control followed by an actual pan is required.

## Gotchas

- Bare drawing keys type into editable content. Give the canvas the keyboard first, then confirm `input state`.
- API `object.create` is useful setup but does not prove File menu or drawing-tool creation.
- The title-bar drag and Move's body drag are separate paths. Do not substitute one for the other.
- A changed frame alone does not prove the terminal received no input. Retain terminal output and responder state too.
