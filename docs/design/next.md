# Next: a Go server, remote boards, the composer, browser parity

What easl builds after 0.1.0, and the decisions behind it. Each section is a lane; the lanes run in parallel and land as their own PRs. When a lane ships, its behaviour moves into docs/design.md and docs/contracts.md, and its section here shrinks to what is still open.

## Architecture: `easld` and the Mac client

- **One server, `easld`, written in Go**, for macOS and Linux. It owns boards and their persistence, the API and its events, zmx sessions, file reads, git, language servers, call graphs, mention context, placement, layout checks, link resolution and arrow routing. Go gives static, cross-compiled binaries, cheap concurrency for many sessions, language servers and streams, a strong standard library for processes, sockets and JSON, and builds in seconds. The code lives in this repository under `easld/`, so the schema, the client and the server change together.
- **The Mac app stays Swift and AppKit.** WebKit tiles, libghostty's Metal renderer with the user's Ghostty config, and AppKit's text input, accessibility and trackpad handling are what make the board feel native, and a cross-platform client would rebuild all of them. A gpui client was considered and rejected: its webview is an experimental native overlay that renders on top of the UI, so web tiles couldn't zoom or layer with the rest of the board. Its terminal would need a renderer written on libghostty-vt. And Zed's editor crates are GPL, which easl's MIT licence can't take in. The client keeps drawing, hit-testing and provisional geometry while dragging; everything else is the server's.
- **`schema/easl-api.json` is the contract.** Go and Swift types are generated from it, as the TypeScript and Python clients already are.
- **easld runs as a per-user launchd agent.** The app bundles it and is its client even for local boards, so boards and the API keep working with the app closed.
- **Several clients on one board**: the server is authoritative, and writes go through the existing object revisions.
- **`easl render`** is drawn by a connected Mac client, so it matches what the user sees. With no client online it fails `unavailable`; `get` still works.

### Getting there without breaking anything

1. An **API conformance suite** (`conformance/`, docs/testing.md): scripted scenarios recorded from a development instance of the app, normalised for ids, times, revisions and paths, that replay against any socket and diff. The methods that need the Mac client (view.*, agent.prompt/read, object.reload) are marked as delegated. Still open: scenarios for what easld adds beyond today's API (several clients on one board, render delegation).
2. **easld passes the suite.**
3. **The app becomes easld's client.**

Server-side features (the all-agents overview, supervision stats, review passes, remote boards) are built on easld, not on today's app.

## Remote boards

- **One machine does the work per board**: the machine with the repository is the board's host. Either Mac can open the other's boards, and the mechanism is the same in both directions.
- **SSH over Tailscale is the only transport.** There's no network server and no new authentication. easl lists online tailnet peers with `tailscale status --json`.
- **File › Open Remote…** picks a machine and then one of that host's boards (repository, path, agent count), or Browse… for a new directory over ssh. If easl isn't running on the host, the viewer starts it over ssh (`open -g -a easl <dir>`, which needs a logged-in GUI session there). An unreachable host shows as offline.
- **The viewer draws the board natively.** It reads the snapshot and events over the host's socket, forwarded by ssh (`EASL_SOCKET` already accepts any socket path). Terminals attach with `ssh <host> zmx attach <session>`, and the host serves files, git and language servers.
- **Browser tiles run where the user is.** A browser tile executes on the Mac the user is sitting at, and the host routes the agent's `easl browser` calls to it over the same ssh link, so the user and the agent see one page. When that Mac disconnects, the host takes the tile over and reloads its last URL. Browser cookies are shared between the machines over ssh, so logins carry over; in-page state doesn't.
- **Offload**: a terminal tile can have a host of its own, such as a Linux machine with more cores. Its agent works on a clone there, with the board's socket forwarded back (`ssh -R`) so the hooks and the `easl` CLI work. Code and changes tiles it opens read that host's files, so every file-bound tile carries a host.

## The composer

A prompt box outside the terminal. It sends to an agent from anywhere on the board, so pointing at things no longer means panning back to the terminal to type.

- **It lives in the tray bar**, which grows to several lines while focused. A shortcut focuses it from anywhere, and ⌘↩ sends. The target is the tray's "→ terminal" menu, which becomes multi-select: one prompt and its mentions go to every chosen terminal.
- **Mentions are inline tokens.** A Hyper-click drops its `[n]` at the cursor (or at the end, when the composer isn't focused), and the text after a token is that item's note: `[1] make this green [2] drop this row`. A prompt with no tokens is just a prompt. Deleting a token unstages its mention.
- **Sending reuses `agent.prompt`**: the text and Return go into the terminal, and the agent's integration drains the tray with that prompt. A terminal without an easl integration gets the text, with the tokens' context pasted the way Hyper-V pastes it.
- **↑** in an empty composer recalls the board's earlier prompts with their tokens, which also answers "what did I send".
- **A blocked target** (a question or approval) shows its question in the composer, and the text answers it.
- **Drafts**, tokens included, are kept per board across board switches and restarts.

## Links

Shipped (docs/design.md, docs/contracts.md `view.open_url` and the terminal's `open`/`BROWSER` shim): every web link opens a browser tile beside where it came from, a tile already showing the address is reused, and ⌥-click forces the default browser. Nothing open.

## Browser parity

Shipped (docs/design.md, Browser): popups with `window.opener`, downloads, uploads, JavaScript dialogs, HTTP auth and client certificates, camera and microphone prompts, location, print, find, fullscreen, app links, profiles, tile reuse, reload on file change, and a user agent that tracks Safari. Still open:

- Password managers through `WKWebExtension` (macOS 15.4 and later), which hosts Safari web extensions.
- Passkeys for arbitrary sites need Apple's managed `com.apple.developer.web-browser.public-key-credential` entitlement, which an organization developer account requests, so they're parked.
- Notifications: WebKit offers no public permission hook, so `Notification` requests stay denied.

## Backlog in scope

- An all-agents overview: ⌘J across every board and machine.
- Agent supervision stats: each agent's branch, diff size and changed files, and a warning when two worktrees touch the same files.
- Review passes: show only unstaged changes, and a "since last review" bookmark.

## Performance and monitoring

Measured on a real 339-object board (112 HTML tiles, 84 labelled `avoid` arrows, 32 groups): idle costs 2.7% CPU. The cost is bursts of API writes. Each frame-changing write re-routes every arrow on the main thread (`ShapeLayer.settleRouting`, mostly label placement), so 139 writes sent one at a time cost 34 s of CPU and kept the main thread busy for 45 s. A hidden window makes the same work 4–6× slower. Smaller costs:

- `board.get` encodes and then decodes its result, 15–35 ms per call;
- HTML tiles reload their web views on every pan and zoom;
- a terminal's display link is recreated after every idle gap.

- **A repeatable benchmark**: a generated board with the same shape (and a variant with a real board's geometry, every string replaced), a replay of the write pattern, and pass/fail targets. A 139-write burst stays under 3 s of CPU and never blocks the main thread for more than 100 ms. A burst routes the board at most twice. An idle poll causes no hitch over 16 ms. Hidden stays within 2× of visible.
- **The fixes it drives**: route only the arrows a write affects, off the main thread; coalesce routing per burst; don't throttle while API work is pending; encode `board.get` straight to bytes; keep HTML tiles from reloading on navigation; reuse the terminal's display link.
- **Monitoring**:
  - `app.metrics` and `easl metrics --watch`: main-thread busy time and hitches, per-method API cost, events, writes per actor, routings, saves, live tiles per kind, process CPU, memory and wakeups;
  - a debug HUD;
  - signposts for Instruments;
  - a log line for every main-thread stretch over 250 ms that names its cause.
