# Using easl

What easl does, feature by feature. Install, first steps and uninstall are in the [README](../README.md#install).

![A description typed to the agent is deleted. The line is clicked instead, the chip goes with a short question, and the agent's answer starts with that line.](media/stop-describing.gif)

## Show your agent the code

Hyper-click a line of code, a DOM element, a note paragraph, a command's output, a shape or a group's title (the whole group, with the arrows between its members) to stage a mention in the tray at the bottom of the window. It goes with the next prompt you submit to the terminal the tray targets (`→ name ▾`); a mention from another worktree targets the agent working there. ⇧⌘M mentions whatever the keyboard is on. For an agent without an integration, Hyper-V (⌃⌥⇧⌘V) pastes the mentions into the terminal you're typing in, without pressing Return.

The tray is also a prompt box, the composer, so you never pan back to a terminal to type. ⌘I gives it the keyboard from anywhere and ⌘↩ sends; Esc goes back to where you were. Each mention is a token in the text, put where you're typing, and the words after it are your note about it: `[1] make this green [2] drop this row`. Delete a token to unstage it. Check several terminals in the `→` menu to send the same prompt and mentions to each; a terminal without an integration gets the mentions pasted ahead of your text. When an agent you're sending to is waiting on a question or an approval, the question shows above the text and what you send answers it. ↑ in an empty composer brings back what you sent on this board, tokens and all, and an unsent draft is still there after switching boards or restarting easl.

Hyper means all four modifiers, ⌃⌥⇧⌘. Hold them and click, or give yourself one key that sends all four: Caps Lock mapped to Hyper with [Karabiner-Elements](https://karabiner-elements.pqrs.org) is the usual setup, and any remapper that sends ⌃⌥⇧⌘ works.

## Quit the app. Your agents keep working.

Terminals live in zmx sessions, so quitting easl, a crash, a rebuild or closing a board's tab ends nothing: agents and shells keep running and are back when you open the folder again. An agent that finishes while easl is closed comes back done (or blocked) with its answer. After a reboot, omp, Claude Code and Codex tiles relaunch with their recorded session. Closing a terminal tile ends its session; ⌘Z brings the tile back with a new one. To see or end sessions without the app: `zmx list` (easl's are named `canvas-obj_…`), `zmx kill <name>`.

Terminal tiles are rendered by libghostty and use your Ghostty config (theme, colors, font family, keybinds; easl keeps its own font size; zooming the board, or a tile's content with ⌃⌘= / ⌃⌘-, scales text). A program's notification or bell becomes an attention marker, and ⌘-click opens a `path:line` in the output as a code tile and a URL in a browser tile beside the terminal (⌥⌘-click sends it to your default browser). `open https://…` in a terminal tile does the same.

## See which agent needs you

Each agent's state is on its tile: blue working, orange needs you (an approval or a question, in a bubble with its message), green done and not yet seen. ⌘J goes to whoever needs you next: blocked agents first, then open questions, then marked tiles, then finished agents you haven't seen. When this board has nothing more, ⌘J carries on to the next board you have open and brings its tab (or window) forward, and after the last board it starts over, so one key works through every board. A turn that ends while its tile is off-screen stays green until you look at it. When easl isn't in front, macOS notifications tell you. A background board's tab shows a dot, and each board's tab title (and its entry in the Window menu) counts what needs you there: "easl (2)".

When an agent needs a decision from you, it posts a question tile (`easl ask`): the question, its options with the one it recommends marked and why, and links to what it is about. The count beside the drawing toolbar says how many are open; click it, or ⌘J, to go to one. Press a number to pick, add a note if you like, and Return answers. The answer goes back to the agent that asked (with its next prompt, or to a script waiting with `easl ask --wait`), and the tile collapses to your answer. Archive hides an answered tile; a question its asker cancelled, or that expired, stays dimmed until you archive or delete it.

Which agents report their state and get your mentions:

- **Claude Code and Codex:** no setup, only inside easl. easl's wrappers come first on a terminal tile's PATH and load the hooks and the easl skill per session; nothing is written to your global agent config. `EASL_AGENT_HOOKS=0` turns this off.
- **opencode:** no setup, through a plugin easl adds per session.
- **Gemini CLI:** no setup before 0.60. Gemini 0.60 and later runs as a plain terminal, without a state dot.
- **omp:** the easl extension (one symlink, [Install](../README.md#install) step 4). omp's `browser` tool also drives browser tiles.
- **aider and any other CLI:** green when they send a terminal notification saying they're waiting; no working or needs-you state. Hyper-V pastes your mentions into them.

## See what it changed

Each agent terminal has one follow tile: the file the agent last read or edited, with a history strip and its edited rows flashing. Code tiles show the whole file scrolled to a range, with a gitsigns-style gutter against the merge-base (or HEAD); click a sign to peek at the old lines. A code tile can follow a branch instead of a checkout: it reads the branch's worktree live while one has it checked out, its commit once the worktree is gone, and after the merge says "merged in <sha>" and keeps showing the code. Your language server gives them hover, go to definition, references and outline; without one, the last three answer by text search.

Changes tiles review an agent's work like a PR: uncommitted changes, the branch against its default branch, or against any commit. Stage, unstage or discard files, hunks and lines. They also show any branch or fetched pull request against its base straight from git, no checkout needed, read-only, with the same hunks and Viewed boxes. ⌘Z undoes agents' changes too, and says what it undid.

## The code it means

The agent points back the same way: it opens the exact code it means beside its terminal, draws arrows between things, and leaves notes and walkthroughs you step through with ⌥⌘→. What it creates lands next to its terminal and says "by <terminal name>" in its title bar; the view never moves by itself.

## Also on the board

- **Notes.** Markdown with fences that quote real files: an excerpt shows its code as it is now and follows it as lines move, and says it's stale only when that code is gone; a `propose` fence renders as a diff.
- **HTML tiles.** Sandboxed explainers with a bundled kit (Mermaid, code excerpts); agents chain them into walkthroughs.
- **Browser tiles.** Agents drive them: omp with its `browser` tool, Claude Code, Codex and any other CLI with `easl browser` (snapshot, click, type, eval, screenshot). The page's errors show on the tile.
- **Image tiles.** An image file with a caption, reloaded when the file changes.
- **Diagram tiles.** Who calls a function, or what it calls, computed live by your language server: symbol-anchored nodes with the lines making each call. Click a node to open its next level, click its `path:line` for the code, Hyper-click to point your agent at it; a deleted function stays with a stale badge instead of vanishing.
- **Drawing.** Shapes, arrows (straight, orthogonal, or routed around tiles), ink, and titled group regions.
- **One board per repository.** Every worktree and branch of a repo opens the same board, rooted at the main checkout; opening a worktree names it in the window, starts new terminals there, and goes to its branch's region. Boards easl kept per branch before are merged into their repository's board once, each branch's as a region (the old files are kept in `boards/pre-repo-migration/`).
- **Getting around.** Go to… (⌘P) searches every group and tile by title, path, or note heading and takes you to the one you pick. When you've panned into empty space, a "Back to content" pill brings you home, and Zoom to Fit (⌘9) frames the main cluster of work instead of shrinking to fit a few far-off strays.
- **Where you left it.** Each board reopens at the zoom and spot you left it, on the next launch or when you open it again; a board you've never opened here starts at the top of its content. Your view is kept on your Mac, not in the board, so a board shared with others stays yours to look at your way. View ▸ Increase Chrome Text Size (⌥⌘=) makes easl's own text (the tray and tile titles) bigger, Decrease (⌥⌘-) smaller, Reset (⌥⌘0) back; it's separate from zooming the board (⌘= / ⌘-) and a tile's content (⌃⌘= / ⌃⌘-), and your Mac remembers it.
- **Agent API.** A local socket with a JSON schema, a Python SDK, a TypeScript client, and the `easl` CLI, which is on PATH inside easl terminal tiles and needs bun. Agents create and lay out objects in atomic batches, measure and fit content, render any region offscreen without moving your view, read the board's activity history, and hand each other board objects instead of re-describing them. Scripts that keep a board current (a region per ticket) name objects with a key and upsert them, so every run updates the same objects.

## Boards on another Mac

File › Open Remote… lists the Macs on your tailnet that are online (from Tailscale) and the hosts you opened before; type any ssh host instead if it isn't there. Pick one and easl reaches it over ssh, so the host needs Remote Login or Tailscale SSH and nothing else: no server, no new password. You see that Mac's boards with their root, whether they're open there and how many agents they have; pick one to open it. A Mac that can't be reached shows as offline with ssh's reason and a Retry button; one where easl isn't running offers Start easl, which opens it in the background there (someone must be logged in on that Mac). easl remembers which hosts you opened, never what their boards hold.

## Browser tiles

A browser tile is Safari's engine on the board: sign-in popups, downloads (to ~/Downloads, shown in the address bar), uploads, logins, camera and microphone prompts, ⌘F to find in the page, File › Print Page…, and fullscreen video work as in Safari. Right-click a tile for **Profile** (a second set of cookies and logins, e.g. a work account; tiles with the same profile name share it) and, for a page served from your Mac, **Reload When Files Change**. ⌥-click a link to open it in your default browser instead.

## Password managers and other Safari extensions

On macOS 15.4 or later, browser tiles run Safari web extensions, so your password manager can unlock and fill in them.

1. Install the password manager's Mac app with its Safari extension. Bitwarden from the App Store, for example, puts a Safari extension inside Bitwarden.app; other password managers with a Safari extension ship it inside an app the same way.
2. In easl, choose easl › Browser Extensions › Add Extension… and pick the app. easl shows what the extension asks for (its permissions and the sites it runs on); Add allows it.
3. The extension's icon appears at the right end of every browser tile's address bar. Click it to open its popup on that page: sign in or unlock there, then fill.

With more than one extension, the address bar shows a puzzle piece that lists them. easl › Browser Extensions lists each one with Enabled, Options… and Remove… (removing one closes its open pages and deletes what it stored in easl, its extension storage and its pages' local storage and databases; its app stays installed). An extension can turn its button off for a page; the button then shows dimmed and does nothing there. Tabs an extension opens use the browser profile of the tile they came from. You can also add an `.appex` or an unpacked extension folder with a `manifest.json`, such as one you're developing.

What doesn't work yet: passkeys. Passkeys for arbitrary websites need an entitlement Apple grants to browsers on request, which easl doesn't have, so sign in with your saved password instead. Extensions can't open windows of their own, and an extension's own pages (its options, a full-page vault) open in a separate window, not a tile.

## Credits

Terminals are [Ghostty](https://ghostty.org)'s, through [libghostty-spm](https://github.com/Lakr233/libghostty-spm); code tiles highlight with [tree-sitter](https://tree-sitter.github.io) and notes parse Markdown with [swift-markdown](https://github.com/swiftlang/swift-markdown); sessions are [zmx](https://github.com/neurosnap/zmx)'s (installed separately, not part of the app). Every third-party component in the app and its license is in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), which ships inside `easl.app` too. One of them, GNU libintl (inside libghostty), is under the LGPL 2.1: the notices say where its source is and how to relink easl with a modified copy.
