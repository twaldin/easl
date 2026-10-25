# Graph diagrams

Users read authored knowledge and reasoning graphs, expand Markdown explanations, and follow recorded sources to terminals on the current board.

## Sub-features

- `graph-status` draws taught, practiced, retained, and weak nodes with labelled edges.
- `graph-detail` expands a node's complete Markdown and math without opening code.
- `graph-sources` follows an available terminal source or explains why a source is unavailable.
- `graph-preservation` retains authored `props.knowledge` across saves and older peers.

## How to get to it (user POV)

Create a diagram through the API with `props.kind: "graph"` and `props.knowledge`. Find its title through Command-P. Click the node body to expand or collapse its detail. Click its source badge to visit a terminal. A status badge is not a detail control.

## Driving it with dev.sh

Preconditions: follow Launch and Doctor. Run on a local board and a remote board served by guest-local scratch easld. Record a terminal ID on the same board for the source fixture.

1. Create a diagram with four nodes named Premise, Practice, Retention, and Review. Set their statuses to `taught`, `practiced`, `retained`, and `weak`. Connect Premise to Practice with `apply`, then Practice to Retention with `remember` and Review with `revisit`.
2. Give Premise this detail: `## Premise detail\n\nA complete explanation.\n\nInline $x^2+y^2=z^2$.\n\n- First supporting point.\n- Final supporting point.` Set its `sources` to `[{"board":"<BOARD>","tile":"<TERMINAL>","session":"verification-session","message":"verification-message"}]`. Use actual IDs, not these placeholders.
3. Navigate to the diagram. Capture all four status labels, edge labels, and the source badge. Derive body-click coordinates from the current capture and `view.get`, not from a previous run.
4. Click the Premise body away from its badges. Capture the expanded heading, formula, and both bullet points. Click again and capture collapse. Do not seed expansion through an API field.
5. Click the source badge. Require the recorded terminal to receive focus. Change the source to a nonexistent tile, return to the graph, and click again. Capture the unavailable-source notice without treating it as data loss.
6. For long-detail coverage, use an 8,192-byte detail ending in `LAST-LINE-8192`. Expand it and scroll inside its panel until that last line is visible. Expand a second short node ending in `SHORT-DETAIL-END`; require its panel to start at the top.
7. Save and reopen. Compare `props.knowledge` before and after. For mixed-version qualification, also retain raw persisted fragments and byte-compare across each older-peer save. A legacy `props.graph` error cache must not replace authored knowledge.

## Gotchas

- `props.knowledge` is authored content. `props.graph` is the computed calls cache. They are not interchangeable.
- Graphs accept at most 500 nodes and 2,000 unique directed edge pairs. Detail is limited to 8,192 UTF-8 bytes per node. Each node accepts at most eight sources.
- A source badge can focus only a terminal available on this board. A message reference alone is provenance, not a navigable tile.
- Older apps can show a calls error instead of the authored graph. Record the actual older-peer display and preservation result; do not call fallback rendering graph support.
- Source entry points are `Sources/CanvasCore/Diagram/DiagramSpec.swift`, `Sources/CanvasCore/Diagram/DiagramGraph.swift`, and `Sources/CanvasApp/DiagramTile.swift`.
