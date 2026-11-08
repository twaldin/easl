# easl API from an agent

The method catalog is `schema/easl-api.json`; `easl methods` prints every method with its description, and in Python `help(canvas.<ns>.<method>)` shows the signature.
This page covers the conventions the catalog doesn't spell out.

## Calling conventions

| | Python SDK | CLI |
| --- | --- | --- |
| Call | `canvas.agent.read(target="obj_…", lines=50)` | `easl agent.read --target obj_… --lines 50` |
| camelCase params | snake_case keywords: `timeout_ms`, `session_id`; reserved words take a trailing underscore: `as_="graph"` | as in the schema: `--timeoutMs` |
| Nested params | dicts: `props={"range": {"start": 1, "end": 9}}` | `--props.range.start 1`, `--json '{"props":{…}}'`, or `--json @params.json` (`@-`: stdin) |
| Result | the `result` object as a dict | pretty JSON on stdout; `object.create`/`update` print prop values over 1 KB elided (`--full` prints them) |
| Error | raises `CanvasError` (`.code`); without a socket it raises `unavailable` saying so, never guessing one | `code: message` on stderr, exit 1 |
| Props per type | `help(canvas.object.create)`; the schema's `CodeProps`, `NoteProps`, … | `easl methods CodeProps` |

TypeScript/Bun: `new CanvasClient({ socketPath?, tile?, board? })` from `clients/ts/src/index.ts`, methods under `client.api.<ns>.<method>({…})`.
`caller` and `board` default to the client's tile and board (explicit, else `EASL_TILE_ID`/`EASL_BOARD_ID`).

Results are objects, never bare values:

| Call | Returns |
| --- | --- |
| `object.create`, `object.update`, `object.get` | `{object}` (the new id is `result["object"]["id"]`); `object.get --as graph` adds `graph`; create/update add `warnings` for unknown prop keys |
| `object.upsert` | `{object, created}`; `object.find` → what `object.get` returns (with `key`) or `{objects}` (with `keyPrefix`) |
| `object.batch` | `{results, revision}`: each op's result in order (`results[0]["object"]["id"]`) |
| `layout.place`/`stack`/`translate` | `{frames: {id: frame}}`; `layout.grid` adds `columns` and `rows` |
| `layout.check` | `{overlaps, arrowCrossings, labelOverlaps, arrowOverlaps, arrowIntersections, overflow, scrolls, truncated}`, plus `hints` when there are any |
| `view.render`, `view.snapshot` | `{path, width, height, scale, objects}` plus `canvasRect` (render) or `viewport` (snapshot) |
| `agent.prompt` | `{agent, waitable, submittedAt}`; `agent.wait` → `{agent}`; `agent.read` → `{agent, text, lines}` (`truncated` with `since`) |

Error codes: `not_found` (no such object/agent/board; a code tile's file or `pinnedCommit` that isn't there; no object holds the key `object.find` asked for), `conflict` (stale `rev`: re-read, re-apply, retry; a `props.key` another object holds, named in the message),
`invalid_params`, `unavailable` (e.g. a terminal without a running session, or the app isn't running), `unsupported`, `timeout` (`agent.wait`).
A param the method doesn't take, or a required one missing, is `invalid_params` naming every param it takes (`unknown param delta; missing dx, dy; layout.translate takes ids (required), dx (required), dy (required), caller`); the same for each `object.batch` op.
If the app restarts, the next call reconnects on its own (waiting up to 15 s). `unavailable` with "may or may not have applied" means your request was sent but its reply was lost: re-read (`board.get`) before retrying.

## Reading the board

- `board.get` returns every object with heavy props trimmed (long markdown, HTML source); `object.get` returns one object whole.
- Poll cheaply: keep `revision` from one `board.get` and pass it as `since` next time; `changed` lists ids created or changed after it.
- A repository's board holds every branch's work: `board.get --branch <name>` returns one branch's part (its regions keyed `branch:<name>` with what they hold, tiles whose `ref` is the branch, terminals started on it, arrows between them) and `regions`, the ids of those regions (`[]` when the branch has none).
- `object.get --as graph` gives `encloses`, `enclosedBy`, `overlaps`, `arrowsOut`, `arrowsIn`. To look at an object use `view.render` (`easl render <id> --out file.png`).
- `object.get` on a note adds `fences`: per anchored fence its `info`, `markdownLines`, `path`, `symbol`, `propose`, and `state` (`live`, `relocated`, `stale`, `applied`, `missing`) with the resolved `range`, the `written` range when relocated, and the stale `reason`, resolved against disk now; on a code tile showing a range, `rangeStatus` (the same fields). Check these instead of rendering to see whether excerpts are still true.
  Symbol anchors survive edits (`symbol=Class.method` finds methods deep in long classes and defs with multi-line signatures); line anchors are re-found by content and go stale when lost.
- `object.get` on a browser tile adds `page`: what the page reported since it loaded (`errors`, `warnings`, the latest 100 `entries`: console messages, uncaught errors and rejections, failed requests, each with `level`, `text`, `source` `url:line:column`, `time`), `vitals` (null when not measured, never zeros; `unsupported` names what WebKit can't measure), and a `cursor`.
  Pass `--since <cursor>` next time for only what came after (after a reload: all of the new page, `reloaded: true`). `loaded: false`: the tile has no page now; `easl render <id>` loads it.
  `visibility`: `visible` (on screen), `hidden` (nobody sees it: no rAF, throttled timers), `driven` (kept running for an agent, rAF irregular and slower) or `released`. A page easl released keeps its last log in `previous` (with `releasedAt`), and `cursor` carries on across the release.
  A Hyper-click on a page's `<canvas>`, `<video>` or `<img>` mentions the element with `pixel (x, y) of W×H`: the click in its own pixels (drawing buffer, video frame, natural image size).
- `tray.list` shows what the user has staged but not yet sent. Don't drain the tray yourself; your harness attaches it to the user's next prompt.
  The tray's mentions are for the terminal it shows (`view.get` `promptTarget`): `tray.drain` from any other terminal returns none (`held` says how many wait) and leaves them staged.
  A drawn shape's mention quotes its whole text, says `over <type> <id>` (or `partly over`, for a shape mostly on a tile) with the region in that tile's content points (below its title bar, ÷ its zoom; a browser page starts 32 pt below the title bar), and for a shape on a browser or HTML tile lists the page elements under it (`<selector> "<text>"`, as the page is laid out when the prompt is sent). A Hyper-click on a drawing mentions the whole selection or drawing group it belongs to.
  A code mention names a `(symbol …)` only when its whole range sits inside one declaration. An `(edited)` mention changed after it was staged; a move, a zoom, or another file staged in the same tile doesn't count.
  A Hyper-click in a note's body mentions the block under it (`kind: note`: the paragraph, list item with its sub-items, quote, table row, fence, or a heading with its section; `headings` is its section path). The prompt gets that path and the block's text from the note as it reads when sent, with `changed since it was mentioned` or `no longer in the note` when an edit changed or removed it. Its title bar mentions the whole note (up to 80 lines).
  A Hyper-click on a group's title or empty interior (the innermost group there; ⇧⌘M on a selected group) mentions the whole group (`kind: group`, `objects` its members, `name` its title): each member with a short excerpt (a code tile's range, a note's first lines, a page's URL), then `arrows among them:` with their labels and relations; at most 120 lines, saying what it left out.
- `view.get` says what the user sees, including `appearance` (`dark` or `light`): tiles and renders draw in it, so style charts and pages to match
  (dark: a transparent or dark background with light text, e.g. matplotlib `plt.style.use("dark_background")` and `savefig(…, transparent=True)`).
- An arrow's `frame` is the bounds of its routed line as drawn.

## Objects

- `frame` is `{x, y, w, h}` in board points (100% zoom): the whole box the object draws. A tile's 26 pt title bar is inside its frame, at the top.
  Omit it on create for automatic placement beside your terminal (in the user's view when your terminal is on screen and there's room within 600 pt of it; otherwise beside it even out of view: raise a marker with `view.attention` when the user should look); within 10 minutes of your last tile, the next one stacks below it (else right of it) when that is as much in view. Without a calling terminal (a script outside any tile), or on another board (`board`), it goes to the free spot nearest the view's center, clear of the window's toolbar and tray. Objects you create or change on another board are still credited to your terminal (`createdBy`, `board.history`).
- `props` on `object.update` merge shallowly: `{"range": …}` replaces `range` and keeps other props. Set a prop to `null` to clear it.
  `frame` on `object.update` may give any of `x, y, w, h` (`{"frame": {"h": 420}}`); the rest stay. On create it needs all four, or `size: "fit"` (below).
- A prop the type doesn't define (a typo like `colour` or `markdwon`) is kept, but `object.create`/`object.update` (and each batch op's result) add `warnings`, one per unknown key naming the type's real props. No `warnings` key means every prop is known.
- `props.key` on any object is a name scripts find it by (`"REL-12389"`), unique on its board: a create, update, or upsert that gives a key another object holds is `conflict` naming the holder, and `null` gives it up.
  `object.find(key=…)` returns the holder as `object.get` does; `object.find(key_prefix=…)` lists holders of keys starting with it, in key order (summarized as `board.get` lists them).
  `object.upsert(key, type, props, frame?, size?)` updates the holder (props merged; its type must be `type`, else `conflict`) or creates one with the key; `created` says which. Undo, redo, and a failed batch put keys back with their objects.
- `object.reload(id)` reloads any browser tile's page as its reload button does (the user's tiles too; a failed load is retried) and waits until it has loaded (`timeoutMs`, default 15 s): `{id, url, loaded, failed?}`. Use it after an edit instead of changing `props.url` to a dummy query, which adds to the tile's Back history; then read `easl get <tile> --since <cursor>`.
- Every change bumps `rev`. Pass `rev` on updates to objects the user may be editing; the `rev` a create or update returns is current.
  A note's line-range fences (`file=src/a.ts#L10-40`) come back with an `anchor="<first line>"` added, as the tile would write it.
  A code tile's `range` stays on its code: when lines move above or inside it the tile re-finds it and writes the new `range` (and `anchor`, its first line) back without a new `rev`; an update that changes `range` without `anchor` drops the old one.
- `props.zoom` on any tile but an image or video (0.25–8, default 1) is how big its content draws inside its frame, in place: the frame never changes with it and the title bar stays at 1×;
  the body lays out at body ÷ zoom (a 1200×826 tile at zoom 2 shows what a 600×400 body does, twice as big: a terminal fewer, bigger columns, a page a narrower viewport). An update that sets it never moves or resizes the tile.
  Measure and fit lay out at `width` ÷ zoom (the frame is the 26 pt title bar plus the body × zoom); `layout.check`, `view.render` sizes, and line anchors account for it; everything you get back is in board points.
  Image and video tiles don't zoom (the picture is already fitted to the frame): make the tile bigger. A text shape's font is `props.textSize` (0.25–8, default 1, a multiplier of 20 pt), and its box grows with it.
  `props.scale` is gone: create, update, upsert, batch, and measure reject it with `invalid_params`.
- Terminal tiles: `{"cwd": "/path", "command": ["omp"]}` starts an agent in a new tile (its session survives app restarts). Only start agents the user asked for.
  Deleting a terminal tile (`object.delete`, or in a batch that succeeds) ends its session and whatever runs in it, as closing it does for the user.
- Changes tiles (`type: changes`, `ChangesProps`): `{"base": "HEAD"}` (the default: uncommitted work, staged or not; also `merge-base`, everything the branch changed against the default branch, or a commit or ref; the user can switch it in the tile's header), optional `root` (another worktree of the board's repository, e.g. `"../wt-agent"`; without one you review your own checkout, your worktree when you work in one), `paths` (files or dirs in it) and `title`.
  `head` (any commit or ref, e.g. `{"base": "origin/main", "head": "pull/32642/head"}`) compares two commits instead: read-only from git objects, no checkout (the head against its merge-base with `base`, default `merge-base`: a PR's view; renames and deletions included; no Stage, Unstage, or Discard; a line click opens a code tile pinned to that side's commit). A ref the repository lacks lists nothing and its notice names the exact `git fetch` that brings it; easl never fetches. `ref` (a branch, instead of `root`) is the worktree that has it checked out while one does, else the branch's commits as with `head`; the tile writes the commit it read to `props.refSha` and keeps reading it once the branch is gone (`merged in <sha>` or `branch gone` in its header); creating one with a ref the repository lacks is `not_found`, naming the fetch.
  The user reviews there: hunks as a unified diff, Stage, Unstage, and Discard per file, hunk, or selected lines, each one ⌘Z (Discard only puts back uncommitted work: committed hunks have none); a Viewed box folds a file until its diff changes. To show them what you changed, create one (`size: "fit"` sizes it to every hunk, at most 4000 pt tall, and it grows as you add hunks) rather than an HTML diff. Creating it again with the same `root`/`base`/`head`/`ref`/`paths` returns your existing tile (`reused: true`).
  `object.get` adds `changes`: `files` (`path`, board-relative or absolute outside the board root; `status` added/modified/deleted/renamed; `added`/`removed`; `viewed`; `hunks` with a stable `id`, `header`, `old`/`new` `{start, count}`, `status` unstaged/partial/staged/committed, and `lines`: the unified text, at most 200 with `truncated`) as git has them now, so hunks the user discarded are gone and staged ones say so (`partial`: staged, then changed again); two commits compared add `head` (full SHA), `headLabel`, `baseTip` (the commit the base names; `base` is the merge-base) and `readOnly: true`, and `ref` tiles `refSha` (plus `refState` once the branch is gone);
  `props.reviewed` lists what they staged, unstaged, or discarded (`action` stage/unstage/revert, `path`, `scope` file/hunk/lines, `hunk` id, `header`, `patch`: the patch applied, reversed for a discard). The tile writes `reviewed` and `viewed`; changing them yourself does nothing to git.
  A mention of a diff line says what it is: `… diff vs HEAD 1a2b3c4, new side (working tree) · added line · unstaged hunk`.
- Diagram tiles (`type: diagram`, `DiagramProps`): `kind: "calls"` (default) is a function's call graph (`symbol` or `path`, `direction` incoming/outgoing/both, `depth` 1–4; see Live diagrams and authored graphs below). `kind: "graph"` draws a graph you supply instead: `knowledge.nodes` `[{"id", "label", "detail"?, "level"?, "sources"?, "status"?}]` and `knowledge.edges` `[{"from", "to", "label"?}]`, each edge from premise to conclusion. Levels you omit are computed as reasoning depth (longest path from a premise, 0) and stored back; at most 500 nodes, and duplicate ids, empty labels, edge endpoints that aren't nodes, and a cycle with a level missing are `invalid_params`. `detail` is the markdown a click expands in the tile; `sources` (`session`/`message`/`board`/`tile`) remain provenance records; a badge focuses only the terminal a session or tile names on this board; `status` (`taught`/`practiced`/`retained`/`weak`) draws a coloured badge and reports practice through `object.update` (props merge shallowly: send the graph back with the node's new status). A graph diagram is never computed from code: `object.reload` is a no-op success and `props.knowledge` stays as stored. Limits are 2,000 unique directed edges, 256 UTF-8 bytes per ID or edge label or source field, 512 per node label, 8,192 per detail, and eight sources per node. `props.graph` is ignored for kind graph.
- Code tiles (`type: code`, `CodeProps`): `path` (board-relative, or relative to your own checkout when you work in another worktree of the board's repository, stored absolute there; or outside the board root: another repo or worktree, whose own git the tile reads, `pinnedCommit` included), `range`, `symbol`, `caption`, `diffBase`, `pinnedCommit`, `ref`.
  The gutter shows changes against `diffBase` like gitsigns (green bar added, blue bar modified, red wedge where lines were deleted; the user clicks a sign to see the old lines). A repo with no commits or no default branch, or a diff too large to compute, shows plain source with a header warning; a deleted file shows its base version.
  With a `range`, `size: "fit"` sizes the range even when `symbol` is set; `symbol` alone fits the declaration but the tile still shows the file from the top, so pass the range.
  `pinnedCommit` shows the file as of that commit, read-only: no gutter signs, working-tree edits don't change it, the header says "pinned at <sha>", and mentions quote the lines at that commit. For a PR head you haven't checked out: `git fetch origin pull/<n>/head`, then pin to `git rev-parse FETCH_HEAD`.
  `ref: "<branch>"` anchors the tile to a branch: `path` is relative to the repo (the board root's place in it), and the header says where it reads. "live in <worktree>": a worktree has the branch checked out, so it shows that working tree with its gutter and edits. "<branch> @ <sha>": no worktree has it, so git objects at the branch, read-only. "merged in <sha>": the branch is gone and the default branch contains it, so the file at the commit that merged it. "branch gone, showing <sha>": gone and not contained (squash merge, or deleted unmerged), so its last commit while the objects exist. easl records the SHA it last resolved as `refSha` (you may pass it); a create or update whose `ref` resolves to nothing is `not_found`. `pinnedCommit` wins over `ref`.
- Image tiles (`type: image`, `ImageProps`): `{"path": "out/fig.png", "caption": "…"}` (board-relative or absolute; png, jpg, gif, webp, heic, tiff, bmp, svg, a pdf's first page).
  This is where a chart goes: save the figure to a file and create the tile, no base64 in HTML. Without a frame (or `frame` of just x, y, w) it fits its picture: one point per pixel, at most `w` (default 960) wide.
  It reloads when the file changes on disk, so re-save the chart to the same path to update it (no `object.update` needed). A Hyper-click on it mentions `image <path> · pixel (x, y) of W×H`.
  Its title defaults to its file name: set `title` only when the name doesn't say what it shows. Keep images that must last outside `$TMPDIR`.
- Video tiles (`type: video`, `VideoProps`): `{"path":"clips/demo.mp4","poster":"clips/poster.png","muted":true,"autoplay":false,"loop":false,"startTime":2}`.
  `path` and optional `poster` resolve on the board host. Omit the poster when unnecessary. Local and remote clips stream and seek without copying the clip onto the viewer's disk.
- Images elsewhere: a note shows `![alt](out/fig.png)` (relative to its root, below, or an absolute path inside it or the temp directory), scaled to its width;
  an HTML tile loads `<img src="out/fig.png">` the same way (relative to its root, or `/tmp/…`); `file://` URLs and paths anywhere else never load in a page.
- Link roots: a note's paths (`path:line` and markdown links, excerpt fences, images) and an HTML tile's (`<canvas-link>`, `<canvas-code>`, `<img>`) resolve against its `root` prop (absolute or board-relative: the board's checkout or another worktree of its repository; anything else is `invalid_params`), else the board root.
  A note or page you create from another worktree than the board's gets your worktree as `root` by default, so write `tests/x.ts:16`, not `../wt-x/tests/x.ts:16`; the create result shows it.
  `ref: "<branch>"` instead of `root` reads those paths at the branch, like a code tile's `ref`: the worktree that has it checked out, else the branch's commit, then its merge commit or last SHA once it is gone. Excerpt fences without their own `@<sha>` and `<canvas-code>` read there, and links open code tiles with the same `ref`; the markdown or HTML itself stays inline.

## Layout

Sizes, positions, and checks, so you never measure tiles by hand or move 40 objects one call at a time:

- `canvas.object.measure(type="code", props={…}, width=1546)` → `{w, h}` (`width` optional): the whole frame (title bar included) that shows the content without scrolling.
  Code: exactly `range` (the tile shows no extra context and no neighbouring lines; with no range, the `symbol`'s declaration), plus 20 pt when `caption` is set, and at least as wide as the whole caption;
  `width` is the maximum width (default 1546 pt, 200 columns):
  a range whose longest line fits stays exactly that narrow, longer lines soft-wrap and the height counts their extra rows, and a caption wider than that truncates.
  Notes: the rendered markdown, live fences resolved, at `width` (default 280). Text shapes: at `width`, or one unwrapped line per paragraph.
  HTML: the page laid out `width` wide (default 640) once it has rendered (Mermaid, `<canvas-code>` excerpts), as tall as its document, at most 4000 pt (a longer page scrolls in the tile).
  Changes: the file list and every file and hunk row (deleted and viewed files folded), as wide as the longest line up to `width` (default 960, at least 480), longer lines wrapped, at most 4000 pt.
  Images: the picture at one point per pixel, at most `width` (default 960) wide, plus the caption strip. Browser tiles are `unsupported`.
- `size: "fit"` on `object.create`/`object.update` measures instead of taking `w`/`h`: `frame` then needs only `x, y` (plus `w` to wrap a note, text, or an HTML page, or to cap a code tile's or image's width);
  an update re-measures at the object's current position and width (code and images: at `frame.w` or their default, 1546 pt for code and 960 pt for images, never their current width, so a re-fit can widen them).
  An update without `frame.x`/`y` doesn't grow over what it didn't already cover: it grows up or left instead (keeping its bottom or right edge), else moves to the nearest free spot no farther than its own longer side, else grows in place.
  A fitted result (create, update, or batch op) has `overlaps`, the ids it now covers, when there are any: move it or them.
  So does an `object.update` whose `frame` (given outright, e.g. a browser tile widened to a desktop viewport) makes it cover an object it didn't before.
  While you own layout, refit changed HTML or Markdown in the same call: `canvas.object.update(id=tile, props={"html": page}, size="fit")`.
  After layout hand-back, omit `size` and `frame`. Keep content within the user's dimensions or hand the overflow issue back.
  `object.measure` takes `width`, not `frame`.
- `frame: {w, h}` alone on `object.create` means that size, placed where a create without a frame goes (beside your terminal, clear of other tiles): no `layout.place` call needed afterwards.
- `canvas.layout.place(id=a, near=b, side="right", gap=40, align="start")` (`side`: right, left, above, below; `align`: start, center, end)
  and `canvas.layout.stack(ids=[a, b, c], direction="row", gap=40, wrap_at=2400, align="start", origin={"x": 0, "y": 0})` (all but `ids` optional) move objects in one undo step and return the new frames.
  Groups move with their members, so `canvas.layout.stack(ids=[lane1, lane2], direction="column")` lays out lanes; bound arrows follow.
- `canvas.layout.translate(ids=[…], dx=12000, dy=0)` moves objects by an offset in one undo step (groups with their members, free arrow ends along, bound arrows follow).
  Build a layout offscreen (e.g. at x + 12000) in one batch, check it, then translate its groups into place.
- `canvas.layout.grid(cells=[{"id": a, "row": 0, "col": 0}, …], col_gap=40, row_gap=40, col_align="start", row_align="start", origin={"x": 0, "y": 0})` (all but `cells` optional) puts cells in shared columns and rows:
  each column is as wide as its widest cell, each row as tall as its tallest, so a column lines up across lanes (cells in different groups; the groups re-fit).
  Unused row/col numbers take no space; `origin` defaults to the cells' current top-left.
  Between rows of different groups leave `row_gap` for both groups' padding plus the 32 pt title band (e.g. 24 + 24 + 32 + your gap).
  Returns `frames`, `columns` `[{col, x, w}]`, and `rows` `[{row, y, h}]`.
- `object.batch(ops)`: `[{method, params}]` with `object.create/update/upsert/delete` and `layout.place/stack/translate/grid`, applied as one revision and one ⌘Z, or not at all (the error names the failing op).
  `"$0"` anywhere in a later op's params is the id op 0 created (or, an upsert, created or updated). An upsert of a key an earlier op of the batch creates updates that object; if another request moves a key while the batch is being measured, the batch fails with `conflict`: send it again. Op params are the schema's own names (`colGap`, not `col_gap`):
  ```python
  canvas.object.batch(ops=[
      {"method": "object.create", "params": {"expiresIn": "1d", "type": "code", "props": {"path": "src/a.ts", "range": {"start": 10, "end": 30}}, "size": "fit", "frame": {"x": 0, "y": 0}}},
      {"method": "object.create", "params": {"expiresIn": "1d", "type": "note", "props": {"markdown": "Why this matters"}, "size": "fit", "frame": {"x": 0, "y": 0, "w": 320}}},
      {"method": "layout.place", "params": {"id": "$1", "near": "$0", "side": "below", "gap": 14}},
      {"method": "object.create", "params": {"expiresIn": "1d", "type": "group", "props": {"members": ["$0", "$1"], "title": "Request path", "color": "blue"}}},
  ])
  ```
- `canvas.layout.check(ids=[…])`, `canvas.layout.check(rect={"x": 0, "y": 0, "w": 4000, "h": 3000})`, or the whole board with neither → `overlaps` (pairs),
  `arrowCrossings` (`{arrow, crosses}`: routes through tiles, text, or filled shapes other than the arrow's own ends),
  `labelOverlaps` (`{arrow, label, frame, overlaps, lines}`: the arrow's label text, placed as drawn at `frame` (an arrow's own frame leaves its label out), lies on these tiles, text, or filled shapes (its own ends included), these groups' titles, or these arrows' labels (`overlaps`), or on these arrows' lines (`lines`); widen the gap, shorten the label, or move the tile),
  `arrowOverlaps` (`{arrows, length, at}`: two arrows drawn on top of each other for `length` points: give them room, e.g. a wider gap between columns),
  `arrowIntersections` (`{arrows, count, at}`: two arrows whose lines cross; often a tile order that follows the arrows removes them),
  `overflow` (`{id, x, y}`: points of note/text/HTML content beyond the frame; for HTML, its page laid out at the frame's width),
  `scrolls` (`{id, y}`: code tiles whose range's rows, wrapped at the frame's width, are `y` points taller than the frame, so the tile scrolls to the range; fine for a viewer meant to scroll, refit with `size: "fit"` when the whole range should show),
  `truncated` (`{id, what, x}`, `x` points short: `caption`, a code caption the frame cuts off; `table`, a note table with too many columns for the note's width even with its cells wrapped: widen the note or split the table),
  and, only when there is one, `hints` (advice, not faults: more than 6 labelled arrows all one color, so a label can't show which line it names: color arrows by lane or flow).
  A group and its members, and an unfilled rect around what it contains, are not overlaps. Follow tiles are fixed-size viewers and are never reported.
  With `ids` or `rect`, arrows through the checked objects and labels on them count too, whichever arrow it is: check a new tile by its id to find labels it covers.
  It judges drawn geometry, not group size or ownership, so an empty report does not flag a stretched group. Run it after a layout pass instead of screenshots.
- Groups are regions: `{"members": [...], "title": "…", "color": "blue", "padding": 24}`. The frame is always the members' bounds plus padding and a 32 pt title band, updated as members move;
  it is what `encloses` uses. One group per lane replaces a rect + title text + group.
- Arrows: `route: "straight"` (default), `"orthogonal"` (horizontal/vertical with one jog), or `"avoid"` (horizontal/vertical around every tile in the way, routed with the board's other `avoid` arrows: own ports, parallel tracks, the group's `flow`).
  Arrows between the same two objects, in either direction, are drawn apart automatically, and labels sit beside the route, clear of boxes where there is room (`labelOverlaps` says where there wasn't).
  An end bound to `{object, lines}` on a code tile attaches to its left or right edge at the row of `lines.start`, where the tile shows it:
  scrolled to its range with up to 3 rows of context above (none in a fit tile); a line scrolled out of view pins to the top of the code or the bottom of the tile.
- Colors (`color` on shapes, arrows, groups): `black`, `grey`, `blue`, `green`, `orange`, `red`, `violet`, or `#rrggbb`.
  Shapes: `fill: none|semi|solid` (only filled shapes block clicks and arrow routes).

## Attention markers

`view.attention` raises a marker keyed by the object (raising again replaces the message). It clears when the user selects or looks at the object in the active window or clicks the marker, when you `clear` it, or when the user clears every marker (View › Clear Attention Markers, or right-click the board); markers aren't undo history.
Your first marker after the user's next prompt clears your markers from earlier turns and lists them in `cleared`.
Do not clear old markers yourself or re-raise cleared ones. To withdraw a current marker you raised, use `easl view.attention --id obj_… --clear`.
A terminal's OSC 9/777 notification or bell at its shell prompt raises a marker there unless the user is looking at it (from a program in the foreground it is that program's lifecycle, see Agents); terminals whose agent reports a lifecycle (omp, Claude Code, Codex, Gemini CLI, opencode) show done and blocked themselves, so their notifications raise nothing.

## Events

Long-running helpers can stream changes instead of polling: `events.subscribe` (TS: `subscribe(onEvent, {events: ["object.updated"]})`)
turns a dedicated connection into a stream of `object.created`, `object.updated`, `object.deleted`, `tray.changed`, `agent.lifecycle`, `follow.updated`,
and `attention.changed` (`{id, active, message?, raisedBy?}`: a marker raised, or gone because the user saw it, someone cleared it, or its object was deleted).

## Agents

`agent.list` lists every terminal tile in the app; each entry names its `board` and that board's `root` directory, so you can tell which repo or worktree an agent works in. `lifecycle.state` is `working`, `blocked` (waiting for its user: an approval or a question),
`idle`, `done` (idle with results the user hasn't looked at yet), or `unknown` (no integration reporting: a shell, a CLI without easl hooks; its `kind` is `unknown` too).
An agent without an integration that says when it waits (aider through easl's `aider` wrapper, any CLI's terminal notification or bell) has its program as `kind` and `lifecycle.via: "notifications"`: `done` when it last said it waits, `unknown` from a prompt until it says so again, never `working` or `blocked` (read its screen for a y/n question).
`kind` is the integrated agent (`omp`, `claude`, `codex`, `gemini` before 0.60, `opencode`); `program` is what runs in the terminal's foreground (`gemini`, `cargo test`; absent at a shell prompt) and `title` the title that program set (e.g. Gemini CLI's "✋ Action Required (glow)"), for any terminal.
`lifecycle.error`, `errorCount` (at least 1), and `errorSince` (UTC RFC 3339) describe the current run of failed dispatched model requests. They appear together in `agent.list` and terminal `props.lifecycle`, including `working` and `blocked`. `error` is at most 500 Unicode characters, cut at 499 plus `…`, never the session transcript. Each reported failure increments the count and keeps the first `errorSince`. Only a successful model response, including a tool request, clears all three. Starts, heartbeats, aborts, seeing the tile, `agent.restart`, and daemon restarts retain them. A failing idle never becomes `done`.
Optional `agent.report.turnEndedAt` is the dispatched response's ending time in UTC RFC 3339 with a `Z` suffix, allowed only with `turnOutcome`. omp captures it at assistant `message_end`. The first failed response sets `errorSince` to that timestamp, even if its report is spooled and arrives later. Subsequent failures retain it. Reports without a timestamp, including legacy idle errors, use receipt time. Pre-dispatch failures are excluded from both `errorCount` and `errorSince`.
`agent.report` accepts optional `turnOutcome: "success" | "error" | "aborted"` in any state. Error requires a nonblank `error`; success and aborted forbid it. Against an outcome-aware host, omp reports once per assistant response and sends protocol 4 on every lifecycle report. An explicit outcome or protocol ≥ 4 selects outcome-aware behavior for the current report only. Protocol-4 reports without outcomes leave failure health unchanged, including after restarts. Reports without outcomes and with protocol below 4 or omitted use idle-only errors, count 1, `errorSince` at receipt, and clearing on the next working report, even when an older or different integration replaces omp in the same tile. Pre-dispatch throws without an assistant response event are excluded. Provider-layer errors emitted as assistant responses, including `No API key for provider`, are covered. Aborts retain `agent.read final` cut-off information without counting as failures. When a live report is rejected for unknown `turnOutcome` or `turnEndedAt` fields, omp resends it without those fields and uses legacy protocol-3 idle-error reports until easl reconnects. Reports spooled before that rejection are not converted, so replay on an old host may still show a failed turn as done. Inbox requests still negotiate protocol 3 independently.
`agent.read` returns up to 2000 lines of the terminal's text, trailing blank lines removed; `since="prompt"` returns only what followed your last `agent.prompt` to it (`truncated` when there was more). Rows the terminal soft-wrapped read as one line (on the live screen by the terminal's own wrap flags; above it separator rows padded to the width, pytest's `====`, and rows starting with the same word, pytest's `FAILED …`, stay their own). `block="last"` (or `block=-1`) returns only the output of the last command the shell finished, `block=-2` the one before, and so on back to the first easl saw finish, with `command` (`{command, exit, durationMs}`), from Ghostty's prompt marks (`unavailable` without them or once its rows are gone: cleared, trimmed, reflowed). A command-block mention names the `--block -N` that reads it whole. `agent.list` and `object.get` give a terminal's `lastCommand` (`{command, exit, durationMs, finishedAt}`) once its shell finished one, so `exit` says whether the user's last `go test` passed without reading the screen. A terminal mention (`kind: terminal`) has `part`: `selection`, `rows` (the screen rows around a Hyper-click, the clicked one marked `> `) or `command` (one command's output, with `command`).
`final=True` returns just the agent's last answer (the final message of its last finished turn, reported by omp, Codex, Claude Code and Gemini CLI; not opencode) instead of its screen; it fails with `unavailable` while the agent is still in its turn and when no answer is known (interrupted turn, no integration): then read `since="prompt"`. The answer is kept across app restarts, and an agent that finished while the app was closed comes back `done` with it.
`agent.prompt` returns `waitable`: then `agent.wait` right after it waits for that prompt's turn (it ignores the state from before the prompt), so wait for `done` directly; a prompt that starts no turn within 60 s (a `/` command or `!` escape) fails the wait with `unavailable`: read what followed with `since: "prompt"`. A `working` lifecycle with `restored: true` is from before the app last closed and unconfirmed since: `agent.prompt` refuses it (read the screen first, or `force`). A prompt to an agent that is `working` joins that turn (omp and Codex answer it in the same turn): the wait ends, and `final` is ready, when that turn ends.
Hand over board objects with `mentions` instead of describing them: the receiver gets them as hidden `<canvas-mentions from="<your tile>">` context with that prompt, resolved like the user's Hyper-click mentions (note text, code excerpts), and they never touch the user's tray.
Each is `{"object": id}`, plus `"lines": {"start", "end"}` for a code tile (without lines, the range it shows) or `"point": {"x", "y"}` for an image tile's pixel; the objects must be on the receiver's board, and the receiver must run an integrated agent (else `unavailable`):
```python
canvas.agent.prompt(target="fees", text="review the findings note against the code, read-only",
                    mentions=[{"object": note_id}, {"object": code_id, "lines": {"start": 41, "end": 48}}])
canvas.agent.wait(target="fees", timeout_ms=900_000)      # done, idle, or blocked
reply = canvas.agent.read(target="fees", final=True)["text"]
```
CLI: `easl agent.prompt --target fees --text "…" --mentions '[{"object":"obj_…"}]'`, then `easl agent.read --target fees --final`.
On a terminal whose lifecycle is `unknown` (`waitable` false) `agent.wait` gives it 15 s to report (an agent you just launched there) and then fails with `unavailable`; for a shell or a CLI without integration, poll `agent.read(since="prompt")` instead.
An agent reporting by notification is `waitable`: `agent.wait` returns at its next notification (none comes after a prompt that needs no model reply, like aider's `/add`: pass `timeout_ms`). `mentions` can't go to it (nothing drains them): name the objects in the text.
`agent.prompt` to a `blocked` agent fails with `conflict` naming what it waits on (an approval or a question on its screen would take your text): tell the user, or `agent.wait` for it to move on. omp reports every approval prompt as blocked, nested ones included.
So does a target whose foreground program isn't its agent (`agent.list` `program` nvim or less while `kind` is omp): the text would go to that program. In tmux it goes to the active pane: fine while that pane runs the agent, a `conflict` naming what runs there otherwise. Tell the user; `force=True` sends it anyway.
`force=True` sends anyway, e.g. to a Claude Code or Gemini CLI agent that stays `blocked` after the user pressed Esc on or denied an approval. It types into whatever dialog is open and presses Return, which in an approval menu picks the highlighted option (usually allow): never force an answer to another agent's approval.
`agent.wait` survives an app restart: the SDKs and CLI ask again once the app is back, with `timeoutMs` reduced by the time already waited.

## Agent setup and client choice

- **You have a persistent Python REPL (e.g. an `eval` tool): use the Python SDK.** One connection, typed methods, compositions.
  ```python
  from easl_sdk import canvas
  board = canvas.board.get()                      # manifest of every object
  note = canvas.object.create(type="note", props={"markdown": "# Plan"}, expires_in="2h")["object"]
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
  easl object.create --type note --json '{"props":{"markdown":"# Plan"},"expiresIn":"2h"}'
  easl get obj_… --as graph                      # object.get shorthand
  easl render obj_…                              # view.render shorthand (also obj_a,obj_b or x,y,w,h); prints the PNG path
  ```
  "The socket exists but connecting to it failed … a sandbox may be blocking" means your sandbox blocks the unix socket, not that the app is down: run easl commands outside it (Codex: escalated) or ask the user to allow the socket.


## Mention context details

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
On a browser or HTML tile the mention adds `page elements under it (<url>):` lines (`<selector> "<text>"`), read when the prompt was sent: re-check with the selectors or a render if the page may have changed.
A group's arrows are the diagram's meaning: read their direction, labels and relations as its flow. Member text can be truncated; get a member for its whole text.
A terminal mention quotes its screen (one over 41 lines keeps 40: the first 3, the last 10 and failure lines).
A command's output (``[n] command `go test ./...` · exit 1``) ends `· read it: easl agent.read --target <id> --block -N` while that block can still be read (after `clear` the mention's own lines are all there is): run exactly that to read the block (up to its last 2000 lines).
Whether the user's last command passed: `lastCommand` (`{command, exit, durationMs}`) in `agent.list`/`object.get`, not the screen.
An `(edited)` marker means what the mention holds changed after the user staged it (a note's text, a page's address, a Stage/Unstage/Discard of that code mention's own lines): re-read it.

## Explain code on the board

"How does X work", "walk me through this change", "explain this system", "explain easl to me": answer on the board, as a small map around your terminal, not as a wall of terminal text and not as one big HTML page.
Tiles and arrows are things the user can move, mention and step through; a page is one tile they can only scroll.

1. **The code that matters, as code tiles at exact ranges**, each with a `caption` saying what to notice: `{"path": "src/store.ts", "range": {"start": 41, "end": 60}, "caption": "restore replays the log"}` and `"size": "fit"`.
   Three to six stops, not every file you read. Your follow tile already shows those. Create several in one `object.batch`, with a lifetime on each create.
2. **The structure as shapes and arrows** between those tiles: a `group` per part (`title`, `members`), `arrow`s with a `relation` (`"calls"`) and a two-word `label` only where the ends don't say it.
   For who calls what, use a `diagram` tile (`symbol`, `direction`) instead of drawing the call graph by hand. See [Live diagrams and authored graphs](#live-diagrams-and-authored-graphs) for language-server requirements.
3. **A browser tile when a page makes the point**: the running app, or the docs or README the code follows (`browser` `{"url": "…"}`).
4. **A note for what should last**: the summary in a few lines, with `path:line` links and anchored fences (```` ```ts file=src/store.ts#L41-60 ````), not pasted code.
5. **A short terminal answer**: the answer in a sentence or two and where to look, with a `view.attention` marker on the first stop; don't retell the tiles in prose.
6. **An HTML explainer only when a comparison or a decision needs its components** (`<canvas-compare>`, `<canvas-decisions>` in [HTML explainers](html-explainers.md)), or when the user asks for one page.

When it has an order (a request's path, a change step by step), join the stops with `"relation": "next_step"` arrows labelled "1 · parse", "2 · …" and group them titled "Start here": ⌥⌘→ on the group, or with nothing selected, starts at the first stop (`shapes.md`).
Build it in one `object.batch` with `"$0"` references. Place it with layout helpers and the [readable-diagram rules](shapes.md#lay-out-a-readable-diagram), then run `layout.check`, fix its findings, and inspect `easl render <group>` before pointing the user at it.

Say only what the code, the README or the docs show, and show where: every claim gets its tile, fence or `path:line`; read before you describe a feature, never describe one from its name.
For easl itself, ground it in this skill and `ui.md` (the same text as Help › easl Basics), or in the README and `docs/` when the board is easl's own checkout.
Excerpts show code as it is now: a code tile's range and a note's fence follow their code as lines move, and say stale only when the code they quoted is gone. Never tell the user an excerpt flags code that changed (a code tile's gutter marks lines changed against its `diffBase`; that is the diff, not the excerpt).

## Notes and anchored excerpts

A note created without a frame height fits its markdown (at `frame.w`, default 280), so `frame` can be just `{x, y, w}`.
An anchored fence shows its code as it is on disk now and follows it as lines move, so prefer anchors over pasted code:

- Excerpt, rendered from disk: ```` ```ts file=src/store.ts#L41-60 ```` or ```` ```ts file=src/store.ts symbol=restore ```` (`symbol=Class.method` finds methods deep in long classes: prefer it for whole functions).
- Proposed change, rendered as a diff against the real range: add `propose` (```` ```ts file=src/store.ts#L41-48 propose ````) and write the new code in the fence. An applied one shows "✓ applied"; no need to delete it.
- Plain fences are free-written snippets; `file:line` references anywhere in a note become links; `![alt](out/fig.png)` shows an image (board-relative, or absolute inside the board root or the temp dir); `$…$` and a `$$…$$` paragraph typeset as math (LaTeX; `\$` is a literal dollar and code spans/fences stay as written).
- Same-board object links use `[label](easl:object/<id>)` or `[label](easl:key/<key>)`, with the target percent-encoded as one URL component when needed. They select and show the object like question context links, including fitting oversized targets. Navigate Back returns.
- An exact `mermaid` fence renders asynchronously with the HTML kit's vendored Mermaid.js and theme, in isolated WebKit with a two-second deadline. Invalid, oversized, or timed-out diagrams keep their source with a short diagnostic. Stored Markdown is unchanged. Headless easld measures code; a remote board's viewing Mac renders the diagram.

Whether an excerpt still finds its code: `easl get <note>` → `fences` (per fence `state` live|relocated|stale|applied|missing, `range`, `reason`; `relocated`: the code moved and the fence followed it; `stale`: the code it quoted is gone), not a render searched for badges.
Table cells wrap to the note's width, so keep evidence timelines as `| time | event | evidence |` tables; `layout.check` `truncated` `{what: "table", x}` means too many columns: widen the note by `x` or split the table.

## Code tile behavior

A code tile shows the whole current file, scrolled so `range` sits a few rows below the top, with `range` tinted among the rows around it. Its range follows code as lines move. Do not retarget evidence tiles by hand; `rangeStatus: stale` means the quoted code is gone.
Its gutter shows changes against `diffBase` (default `merge-base`: the whole branch; `head` for uncommitted work only; or a commit sha).
A header "⚠ git failed: …" means git couldn't answer (cancelled, timed out, failed), not that the repo lacks commits; it clears on the next load. Don't work around a base warning with `diffBase: "head"` or a hand-picked sha unless the user asked for that base.

- **`caption`** is one line under the header (plain text, `inline code`, never wraps), so a tile doesn't need a separate note for its one-line explanation.
- **`size: "fit"`** sizes a tile to exactly its range (up to 1546 pt wide, 200 columns; longer lines soft-wrap). Pass the `range` even when `symbol` is set. Without `size` or a `frame`, a code tile is as wide as its file's longest line needs (from 640 up to the same 200 columns), read from the working tree; a tile shown from git (`pinnedCommit`, `ref`) or over a file larger than 1 MiB stays 640 wide.
- `pinnedCommit` accepts a SHA, tag, branch or `HEAD~N`; `null` returns to the working tree. For "what changed since X", use `diffBase` instead.

Code navigation (Go to Definition, Find References, Outline) needs the language's server; if a panel says it wasn't found, answers are text search: tell the user where easl looked (`ui.md` "Zoom and keys") rather than suggesting PATH edits.

## Changes tile behavior

To show the user what you changed, use a changes tile instead of an HTML diff. For a genuinely new task tile, choose an unused key: `easl object.create --type changes --json '{"props":{"key":"task-review"},"size":"fit","expiresIn":"1d"}'`.
A keyed create never takes over another tile. Find an existing review by key and update its id without expiry or layout fields unless those changes are intended. An unkeyed changes create can reuse your existing tile and apply its expiry, `frame` and `size` params, including to retained or user-owned evidence.
The user stages, unstages or discards per file, hunk, or selected lines; Stage/Unstage never change files: tell a user unsure of git so when they review your work.

## Live diagrams and authored graphs

For "show me who calls X" (or what X calls), create a live call graph from the language server instead of drawing one:
`easl object.create --type diagram --json '{"props": {"symbol": "AgentReportSpool.read", "direction": "incoming", "depth": 2}, "expiresIn":"1d"}'`.

- `symbol` is `Type.member` or a bare name (labels optional), found through the language server's workspace symbols when no path is given; when several functions have that name, `graph.error` lists them (`path:line (Container.name)`): recreate with `path` or a `Container.member` symbol. `line` (with `path`) works instead of `symbol`. `direction`: `incoming` (callers), `outgoing` (callees) or `both`; `depth` 1–4 (default 2).
- The graph is computed by the language server (sourcekit-lsp answers from the index of the user's last `swift build`; its first answer in a project takes ~20 s). `easl object.reload --id <tile>` computes it again and waits (up to 60 s); then read `props.graph` with `object.get`: `nodes[]` (`id`, `name`, `container`, `path`, `line`, `lines`, `excerpt`, `level`, `stale`, `expandable`), `edges[]` (`from` caller → `to` callee, call `lines`), `error`.
- It stays live: a file it shows changing recomputes it; nodes are re-found by symbol, and one whose symbol was deleted stays with a stale badge (`stale: true`). Only functions in the board's files are nodes.
- Open a node's next level by adding its id to `props.expanded` (the user clicks the node's +). The tile sizes itself to its first graph and grows into free space when a node opens (never over other objects; what doesn't fit is drawn smaller: resize it or zoom); `size: "fit"` on create waits for the first graph (up to 60 s, as `object.reload`) and fits the tile to it; the result's `diagram` is `object.reload`'s summary.
- Bind an arrow to a node with `{"object": "<diagram>", "node": "<node id>"}` (e.g. from a note explaining that caller).
- `error` says why a graph is empty or old (no server for the language, the symbol isn't declared there, an unindexed project); the last good graph stays.
- An authored graph node shows its label and the first two rows of detail. A click expands the full Markdown detail. Store and update the graph in `props.knowledge`, never the ignored calls cache `props.graph`. See [Objects](#objects) for graph props, provenance and status. `size: "fit"` sizes it to its levels.

## Questions and answers

When a decision is the user's to make and blocks you or another agent, post a question tile instead of asking in chat or building a `<canvas-decisions>` page.
It carries discrete options and your recommendation, shows up in the user's ⌘J needs-you list and the board's open-asks count, and the answer comes back to you as a mention with your next prompt, or from `--wait`.

```sh
easl ask "Ship the migration before the freeze?" --option now="Ship now:needs the 9am deploy window" --option later="After the freeze" --recommend now --context src/migrate.ts:40-72 --expires 4h
easl ask "Which cache is right?" --option a=L1 --option b=L2 --correct a --confidence --expires 4h   # graded: the closed tile shows ✓ or ✗
easl ask wait obj_returned_id                                  # blocks; answer JSON, exit 0; cancel/expiry/deletion exits 2
easl ask cancel obj_…                                              # the question is moot
```

For creation-time retention, use a native question with separate answer and deletion deadlines:

```python
from datetime import datetime, timedelta, timezone
from easl_sdk import canvas
question = canvas.object.create(type="question", props={
	"key": "name-choice-round-1", "question": "Which name?",
	"options": [{"id": "a", "label": "Atlas"}, {"id": "b", "label": "Beacon"}],
	"expiresAt": (datetime.now(timezone.utc) + timedelta(hours=4)).isoformat(),
}, expires_in="1d")["object"]["id"]
print(question)
```

For each convenience `easl ask` above, immediately set the returned tile's deletion deadline with `object.update --id <id> --expires <RFC3339-deadline>`, later than its actual answer timeout plus the reading window. For a blocking wait, use the two-step create/wait form so the deadline is set before waiting. The answer includes `id`, `option`, `label`, `note`, `confidence`, `correct`, `at` and `by` when applicable.

- `--option id=label[:why]` repeats; `--recommend <id>` names your pick; `--context` points at what it is about (an `obj_…`, a URL, or `path:10-20`). Without options the answer is a note.
- `--correct <id>` makes the question graded: while it is open nothing marks the right option; once answered the tile shows ✓ or ✗, a wrong pick highlights the right option and its `why`, and the answer line tells you whether the pick was right. `--confidence` asks how sure the user is: the tile gets a slider (optional; skipping it leaves `confidence` out), and the answer line says e.g. `confidence: 80%`. `--json` takes both as `correct` and `askConfidence`.
- Asking returns at once: carry on, and the answer reaches you as an object mention. Only when nothing else can proceed, use `easl ask wait <id>` after setting deletion retention. Cancellation, answer expiry or deletion ends the wait with its reason on stderr and exit 2.
- Ask only what you can't decide yourself, one question per decision. Cancel one the moment it is moot (you found the answer, the plan changed): an open question keeps counting as something the user must do.
- Keep `<canvas-decisions>` for an explanatory page with many choices recorded in its state, and chat for anything conversational.
- `easl ask list --open` lists the board's open questions; `easl ask wait <id>` resumes waiting on one after an interruption.

## Agent addressing, messages and restarts

Agents in other terminal tiles (any board in the app) are reachable by tile id, tile name, or `name@board` (board = its folder's name, or its id). A bare name is looked up on your board first, then every open board; a name on two boards is `ambiguous`: say `name@board`. A renamed tile still answers to its old name.

```sh
easl agent.list                                    # every terminal on every board (closed boards too: `open: false`): tile, kind, name, lifecycle, board, root, `program`, `title`, `pid`, `focused`, `draft`, `model`, `thinking`, `live`
easl agent.prompt --target reviewer --text "Review the diff in src/store.ts"   # → waitable, submittedAt
easl agent.wait --target reviewer --timeoutMs 600000   # until idle/done/blocked; `--until working` (or `working,blocked`) narrows it
easl agent.read --target reviewer --since prompt   # only what came after your last agent.prompt
```

`easl tell <name[@board]> "text" [--when next-turn] [--from <label>]` is `agent.prompt` for a message: an agent whose integration takes messages (omp with easl's extension) gets it out of band as a message naming you, without touching its draft or an open question (a working one is steered; `--when next-turn` waits for its turn to end), and replies with `write agent://<your address>`. Others are typed into as before (the result's `delivery` says `message` or `typed`). From a script with no tile, `--from machine-watch` names the sender and the message counts as the user's. If that agent exits, is killed or starts another session before it takes your message, the message bounces: you get a message from `easl` saying `undelivered to <address>: <its first line>` (a script's lands in the board's history, kind `message`). `unavailable` means nothing there takes it now (its agent was killed, or ended while you sent): check `easl agent.list` before sending again. Hosts aren't part of an address yet.

`agent.read --final true` returns only the last answer. Its `cutOff` flag means the turn died on that error: report that, not a completed result.
At Codex launch, `blocked` can mean it is waiting for the user to trust the folder. It reports `idle` after trust.
After a restored lifecycle, omp and opencode report again within seconds; Claude Code, Codex and Gemini CLI do so on their next tool call. If it stays restored, read the screen first. Never force a question or approval.

### Running a board's agents (chief of staff)

```sh
easl agent spawn --name reviewer --command 'omp --model=anthropic/claude-opus-4-5' --prompt "Review the open PR" --wait   # a new terminal tile; waits until it is ready, prompts it, waits for that turn
easl agent.restart --target reviewer --mode resume   # same tile, same session, same model and thinking level
easl agent.restart --target reviewer --mode fresh --args '["--plan"]'   # a new session with the same model and thinking
```

`agent spawn` takes `--cwd` (default here), `--board`, and `--command` as words or a JSON array; without `--prompt`, `--wait` only waits until the agent is ready.
`agent.restart` refuses (`conflict`) while the agent is `working` or `blocked`, was just prompted and hasn't started that turn or has a message queued it hasn't taken yet, while the user's keyboard is in its terminal (`focused`), or while its editor holds a draft the user hasn't sent (`draft` true) or may (`draft` absent: its integration doesn't say, as with every agent but omp). Wait and retry; `--force` throws that work, prompt, dialog or draft away, so use it only when the user asked.
A forced restart kills the agent: messages still queued for it bounce back to their senders (resend what matters once it reports again), and while it runs, prompts to that terminal are refused (`conflict`: send once it reports). A terminal on another machine (`props.host`) restarts there; on a board you view from another Mac, restart through that host's easl.
`agent.list` shows closed boards' terminals with `open: false` and `live` (their session still runs); you can only prompt, wait on, read or restart terminals of open boards (`easl board.open --root <root>` opens one as a background tab). A terminal on another machine has `live` from that machine and no `pid`.

A board's standing orders are its note keyed `rules`: every omp agent on that board gets the note's text appended to its system prompt at the start of each turn (the first 8 KB). To change what the board's agents follow, edit that note: `easl object.upsert --key rules --type note --json '{"props": {"markdown": "…"}}'`. Keep it short and imperative; it costs every agent's every turn.

## Terminals on another machine (offload)

A terminal created with `props.host` (an ssh target such as `deckbox`) runs its session on that machine, under its easld, and attaches over ssh: `easl object.create --type terminal --json '{"props":{"host":"deckbox","command":["omp"]},"expires":null}'`. `command` is argv (`["sleep","600"]`; a shell line is `["sh","-c","…"]`) and `cwd` is a directory on that machine. Your `easl` CLI and lifecycle work there as here. If you run there: Docker containers escape the machine's capped slice, so start any container with `--cpuset-cpus` inside the slice's CPUs and `--memory`; files you name (`path:line`, follow) are the host's, which the Mac's code tiles can't open yet.

## Compositions

Reusable helpers come built into the SDKs, plus your own in `~/.easl/compositions` (yours shadow built-in ones of the same name). In Python:

```python
canvas.compositions.available()                              # name -> summary
canvas.compositions.grid.arrange([id1, id2, id3])            # grid beside your terminal, clear of other tiles
```

The built-in `locations.open` creates code tiles but exposes no lifetime argument. For task-owned excerpts, use `object.batch` with an explicit `expiresIn` on every `object.create` for a non-terminal instead. Use `grid.arrange` only while you own the initial layout.

A composition is a plain module; functions whose first parameter is named `canvas` receive the client.
When you catch yourself repeating a multi-call board pattern, write it as a composition in `~/.easl/compositions/<name>.py`
(and `.ts` for the TS client, `client.compositions.<name>`), then `canvas.compositions.reload()`. Improve existing ones rather than forking them.

## Boards, worktrees and remote tabs

One board per git repository, whichever worktree or branch opens it (rooted at the main checkout); one per directory outside git. Boards open as tabs of one window.
`easl board.open --root <absolute dir>` opens a directory's board as a tab (creating it if new) behind the user's current tab; pass `--select true` only when the user asked to see it.
A worktree opens its repository's board: the result's `worktree` names it (path, branch, and `region`, the group that holds that branch's objects when there is one), and New Terminal starts there.
Then address it with `board: <id>` (from the result) on every call, and start agents there by creating terminal tiles on that board; a terminal records the `worktree` and `branch` it works in (where it started, and after a `cd` into another worktree, where its program runs) in its props.
Give each branch's work a group titled with the branch and keyed `branch:<name>`. `easl board.get --branch <name>` discovers that group and its members. This is the branch form of a playbook region, not a second group: include its plain `region/<work>/manifest` note, owner and lifetimes just as for `region/<work>`. Read an existing branch manifest before claiming the group.
`easl board.list` shows every stored local board, including a repository board's `worktrees` (path, branch, `live`: still checked out there). The Mac app also lists its open remote tabs with `remote:true`, `host`, `sshTarget`, the host's `board` id and `root`, `title`, `window`, and `open:true`. Remote roots are not local paths. Check `remote` before using local-only `archived`, `objects`, `updatedAt`, `repo`, or `worktrees` fields. Closing a remote tab removes its row; closed local boards stay with `open:false`. easld lists only its own boards.
Use a remote row's host `board` id for `view.get` through this app's socket to inspect its tab, or for `board.get` to read its host's manifest. Open and stored local IDs take precedence when IDs collide, including migrated IDs. A closed local target stays `not_found`; several matching remote tabs return `ambiguous`. Connect to the intended host directly when IDs collide. `view.render` on a remote tab requires `--inline true` and no `--out`; `view.snapshot` is unsupported to avoid writing host content locally. Tray calls use this viewer's private tray. `view.open_url` is unsupported for remote tabs because forwarding would pan the host user's window; use the tab's native link action.
`easl board.export` writes a readable snapshot to `<root>/.easl/board.json` for committing when the user asks to save the board with the repo.
`easl board.open_remote --host <host> --board <brd_…>` opens a board another Mac's easl hosts as a tab, viewed live over ssh (File › Open Remote…'s way): `host` as the picker names it (a tailnet Mac such as `twaldin-work`, or an ssh host), `board` the id from that host's `board.list` (run `easl board.list` there; your own board is never filled in). It stays behind the user's current tab unless `--select true`, and returns the tab already open instead of a second one. Nothing of that board is written here. `unavailable`: the host is offline or its easl isn't running; `not_found`: no such board open there.

## Lifetimes and cleanup

`object.create`, `object.update` and `object.upsert` accept top-level `expires` or `expiresIn`, never both.
`expires` is an RFC3339 timestamp with timezone, or `null` to remove the deletion deadline.
`expiresIn` is a finite nonnegative duration using `s`, `m`, `h` or `d`, including fractions, resolved once by the host.
On update or upsert, omission preserves an existing deadline. Sending `expiresIn` again renews it.
The returned object has an absolute `expires` when scheduled, and no `expires` field when no deletion is scheduled.
Do not put these fields inside `props`. Pick answer, task evidence or standing state as described in the core.

```sh
	easl object.upsert --key example/answer --type note --expires 2h --json '{"props":{"markdown":"A short answer, with its source."},"size":"fit"}'
	easl object.update --id obj_example --expires null
	easl board.stale --older-than 7d --mine
```

The last command is read-only. `--mine` fills `createdBy` from `EASL_TILE_ID` and refuses a missing caller.
The API's `createdBy` filter accepts a terminal id even after its terminal is gone.
Candidates list every applicable reason: `creator-gone`, `expired`, `untouched`, `exited`.
Content age starts at creation and advances when normal prop writes change values, including undo and redo.
Frame, z, parent, expiry, no-op prop writes and group membership changes do not refresh content age.
An exited shell is different from a completed `zmx run` task. Inspect reasons, keys and creators before deleting.
Use a region's member keys to remove its own young task tiles too. Staleness is not permission to delete foreign content.

Question `props.expiresAt` is an answer timeout. `easl ask --expires` writes that timeout, not the object's deletion deadline.
Immediately after an ask, use `object.update` with the returned id and a top-level lifetime.
Question archival hides a closed tile but keeps its answer queryable with `easl ask get`.

## Operational guardrails
Mouse users do not need a trackpad to zoom. Do not tell them zoom requires a pinch: use ⌘-scroll. Every action is also in the menu bar, including Help › search.

- Write locations as `path:line`, `:line:column`, `:start-end` or `#Lstart-end`. Terminal links also recognize Python traceback and pdb frames.
  Bare names open only when unique or nearest the cwd. Production `file:///srv/app/server/x.ts:39:5` paths can resolve to `server/x.ts:39`.
  A file name without a line can open too. `/rustc/…` standard-library frames are not links.
- Tiles you create show your terminal's name. User navigation never re-aims a tile you made, captioned or grouped.
- A fit code tile shows only its range, untinted. Use a taller frame to tint a short range among context.
  Line-bound arrows pin to the edge when their line is out of view, so keep bindings within visible rows.
- An invalid or missing method param fails with `invalid_params`, listing accepted params. Fix unknown-prop warnings.
  Objects written on another board still carry your attribution, but placement there is near the view's centre.
- A tile's frame controls how much it shows. Content zoom changes the content inside that frame, not its geometry.
  Zoom is 0.25–8, except image and video tiles. A text shape uses `textSize` instead. Leave the user's zoom alone.
- Do not rewrite a note when `view.get.focused` identifies it as being edited. Wait or add another note.
  A concurrent rewrite creates a conflict banner. Escape can keep the user's version with yours only one undo away.
- The user can Copy as Image or Save as PNG, save HTML or Markdown, and Snapshot to Image from a browser tile.
  Do not rebuild those exports by hand unless another format was requested.
- The follow tile is automatic and on by default. It flashes edited lines and stops when the user closes it.
  Create a separate code tile only for code the user should keep looking at. Never resize, recreate or enable follow unasked.
- Attention markers persist across restarts until the user looks. Put the point in the first 40 characters of a 240–480 pt bubble. Raise one marker per thing your answer points at.

## Keyed producers

An upsert's props merge. A `frame` passed to it applies on every run. Omit it after initial layout so the user's moves stick.
Always pass a lifetime when upsert may create. For a content-only refresh that must not recreate expired evidence, find by key and use `object.update` with that id. A missing object requires a new claim and explicit lifetime.
Find closed-ticket regions by `object.find --keyPrefix <prefix>`, then inspect ownership before deleting.
Claim a region with the core's plain manifest note. This note does not enforce ownership in the API.
The manifest's layout owner takes precedence over the fact that you created an object.
When a producer retires, remove its own standing region or name its successor as refresher in the manifest, without changing `Layout owner: user`.

