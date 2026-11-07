# Shapes, arrows and groups

The full rules behind SKILL.md's summary.

- `shape`: `{"kind": "rect" | "ellipse" | "text" | "ink", "text": "…", "color": "…", "fill": "none" | "semi" | "solid"}` with a `frame`.
  A rect drawn around tiles *encloses* them.
  - `color`: `black` (the default ink, drawn to contrast with what is under it: dark over a white page, an image or the light board, light over the dark board or a dark page, on screen and in renders), `grey`, `blue`, `green`, `orange`, `red`, `violet`, or `#rrggbb`. Arrows take `color` too.
  - `fill` (rect/ellipse): `none` (default; the interior passes clicks through), `semi` (a 14% wash of the color, for regions), `solid` (85%).
  - Text sizing: a `text` shape draws its text in 20 pt handwriting from the frame's top-left, wrapping at the frame width;
    one line needs about 30 pt of height (`h ≈ 30 × lines`).
    A rect/ellipse `text` is an 18 pt label centered in the frame, wrapping at `w − 16`.
    Arrow labels are 15 pt, wrapping at 240 pt, centered on the shaft.
- `arrow`: `{"from": {"object": "obj_…"}, "to": {"object": "obj_…", "lines": {"start": 41, "end": 48}}, "relation": "calls", "label": "…", "route": "avoid"}`.
  - Endpoints bind to objects (optionally a line range or a DOM `selector`) or to a `{"point": [x, y]}`. Arrows the user draws bind to the tile or shape their end was released on or near, like `{object}` ends from the API.
  - An end bound to `lines` of a code tile attaches to the tile's left or right edge at the row of `lines.start`
    (the right edge unless the other end lies wholly to the left), so call-site → callee arrows point at the lines.
    It follows the tile's scroll, and a line scrolled out of view pins the end to the top of the code or the bottom of the tile.
    On other tiles `lines` binds the whole tile.
  - `relation` is the machine-readable edge (`calls`, `depends_on`, `hypothesis_about`, …); `label` is what the user reads.
    `relation: "next_step"` makes an order the user can step through: ⌥⌘→ on the selected tile follows its outgoing next_step arrow (⌥⌘← its incoming one) before geometry, centering each stop (fitted readably when the user steps from a zoomed-out overview), and says "Last step" at the end.
    ⌥⌘→ on a group holding the stops, or with nothing selected, starts at the first stop (the one no next_step arrow points to), so group a walkthrough and mark the group "Start here".
    Join a walkthrough's stops with next_step arrows and lay them out however reads best; the order doesn't depend on the layout.
    Without a label the arrow shows its relation in a secondary color; `label: ""` shows no caption.
  - `route`: `straight` (default), `orthogonal`, or `avoid` (goes around tiles in the way).
    `avoid` arrows are routed together: arrows sharing a side get their own ports, arrows sharing a gap run in parallel tracks, and each leaves the side of its source that faces downstream (its group's `flow`).
    Arrows between the same two objects are drawn apart automatically, both directions.
    A label sits beside its own arrow where no other line runs, else on its line, else a dashed leader away; in a bundle of parallel lines it is led to its own stub, where its line still runs alone. `layout.check` reports any that couldn't.
    Label chips are outlined in their arrow's color: on a diagram with more than about 6 arrows, color them by lane or flow so each label reads with its line.
- `group`: `{"members": [ids], "title": "…", "color": "blue", "padding": 24, "flow": "down"}` is a titled, tinted region whose frame always wraps its members
  (plus padding and a title band) as they move; use one per lane or cluster instead of a rect plus a text label.
  `flow` (`right`, `down`, `left`, `up`) says which way the diagram inside reads, for `avoid` arrows among its members; without it the board's arrows between groups decide.

## Lay out a readable diagram

1. Use one group per stage in reading order. Set the outer group's `flow` to `right` or `down` when geometry does not make the order clear.
2. Leave about 120 pt between columns and 60 pt between stacked tiles for arrows. Leave more where arrows converge.
3. Use `route: "avoid"` for arrows crossing the diagram. Order each column's tiles to match their arrows and avoid crossing fans.
4. Label only what the ends do not explain, in two or three words. Put detail in the tile.
5. With more than about six arrows, color by lane or flow so labels match their lines.
6. Run `layout.check`. Fix `arrowOverlaps`, `labelOverlaps` and avoidable `arrowIntersections`. Its `hints` flag crowded one-color labels.

`easl get <id> --as graph` exposes enclosures, overlaps and connections to other agents.
Apply layout once while your manifest names you as layout owner. After hand-back, preserve the user's positions.
