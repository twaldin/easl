# Local board basics

Users create tiles and drawings on a folder's board, arrange them, and undo changes without sending input into live tile content.

## Sub-features

- `board-create` creates a note through the menu and keyboard.
- `board-move-undo` moves a selection and restores it with one undo.
- `board-move-tool` drags a live terminal by its body without focusing or typing into it.
- `board-draw` creates rectangles, ellipses, arrows, text, and ink through the drawing tools.

## How to get to it (user POV)

Open a folder with File > Open Board… or New Board Tab…. Choose File > New Note or press Command-N. Choose drawing tools in the toolbar or use V, M, R, O, A, T, and P with the canvas holding the keyboard.

## Driving it with dev.sh

Preconditions: the isolated local board is selected, Get Started is closed, and the current PID/window passed Doctor. Obtain fresh content-point coordinates from native pixels and `view.get` before every gesture.

- Create a note with `scripts/dev.sh input mainmenu "File/New Note"`. Enter distinct text with `input text`. Capture the text in native pixels and retain `scripts/dev.sh cli board.get`. Repeat the creation entry with `input shortcut n --mods cmd`. The board must contain two distinct notes.
- Leave text editing with `input key escape`. Select a note by its title or measured bounds, drag its title with `input drag "$X" "$Y" "$TO_X" "$TO_Y"`, and retain the old and new frames through `object.get --id "$NOTE"`. `input shortcut z --mods cmd` must restore the original frame in the API and pixels.
- Create a terminal using [the terminal journey](terminals.md). With canvas focus, press `input shortcut m`. Drag the terminal's **live body**, then Shift-click a second tile and drag both. One Command-Z must restore both frames. Retain terminal readback before and after; no gesture may type into it or give it keyboard focus. `input state` must show canvas focus.
- Start a held drag with `input drag "$X" "$Y" "$TO_X" "$TO_Y" --hold`, capture the preview, then send Escape and release with `input release "$TO_X" "$TO_Y"`. The preview must cancel without a frame commit. V or Escape returns to Select. In Move, `input scroll "$X" "$Y" 0 100` over a tile must pan the board instead of scrolling its content.
- With canvas focus, use `input mainmenu "Drawing/Rectangle"` and drag on empty canvas. Repeat for Ellipse and Arrow. Use Text, click empty canvas, and type a label. Use Draw and drag a stroke. Capture each tool's visible result and confirm its object in `board.get`. Undo each completed drawing once. Also select the same tools from their toolbar accessibility buttons when qualifying toolbar interaction.
- Focus a terminal in Select, pan it offscreen until it becomes a card, then enter Move and pan back. It must not regain terminal focus. Escape must not send a byte. Repeat the Move, group, and multi-selection cases through a scratch remote board with a second viewer before claiming remote behavior.

## Gotchas

- Bare drawing keys type into editable content. Give the canvas the keyboard first, then confirm `input state`.
- API `object.create` is useful setup but does not prove File menu or drawing-tool creation.
- The title-bar drag and Move's body drag are separate paths. Do not substitute one for the other.
- A changed frame alone does not prove the terminal received no input. Retain terminal output and responder state too.
