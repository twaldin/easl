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
- `props.zoom` on any tile but an image (0.25–8, default 1) is how big its content draws inside its frame, in place: the frame never changes with it and the title bar stays at 1×;
  the body lays out at body ÷ zoom (a 1200×826 tile at zoom 2 shows what a 600×400 body does, twice as big: a terminal fewer, bigger columns, a page a narrower viewport). An update that sets it never moves or resizes the tile.
  Measure and fit lay out at `width` ÷ zoom (the frame is the 26 pt title bar plus the body × zoom); `layout.check`, `view.render` sizes, and line anchors account for it; everything you get back is in board points.
  Image tiles don't zoom (the picture is already fitted to the frame): make the tile bigger. A text shape's font is `props.textSize` (0.25–8, default 1, a multiplier of 20 pt), and its box grows with it.
  `props.scale` is gone: create, update, upsert, batch, and measure reject it with `invalid_params`.
- Terminal tiles: `{"cwd": "/path", "command": ["omp"]}` starts an agent in a new tile (its session survives app restarts). Only start agents the user asked for.
  Deleting a terminal tile (`object.delete`, or in a batch that succeeds) ends its session and whatever runs in it, as closing it does for the user.
- Changes tiles (`type: changes`, `ChangesProps`): `{"base": "HEAD"}` (the default: uncommitted work, staged or not; also `merge-base`, everything the branch changed against the default branch, or a commit or ref; the user can switch it in the tile's header), optional `root` (another worktree of the board's repository, e.g. `"../wt-agent"`; without one you review your own checkout, your worktree when you work in one), `paths` (files or dirs in it) and `title`.
  `head` (any commit or ref, e.g. `{"base": "origin/main", "head": "pull/32642/head"}`) compares two commits instead: read-only from git objects, no checkout (the head against its merge-base with `base`, default `merge-base`: a PR's view; renames and deletions included; no Stage, Unstage, or Discard; a line click opens a code tile pinned to that side's commit). A ref the repository lacks lists nothing and its notice names the exact `git fetch` that brings it; easl never fetches. `ref` (a branch, instead of `root`) is the worktree that has it checked out while one does, else the branch's commits as with `head`; the tile writes the commit it read to `props.refSha` and keeps reading it once the branch is gone (`merged in <sha>` or `branch gone` in its header); creating one with a ref the repository lacks is `not_found`, naming the fetch.
  The user reviews there: hunks as a unified diff, Stage, Unstage, and Discard per file, hunk, or selected lines, each one ⌘Z (Discard only puts back uncommitted work: committed hunks have none); a Viewed box folds a file until its diff changes. To show them what you changed, create one (`size: "fit"` sizes it to every hunk, at most 4000 pt tall, and it grows as you add hunks) rather than an HTML diff. Creating it again with the same `root`/`base`/`head`/`ref`/`paths` returns your existing tile (`reused: true`).
  `object.get` adds `changes`: `files` (`path`, board-relative or absolute outside the board root; `status` added/modified/deleted/renamed; `added`/`removed`; `viewed`; `hunks` with a stable `id`, `header`, `old`/`new` `{start, count}`, `status` unstaged/partial/staged/committed, and `lines`: the unified text, at most 200 with `truncated`) as git has them now, so hunks the user discarded are gone and staged ones say so (`partial`: staged, then changed again); two commits compared add `head` (full SHA), `headLabel`, `baseTip` (the commit the base names; `base` is the merge-base) and `readOnly: true`, and `ref` tiles `refSha` (plus `refState` once the branch is gone);
  `props.reviewed` lists what they staged, unstaged, or discarded (`action` stage/unstage/revert, `path`, `scope` file/hunk/lines, `hunk` id, `header`, `patch`: the patch applied, reversed for a discard). The tile writes `reviewed` and `viewed`; changing them yourself does nothing to git.
  A mention of a diff line says what it is: `… diff vs HEAD 1a2b3c4, new side (working tree) · added line · unstaged hunk`.
- Code tiles (`type: code`, `CodeProps`): `path` (board-relative, or relative to your own checkout when you work in another worktree of the board's repository, stored absolute there; or outside the board root: another repo or worktree, whose own git the tile reads, `pinnedCommit` included), `range`, `symbol`, `caption`, `diffBase`, `pinnedCommit`, `ref`.
  The gutter shows changes against `diffBase` like gitsigns (green bar added, blue bar modified, red wedge where lines were deleted; the user clicks a sign to see the old lines). A repo with no commits or no default branch, or a diff too large to compute, shows plain source with a header warning; a deleted file shows its base version.
  With a `range`, `size: "fit"` sizes the range even when `symbol` is set; `symbol` alone fits the declaration but the tile still shows the file from the top, so pass the range.
  `pinnedCommit` shows the file as of that commit, read-only: no gutter signs, working-tree edits don't change it, the header says "pinned at <sha>", and mentions quote the lines at that commit. For a PR head you haven't checked out: `git fetch origin pull/<n>/head`, then pin to `git rev-parse FETCH_HEAD`.
  `ref: "<branch>"` anchors the tile to a branch: `path` is relative to the repo (the board root's place in it), and the header says where it reads. "live in <worktree>": a worktree has the branch checked out, so it shows that working tree with its gutter and edits. "<branch> @ <sha>": no worktree has it, so git objects at the branch, read-only. "merged in <sha>": the branch is gone and the default branch contains it, so the file at the commit that merged it. "branch gone, showing <sha>": gone and not contained (squash merge, or deleted unmerged), so its last commit while the objects exist. easl records the SHA it last resolved as `refSha` (you may pass it); a create or update whose `ref` resolves to nothing is `not_found`. `pinnedCommit` wins over `ref`.
- Image tiles (`type: image`, `ImageProps`): `{"path": "out/fig.png", "caption": "…"}` (board-relative or absolute; png, jpg, gif, webp, heic, tiff, bmp, svg, a pdf's first page).
  This is where a chart goes: save the figure to a file and create the tile, no base64 in HTML. Without a frame (or `frame` of just x, y, w) it fits its picture: one point per pixel, at most `w` (default 960) wide.
  It reloads when the file changes on disk, so re-save the chart to the same path to update it (no `object.update` needed). A Hyper-click on it mentions `image <path> · pixel (x, y) of W×H`.
  Its title defaults to its file name: set `title` only when the name doesn't say what it shows. Keep images that must last outside `$TMPDIR`.
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
  After changing an HTML tile's `html` or a note's `markdown`, refit it in the same call: `canvas.object.update(id=tile, props={"html": page}, size="fit")` (the tile doesn't grow by itself).
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
      {"method": "object.create", "params": {"type": "code", "props": {"path": "src/a.ts", "range": {"start": 10, "end": 30}}, "size": "fit", "frame": {"x": 0, "y": 0}}},
      {"method": "object.create", "params": {"type": "note", "props": {"markdown": "Why this matters"}, "size": "fit", "frame": {"x": 0, "y": 0, "w": 320}}},
      {"method": "layout.place", "params": {"id": "$1", "near": "$0", "side": "below", "gap": 14}},
      {"method": "object.create", "params": {"type": "group", "props": {"members": ["$0", "$1"], "title": "Request path", "color": "blue"}}},
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
  It judges what is drawn (whole tile frames, routes and line-bound ends as drawn), so an empty report means a clean picture. Run it after a layout pass instead of screenshots.
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
