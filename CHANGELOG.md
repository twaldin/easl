# Changelog

Each version's section is its GitHub release's notes.

## Unreleased

- **boards reopen where you left them.** Each board comes back at its zoom and spot on relaunch, kept on your Mac (not in the board file, so shared boards stay yours to look at your way).
- **chrome text size.** View ▸ Increase / Decrease / Reset Chrome Text Size (⌥⌘= / ⌥⌘- / ⌥⌘0) scales the tray and tile title bars to 150%, separate from board zoom and a tile's content zoom.
- **web links open in a browser tile beside where you clicked.** A ⌘-click on a URL in a terminal, a link in an HTML page or a note, a ⌘-click on a URL in code, and `open <url>` or `$BROWSER` run in a terminal tile (the new `view.open_url` call) show the page in a tile beside the source; a tile already showing that address is shown instead of a duplicate. ⌥-click (⌥⌘ in a terminal or code) sends the URL to your default browser; `/usr/bin/open` stays the system's.

## 0.1.0

easl is a native Mac app: one infinite board where your agents run in real terminals beside your code, a browser, html pages and diagrams.

- **real terminals.** Claude Code, Codex and any CLI agent run unmodified, rendered by libghostty with your Ghostty config.
- **your code, with your language server.** Hover, definitions, references, a git gutter against your branch, and live call graphs.
- **a browser your agents drive**, with the page's errors on the tile.
- **html pages and diagrams** your agents build beside their terminals.
- **reference anything in the next prompt.** Hyper-click a line of code, a DOM element, a note paragraph or a command's output.
- **agents keep running when you quit.** Terminals live in zmx sessions, so quitting or rebuilding easl leaves them working.
- **works with** Claude Code, Codex, opencode and Gemini CLI (before 0.60) with no setup, and omp with one symlink.

Requires macOS 14 or later on Apple silicon.
