# Keyboard shortcuts

Users invoke menu actions through native key equivalents and change their bindings in the isolated instance's Settings window.

## Sub-features

- `keys-native` routes actual replayed key-down and key-up through canvas, composer, and terminal responders.
- `keys-settings` records, clears, resets, and persists a binding.
- `keys-conflict` swaps a conflicting binding or cancels without changing either.
- `keys-drawing` keeps bare drawing letters on the canvas rather than intercepting text input.
- `keys-rejection` refuses reserved or invalid bindings without changing the saved map.

## How to get to it (user POV)

Press Command-comma or choose easl > Settings…. The **Settings** window opens directly to **Keyboard Shortcuts**. The current menus show current bindings. The full default table is `docs/keyboard-shortcuts.md`.

## Driving it with dev.sh

Preconditions: an isolated `EASL_DEV_HOME`, fresh settings, one owned terminal, and a scratch note. Retain baseline menus and `ui-settings.json` if present. Discover Settings as another window of the **same** dev PID and use its exact window ID.

- Send `scripts/dev.sh input shortcut t --mods cmd --window "$WINDOW"` and require one new terminal. Send Command-I from that terminal and require **Prompt** to receive text. Send Escape and verify the prior responder. Use `input state` and native before/after captures, not direct action selectors.
- Give the canvas focus, then send `input shortcut m` and require Move. V and Escape must restore Select. In terminal or note text, typing `m` must insert text rather than switch tools. Check the terminal received no drawing shortcuts during the drag in [Move tool](move-tool.md).
- Open Settings with `input shortcut , --mods cmd --window "$WINDOW"`. Read a fresh exact-window AX tree. Find **Record** by its title and the chosen action identifier; **Clear** and **Reset** share that identifier. Press **Record** through its fresh background AX action and confirm it becomes **Cancel**. Then send `input shortcut u --mods ctrl+opt+cmd --window "$SETTINGS_WINDOW"`. Capture the displayed chord and menu update. Invoke that chord from both the canvas and a focused terminal and require the intended action. Do not qualify key routing by `input mainmenu` or `input command`.
- Record a chord already owned by another action. Capture the conflict dialog naming that action. Choose **Cancel** and require both bindings unchanged. Repeat, choose **Swap**, and invoke both resulting chords. If the first action was unbound, the second must become unbound.
- Use **Clear**, **Reset**, and **Restore Defaults** in separate cases, retaining the resulting menu bindings and behavior. Restart the same development home, rediscover its windows, and verify the chosen persisted binding before restoring defaults.
- Attempt to record Command-L and require a rejection with no binding change. Cancel recording with Escape, then separately by moving focus to the board window, and require the original binding. Test a bare drawing-letter swap into a global action and require refusal. Record active keyboard layout when qualifying punctuation.
- To test Ghostty remap precedence, set `XDG_CONFIG_HOME` to a scratch directory before launching and put the test configuration in its `ghostty` directory. `EASL_DEV_HOME` does not isolate Ghostty configuration. The guest account's `~/Library/Application Support/com.mitchellh.ghostty` configuration is still read; require it absent or record that unmet isolation prerequisite without changing the shared file. Qualify unchanged default and customized bindings separately, retaining which action receives each chord.

## Gotchas

- `input command` calls an AppKit selector directly. It does not prove the physical shortcut path. `shortcut` and `key` do exercise key equivalents and the responder chain.
- Settings and a board can have different window IDs under one PID. Untargeted input can test the wrong responder.
- System-reserved chords are refused. Bare letters are drawing tools, not global shortcuts.
- Custom menu bindings and unchanged default bindings have different precedence over Ghostty remaps. Test both when changing that contract.
- Use current menu titles and AX labels. The default table is not proof that an instance has those bindings.
