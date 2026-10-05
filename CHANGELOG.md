# Changelog

Each version's section is its GitHub release's notes.

## Unreleased

- **boards reopen where you left them.** Each board comes back at its zoom and spot on relaunch, kept on your Mac (not in the board file, so shared boards stay yours to look at your way).
- **chrome text size.** View ▸ Increase / Decrease / Reset Chrome Text Size (⌥⌘= / ⌥⌘- / ⌥⌘0) scales the tray and tile title bars to 150%, separate from board zoom and a tile's content zoom.
- **web links open in a browser tile beside where you clicked.** A ⌘-click on a URL in a terminal, a link in an HTML page or a note, a ⌘-click on a URL in code, and `open <url>` or `$BROWSER` run in a terminal tile (the new `view.open_url` call) show the page in a tile beside the source; a tile already showing that address is shown instead of a duplicate. ⌥-click (⌥⌘ in a terminal or code) sends the URL to your default browser; `/usr/bin/open` stays the system's.
- **browser tiles behave like a browser.** Sign-in popups keep `window.opener` (a popup opens in a tile beside its page and closes with it), downloads land in ~/Downloads with a progress pill in the address bar, file uploads, `alert`/`confirm`/`prompt`, HTTP logins and client certificates, per-site camera and microphone prompts, location, Find in Page (⌘F), File › Print Page…, fullscreen video, other apps' links (`mailto:`, `zoommtg:`) after asking, named browser profiles (the tile's Profile menu, `props.profile`), Reload When Files Change for local pages (`props.reloadOnChange`), and a user agent that follows your installed Safari.
- **Password managers and other Safari extensions in browser tiles** (macOS 15.4 or later). Add one from easl › Browser Extensions › Add Extension… (an app such as Bitwarden that includes a Safari extension, an `.appex`, or an unpacked folder), see what it asks for, and click its icon in the address bar to unlock and fill. Passkeys aren't supported.
- **an API conformance suite** (`conformance/`): scripted conversations with the socket API, recorded from the app, that replay against any server and print what differs (docs/testing.md).
- **easld** (`easld/`): the Go server that will own boards and the API. It serves the socket API from the same board files and passes 17 of the 19 conformance scenarios, `view.open_url` and `app.metrics` (its own request, event, write and save counters) included; the app doesn't use it yet. It won't start on a home the app or another easld is using, or take over a socket another server answers on, and it leaves alone a board file it can't fully read (one from a newer app) instead of overwriting it.
- **the composer.** The tray is a prompt box: ⌘I from anywhere, ⌘↩ sends. Hyper-clicks drop inline `[n]` tokens where you type, the words after a token are its note, and deleting a token unstages it. Send one prompt to several terminals at once; a blocked agent's question shows in the composer and your text answers it; ↑ recalls what you sent, and drafts survive board switches and restarts. API: `tray.drain` takes the `prompt` an integration is about to submit, so the drain of a prompt sent from the composer takes exactly its own mentions, however the agent rewrote the text (the bundled hooks and extensions pass it).
- **agent write bursts no longer freeze the board.** An agent writing tile after tile used to re-route every arrow on the main thread once per write (a 139-write burst on a 339-object board: 34 s of CPU, the UI frozen for 45 s). The board now routes once the burst ends, off the main thread, while arrows bound to a written tile follow it as it changes.
- **`easl metrics`** (`app.metrics`, View › Performance HUD): what easl's work costs (main-thread busy time and stretches, per-method API cost, events, writes per agent, routings, saves, live tiles, CPU, memory and wakeups), and an `app.log` line naming the cause of any main-thread stretch over 250 ms.
- HTML tiles panned or zoomed out of view and back within 30 s no longer reload their page.

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
