---
name: easl
description: You are running inside easl (EASL_ENV=1), an infinite board where your terminal sits next to tiles and drawings the user also sees. Use before explaining code, a change or a system (easl itself too), showing code/notes/HTML explainers/diagrams/changes on the board, reading or arranging what is on it, pointing the user at things, and talking to other agents. Answering a plain question or one about a mentioned item needs no skill.
---

# Working in easl

Your terminal is one tile on an infinite board the user is looking at.
Next to it live code tiles, changes (review) tiles, diagram tiles computed from the code, markdown notes, image tiles, browser tiles, sandboxed HTML tiles, and shapes/arrows/ink.
You and the user read and change the same objects: the board is the shared working state; your transcript stays in your terminal.

You are in easl when `EASL_ENV=1`. omp, Claude Code (`claude`) and Codex (`codex`) started in a tile all get the integration
(lifecycle, mentions, follow mode, this skill; `EASL_AGENT_HOOKS=0` turns it off for Claude and Codex).
Your tile's environment also has `EASL_TILE_ID` (you), `EASL_BOARD_ID`, `EASL_BOARD_ROOT` (the directory this board belongs to: a repo's main checkout, whichever worktree you are in), and `EASL_SOCKET`.

## Known surprises

Read these before you build anything; each one cost earlier agents a round trip.

- **Start small.** A first draft is about one screen: one tile, or a few in a group.
  Split a long explainer into grouped tiles rather than one tall page, and expand when the user asks. A 20-object first draft overwhelms; a compact one gets read.
- **Let the board do the geometry.** Omit `frame` and a new object lands in the free spot nearest your terminal, clear of every tile and group (other agents' too),
  inside the user's view when there's room within ~600 pt, else beside you out of view: raise a marker (`view.attention`) on anything they should look at.
  `frame: {w, h}` alone places that size the same way. Read the returned frame to place related objects.
  For deliberate layouts use `size: "fit"` and the layout helpers (`layout.place`/`stack`/`grid`/`translate`, then `layout.check`), not hand-computed coordinates:
  those collided with the follow tile and other agents' tiles. When `object.update` returns `overlaps`, move the object or grow it the other way.
- **Renders go to a temp file.** `easl render obj_…` without `--out` writes a new PNG under `$TMPDIR/easl-renders/` and returns its `path`. Never pass an `--out` inside the repo: it shows up in `git status`.
- **Write locations as `path:line`.** The user can ⌘-click `src/a.ts:42`, `:42:7`, `:10-20` or `#L10-20` (and Python `File "x.py", line N` or pdb `x.py(N)` frames) in your terminal output to open that code beside your terminal,
  resolved from your shell's cwd, then the board root. A bare `core.py:42` opens only when that name is unique or clearly nearest the cwd; deploy paths from production stack traces (`file:///srv/app/server/x.ts:39:5` → the repo's `server/x.ts:39`) and file names without a line (`Applied edit to url.go`) open too; `/rustc/…` std frames aren't links.
  So write repo-relative (or deploy) `path:line`, not prose like "in the store module".
- **In a worktree, write paths relative to it.** If you work in a git worktree other than the board root, your relative paths are your worktree's: code, image and diagram tiles read your worktree's files, and notes, HTML and changes tiles get your worktree as `root` automatically. Write `tests/x.ts:16`, never `../wt-x/…`; pass `ref` to anchor a tile to the branch instead.
- **Name what the user will look for.** Go to (⌘P) matches every tile's caption and terminal name, and captions tell excerpts of one file apart (VoiceOver reads them first);
  the tray labels the terminal mentions go to by its `name`: caption your code tiles and name terminals you create.
- **Your objects carry your name.** Tiles you create show "by <your terminal's name>" in their title bar, and the user's own Go to, definition jumps and changes-tile clicks never re-aim a tile you made, captioned, or grouped.
- **Code tiles tint their `range` only among other rows.** A `size: "fit"` tile shows exactly its range, untinted. To mark a few lines inside more context, give the tile a taller frame instead of fitting it.
- **Line-bound arrows pin when their line is out of view.** An arrow end bound to `lines` of a code tile attaches at that row only while the tile shows it; keep bound lines inside the rows the tile shows (fit the range, or bind to lines near its top).
- **Params are checked.** A param a method doesn't take (a typo, or `board` where the schema has none), or a missing required one, fails with `invalid_params` listing every param the method takes.
  Objects you create or change on another board (`board`) are credited to your terminal; placement there goes near the view's centre.

## Pick a client

- **You have a persistent Python REPL (e.g. an `eval` tool): use the Python SDK.** One connection, typed methods, compositions.
  ```python
  from easl_sdk import canvas
  board = canvas.board.get()                      # manifest of every object
  note = canvas.object.create(type="note", props={"markdown": "# Plan"})["object"]
  canvas.agent.wait(target="reviewer", timeout_ms=600000)   # keywords are snake_case (CLI: --timeoutMs)
  ```
  omp's `eval` kernel does not inherit `EASL_*` (omp gives it an allowlisted environment), so connect explicitly there;
  your system prompt has the exact line, or read the values with `echo $EASL_SOCKET $EASL_TILE_ID $EASL_BOARD_ID` in bash:
  ```python
  from easl_sdk import connect
  canvas = connect(socket="…/easl.sock", tile="obj_…", board="brd_…")   # `from easl_sdk import canvas` uses it too
  ```
- **Otherwise: the `easl` CLI** (on PATH in every tile; it reads `EASL_SOCKET`, `EASL_TILE_ID`, `EASL_BOARD_ID`, so pass them through when you run it from a kernel that lacks them).
  Methods are `namespace.method`; params are `--key value` (values parse as JSON when they can; an array param takes one item, a comma-separated list of strings, or a repeated flag: `--until working,blocked`, `--ids obj_a --ids obj_b`), a bare `--flag` (true), or `--json '{…}'` (`--json @params.json`, or `@-` for stdin, for big HTML).
  ```sh
  easl methods                                   # every method with its description
  easl methods view.render                       # its params (types, defaults, required) and result
  easl methods CodeProps                         # a type's props (any *Props: NoteProps, HtmlProps, …)
  easl object.create --type note --json '{"props":{"markdown":"# Plan"}}'
  easl get obj_… --as graph                      # object.get shorthand
  easl render obj_…                              # view.render shorthand (also obj_a,obj_b or x,y,w,h); prints the PNG path
  ```
  "The socket exists but connecting to it failed … a sandbox may be blocking" means your sandbox blocks the unix socket, not that the app is down: run easl commands outside it (Codex: escalated) or ask the user to allow the socket.

Results are objects, never bare values: `object.create`/`update`/`get` return `{object}` (the new id is `result["object"]["id"]`), and create/update add `warnings` for a prop key the type doesn't know (a typo like `colour`): fix it.
`caller` (you) and `board` are filled from the client's tile and board, so objects you create are attributed to you and placed next to your terminal.
Every result shape, the TypeScript client, error codes and reconnects: `references/api.md` in this skill's directory.

## Read what the user points at

When the user Hyper-clicks things on the board and then prompts you, the prompt carries a hidden block:

```text
<canvas-mentions board="brd_…" root="/repo">
[1] code src/store.ts:41-48 (symbol restore) · tile obj_A · diff vs merge-base 1a2b3c4
  > 41   export async function restore(id: string) {
[2] dom http://localhost:3000/login · button#submit "Sign in" · browser tile obj_B
[3] shape rect obj_C "auth path?" (drawn by user) · encloses obj_A · arrow → obj_D (hypothesis_about)
[4] shape ellipse obj_E (drawn by user) · over browser obj_B at (240, 200) 125×120
</canvas-mentions>
```

"this", "these", "here", "that box" in the prompt refer to these entries, in order.
A mention of your own terminal says `(your terminal)`; other terminals are named, so "this terminal" means the one mentioned, not yours.
Mentions arrive only in prompts submitted in the terminal the tray shows (`view.get` `promptTarget`); to see what is staged use `tray.list`, never `tray.drain`.
Excerpts are short; read the real file or `easl get <id>` for more.
A drawn shape means nothing by itself: read what it encloses and connects (`easl get <id> --as graph`) or look at it (`easl render <id>`).
A shape `over` a tile marks a region in the tile's local units (`partly over`: more than half of it, clipped to the tile); look at that part with `easl render <tile>`.
On a browser or HTML tile the mention adds `page elements under it (<url>):` lines (`<selector> "<text>"`), read when the prompt was sent: re-check with the selectors or a render if the page may have changed.
A Hyper-click on a page's `<canvas>`, `<video>` or `<img>` carries `pixel (x, y) of W×H` in the element's own pixels: use it directly instead of mapping a drawn shape's region.
A Hyper-click on a group's title or empty interior mentions the whole group: `[n] group "Ingress" of 6 objects · group obj_…`, then each member (`- note obj_… "title"` with its first lines, `- code obj_… "path" · lines 40-52` with a few of them, a page's URL, a terminal's name), then `arrows among them:` (`from "title" → to "title" · "label" (relation)`): the arrows are the diagram's meaning, read them as its flow. Member text is cut short and a long group ends `(left out to keep this short: …)`: `easl get <id>` a member for all of it.
A terminal mention quotes its screen (one over 41 lines keeps 40: the first 3, the last 10 and failure lines).
A command's output (``[n] command `go test ./...` · exit 1``) ends `· read it: easl agent.read --target <id> --block -N` while that block can still be read (after `clear` the mention's own lines are all there is): run exactly that to read the block (up to its last 2000 lines).
Whether the user's last command passed: `lastCommand` (`{command, exit, durationMs}`) in `agent.list`/`object.get`, not the screen.
An `(edited)` marker means what the mention holds changed after the user staged it (a note's text, a page's address, a Stage/Unstage/Discard of that code mention's own lines): re-read it.
Every mention kind and field: `references/api.md` "Reading the board".

## See the board

| Want | Call |
| --- | --- |
| Look at objects or a region, wherever the user is | `view.render` |
| What the user is looking at right now, as pixels | `view.snapshot` |
| Where the user is looking, without pixels | `view.get` |
| What happened since you last looked (who made, moved, deleted what; where the user went) | `board.history` |

**`view.render`** draws part of the board offscreen at a fixed scale.
It never moves the user's view and doesn't depend on it, so never put probe objects in the user's view to look at them.

```sh
easl render obj_…                                  # one object (the board region under it)
easl render obj_a,obj_b --scale 2                  # the region covering several
easl render 0,1200,2400,1600 --exclude '["terminal"]'   # a board rect x,y,w,h
easl render obj_… --full                           # a note/HTML tile's whole content (code: its whole range), below its frame too
```

Per object drawn the result has `state` (`placeholder`: it didn't paint in time, `reason` says why) and `overflow {x, y}` (content beyond the frame: resize by that much, or render `--full`).
`easl board.history --since <cursor>` lists who created, moved, and deleted what (`actor` `user`, `system` or `agent:<tile>`) since your last look.
Every result field, pixel-to-board mapping, and history detail: `references/rendering.md`.

## When the user asks you to explain something

"How does X work", "walk me through this change", "explain this system", "explain easl to me": answer on the board, as a small map around your terminal, not as a wall of terminal text and not as one big HTML page.
Tiles and arrows are things the user can move, mention and step through; a page is one tile they can only scroll.

1. **The code that matters, as code tiles at exact ranges**, each with a `caption` saying what to notice: `{"path": "src/store.ts", "range": {"start": 41, "end": 60}, "caption": "restore replays the log"}` and `"size": "fit"`.
   Three to six stops, not every file you read (your follow tile already shows those); several at once with `canvas.compositions.locations.open([…])`.
2. **The structure as shapes and arrows** between those tiles: a `group` per part (`title`, `members`), `arrow`s with a `relation` (`"calls"`) and a two-word `label` only where the ends don't say it.
   For who calls what, a `diagram` tile (`symbol`, `direction`) instead of drawing the call graph by hand (it needs the language's server: Diagram tiles).
3. **A browser tile when a page makes the point**: the running app, or the docs or README the code follows (`browser` `{"url": "…"}`).
4. **A note for what should last**: the summary in a few lines, with `path:line` links and anchored fences (```` ```ts file=src/store.ts#L41-60 ````), not pasted code.
5. **A short terminal answer**: the answer in a sentence or two and where to look, with a `view.attention` marker on the first stop; don't retell the tiles in prose.
6. **An HTML explainer only when a comparison or a decision needs its components** (`<canvas-compare>`, `<canvas-decisions>`; `references/html-explainers.md`), or when the user asks for one page.

When it has an order (a request's path, a change step by step), join the stops with `"relation": "next_step"` arrows labelled "1 · parse", "2 · …" and group them titled "Start here": ⌥⌘→ on the group, or with nothing selected, starts at the first stop (`references/shapes.md`).
Build it in one `object.batch` (`"$0"` references), place it with `layout.place`/`layout.stack`/`layout.grid` (Readable diagrams, below), then run `layout.check` and fix what it reports, and look at it (`easl render <group>`) before you point the user at it.

Say only what the code, the README or the docs show, and show where: every claim gets its tile, fence or `path:line`; read before you describe a feature, never describe one from its name.
For easl itself, ground it in this skill and `references/ui.md` (the same text as Help › easl Basics), or in the README and `docs/` when the board is easl's own checkout.
Excerpts show code as it is now: a code tile's range and a note's fence follow their code as lines move, and say stale only when the code they quoted is gone. Never tell the user an excerpt flags code that changed (a code tile's gutter marks lines changed against its `diffBase`; that is the diff, not the excerpt).

## Show your work on the board

Create objects when a visual helps the user more than terminal text: a plan they will come back to, code they should look at, a comparison, a diagram, an explanation (above).
Don't mirror your whole transcript onto the board.
Within 10 minutes of your last object, the next one without a `frame` stacks below it (else right of it).
When you lay things out deliberately:

- `size: "fit"` sizes a tile to its content.
- `layout.place`/`layout.stack`/`layout.grid` position objects (groups move whole; `grid` lines up columns across lanes), and `layout.translate` moves a finished build into place.
- `object.batch` applies a whole layout as one ⌘Z step with `"$0"` references to objects it creates.
- `layout.check` reports overlaps, arrows through tiles, arrows on top of or crossing each other, arrow labels on tiles, titles, lines or each other, content that doesn't fit (HTML pages too), code tiles that scroll, and cut-off captions and note tables.
  It judges what is drawn, so an empty report means the picture is clean. Unfilled rects and ellipses are annotations and never count as overlaps.

Details and an example: `references/api.md` "Layout".

| Want | Create |
| --- | --- |
| Point at real code | `code` tile: `{"path": "src/store.ts", "range": {"start": 41, "end": 60}, "caption": "restore replays the log"}` (`path` relative to the board root; see Code tiles) |
| Several locations at once | `canvas.compositions.locations.open(["src/a.ts:10-40", "src/b.ts:7"])` |
| Durable notes, plans, findings | `note`: `{"markdown": "…"}` |
| Who calls a function, what it calls | `diagram`: `{"symbol": "SocketServer.start", "direction": "incoming"}`, see Diagram tiles |
| A chart or figure | `image`: `{"path": "out/fig.png", "caption": "…"}`: save the figure to a file and show it; re-save to the same path and the tile reloads. No base64 PNGs in HTML |
| A plan to approve, a comparison, a decision | `html` tile, see below |
| Structure: boxes, labels, relations | `shape` / `arrow`, see below |
| A web page | `browser`: `{"url": "http://localhost:3000"}` (your browser tool opens its own; see Browser tiles) |

A tile's size is its frame; `zoom` in its props (0.25–8, default 1; not on image tiles) is how big its content draws inside that frame, in place: 1.5 is 150%, the frame never changes with it, and the content lays out at the body ÷ zoom (a terminal gets fewer, bigger columns; a page a narrower viewport).
To show more or less, resize the tile; don't zoom to make room. A text shape's font is `textSize` (0.25–8, default 1), and its box grows with it.
Users zoom content themselves (Object › Content Zoom, ⌃⌘= / ⌃⌘-, or the − % + in a tile's title bar); leave their zoom alone unless asked. `props.scale` is gone: it fails with `invalid_params`.

Update with `object.update` (props shallow-merge; `frame` may give any of x, y, w, h; pass `rev` from your last read or create to avoid clobbering a concurrent edit; `conflict` means re-read and retry).
After changing a note's markdown or an HTML tile's html, refit in the same call: `object.update` with `"size": "fit"`.
Don't rewrite a note the user is editing (`view.get` `focused` is that note): they get a conflict banner, and Esc keeps theirs with yours one ⌘Z away, where it can silently vanish. Wait until they leave it, or add a separate note.
Before styling a chart or page, read `view.get` `appearance` (`dark`|`light`); for dark, e.g. matplotlib `plt.style.use("dark_background")` and `savefig(…, transparent=True)`, not white slabs.
The user can share without you: the object menu has Copy as Image and Save as PNG…, an HTML tile's Save as HTML… and Open in Browser, a note's Copy as Markdown and Save as Markdown… (its markdown as written, links and fences intact), and a browser tile's Snapshot to Image (the page frozen as an image tile kept with the board, for before/after evidence).
Don't rebuild an export by hand (a note as an HTML tile, say) unless they ask for another format.
Delete with `object.delete`; deleting a terminal tile ends its session and whatever runs in it.

### Notes

A note created without a frame height fits its markdown (at `frame.w`, default 280), so `frame` can be just `{x, y, w}`.
An anchored fence shows its code as it is on disk now and follows it as lines move, so prefer anchors over pasted code:

- Excerpt, rendered from disk: ```` ```ts file=src/store.ts#L41-60 ```` or ```` ```ts file=src/store.ts symbol=restore ```` (`symbol=Class.method` finds methods deep in long classes: prefer it for whole functions).
- Proposed change, rendered as a diff against the real range: add `propose` (```` ```ts file=src/store.ts#L41-48 propose ````) and write the new code in the fence. An applied one shows "✓ applied"; no need to delete it.
- Plain fences are free-written snippets; `file:line` references anywhere in a note become links; `![alt](out/fig.png)` shows an image (board-relative, or absolute inside the board root or the temp dir).

Whether an excerpt still finds its code: `easl get <note>` → `fences` (per fence `state` live|relocated|stale|applied|missing, `range`, `reason`; `relocated`: the code moved and the fence followed it; `stale`: the code it quoted is gone), not a render searched for badges.
Table cells wrap to the note's width, so keep evidence timelines as `| time | event | evidence |` tables; `layout.check` `truncated` `{what: "table", x}` means too many columns: widen the note by `x` or split the table.

### Code tiles

A code tile shows the whole current file, scrolled so `range` sits a few rows below the top, with `range` tinted among the rows around it.
Its gutter shows changes against `diffBase` (default `merge-base`: the whole branch; `head` for uncommitted work only; or a commit sha).
A header "⚠ git failed: …" means git couldn't answer (cancelled, timed out, failed), not that the repo lacks commits; it clears on the next load. Don't work around a base warning with `diffBase: "head"` or a hand-picked sha unless the user asked for that base.

- **`caption`** is one line under the header (plain text, `inline code`, never wraps), so a tile doesn't need a separate note for its one-line explanation.
- **`size: "fit"`** sizes a tile to exactly its range (up to 960 pt wide; longer lines soft-wrap, so keep them in the range). Pass the `range` even when `symbol` is set.
- **`pinnedCommit`** (a sha, tag, branch, or `HEAD~N`) shows the file as of that commit, read-only: for old-vs-new comparisons, or a PR head you fetched. `null` goes back to the working tree; for "what changed since X" use `diffBase: "<sha>"` instead.
- **`ref`** (a branch) anchors the tile to the branch, not one checkout: while a worktree has it checked out the tile reads that worktree live (gutter, edits); otherwise the branch's commit, read-only; after the worktree and branch are deleted it keeps showing the merge commit ("merged in <sha>") or, for a squash merge, the branch's last commit ("branch gone, showing <sha>"). Use it for tiles about a PR lane whose worktree will go away; `path` stays repo-relative. `pinnedCommit` wins if both are set. Notes and HTML take `ref` too: their excerpts and links read at the branch (the body stays inline).
- **Ranges stay on their code** as lines move (the app rewrites `range`), so don't retarget evidence tiles by hand; `easl get` → `rangeStatus` `stale` means the code is gone.

Paths may point outside the board root (another repo, a worktree); a path or commit that doesn't exist is `not_found`. Every code-tile prop: `references/api.md` "Objects".
Code navigation (Go to Definition, Find References, Outline) needs the language's server; if a panel says it wasn't found, answers are text search: tell the user where easl looked (`references/ui.md` "Zoom and keys") rather than suggesting PATH edits.

### Changes tiles

To show the user what you changed, create a changes tile instead of an HTML diff: `easl object.create --type changes --json '{"props":{},"size":"fit"}'`.
Props: `base` (default `HEAD`: uncommitted work; `merge-base`: everything the branch changed, a PR's view; or a commit), optional `root` (another worktree of the board's repo, e.g. `"../wt-agent"`), `paths` and `title`. Creating it again with the same props returns your existing tile (`reused: true`).
A branch's or PR's diff without checking it out: `{"base": "origin/main", "head": "<branch or pull/N/head>"}`, read-only from git objects (head vs its merge-base with base; renames and deletions shown; no Stage/Discard; a line click opens a code tile pinned to that side's commit). A ref the repo lacks shows the exact `git fetch` to run: easl never fetches, so fetch first.
`{"ref": "<branch>"}` instead of `root`: the worktree that has that branch checked out while one does (live, stageable), else its commits as with `head`; once the branch is deleted it keeps showing the last commit it read (`props.refSha`), marked `merged in <sha>` or `branch gone`.
The user stages, unstages or discards per file, hunk, or selected lines; Stage/Unstage never change files: tell a user unsure of git so when they review your work.
Read what they kept with `object.get` (`changes.files[].hunks[]` with `status` and `lines`; `props.reviewed[]`), no render needed. Every field: `references/api.md` "Objects".

### Diagram tiles

For "show me who calls X" (or what X calls), create a live call graph from the language server instead of drawing one:
`easl object.create --type diagram --json '{"props": {"symbol": "AgentReportSpool.read", "direction": "incoming", "depth": 2}}'`.

- `symbol` is `Type.member` or a bare name (labels optional), found through the language server's workspace symbols when no path is given; when several functions have that name, `graph.error` lists them (`path:line (Container.name)`): recreate with `path` or a `Container.member` symbol. `line` (with `path`) works instead of `symbol`. `direction`: `incoming` (callers), `outgoing` (callees) or `both`; `depth` 1–4 (default 2).
- The graph is computed by the language server (sourcekit-lsp answers from the index of the user's last `swift build`; its first answer in a project takes ~20 s). `easl object.reload --id <tile>` computes it again and waits (up to 60 s); then read `props.graph` with `object.get`: `nodes[]` (`id`, `name`, `container`, `path`, `line`, `lines`, `excerpt`, `level`, `stale`, `expandable`), `edges[]` (`from` caller → `to` callee, call `lines`), `error`.
- It stays live: a file it shows changing recomputes it; nodes are re-found by symbol, and one whose symbol was deleted stays with a stale badge (`stale: true`). Only functions in the board's files are nodes.
- Open a node's next level by adding its id to `props.expanded` (the user clicks the node's +). The tile sizes itself to its first graph and grows into free space when a node opens (never over other objects; what doesn't fit is drawn smaller: resize it or zoom); `size: "fit"` on create waits for the first graph (up to 60 s, as `object.reload`) and fits the tile to it; the result's `diagram` is `object.reload`'s summary.
- Bind an arrow to a node with `{"object": "<diagram>", "node": "<node id>"}` (e.g. from a note explaining that caller).
- `error` says why a graph is empty or old (no server for the language, the symbol isn't declared there, an unindexed project); the last good graph stays.

### HTML explainers

`object.create --type html` with `{"html": "…", "title": "…"}` and `"size": "fit"` (with `frame` `{x, y, w}`, default width 640).
Tiles are sandboxed (no network unless you list hosts in `allowNetwork`) and preload Tailwind themed to the app, Mermaid, and grounded components (`<canvas-code>`, `<canvas-link>`, `<canvas-decisions>`, `<canvas-compare>`).
Ground every code claim with `<canvas-code>`/`<canvas-link>` instead of pasting code.
Read `references/html-explainers.md` before building an explainer: components, playbooks for plans, walkthroughs, comparisons and decisions, and Mermaid pitfalls.

### Shapes and arrows

- `shape`: `{"kind": "rect" | "ellipse" | "text" | "ink", "text": "…", "color": "blue", "fill": "none" | "semi" | "solid"}` with a `frame`; a rect drawn around tiles *encloses* them.
- `arrow`: `{"from": {"object": "obj_…"}, "to": {"object": "obj_…", "lines": {"start": 41, "end": 48}}, "relation": "calls", "label": "…", "route": "avoid"}`; `relation` is the machine-readable edge, `label` what the user reads.
  For a walkthrough, join the stops with `"relation": "next_step"` arrows (label them "1 · parse"): ⌥⌘→/⌥⌘← step along them, centring each stop.
- `group`: `{"members": [ids], "title": "…", "color": "blue"}` is a titled, tinted region that always wraps its members; use one per lane or cluster instead of a rect plus a label.

Colors, fills, text sizes, arrow routing and binding rules: `references/shapes.md`.

**Readable diagrams** (a flow of tiles joined by arrows):

1. One group per stage, laid out in reading order: stage columns left to right, or rows top to bottom. Set the outer group's `flow` (`"right"`, `"down"`) when the layout alone doesn't say which way it reads.
2. Leave room for the arrows: about 120 pt between columns and 60 pt between stacked tiles where arrows run between them, more for a column many arrows fan into.
3. `route: "avoid"` for every arrow that crosses the diagram; in each column, order tiles the way their arrows go, so fans don't cross.
4. Label an arrow only when the relation isn't obvious from its ends, in two or three words; detail goes in the tile.
5. With more than about 6 arrows, color them by lane or flow, so each label (outlined in its arrow's color) reads with its own line: e.g. `"color": "blue"` on every request-path arrow and `"color": "green"` on the replies.
6. `layout.check`, then fix what it reports: `arrowOverlaps`, `labelOverlaps` (a label on a tile, title, label, or another arrow's `lines`), and the `arrowIntersections` a tile order or a wider gap removes; its `hints` say when many labelled arrows share one color.
`easl get <id> --as graph` returns what an object encloses, overlaps, and connects to, so diagrams you draw are readable by other agents too.

### Boards a script keeps current

A script that rebuilds part of the board from elsewhere (a region per Linear ticket or PR, its status, its diff) names what it makes with `props.key` instead of keeping ids: any object takes one, unique on its board.
`object.upsert` finds the object holding the key and updates it (props merge; it stays where the user moved it unless you pass `frame`), or creates it when none does; `created` in the result says which.
Run the same batch every time; the second run changes only what changed, with the same ids, one ⌘Z:

```python
for t in tickets:  # e.g. from Linear
    k = t["id"]    # "REL-12389"
    canvas.object.batch(ops=[
        {"method": "object.upsert", "params": {"key": f"{k}/status", "type": "note", "props": {"markdown": f"**{t['state']}** · CI {t['ci']}"}, "size": "fit", "frame": {"x": 0, "y": 0, "w": 320}}},
        {"method": "object.upsert", "params": {"key": f"{k}/diff", "type": "changes", "props": {"root": t["worktree"]}}},
        {"method": "object.upsert", "params": {"key": k, "type": "group", "props": {"members": ["$0", "$1"], "title": f"{k} {t['title']}"}}},
    ])
```

`"$0"` is op 0's object whether it was created or updated. A frame given to an upsert applies on every run, so leave it out (or out of the batch after the first run) where the user may rearrange.
`object.find(key="REL-12389")` returns that object as `object.get` does (`not_found` when none holds it); `object.find(key_prefix="REL-")` lists every keyed object whose key starts with it, e.g. to delete regions of tickets that closed.
Taking a key another object holds, or upserting it as another type, is `conflict` naming the holder.

## Browser tiles

omp's `browser` tool opens a browser tile beside your terminal for each `browser.open` (find its id with `easl board.history --limit 5`); `close` deletes it.
To drive a tile it didn't open, `browser.open({name: "<new tab name>", url: "canvas:obj_…"})` attaches to that tile at its current page; `browser.close` then lets go and leaves the tile on the board.
Without omp's tool (Claude Code, Codex, a script), drive tiles with `easl browser <verb> <tile> [--key value]`, one call per step; every browser tile works, the user's too.
`easl browser open <url>` opens one beside your terminal and prints its `surface_id`; `easl browser list` lists the board's.
Loop: `easl browser snapshot <tile> --interactive` (refs `e1`…), then `click <tile> --selector @e2`, `fill <tile> --selector @e1 --text "…"` (or `type`), `press <tile> --key Enter`, `wait <tile> --load_state complete`, `eval <tile> --script "document.title"`; refs last until the next snapshot or navigation, so snapshot again after the page changes.
`easl browser screenshot <tile> --out shot.png` writes the PNG and prints its `path`. `close <tile>` deletes the tile: close only tiles you opened. Verbs and params: `references/browser.md`.
Codex runs these escalated, like every easl command. Playwright, browser-use and Chrome DevTools MCP can't reach tiles: they are WebKit, with no CDP endpoint.
The page's viewport is the tile's body; the tool's `viewport` and emulation don't reach it: for a phone width resize the tile (`object.update` frame `{"w": 390, "h": 902}`).
Pages you drive stay live for 60 s wherever the tile is; 2 min after the tile leaves view the page is released (in-page state gone), so finish multi-step page work without long pauses.
Before trusting rAF or timer numbers, check `easl get <tile>` → `page.visibility` (visible/hidden/driven/released).
After editing a page, reload any browser tile (the user's too) with `easl object.reload --id <tile>` (it waits for the load), then read `easl get <tile> --since <cursor>` → `page.errors`/`page.entries` before calling it clean; never change `props.url` to a dummy query to force a reload.
A released page's last log is in `page.previous`, and `page.cursor` stays valid across the release.
Also read a dev-server terminal on the board after edits (`agent.list` program `next dev`, `vite`…): `easl agent.read --target <it> --lines 40`. Compile errors and 500s show there. Report, don't restart it unasked.
Leave tiles and servers the user is looking at until they say they're done with them ("looks good" isn't done). Don't promise a page refreshes by itself after you change what it shows: reload or render it and check.
Never open the Web Inspector yourself. Eval and CSP limits, visibility states, rendering unloaded pages, and history credit: `references/browser.md`.

## Follow mode

Your terminal has one follow tile: the board re-aims it at every source file in the project you read, edit, or write, and flashes the lines each edit changed.
It happens automatically and is on by default (never tell the user to turn it on); don't create code tiles just to show what you are reading, and don't resize it or lay out around its size.
If the user closes it, your terminal stops following until they turn Follow Files back on in your terminal's menu: don't re-create it or turn following back on yourself.
Create code tiles for code you want the user to keep looking at.

## Getting the user's attention

Never move the user's viewport (no panning or zooming to your objects) unless they ask. To point at something, raise an attention marker:

```sh
easl view.attention --id obj_… --message "The race is here"   # → {"id": "obj_…", "active": true}
easl view.attention --id obj_… --clear                         # take it back
```

Markers are keyed by the object (raising again replaces the message) and stay until the user looks at the object, even across app restarts.
A marker's bubble is at most the object's width (240–480 pt), so put the point of `--message` in its first ~40 characters.
Raise one marker per thing your answer points at. Your first marker after the user's next prompt clears your earlier turns' markers (the result lists them in `cleared`), while markers of the same turn stay together:
don't clear old ones yourself, and never re-raise the cleared ones; the user saw them with your last answer.

## Asking the user

When a decision is the user's to make and blocks you or another agent, post a question tile instead of asking in chat or building a `<canvas-decisions>` page.
It carries discrete options and your recommendation, shows up in the user's ⌘J needs-you list and the board's open-asks count, and the answer comes back to you as a mention with your next prompt, or from `--wait`.

```sh
easl ask "Ship the migration before the freeze?" --option now="Ship now:needs the 9am deploy window" --option later="After the freeze" --recommend now --context src/migrate.ts:40-72 --expires 4h
easl ask "Which name?" --option a=Atlas --option b=Beacon --wait   # blocks; the answer {id, option, label, note, at, by} prints as JSON, exit 0
easl ask cancel obj_…                                              # the question is moot
```

- `--option id=label[:why]` repeats; `--recommend <id>` names your pick; `--context` points at what it is about (an `obj_…`, a URL, or `path:10-20`). Without options the answer is a note.
- Without `--wait` the command returns at once: carry on, and the answer reaches you as an object mention. Use `--wait` only when nothing else can proceed; a question cancelled, expired (`--expires 30m`, `2h`, `1d`) or deleted ends it with the reason on stderr and exit 2.
- Ask only what you can't decide yourself, one question per decision. Cancel one the moment it is moot (you found the answer, the plan changed): an open question keeps counting as something the user must do.
- Keep `<canvas-decisions>` for an explanatory page with many choices recorded in its state, and chat for anything conversational.
- `easl ask list --open` lists the board's open questions; `easl ask wait <id>` resumes waiting on one after an interruption.

## Whose objects are whose

Every object records who created and last changed it (`createdBy`/`updatedBy`: `user` or an agent's tile).
Objects you created are yours to update, rearrange, and delete.
Touch the user's objects (their notes, drawings, tile layout) only when the user is collaborating with you on them: they asked, or they mentioned the object in this request.
Every agent change is undoable with ⌘Z, but that is a safety net, not a license.

## Other agents

Agents in other terminal tiles (any board in the app) are reachable by tile id, tile name, or `name@board` (board = its folder's name, or its id). A bare name is looked up on your board first, then every open board; a name on two boards is `ambiguous`: say `name@board`. A renamed tile still answers to its old name.

```sh
easl agent.list                                    # every terminal: tile, kind, name, lifecycle, board, root, `program` (foreground program) and `title` (its OSC title)
easl agent.prompt --target reviewer --text "Review the diff in src/store.ts"   # → waitable, submittedAt
easl agent.wait --target reviewer --timeoutMs 600000   # until idle/done/blocked; `--until working` (or `working,blocked`) narrows it
easl agent.read --target reviewer --since prompt   # only what came after your last agent.prompt
```

`easl tell <name[@board]> "text" [--when next-turn] [--from <label>]` is `agent.prompt` for a message: an agent whose integration takes messages (omp with easl's extension) gets it out of band as a message naming you, without touching its draft or an open question (a working one is steered; `--when next-turn` waits for its turn to end), and replies with `write agent://<your address>`. Others are typed into as before (the result's `delivery` says `message` or `typed`). From a script with no tile, `--from machine-watch` names the sender and the message counts as the user's. Hosts aren't part of an address yet.

When `agent.prompt` returns `waitable`, call `agent.wait` right away: it waits for the work you just asked for, not the previous idle.
Then `agent.read --since prompt` returns what followed your prompt (its echo, then the reply), and `agent.read --final true` only its last answer (`unavailable` mid-turn or for opencode: use `--since prompt`; `cutOff` means the turn died on that error: say so, don't treat it as done).
A prompt sent while the agent is `working` joins that turn: `agent.wait` returns at its end. The last answer survives an app restart, and an agent that finished while easl was closed comes back `done` with it.
Hand over board objects instead of describing them: `agent.prompt` `mentions=[{"object": id}, {"object": code_id, "lines": {"start": 41, "end": 48}}]` reach the receiver as hidden context naming your terminal.
Kind `omp`, `claude`, `codex`, `gemini` (before 0.60) or `opencode` reports a lifecycle (a Codex tile is `blocked` at launch while Codex asks whether to trust the folder, and `idle` once the user trusts it).
Agents without an integration (aider via easl's `aider` wrapper, any CLI's OSC 9/777 or bell) have their program as `kind` and `lifecycle.via: "notifications"`: `done` when they last said they wait, `unknown` after a prompt, never working/blocked; `agent.wait` returns at their next notification (give it `timeout_ms`), and `mentions` can't go to them.
Kind `unknown` (a shell, another CLI) has none: `agent.wait` fails once 15 s pass without a first report, so poll `agent.read --since prompt`; `program` and `title` still hint at its state.
A `conflict` saying the agent was working when easl last closed and hasn't reported since (`lifecycle.restored`): omp and opencode report again within seconds of the app coming back, Claude Code, Codex and Gemini CLI at their next tool call; if it stays, read its screen (`agent.read --lines 40`) before deciding; never `force` it if the screen shows a question or approval.
Don't prompt an agent that is `blocked`; it is waiting for its user. `agent.prompt` to one fails with `conflict` quoting what it waits on, and so does one whose foreground program isn't its agent (nvim, another tmux pane): tell the user.
Never answer another agent's approval with `force: true`: it types into the dialog and presses Return, which in an approval menu picks the highlighted option (usually allow). Force only when you know the dialog is gone.

## Terminals on another machine (offload)

A terminal created with `props.host` (an ssh target such as `deckbox`) runs its session on that machine, under its easld, and attaches over ssh: `easl object.create --type terminal --json '{"props":{"host":"deckbox","command":["omp"]}}'`. `command` is argv (`["sleep","600"]`; a shell line is `["sh","-c","…"]`) and `cwd` is a directory on that machine. Your `easl` CLI and lifecycle work there as here. If you run there: Docker containers escape the machine's capped slice, so start any container with `--cpuset-cpus` inside the slice's CPUs and `--memory`; files you name (`path:line`, follow) are the host's, which the Mac's code tiles can't open yet.

## Compositions

Reusable helpers come built into the SDKs, plus your own in `~/.easl/compositions` (yours shadow built-in ones of the same name). In Python:

```python
canvas.compositions.available()                              # name -> summary
canvas.compositions.grid.arrange([id1, id2, id3])            # grid beside your terminal, clear of other tiles
canvas.compositions.locations.open(["src/a.ts:12-40", "src/b.ts#L7"])
```

A composition is a plain module; functions whose first parameter is named `canvas` receive the client.
When you catch yourself repeating a multi-call board pattern, write it as a composition in `~/.easl/compositions/<name>.py`
(and `.ts` for the TS client, `client.compositions.<name>`), then `canvas.compositions.reload()`. Improve existing ones rather than forking them.

## Boards

One board per git repository, whichever worktree or branch opens it (rooted at the main checkout); one per directory outside git. Boards open as tabs of one window.
`easl board.open --root <absolute dir>` opens a directory's board as a tab (creating it if new) behind the user's current tab; pass `--select true` only when the user asked to see it.
A worktree opens its repository's board: the result's `worktree` names it (path, branch, and `region`, the group that holds that branch's objects when there is one), and New Terminal starts there.
Then address it with `board: <id>` (from the result) on every call, and start agents there by creating terminal tiles on that board; a terminal records the `worktree` and `branch` it works in (where it started, and after a `cd` into another worktree, where its program runs) in its props.
Give each branch's work its own region: a group titled with the branch (`props.key: "branch:<name>"`), and `easl board.get --branch <name>` returns just that part of the board, with `regions` listing that branch's region ids (`[]` before you make one).
`easl board.list` shows every stored board, and a repository board's `worktrees` (path, branch, `live`: still checked out there).
`easl board.export` writes a readable snapshot to `<root>/.easl/board.json` for committing when the user asks to save the board with the repo.

## When the user asks how to use easl

Help › easl Basics ⌥⌘/ is the user's legend of everything on screen (dots, rings, markers, follow tile, tray, keys); `references/ui.md` has the same text: answer "what is this?" and "which key?" from it, not from easl's source.
⌘P goes to any tile or opens a repo file (`core.py:120` opens at a line, `@name` finds a symbol); ⌥⌘-arrows (all four) move between tiles; Return gives the selected tile the keyboard, Esc gives it back (in a terminal or a web page Esc stays with the program or page: ⌘Esc leaves any tile).
⌘J goes to the next thing that needs the user, on this board and then on their other open boards; ⌘[ / ⌘] go back and forward; ⌘9 fits everything; ⌘Z undoes the user's last change or an agent's, and a notice names what it undid.
Hyper-click (⌃⌥⇧⌘-click) or Edit › Mention ⇧⌘M stages a mention for the terminal the tray shows ("→ name ▾" picks another); Hyper-V pastes staged mentions into the terminal the user is typing in (else that one), for agents without an integration.
Mouse users: the wheel pans, ⌘-scroll zooms around the pointer, ⇧-scroll pans sideways; don't tell a user without a trackpad that zooming needs a pinch.
On a PC keyboard ⌘ is the Windows key and does what Ctrl does elsewhere, ⌥ is Alt (`macos-option-as-alt = true` in their Ghostty config for Meta), and Hyper is Ctrl+Alt+Shift+Win: point them at easl Basics' "Coming from Linux or Windows" section.
Every action is also in the menu bar (Help › search).
