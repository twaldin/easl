# Seeing the board: result details

Result fields and usage for `view.render`, `view.snapshot`, `view.get` and `board.history`.

Python: `canvas.view.render(target="obj_…", full=True)["path"]`
(`target` is an id, a list of ids, or `{"x","y","w","h"}`; ids render the region under them, taking in the whole route of any arrow between two of them).
The app writes a new file under `$TMPDIR/easl-renders/` (or `out` if you pass one: png or jpg by extension; clients resolve relative paths), and `path` in the result is that file.
The result maps pixels to the board: pixel `(px, py)` is board `(canvasRect.x + px / scale, canvasRect.y + py / scale)`,
and `objects` lists every object drawn with its `pixelRect`
(a tile's is exactly its frame: a tile's `frame` is its whole drawn box, 26 pt title bar included), `state`, and `overflow`:

- `state: rendered` means the content painted.
  `placeholder` means it didn't in time or can't be rendered here (`reason` says why; the image shows an orange "not rendered" tag instead of a silent blank).
  A browser tile that isn't loaded (offscreen, never shown) is loaded for the render.
  Content waits up to `timeoutMs` (8 s) for HTML and browser pages and file reads to settle.
- `overflow: {x, y}`: board points of content beyond the tile's frame
  (a note taller than its box, a code range longer than the tile; code wraps at the tile's width, so it only overflows downward).
  Absent when the content fits. Resize the frame by that much to fit it, or render with `full`.
- `contentSize`: the content's own extent at the tile's width, below its title bar.
  For code it is the range (its rows, wrapped at the tile's width, and longest line under the header), not the whole file: what `size: "fit"` shows.

Terminals are drawn from their session text in the terminal's font and colors.
App chrome (toolbar, tray, hints, selection rings, attention markers) is never drawn.
`exclude` leaves objects out: types (`["terminal"]`), ids (`["obj_…"]`, e.g. a tile to see what lies under it; a group's id takes its members with it), or both mixed. Targets are always drawn.

**`view.snapshot`** is the window as the user sees it now, toolbar and all.
Its result includes `viewport {rect, zoom}`, `scale`, and visible `objects` with `pixelRect`s, so you never need pixel math against a known tile.

**`view.get`** returns `viewport {rect, zoom}` (the visible board rect in board coordinates), `promptTarget`, `focused`, `selection`, and whether the window is `visible`.

**`board.history`** is a plain request/response log, cheap to poll from a REPL:
`easl board.history --since 42` (the `cursor` from your last call; or an ISO time) → `entries` oldest first, each `{seq, rev, at, actor, kind, id?, type?, summary}`.

- `actor` is `user`, `system`, or `agent:<tile>`.
  A side effect of someone's change (a group re-fit to its members, an arrow end freed because what it pointed at was deleted) is credited to them and has a `cause`,
  logged once per object per revision at its net change.
- `kind` is `created`, `updated`, `deleted`, `viewport` (logged once the view comes to rest), `selection`, `follow` (your follow tile re-aimed, and by whom),
  or `restart` (the app started; if your `since` is from before a restart the result says `restarted: true` and returns everything).
  `kinds: ["created","deleted"]` narrows it.
- Objects that existed for only seconds are in it too.
  The log is in memory: the newest 2000 entries per board (`truncated: true` when entries you hadn't seen were dropped).

## Choose a view

| Want | Call |
| --- | --- |
| Objects or a region without moving the user's view | `view.render` |
| A redraw of the current window, including chrome; not actual screen pixels | `view.snapshot` |
| The user's view without pixels | `view.get` |
| Who changed what since the last look | `board.history` |

```sh
	easl render obj_example
	easl render obj_a,obj_b --scale 2
	easl render 0,1200,2400,1600 --exclude '["terminal"]'
	easl render obj_example --full
```

`--full` includes a note or HTML tile's whole content, or a code tile's whole range, below its frame.
Rendering is offscreen at a fixed scale. Never move the view or add probe tiles in the user's view to inspect content.
Without `--out`, renders use a new temp file under `$TMPDIR/easl-renders/`. Do not write scratch renders inside the repository.
Headless easld without a drawing viewer cannot prove pixels. Its approximate `layout.check` is geometry evidence, not visual proof.
`view.snapshot` redraws the window offscreen and can hide blank or smeared tiles. Do not use it to verify what reached the screen; use an actual screen capture as described in [Seeing the window](../../../docs/testing.md#seeing-the-window).
