# Using easl

What easl does, feature by feature. Install, first steps and uninstall are in the [README](../README.md#install).

![A description typed to the agent is deleted. The line is clicked instead, the chip goes with a short question, and the agent's answer starts with that line.](media/stop-describing.gif)

## Show your agent the code

Hyper-click a line of code, a DOM element, a note paragraph, a command's output, a shape or a group's title (the whole group, with the arrows between its members) to stage a mention in the tray at the bottom of the window. It goes with the next prompt you submit to the terminal the tray targets (`→ name ▾`); a mention from another worktree targets the agent working there. ⇧⌘M mentions whatever the keyboard is on. For an agent without an integration, Hyper-V (⌃⌥⇧⌘V) pastes the mentions into the terminal you're typing in, without pressing Return.

Hyper means all four modifiers, ⌃⌥⇧⌘. Hold them and click, or give yourself one key that sends all four: Caps Lock mapped to Hyper with [Karabiner-Elements](https://karabiner-elements.pqrs.org) is the usual setup, and any remapper that sends ⌃⌥⇧⌘ works.

## Quit the app. Your agents keep working.

Terminals live in zmx sessions, so quitting easl, a crash, a rebuild or closing a board's tab ends nothing: agents and shells keep running and are back when you open the folder again. An agent that finishes while easl is closed comes back done (or blocked) with its answer. After a reboot, omp, Claude Code and Codex tiles relaunch with their recorded session. Closing a terminal tile ends its session; ⌘Z brings the tile back with a new one. To see or end sessions without the app: `zmx list` (easl's are named `canvas-obj_…`), `zmx kill <name>`.

Terminal tiles are rendered by libghostty and use your Ghostty config (theme, colors, font family, keybinds; easl keeps its own font size; zooming the board, or a tile's content with ⌃⌘= / ⌃⌘-, scales text). A program's notification or bell becomes an attention marker, and ⌘-click opens a `path:line` in the output as a code tile and a URL in a browser tile beside the terminal (⌥⌘-click sends it to your default browser). `open https://…` in a terminal tile does the same.

## See which agent needs you

Each agent's state is on its tile: blue working, orange needs you (an approval or a question, in a bubble with its message), green done and not yet seen. ⌘J goes to whoever on this board needs you next: blocked agents first, then marked tiles, then finished agents you haven't seen. A turn that ends while its tile is off-screen stays green until you look at it. When easl isn't in front, macOS notifications tell you, and a background board's tab shows a dot.

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

## Credits

Terminals are [Ghostty](https://ghostty.org)'s, through [libghostty-spm](https://github.com/Lakr233/libghostty-spm); code tiles highlight with [tree-sitter](https://tree-sitter.github.io) and notes parse Markdown with [swift-markdown](https://github.com/swiftlang/swift-markdown); sessions are [zmx](https://github.com/neurosnap/zmx)'s (installed separately, not part of the app). Every third-party component in the app and its license is in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), which ships inside `easl.app` too. One of them, GNU libintl (inside libghostty), is under the LGPL 2.1: the notices say where its source is and how to relink easl with a modified copy.
