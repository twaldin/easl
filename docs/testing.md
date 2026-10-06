# Testing easl

## Behavior tests

```sh
swift run -j 4 CanvasCoreTests        # swift-testing suites for CanvasCore
bun scripts/gen-clients.ts --check    # generated TS/Python clients match schema/easl-api.json, package versions match VERSION
(cd clients/python && python3 -m unittest)   # Python SDK (Python 3.11+): compositions loading, shipped compositions, connection config/reconnect against a fake socket
bun test extensions/agent-hooks             # hook payload classification: which thread (the tile's session, a subagent, Codex's internal sessions) an event comes from; the Codex awareness block's easl commands stay plain words
(cd conformance && go test ./...)          # the conformance runner's normalisation and diff (Go 1.26)
(cd easld && go vet ./... && go test ./...)  # easld (Go 1.26): its packages' tests, and the conformance suite replayed in-process (cmd/easld, ~2 min; -short skips it)
```

`CanvasCoreTests` is an executable target, not a test target: with only the Command Line Tools installed, `swift test` doesn't discover swift-testing suites, so `main.swift` calls the swift-testing entry point. Tests drive real objects (boards, the socket server over a Unix socket), never mocks of our own code.

## API conformance

`conformance/` drives the socket API the way agents do and checks a server against transcripts recorded from today's app. It is how `easld` (docs/design/next.md, "Getting there") proves it behaves like the app before the app becomes its client.

```sh
scripts/dev.sh start                                       # or any server: EASL_SOCKET=… / --socket
go run ./conformance/cmd/easl-conformance replay --socket .easl-home/easl.sock            # every scenario
go run ./conformance/cmd/easl-conformance replay --socket … --json out.json tray agents   # some, plus a JSON report (flags before scenario names)
go run ./conformance/cmd/easl-conformance record --socket … --on "easl main <sha>, dev instance" [scenario…]
```

- `conformance/scenarios/<name>.json` is one conversation on a board of its own: the runner makes a fresh directory (with `files`, and with `git: true` a repository whose one commit has fixed dates, so its id never changes), opens it with `board.open`, subscribes to its events, and runs the steps. A step is a `call` with `params` (templates: `{{board}}`, `{{root}}`, `{{name.path}}` from a step saved as `name`), on a named `conn` (each its own connection), optionally `async` and `await`ed later; or a `raw` line, `readFile`, `writeFile`, `sleepMs`. Terminal tiles run `/bin/cat` far off screen and are deleted at the end.
- `conformance/fixtures/<name>.json` is the transcript: each step's request, response and the events every subscribed connection received until it went quiet (`--settle`, default 120 ms; `settleMs` for steps that set off a slower write-back). An event on a connection that never subscribed fails its step (the transport sends events only after `events.subscribe`), and `record` refuses a run that has one. Ids become `<obj:1>`… (the prefix before `_`) by first appearance: an id is a value of an id field (every property the schema types `Id`, and the untyped `from`/`to` of an object's graph, `encloses`, `enclosedBy`, `follow`, `raisedBy`) or a key of `frames`, whatever made it, and once known it is replaced in any text (summaries, messages, refs). Revisions become `<rev:n>`/`<board:n>` by value (equal stays equal). Times keep their wire type: `<time:number>` (the API's dates, seconds since 2001, which schema/easl-api.json calls date-time strings: the fixtures record what the app sends) or `<time:iso>` (activity entries, board files); a value under a time key that isn't a moment between 2020 and now stays as it is, so it fails. The scenario directory becomes `<root>`, the home `~`, pids `<pid>`. Everything else is compared exactly, error messages included, and so is a key's presence: an explicit `null` and an absent key differ. A value the server can't know today (where a placement lands in the user's view, the foreground program of a terminal) is left out of the comparison (value and presence) through the scenario's or step's `ignore`, which says why; a step's `mask` leaves out only part of a string (the matches of `match` become `as`, the rest is still compared: a placement's coordinates in a history summary). Arrays a server lists in no particular order are compared sorted (`unordered`).
- A step whose result is the server's own measurements (`app.metrics`) says so with `shape` (the reason): instead of being compared, its result is checked against the method's result schema in schema/easl-api.json (`$ref`, `type`, `enum`, `const`, `required`, closed `properties`, `additionalProperties`, `items`, `oneOf`/`anyOf`; bounds, formats and patterns aren't checked), and the transcript keeps the verdict: `<fits the result schema>`, or where it doesn't.
- `replay` prints a table per scenario, per method and per method family, the client-delegated methods (`conformance/delegated.json`: view.get, view.render, view.snapshot, agent.prompt, agent.read's live-terminal modes (its `final` mode is the server's and replayed), object.reload, text.measure, which a Mac client serves), any schema method that is neither exercised nor delegated, and the diffs; it exits 1 unless everything passes.
- Scripted clients: a step's `replies` makes its connection a client (`client.attach` with `{{schemaVersion}}` and `{{schemaHash}}`, read from the schema) that answers the requests the server sends it, by method in order (`result`, `error`, `silent` to let the deadline pass, `hangUp` to close instead); the fixture records each step's `forwarded` requests. `client-delegation` replays every delegated method this way, `client-versions` clients on other schema versions and hashes, and `client-failures` the choice among several clients, a missed deadline and a hang-up mid-call. `no-client` replays easld with none attached: each delegated method's `unavailable`, and what measures text marked `approximate`. They are recorded against easld (their `recordedOn` says so), since the app doesn't speak the client protocol yet. Record them on a fresh easld: it keeps the exact arrow label sizes clients gave it for as long as it runs, so an arrow label a scripted client measures names `{{board}}`, which is new on every run.
- Text measurement with no client attached comes from `easld/internal/measure/glyphs/glyphs.json`, the advance widths of the fonts easl draws text in. After a font or text style change, regenerate it on a Mac: `swift scripts/glyph-widths.swift > easld/internal/measure/glyphs/glyphs.json`. The app-recorded `measure-notes` scenario doesn't pass against easld alone: its sizes are within a few points and marked `approximate: true`.
- Recording: run `record` against a fresh `scripts/dev.sh` instance of the commit you mean (`--on` says which), then `replay` against it twice: both must pass, or a step depends on timing. Re-record after an intended API change and review the fixture diff like code.
- Against easld: `go run ./easld/cmd/easld --home /tmp/easld-home --socket /tmp/easld.sock &`, then `replay --socket /tmp/easld.sock` (kill it afterwards; SIGINT, SIGTERM and SIGHUP save its pending board changes). Give it a home of its own: it refuses one the app (or another easld) holds, naming the holder's pid, and a socket another server answers on. `go test ./cmd/easld` in `easld/` does the same in-process and fails when a scenario in its `passing` list stops passing, or names no scenario.

## A development instance

`scripts/dev.sh` runs one isolated development instance per checkout. It never takes focus, so it doesn't interrupt whatever else you are doing on the Mac:

```sh
scripts/dev.sh start [root]      # build, bundle, launch without activating (no root: the home's previous tabs)
scripts/dev.sh cli board.get     # the easl CLI against this instance (sets EASL_SOCKET)
scripts/dev.sh snapshot out.png  # view.snapshot: what agents see (not verification)
scripts/dev.sh input click 400 300 --mods hyper
scripts/dev.sh restart           # rebuild + relaunch with the same tabs; terminal sessions keep running
scripts/dev.sh stop              # quit and kill this instance's terminal sessions
```

What it sets up:

- `EASL_HOME=<checkout>/.easl-home` holds this instance's socket, boards, pid, and `app.log`, so it never touches the installed app's boards or another instance's.
- `EASL_NO_ACTIVATE=1`: the app refuses to activate (`CanvasApplication`), so it can't steal focus or switch Spaces.
- Boards open as tabs of one window, and `open-boards.json` in the home reopens them at launch. The initial root (`dev.sh start <root>`) is the selected tab; without a root, `start` and `restart` reopen the tabs the home had open (the first one selected), or the checkout's board in a fresh home. A board opened while the window is minimized joins it as a hidden tab; under `EASL_NO_ACTIVATE`, `--select true` doesn't bring the window back.
- `EASL_DEV_INPUT=1` enables input replay (below).
- A fresh home is a first launch: Help › Get Started opens with its practice note until it's closed. For captures and studies that shouldn't show it, write `{"dismissed":true}` to `<home>/get-started.json` before `start`; a home that already has boards never shows it by itself.
- More instances of one checkout (parallel agents, user studies): `EASL_DEV_HOME=/tmp/study-a/home` gives an instance its own home (socket, boards, log, pid, zmx session label, so `stop` kills only its sessions, and browser profile), and `EASL_DEV_APP=<bundle>` launches a prebuilt bundle without rebuilding: assemble one with `EASL_BUNDLE_APP=/tmp/study-a/easl.app scripts/bundle.sh` and every instance runs that frozen build while the checkout changes (bundling deletes and rebuilds its target).
- Development bundles: an instance never runs from the bundle it was built as. `scripts/dev-bundle.sh` copies it (an APFS clone) to `<home>/easl.app` and stamps the copy's Info.plist: `LSEnvironment` with the instance's environment (`EASL_HOME`, `EASL_ROOT`, `EASL_NO_ACTIVATE`, `EASL_DEV_INPUT`, `EASL_DEV_PERF`, `EASL_BROWSER_PROFILE`, `XDG_CONFIG_HOME` when set), so when macOS relaunches it (logging back in reopens the apps that were running, or the Dock, Finder, a plain `open`) it comes back on its own home and last root instead of starting on the default home beside the user's live app; `CFBundleIdentifier` `net.waldin.easl.dev.<hash of the home>` for an `EASL_DEV_HOME` (its own user defaults, saved state and TCC identity), while the checkout's `.easl-home` keeps `net.waldin.easl` and with it its browser logins and window frames; and `NSQuitAlwaysKeepsWindows` false. The copy is signed again ad hoc (keeping the source's entitlements and hardened runtime) and registered with LaunchServices; the source bundle, a release build included, is never changed. An instance started before this runs from its source bundle until its next `start` or `restart`.
- Legacy migration rehearsal: `LegacyMigration` runs only on the default home, so to watch it on a real bundle give a throwaway home laid out like a user's: put an older install under `/tmp/up/home` (the support directory, dot directory and preferences plist of a name in `LegacyMigration.earlier`), make a development bundle with `scripts/dev-bundle.sh <app> /tmp/up/bundle HOME=/tmp/up/home "EASL_HOME=/tmp/up/home/Library/Application Support/Easl" EASL_BROWSER_PROFILE=own EASL_NO_ACTIVATE=1` and `open -g -n` it. With `HOME` not the user's own and `EASL_HOME` its default support directory, the launch migrates that home, reading and writing its `Library/Preferences` plists directly (`PreferenceFiles`: `UserDefaults` ignores `HOME`), and logs each step as `easl (rehearsal on <home>): …`. Keep the bundle outside the home: the migration may move the support directory aside.

Browser tests: `EASL_DEV_DOWNLOADS=<folder>` (passed through by `dev.sh`) saves browser downloads there instead of ~/Downloads, and `EASL_DEV_EXTERNAL_OPEN=log` makes links handed to the default browser or another app (⌥-click, `mailto:`) only log `easl: … → <app>` in `app.log`, so a test never opens a window in the user's browser. A page's open panel runs out of process, where no replayed click or key reaches: `input panel <path>` chooses the file.

Run `scripts/dev.sh stop` when the test is done, not at the end of the session: it also kills the instance's zmx sessions.

### Seeing the window

Verify what the screen shows with real pixels: the window itself, or `scripts/dev.sh shot` (with yabai; see "Optional: a machine shared with other agents"), a WindowServer capture of the window, the same pixels a person sees. Only a displayed Space is composited, and a window anywhere else keeps a stale frame, so `shot` refuses unless the window is on a displayed Space.

`view.snapshot` (`scripts/dev.sh snapshot`) is the agents' view, not verification: it redraws the window in-process and substitutes stand-ins for content drawn outside AppKit (code tiles render their text themselves, terminals are drawn from zmx session text, web views show cached images). It hides compositor and layer bugs by construction: on a large dogfood board, code tiles that were blank or smeared on screen looked perfect in `view.snapshot`.

Shots are at the display's backing scale (2× on both displays): divide pixel coordinates by 2 for window-content points (subtract the 28 pt title bar, or 64 pt once a second board adds a tab bar; `shot` includes the window frame, `snapshot` doesn't).

### Input replay

Real mouse input can't reach an unviewed Space, and posting system events needs a TCC grant this process doesn't have. `scripts/dev.sh input` sends events into the instance's own event queue, so the Hyper monitor, hit testing, and responders run as they do for real input:

```sh
scripts/dev.sh input click <x> <y> [--mods hyper|cmd|shift|opt|ctrl[+…]] [--clicks 2]
scripts/dev.sh input drag <x> <y> <toX> <toY> [--mods …] [--hold]   # --hold keeps the button down: shoot mid-drag, then
scripts/dev.sh input release <x> <y>                # end the held drag
scripts/dev.sh input rightclick <x> <y>             # opens the context menu on screen
scripts/dev.sh input menu <x> <y> "Content Zoom/150%"   # performs that context-menu item without opening the menu (over code: "Find References", "Outline"; "//" is a slash in a title: "Review Changes/Branch vs origin//main")
scripts/dev.sh input mainmenu "Edit/Send Mentions To/codex"   # performs that menu-bar item (menus AppKit fills as they open are filled first)
scripts/dev.sh input flags <x> <y> --mods hyper     # hold Hyper over x,y (hover outline); omit --mods to release
scripts/dev.sh input move <x> <y>                   # pointer move over tracking areas: moved, entered and exited (code navigation hover, a tile's − % + control)
scripts/dev.sh input text "hello"                   # insert into the first responder
scripts/dev.sh input command insertNewline:
scripts/dev.sh input shortcut z --mods cmd           # a key press by character: p, 9, =, +, $'\r'
scripts/dev.sh input key return                      # by name: return escape tab space delete forwarddelete up down left right home end pageup pagedown
scripts/dev.sh input scroll <x> <y> <dx> <dy>
scripts/dev.sh input scroll <x> <y> <dx> <dy> --repeat 30 --gesture   # one phased trackpad gesture (began and ended without movement)
scripts/dev.sh input scroll <x> <y> <dx> <dy> --lines   # a mouse wheel's notches (line units, no precise deltas); with --mods cmd, ⌘-scroll
scripts/dev.sh input magnify <x> <y> <amount>      # one pinch step: zoom × (1 + amount); 0.05 in, -0.05 out
scripts/dev.sh input panel <path>                  # choose a file in the open panel a page's <input type=file> opened
```

Coordinates are window-content points from the top-left: `shot` pixels / 2 (a Retina capture), minus the 28-point title bar (64 points while the window shows a tab bar, i.e. two or more boards are open). Prefer Hyper clicks and API calls: a plain click on a window of an inactive app is how macOS decides to activate it, and `EASL_NO_ACTIVATE` is the only thing standing between that and the user's screen.

`shortcut` and `key` are real key presses (key down and up, with the US-layout virtual key code and characters a keyboard produces) posted into the app's event queue, so they go where a physical key goes: the window's key equivalents first (board navigation shortcuts, `CanvasWindow`), then the focused view's (Ghostty's bindings), the main menu, and finally `keyDown` to the first responder. `input key return` submits a shell command or an omp prompt in a terminal tile; `input text` alone only types. Since the app never activates, no window is key; `CanvasApplication` dispatches a replayed key press as for the key window and resolves untargeted menu actions (Select All, Copy) through that window's responder chain, as a real key press would. `command` calls `doCommand(by:)` on the first responder directly: the text system handles it, a terminal ignores it.

`text`, `command`, `shortcut`, and `key` go to an open sheet (e.g. the ⌘G group-name prompt) when the window has one, so `input text "Auth"` then `input key return` confirms it. Esc/Delete on the board: `input key escape` / `input key delete` (the board has keyboard focus unless a terminal does). A save sheet (Save as PNG…, Save as HTML…) runs out of process: no replayed event reaches it, and `input key return` saves under the name it suggests, in the folder it opened in (the last export folder, else `~/Downloads`; `canvas.exportDirectory` in the `net.waldin.easl` defaults, which every instance shares: `defaults delete net.waldin.easl canvas.exportDirectory` after testing).

Any kind takes `--repeat N [--interval ms]` (default 8 ms apart) for a trackpad-rate burst, e.g. `input scroll 950 220 -40 -15 --repeat 120`; a `magnify` burst is one gesture (began, changed…, ended). A `scroll` burst sends continuous (trackpad-precise) steps without a gesture phase: on macOS 26 NSScrollView tracks a real phased scroll itself, and a replayed phased gesture only moved the view by its first step. `--gesture` replays the burst as that phased gesture anyway, for views that own a gesture from its first event (a changes tile keeps a whole gesture, the board never pans in it). A horizontal-dominant step (`|dx| > |dy|`) pans even over a code tile or a terminal; a vertical one over a terminal pans only while the terminal has neither keyboard focus nor scrollback (a fresh shell; a full-screen TUI in the alternate screen). When the burst ends, `app.log` records `longest gap … before step …, mean lateness …`. The longest gap between two steps is the longest stall a person sees, and it is the number to compare before and after a performance change. `scripts/perf-replica.sh start <board-id|file> [app]` copies a real board (terminals dropped) into a scratch home to measure against (with yabai, which places its window); `[app]` runs a given bundle, so two frozen builds can be measured in turns.

`magnify` is a real gesture event (CG type 29 with HID zoom type), so NSScrollView runs its own live magnification and the board's liveness pass runs at the end, exactly as for a trackpad pinch. Calling `setMagnification` per step instead measures a different thing. Live magnification anchors at the real pointer, so the replay moves the document back under the replayed point after each step. Put that point over empty board or a code tile: a note or terminal under it takes the gesture. On macOS 26 AppKit damps replayed steps after the first few (0.05 per step barely moves; `0.25 --repeat 45` goes from fit to 100% and `-0.25 --repeat 45` back out, rubber-banding at the limits).

### Performance probes

`EASL_DEV_PERF=1` (set by `dev.sh` and `perf-replica.sh`) turns on `DevPerf` (`Sources/CanvasApp/DevPerf.swift`). Every input burst becomes a span with a `gesture` phase and a 1.5 s `settle` phase (the liveness pass, card and live flips, and the redraws they cause); `input perf [ms]` is an idle span (default 5000 ms), which also works while the window is minimized. At the end of a span `app.log` gets one line per phase:

```text
DevPerf: burst of 45 magnify settle 1574 ms: frames 89 missed 6 (vsync 16.7 ms, longest frame 62.9 ms), main busy 278 ms, hitches 3 (longest 46.3 ms); counts: …; timings (n/total/max ms): card.call.CodeTile=9/46.1/5.9 draw.GroupView=220/11.4/0.1 scene.pass=23/48.0/46.2 …
```

- `frames`/`missed`/`longest frame`: a display link on the window; a missed vsync is one the main thread was too busy to serve (a dropped frame for anything the main thread draws).
- `main busy`/`hitches`: a main run-loop observer times each stretch from waking to sleeping; a stretch longer than one vsync is a hitch.
- `timings`: count, total, and longest milliseconds per probe: `draw.<View>` (every `draw(_:)` of our views), `scene.pass` (the liveness pass), `scene.boundsChanged` (per pan/pinch step), `content.live.<Tile>`/`content.unlive.<Tile>` (live/card flips), `card.call`/`card.latency`/`card.install.<Tile>` (card snapshots), `live.reveal.<Tile>` (card lifted after going live).

For CPU and wakeups, measure the process from outside: `/usr/bin/top -l 5 -s 3 -c d -stats pid,cpu,idlew,power -pid <pid>` (`IDLEW`: idle wakeups per 3 s interval; skip the first sample) and `/bin/ps -o time= -p <pid>` before and after a fixed interval (the shell's `ps` may be another tool); `sample <pid> 5` shows where the main thread spends it. Without `-c d`, `top -l` prints the process's lifetime total in every sample: a number that never varies within a run and only rises from run to run, whatever the app is doing now. `IDLEW` counts only wakeups that bring the CPU package out of idle, so on a busy shared machine it undercounts; timer wakeups are steadier as `ri_interrupt_wkups` from `proc_pid_rusage(pid, RUSAGE_INFO_V4)` (Python `ctypes`) over the same interval. A sleeping main thread with wakeups still counted belongs to another thread: per-thread CPU time from `proc_pidinfo(PROC_PIDTHREADINFO)` names it (Ghostty's are `io`, `io-reader`, `io-gather`, `renderer`, one set per terminal).

- Frame pacing needs a displayed window: show it only for the bursts you measure, and minimize an instance right after every `start`/`restart`. CPU, wakeups, and memory work minimized. Scenarios with synthetic boards: keep every object near the rest, or Zoom to Fit leaves the pinch point over empty board and the gesture measures nothing.
- Wakeups that stay high while the window is minimized and the main thread sleeps: `sample` the app and look for `CVDisplayLinkDriverHelper` → `TerminalSurfaceCoordinator.tick` → `draw`. That is a Ghostty surface that still believes it is visible: libghostty-spm's shared display link runs at up to 120 Hz while any visible surface owes a frame. With no display link in the sample, look at the `io` and `renderer` threads: a surface Ghostty believes focused runs cursor-blink and termios-poll timers, ~12 wakeups/s per terminal, visible or not (docs/design.md, Performance).
- Idle soak: a minimized instance with the load you care about (e.g. three idle omp tiles and a shell running `while :; do date +%T; sleep 2; done`), shown once first (a window that was never shown hides focus and visibility bugs), then CPU, wakeups, and `footprint` at the start and after 20 minutes; finally show it and take a `shot`: every terminal shows its current screen, and typing (`input click` on it, `input text`) reaches it.
- Memory: `footprint -p <pid>` for the app; WebKit's processes aren't its children, so attribute them with `responsibility_get_pid_responsible_for_pid` (e.g. Python `ctypes.CDLL(None)`) and sum their footprints.

### Performance benchmark

A repeatable loop for API-write bursts on a large board (docs/design/next.md, "Performance and monitoring"). Bundles are frozen release builds (`EASL_BUNDLE_APP=/tmp/a.app scripts/bundle.sh release`); the loop needs yabai and its own virtual screen (`EASL_DEV_DISPLAY`), and starts and stops its instances itself.

```sh
python3 scripts/perf-board.py <home> <root> [--arrows N] [--labels N]   # the synthetic board (seeded), into a dev home
python3 scripts/perf-load.py serial|batch [--variant 0|1]                # an agent's 139-event write burst over EASL_SOCKET
python3 scripts/perf-load.py poll --duration 60                          # board.get every 10 s, nothing else
python3 scripts/perf-loop.py --app base=/tmp/a.app --app fix=/tmp/b.app [--board <sanitized.json>] [--runs 3]
```

- The loop starts each bundle in turn on a scratch home of its own (a new directory under `--tmp`, deleted when that bundle stops; it never deletes anything else, so your `EASL_DEV_HOME` is safe), order alternating between runs, shows the board at 100% over its html cards, and runs `visible-serial`, `hidden-serial` (window minimized), `visible-batch` and `poll-idle`. Each row (JSONL, `--out`) has the app's CPU from the burst's start until it is quiet again, the burst's wall time and per-method RPC latency, the `DevPerf` span around it (main busy, the longest stretch the main thread didn't sleep, `route.board` routings) and `app.metrics` where the bundle has it; the table prints medians and ranges with the targets as pass/fail, and a target whose measurement is missing fails. `--summarize` re-prints a table from earlier rows.
- A real board's geometry without its content: `scripts/perf-sanitize.py <board.json> <out.json>` keeps types, frames, z, numbers, and enum values in their own fields (checked against each field's closed list), renumbers ids found in identity and reference positions (ids, parents, actors, arrow ends, group members), and replaces every other string with filler of the same length, decided by where a value sits, never by how it looks. It fails, naming only lengths and JSON paths, if any input string over 5 characters or word of 6+ letters survives outside the sanitizer's own vocabulary. Run it on the board's machine and copy only its output; `perf-board.py --replica <out.json>` re-roots it into a home. Its tests: `python3 -m unittest discover -s scripts`.

### Terminals and agents

- Terminal text: `TMPDIR=$(getconf DARWIN_USER_TEMP_DIR) zmx history canvas-<tileId> | tail -n 40` (zmx keys its socket directory off `TMPDIR`; the GUI app's differs from a terminal's).
- Create an omp tile: `scripts/dev.sh cli object.create --type terminal --json '{"props":{"cwd":"<repo>","command":["omp"]}}'`.
- Prompt it and wait: `scripts/dev.sh cli agent.prompt --target <tileId> --text "…"`, then `scripts/dev.sh cli agent.wait --target <tileId> --timeoutMs 300000`.
- Recent terminal text through the API: `scripts/dev.sh cli agent.read --target <tileId> --lines 40`; `--since prompt` gives what followed the last `agent.prompt` (its echo, then the reply); `--final` only the answer.
- Reboot resume: quit the app (`kill $(cat .easl-home/pid)`), `zmx kill canvas-<tileId> --force`, `scripts/dev.sh start`. A tile whose session is gone reruns `props.command`, or resumes its recorded agent session (`omp --resume=<sessionId>`, `claude --resume <sessionId>`, `codex resume <sessionId>`) with the options of the tile's `props.command` when it runs that agent (e.g. `-e <checkout extension>` stays, so the resumed omp loads the checkout's extension); options typed in the shell aren't known, so a tile started from its shell resumes without them.
- Terminal notifications: `printf '\e]9;Build finished\a'`, `printf '\e]777;notify;Title;Body\a'`, `printf '\a'` in a tile raise an attention marker on it (`app.log`: "terminal … sent a notification" / "rang the bell"; stored in the board file's `attention`). With `EASL_NO_ACTIVATE` the app is never active, so a focused terminal still gets them.
- Ghostty config: `app.log` logs which files loaded, the theme, font and size ("Ghostty config from …"), each rejected line, and each keybind of a window, tab or split action ("Ghostty keybind … runs easl's New Terminal", "dropped Ghostty keybind …"). Try a scratch config without touching the real one: `XDG_CONFIG_HOME=/tmp/x scripts/dev.sh restart` reads `/tmp/x/ghostty/config` (dev.sh passes `XDG_CONFIG_HOME` through; the Application Support config still loads after it).
- macOS notifications (agent done/blocked while the app is in the background) are never requested or posted with `EASL_NO_ACTIVATE=1`; `app.log` records "notification suppressed" instead.
- With the omp extension installed globally (`~/.omp/agent/extensions/easl.ts`, README), test a modified extension from a checkout: launch omp with `["omp", "--no-extensions", "-e", "<checkout>/extensions/omp/easl.ts"]`.
- Claude Code, Codex, Gemini CLI and opencode integrations (docs/contracts.md "Agent integrations"): type `claude`, `codex`, `gemini` or `opencode` in a tile of your instance; the bundle's wrappers load the integration from that bundle, so no install step. `agent.list` shows the kind and session id after `SessionStart`. To see what a hook does, run it by hand with the tile's variables: `echo '{"session_id":"s","source":"startup"}' | EASL_ENV=1 EASL_TILE_ID=<tile> EASL_SOCKET=<sock> extensions/agent-hooks/run claude SessionStart` prints the context it gives the agent and reports to that instance. The Codex hooks run only while `extensions/codex/config.ts` hashes them the way the installed Codex does: after a Codex update, start `codex` in a tile and check it prints no "hooks need review" warning (`/hooks` lists them as trusted). Keep real agents cheap: scratch repo copies without remotes, a low reasoning effort (`codex -c model_reasoning_effort=low`), and Claude Code against a local stand-in for the Messages API (`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, with `CLAUDE_CONFIG_DIR` pointing at a scratch config so first-run and trust dialogs don't touch `~/.claude`) when no login is available.
- Gemini CLI in a tile: the tile's login shell may pick an older Node (nvm's default) that can't run it; `nvm use` a newer one first. Never run it opted out (`EASL_AGENT_HOOKS=0`) or outside a tile without `general.enableAutoUpdate: false`: a plain Gemini `npm install -g`s its newest version on start (into the active Node's prefix), and 0.60+ refuses easl's settings layer. Answer its approval dialogs without the stage with `TMPDIR=$(getconf DARWIN_USER_TEMP_DIR) zmx send canvas-<tile> $'\r'` (Esc: `$'\e'`). opencode: a scratch repo's `opencode.json` with `"permission": {"bash": "ask", "edit": "ask"}` makes it ask when the global config allows everything.

## Optional: a machine shared with other agents

When several agents test on a Mac someone is using, each instance's window should stay off the Space that person is viewing and still render. `scripts/dev.sh` does this with [yabai](https://github.com/koekeishiya/yabai) (`YABAI`, else `~/Applications/Yabai.app`, else `yabai` on `PATH`) and a [BetterDisplay](https://github.com/waydabber/BetterDisplay) headless virtual screen. Without yabai, `start` and `restart` leave the window where macOS opens it (still never activated), and `shot`, `move` and `scripts/perf-replica.sh` stop with a message saying they need yabai.

```sh
scripts/dev.sh shot out.png      # real pixels: what the screen shows (verification)
scripts/dev.sh move <space>      # put the window on a Space to watch it; `move` alone returns it to the testing Space
EASL_DEV_SPACE=<space> scripts/dev.sh restart   # relaunch straight onto that Space
```

- A one-shot yabai rule parks the launch's first `easl` window on an unviewed Space of the built-in display (`EASL_DEV_PARK_SPACE`, default 7; floating, maximized) and is removed once `dev.sh` has moved the window to the testing Space. The testing Space is `EASL_DEV_SPACE`, else the first Space of the virtual screen named by `EASL_DEV_DISPLAY` (default `CanvasTest`: a headless monitor placed diagonally below-right of the built-in display, touching it only at the corner). A standing rule on `app=easl` would also grab every later window (tabs, other instances, the user's own boards) and hide them on the parking Space. Agents working in parallel each create their own virtual screen and select it with `EASL_DEV_DISPLAY=<name>`.
- A yabai rule can't place a window on another display's Space: the window lands on whatever Space the user is viewing, so never point the rule at the virtual screen. Recreate the screen if it's gone: `betterdisplaycli create --type=VirtualScreen --virtualScreenName=CanvasTest --useResolutionList=on --resolutionList=1512x982 --virtualScreenHiDPI=on`, then `betterdisplaycli set --name=CanvasTest --connected=on --placement=1512x982`.
- yabai moves windows behind AppKit's back, so a tab selected through the API while the app is inactive (`board.open --select true`) can reappear on the parking Space; `scripts/dev.sh move` puts it back.
- The testing Space on the virtual screen is always displayed, so `shot` works while the user is looking elsewhere.
- Keep builds light while others work: check the machine's load first, and use `swift build -j 2` when several agents build at once.
- One instance per checkout, and at most one omp tile at a time unless the test needs more.
