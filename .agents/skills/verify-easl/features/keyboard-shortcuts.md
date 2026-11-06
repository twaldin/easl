# Keyboard shortcuts

Users invoke menu actions through native key equivalents and change their bindings in the isolated instance's Settings window.

## Sub-features

- `keys-native` routes actual replayed key-down and key-up through canvas, composer, and terminal responders.
- `keys-settings` records, clears, resets, and persists a binding.
- `keys-conflict` swaps a conflicting binding or cancels without changing either.
- `keys-drawing` keeps bare drawing letters on the canvas rather than intercepting text input.
- `keys-rejection` refuses reserved or invalid bindings without changing the saved map.
- `keys-selection-typing` gives a single user-selected tile typing, keeps board gestures on the board, and preserves typing through programmatic navigation.

## How to get to it (user POV)

Press Command-comma or choose easl > Settings…. The **Settings** window opens directly to **Keyboard Shortcuts**. The current menus show current bindings. The full default table is `docs/keyboard-shortcuts.md`.

## Driving it with dev.sh

Preconditions: an isolated `EASL_DEV_HOME`, fresh settings, one owned terminal, and a scratch note. Retain baseline menus and `ui-settings.json` if present. Discover Settings as another window of the **same** dev PID and use its exact window ID.

- Send `scripts/dev.sh input shortcut t --mods cmd --window "$WINDOW"` and require one new terminal. Send Command-I from that terminal and require **Prompt** to receive text. Send Escape and verify the prior responder. Use `input state` and native before/after captures, not direct action selectors.
- Activate only the private app inside the claimed guest with `open -a "$EASL_DEV_HOME/easl.app"`. Give the canvas focus, then send `input shortcut m` and require Move. Test V and Escape independently and require Select. Repeat Escape through background replay, since the key-equivalent and document-responder routes differ. In terminal or note text, typing `m` must insert text rather than switch tools. Check the terminal received no drawing shortcuts during the drag in [Move tool](move-tool.md).
- Open Settings with `input shortcut , --mods cmd --window "$WINDOW"`. Read a fresh exact-window AX tree. Find **Record** by its title and the chosen action identifier; **Clear** and **Reset** share that identifier. Press **Record** through its fresh background AX action and confirm it becomes **Cancel**. Then send `input shortcut u --mods ctrl+opt+cmd --window "$SETTINGS_WINDOW"`. Capture the displayed chord and menu update. Invoke that chord from both the canvas and a focused terminal and require the intended action. Do not qualify key routing by `input mainmenu` or `input command`.
- Record a chord already owned by another action. Capture the conflict dialog naming that action. Choose **Cancel** and require both bindings unchanged. Repeat, choose **Swap**, and invoke both resulting chords. If the first action was unbound, the second must become unbound.
- Use **Clear**, **Reset**, and **Restore Defaults** in separate cases, retaining the resulting menu bindings and behavior. Restart the same development home, rediscover its windows, and verify the chosen persisted binding before restoring defaults.
- Attempt to record Command-L and require a rejection with no binding change. Cancel recording with Escape, then separately by moving focus to the board window, and require the original binding. Test a bare drawing-letter swap into a global action and require refusal. Record active keyboard layout when qualifying punctuation.
- To test Ghostty remap precedence, set `XDG_CONFIG_HOME` to a scratch directory before launching and put the test configuration in its `ghostty` directory. `EASL_DEV_HOME` does not isolate Ghostty configuration. The guest account's `~/Library/Application Support/com.mitchellh.ghostty` configuration is still read; require it absent or record that unmet isolation prerequisite without changing the shared file. Qualify unchanged default and customized bindings separately, retaining which action receives each chord.

### Selection and typing

Run local and scratch remote boards. Keep a raw terminal byte recorder, a note, an HTML page with two fields and an object link, and a browser textarea. Record `view.get` selection and `focused` before and after each action.

1. Click note prose once and type. Require the exact saved markdown and caret placement. Click an HTML field once and require its visible value and `props.state` receipt.
2. Focus the terminal recorder. Click HTML prose and immediately post a native key. Require no new terminal bytes, including while the page delays its mouse handler. A pending key may be delivered to HTML or dropped, never sent to the previous terminal.
3. Click the HTML object link. Require destination selection and source HTML typing. Separately perform a permitted programmatic `canvasKit.goTo` after restoring terminal typing; no click at navigation time may change that responder. The bridge still requires its existing fresh gesture permit.
4. Marquee one terminal, Shift-click to select several tiles, and select a group. Require board ownership and no terminal receipt. Command-9 must still zoom the board. Select an image and require board ownership.
5. Send plain Escape to the terminal program and require byte `1b`. Command-Escape must leave typing without a second byte or selection change. Repeat Leave Tile for every keyboard-handling type.
6. Type into the browser textarea, undo with Command-Z, and redo with Shift-Command-Z. Require exact DOM text and unchanged board object frames. Repeat in HTML.
7. Record selection and typing, then scroll a rendered note, drag its scrollbar, resize or move another tile, hover, and pinch. Both states must stay unchanged. A title/card click without dragging still selects; an overview-card drag must retain zoom and save exactly its pointer delta.
8. Click note prose, type, and finish with plain Escape and Command-Return in separate trials. If typing returns to the prompt terminal, require selection to move to that terminal and the next key to reach its recorder. With no prompt terminal, require the note to stay selected with board keys. Keyboard/title entry also returns to the board.
9. Right-click an unselected tile and cancel its native context menu without a command. Require that single tile's typing and a native text or terminal-byte result. Repeat for an already singly selected tile and for a member of a multi-selection; the latter keeps the multi-selection and board keys.
10. Exercise the shipped `view.open_url` command through the private app socket while another tile has typing. Require destination selection, the exact previous responder, and a real typed result in that owner. There is no tile-select CLI command. Separately choose a destination through Command-P and require typing in that destination.
11. Drag a visible scrollbar on overflowing HTML through the guest's authorized HID pointer path. Require an actual DOM scroll delta, then require that the HTML tile is selected and has typing. Repeat for a browser page. A page press, including its own scrollbar, is the one exception to the scroll rule. Wheel and trackpad scrolling must preserve selection and typing. A replayed mouse event that does not scroll is not proof. If native tracking cannot be driven, retain the exact attempted pointer calls and pixels.

Replay uses `scripts/dev.sh input key` and `shortcut` with the owned window ID. Independently exercise genuine HID inside the guest using `/Applications/CuaDriver.app/Contents/MacOS/cua-driver call press_key` with JSON fields `pid`, `window_id`, a unique `session`, `key`, `modifiers`, and `delivery_mode: "foreground"`. This exact-window route briefly activates the owned guest window and restores the previous app. Never invoke it on home. Retain the delivery receipt and verify independent pixels or terminal bytes; a posted-key receipt alone proves no effect. End the Cua session before cleanup.

Supplement the real-app proof with the native matrix:

```sh
swift build --build-system native -c release -j 2 --product Easl -Xswiftc -enable-testing
python3 Tests/SelectionTyping/run.py --bin-path "$(swift build --build-system native -c release --show-bin-path)" --output "$G/proof/selection-typing"
```

The fixture installs production menus and a native board window/controller, activates only its isolated guest process, and tests native key equivalents. Its CLI cases use a real socket and production API router with the same view adapter as the app. Full application startup and registration remain part of the real-app proof. Baseline menu controls are not evidence until the fixture has a key window and the board undo control passes.


## Gotchas

- `input command` calls an AppKit selector directly. It does not prove the physical shortcut path. `shortcut` and `key` do exercise key equivalents and the responder chain.
- Settings and a board can have different window IDs under one PID. Untargeted input can test the wrong responder.
- Hard-coded reserved chords are refused. An action's own default bypasses the additional enabled macOS symbolic-hotkey check. Bare letters are drawing tools, not global shortcuts. Replay uses US-ANSI key codes and supplied characters; it does not qualify non-US physical-key translation.
- Custom menu bindings and unchanged default bindings have different precedence over Ghostty remaps. Test both when changing that contract.
- Use current menu titles and AX labels. The default table is not proof that an instance has those bindings.
