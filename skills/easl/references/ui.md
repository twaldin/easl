# What the user sees

The legend behind Help › easl Basics, so you can answer "what is this?" without reading easl's source.
Point the user at Help › easl Basics (⌥⌘/) for the same text in the app.

## Pointing an agent at things

- **Hyper-click** (⌃⌥⇧⌘-click: Control+Option+Shift+Command, on a PC keyboard Ctrl+Alt+Shift+Win; Caps Lock mapped to Hyper with a key remapper): stages a mention of a code line, page element, drawing, image pixel, tile, or group in the **tray**, the bar at the bottom of the window.
  On a group's title or empty interior it mentions the whole group (the innermost there; the chip reads its title), holding Hyper outlines the region, and a second Hyper-click unstages it.
  Hyper-drag on empty board, or inside a group, mentions everything inside the box as one group.
- **⇧⌘M** (Edit › Mention) stages a mention from the keyboard, of what the user is on in the tile that has the keyboard: the current hunk or selected lines of a changes tile (`m` there too), a code tile's selected text or else its range, the block of a note being edited, a page's text selection, a terminal's selection or else its last command's block; with the board's keyboard, the selected tiles, or the selected group as a whole.
- **Composer** (the tray bar at the bottom): the user's prompt box (⌘I from anywhere, ⌘↩ sends, Esc leaves). Staged mentions are its inline tokens; "→ name" on the right is the terminal they go to with the user's next prompt (hover says so): the terminal the user last typed in that runs an agent, else the board's only agent terminal (a dev-server shell beside it never takes it), else the last terminal typed in. The user can check several terminals in its menu: each gets the same prompt and mentions (the others through the same hand-off as `agent.prompt` `mentions`), numbered alike.
  Clicking "→ name" opens a menu of the board's terminals (agents first) to check or uncheck; it is kept across restarts. ⌃⌥⇧⌘V pastes the mentions, for an agent without an integration, into the terminal the user is typing in, else into that target; ⌘Z brings the pasted tokens back. A prompt from the composer to a terminal without an integration carries the mentions' context pasted ahead of it.
  Each token shows the number its mention has in the context the agent gets ([1], [2]… in the order the tokens stand), and the user's words after a token are their note about it, so "[2] drop this row" in a prompt means "drop the row the second mention points at". Clicking a token selects what it points at and brings it into view; code lines and note blocks are scrolled to and flashed. A token whose page navigated since says "page changed". Deleting a token, or a second Hyper-click on something staged, takes it out (a notice says so); tile context menus have a Mention item (⇧⌘M). When you are blocked on a question or approval, the composer shows your question and the user's text there is the answer.
- **Help › Get Started** walks a new user through a first mention on a practice note: Hyper-click it (or ⇧⌘M), then send it with a prompt; each step turns green when done. It opens by itself only on a first launch, until closed; a user who never set up Hyper can reopen it there.
- **Drawing toolbar** at the top: select (V), rectangle (R), ellipse (O), arrow (A), text (T), ink (P), colors, fill.
  The default ink (Black) is drawn dark over light pages and images and light over the dark board; other colors stay as chosen.

## Reading a board

- Scroll pans, pinch zooms; ⌘9 shows everything, ⌘0 is 100%.
  With a mouse: the wheel pans, ⌘-scroll zooms around the pointer, ⇧-scroll pans sideways.
- **Groups** are tinted, titled regions of tiles that belong together; an **arrow**'s label says how two things relate, and one into a code tile points at its lines.
  A code tile's **caption** (the line under its header) says why those lines matter. A code tile keeps its range on its code as lines move above or inside it; "⚠︎ stale: …" in its header means that code is gone (the range is left untinted).
- **⌥⌘-arrows** (↑ ↓ ← →) move between tiles: to the nearest tile that way, and a terminal landed on takes the keyboard.
  ⌥⌘→ / ⌥⌘← step along the selected tile's `relation: "next_step"` arrows when it has one ("Last step" / "First step" ends a sequence); ⌥⌘→ on the walkthrough's group, or with nothing selected, starts at its first stop.
  A stop not wholly in view is centered (fitted when larger than the view); an agent's terminal comes with its follow tile when both fit. Each step is a Back entry.
- **⌘P** finds a tile by title or caption.
- **Links**: a `path:line` link in a note or page, Go to, a definition and a terminal ⌘-click go to the code tile already showing those lines (exactly, or a captioned tile whose range holds them) wherever it is, else open them beside the source.
- **⌘[ / ⌘]**: back and forward through steps, links, Go to, definitions, ⌘J, Review Changes' jump and edge-pill jumps.
- **View › Hide Board Chrome** (⌥⌘T; also a button in easl Basics), for presenting: hides the toolbar, tray, selection rings and handles, author marks, code tiles' header rows (their code moves up into the space; captions stay) and agents' attention markers; a blocked agent's ring and pill stay.
  Esc on the board or the item again brings them back.

## Agents

- **Lifecycle dot** in a terminal's title bar (its tooltip says the same):
  blue *working* (busy), orange *blocked* (waits for the user to approve or answer), green *done* (finished, not seen yet), grey *idle* (waiting for the next prompt).
  No dot: no agent reports a lifecycle in that terminal.
  An agent without an integration (aider through easl's `aider` wrapper, any CLI that sends a terminal notification or bell) turns green *done* when it says it waits and has no dot while it may be working; it never shows blue or orange.
- **Blocked**: the terminal also gets an orange ring and a bubble with a raised hand and the approval text; clicking the bubble brings the terminal into view (its bottom, where the question is, when it is taller than the window) and puts the keyboard in it.
  Off screen, an orange pill at the edge of the view points at it.
- **Tab dot** on a board's tab: orange, an agent there is blocked; green, one finished unseen.
- Zoomed far out, tiles become cards tinted with their agent's state.

## Needs you

- **Pink ring and bubble**: an attention marker (`view.attention`, or a terminal's bell or notification): "look here".
  It clears when the user selects the tile, types in it, or looks at it for a few seconds; View › Clear Attention Markers clears them all.
  Bubbles sit beside their tile, off other tiles (cut short, the whole message in the tooltip, when that's what keeps them off) and never over the terminal the user is typing in.
- **Edge pill** (arrow + the start of the message; the whole message in its tooltip): something that needs the user is off screen that way; clicking it goes there.
  It sits on a stretch of the view's edge with no tile under it; when the edge is covered, it is a chip in the toolbar row beside the drawing toolbar.
- **⌘J**: the next thing on this board that needs the user, blocked agents first, then markers, then agents that finished unseen; "Nothing needs you" when there's nothing.

## Agents' tiles

- **Follow tile**: each agent terminal's code tile that follows the file and line the agent last read or edited (on by default; it appears on the first file read) and flashes the lines each edit changed.
  Files in another worktree of the board's repository count too (shown by absolute path, with that worktree's changes); images, PDFs and other binaries, files under the temp dir, and files that no longer exist never re-aim it.
  It may be narrower than 640 pt so it fits in the user's view. Closing the terminal closes its follow tile.
  The strip under its header lists recent places, newest first; a pencil marks an edit (kept longer than reads).
  While the user scrolls or clicks in it, it holds still for ~10 s and counts what it missed; "N new ▸" catches up. Pin keeps the current view as its own tile; right-click the terminal › Follow Files (or Object › Follow Files) turns it off.
- **Where your objects land**: next to your terminal, clear of other tiles, inside the user's view when there's room within ~600 pt of it; they show "by <your terminal's name>" in their title bar.
  The view never moves for you: when the view is full, what you made may be off screen; raise a marker, or tell the user ⌘9 (Zoom to Fit).
- **Undo**: ⌘Z undoes the last change, the user's or an agent's (an agent's batch is one step), and every ⌘Z/⇧⌘Z shows a notice naming what it undid or redid (the agent, or a changes tile's Stage, Unstage, or Discard); ⇧⌘Z redoes. While a terminal has the keyboard, ⌘Z goes to the terminal, never the board.
  Navigation and bookkeeping nobody chose (a follow tile re-aiming, a terminal's ⌘-click preview re-aiming, a pick in a follow tile's history strip) aren't undo steps; ⌘[ / ⌘] go back and forward through the user's navigation.

## Reviewing work

- **Review Changes** (File › Review Changes ⇧⌘R, or right-click the board) opens a changes tile, or goes to the one already there for the same root and base; File › Review Branch reviews everything the branch changed. Both review the checkout the focused or selected terminal works in (a worktree its agent runs in), else the board's; Review Branch on the default branch with no terminal to go by offers the repository's worktrees. Each changed file shows its changes (hunks), green added, red removed. Its summary is a picker: Uncommitted changes (not in a commit yet) or Branch vs main (everything the branch changed); a code tile's base picker uses the same words, the exact base (merge-base, sha) in its tooltip.
- **Stage** marks a change ready for the next commit, **Unstage** takes the mark off; neither changes files. **Discard** throws an uncommitted change away from the files: it asks first (the button turns into "Discard?" until you click it again or do something else, or `r` then ⌘⌫), then a notice names what went with "⌘Z undoes". Committed hunks have no Discard.
- **committed**: already in the branch's history (a branch review); **Viewed** folds a file until it changes. The tile's keys work once Return (or a click) gives it the keyboard; while it is only selected they say so.

## Zoom and keys

- ⌘9 fits everything (or the largest cluster); ⌘0 is 100% (the selection at 100%); ⌘= and ⌘- step 10–100%.
  Below about 30% (terminals 15%) tiles show as cards; zooming in brings them back live.
- **Bigger text**: board zoom stops at 100%, so the user zooms a tile's content instead, in place: ⌃⌘= / ⌃⌘- step the selected tile (else the one with the keyboard) through 25–500% and ⌃⌘0 puts it back at 100% (Object › Content Zoom, also in its right-click menu). The tile keeps its size and its content reflows (a terminal gets fewer, bigger columns).
  The title bar shows `−  150%  +` left of the ✕: the % whenever it isn't 100% (a click resets it), − and + on hover or selection. Corner drag resizes; ⌥-drag resizes keeping proportions. A zoomed-in tile stays live further out.
- ⌘P Go to (tiles, files, `@symbols`, and while typing a note's headings; `core.py:120` opens at a line; ⌘P again selects the query, Esc closes; an agent's terminal is framed with its follow tile when both fit); ⌘T new terminal; ⌘W close the selection (a terminal asks first; Close is ⌘⌫); ⌘G group; ⌘F find in a code tile; ⌥⌘-arrows step (see Reading a board).
- Right-click empty board for New Terminal Here, New Note Here and New Browser Here; File › New … puts them in the view.
- ⌘-click a `path:line` in terminal output opens it in that terminal's preview tile; ⌥⌘-click opens a separate tile the user keeps.
- Return enters the selected tile (a terminal, a code tile's rows, a changes tile, a note, a page); Esc gives the keyboard back to the board.
  In a terminal or a web page Esc belongs to the program or page: ⌘Esc (View › Leave Tile) leaves any tile.
- Code › Go to Definition ⌃⌘J (Open Definition in New Tile ⌃⌥⌘J), Find References ⌃⌘R (Open All lays them out as excerpts), Outline ⌃⌘O (type to filter), and code tiles' hover use the language's server (sourcekit-lsp, pyright-langserver, typescript-language-server, gopls, rust-analyzer), found through the login shell: `EASL_LSP_<LANGUAGE>` (e.g. `EASL_LSP_RUST`) if set, else PATH, else nvim's mason bin, `~/go/bin`, `rustup which rust-analyzer`; without one they answer by text search, labelled so, and the panel says where easl looked.
- A code tile without changes shows a quiet "no changes" (a file git ignores, such as a dependency under node_modules, a quiet "ignored by git"); its diff-base picker appears when the pointer is over the header.
- A note's menu has Copy as Markdown and Save as Markdown…: its markdown as written (links, fences), for a doc or a chat.
- Save as PNG…, Save as HTML…, Save as Markdown… and File › Export Selection as PNG… (⇧⌘E) open in the folder last saved into, else Downloads, never the board's repo.
  Export Selection keeps the titles and borders of groups whose tiles are all selected; a marquee around groups selects them and the arrows between what it selects.
  Its picture is at most 8000 px on its longest side, named after the one tile or group selected, and drawn without board chrome (no author marks, × buttons, dot grid or selection), as View › Hide Board Chrome shows it; Copy as Image too.
- A browser tile's menu has Snapshot to Image: the page as it shows now becomes an image tile beside it ("<page title> · <time>", its address as the caption), kept with the board.

## Coming from Linux or Windows

- ⌘ (Command, the Windows key on a PC keyboard) does what Ctrl does elsewhere: ⌘T, ⌘W, ⌘Z, ⌘C, ⌘V, ⌘= / ⌘- zoom.
  A Ctrl shortcut pressed on the board shows a notice naming its ⌘ key, once per key per session.
- ⌃ stays the terminal's: ⌃C interrupts, ⌃D ends input; ⌘C copies the selection, ⌘V pastes.
- ⌥ (Option) is Alt; for Alt as Meta in the shell, set `macos-option-as-alt = true` in the user's Ghostty config.
- Mouse: the wheel pans, ⌘-scroll zooms around the pointer, ⇧-scroll pans sideways; right-click the board or a tile for its menu.
- ⌥⌘-arrows move between tiles like a tiling window manager; ⌘Esc leaves a terminal.
