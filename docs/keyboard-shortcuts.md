# Keyboard shortcuts

**easl › Settings… › Keyboard Shortcuts** lists bindable actions by menu. Settings opens with ⌘, by default. Bindings belong to this Mac's easl settings, not to a board.

Choose **Record** on an action, then press the shortcut. Escape cancels recording. **Clear** removes a binding. **Reset** restores that action's default. **Restore Defaults** resets every action. Symbols keep the character macOS reports for the active keyboard layout, without US Shift substitutions.

A conflict names the action that already uses the shortcut. **Swap** exchanges the two actions' current bindings. If the action being edited is unbound, the other action becomes unbound. **Cancel** keeps both unchanged. Reset uses the same conflict check. Reserved system shortcuts cannot be recorded. Plain letters and Shift-only letters are drawing tools, not global shortcuts.

Changes save in `ui-settings.json` and update the menus at once. The menus show the current bindings. With a terminal focused, custom menu shortcuts take precedence over Ghostty's window, tab, and split remaps. Unchanged easl defaults keep those user-configured remaps, including creating a terminal beside the focused terminal in its directory. Board navigation, Close, browser address focus, Write Prompt, and Paste Mentions retain their existing priority over remaps. Other menu shortcuts beat the terminal library's bindings, except terminal editing actions such as copy, paste, undo, and search. Bare drawing keys work on the canvas and do not replace typing in a terminal or text editor.

Move (M) keeps the keyboard on the canvas while you drag tiles from their bodies. V or Escape returns to Select. Leaving Move during a drag cancels that drag.

## Defaults

All existing shortcuts are unchanged. **New** marks a default added with Keyboard Shortcuts. ⌃ means Control, ⌥ means Option, ⇧ means Shift, and ⌘ means Command.

| Menu | Action | Default |
| --- | --- | --- |
| easl | Settings… | ⌘, **New** |
| easl | Quit easl | ⌘Q |
| File | New Terminal | ⌘T |
| File | New Note | ⌘N |
| File | New Browser Tile… | ⇧⌘B |
| File | Open File as Code Tile… | ⌘O |
| File | New Board Tab… | ⌃⌥⌘T **New** |
| File | Open Board… | ⇧⌘O |
| File | Open Remote… | ⌃⌥⌘O **New** |
| File | New HTML Tile | ⇧⌘H |
| File | Review Changes | ⇧⌘R |
| File | Review Branch | ⌃⌥⌘R **New** |
| File | Export Selection as PNG… | ⇧⌘E |
| File | Close | ⌘W |
| Edit | Undo | ⌘Z |
| Edit | Redo | ⇧⌘Z |
| Edit | Copy | ⌘C |
| Edit | Copy as Image | ⇧⌘C |
| Edit | Paste | ⌘V |
| Edit | Select All | ⌘A |
| Edit | Delete Selection | ⌘⌫ |
| Edit | Find in Page… | ⌘F |
| Edit | Paste Mentions into Terminal | ⌃⌥⇧⌘V |
| Edit | Mention | ⇧⌘M |
| Edit | Remove Last Mention | ⌥⇧⌘M |
| Edit | Write Prompt | ⌘I |
| Object | Group | ⌘G |
| Object | Ungroup | ⇧⌘G |
| Object | Bring to Front | ⇧⌘] |
| Object | Send to Back | ⇧⌘[ |
| Object › Content Zoom | Zoom Content In | ⌃⌘= |
| Object › Content Zoom | Zoom Content Out | ⌃⌘- |
| Object › Content Zoom | Reset Content Zoom | ⌃⌘0 |
| Code | Go to Definition | ⌃⌘J |
| Code | Open Definition in New Tile | ⌃⌥⌘J |
| Code | Find References | ⌃⌘R |
| Code | Outline | ⌃⌘O |
| View | Go to… | ⌘P |
| View | Go to Next Needs-You | ⌘J |
| View | Leave Tile | ⌘Esc |
| View | Back | ⌘[ |
| View | Forward | ⌘] |
| View | Actual Size | ⌘0 |
| View | Zoom In | ⌘= |
| View | Zoom Out | ⌘- |
| View | Zoom to Fit | ⌘9 |
| View | Increase Chrome Text Size | ⌥⌘= |
| View | Decrease Chrome Text Size | ⌥⌘- |
| View | Reset Chrome Text Size | ⌥⌘0 |
| View | Reload Page | ⌘R |
| View | Show Web Inspector | ⌥⌘I |
| View | Hide Board Chrome | ⌥⌘T |
| Drawing | Select | V |
| Drawing | Move | M **New** |
| Drawing | Rectangle | R |
| Drawing | Ellipse | O |
| Drawing | Arrow | A |
| Drawing | Text | T |
| Drawing | Draw | P |
| Window | Minimize | ⌘M |
| Help | easl Basics | ⌥⌘/ |

Other listed actions start unbound and can be recorded in Settings. This includes exports without an existing shortcut, Enter Group, Follow Files, Clear Mentions, Clear Attention Markers, Lasso Selection, Exit Group, Performance HUD, and Get Started. Dynamic menus such as browser extensions, mention targets, and content zoom presets are not individual bindable actions.

**New Board Tab…** opens the same folder picker as **Open Board…** and the tab bar's + button. A board is a directory, so choosing an existing board brings it forward instead of making a duplicate. Diagram and question tiles have no manual creation menu. Agents create diagrams through the API and questions through `easl ask`.

New Board Tab, Open Remote, and Review Branch use ⌃⌥⌘ chords rather than Ghostty's new-window, tab, or split defaults. System-reserved keys are refused. Existing chrome-text zoom shortcuts remain unchanged even though macOS Accessibility Zoom can use the same keys when enabled.
