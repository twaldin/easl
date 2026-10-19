# HTML explainers

An HTML tile is the richest single tile you can put next to your terminal: a plan, a comparison the user can decide on, a decision record.
To explain code or a system, start on the board instead (SKILL.md, "When the user asks you to explain something"): code tiles, arrows and a note the user can move and step through. Build a page when a comparison or decision needs these components, or the user asks for one tile.

## The tile

```python
canvas.object.create(type="html", props={"title": "Restore path", "html": html})
```

- `html` is a body fragment or a full document. Update it with `object.update` (the tile re-renders in place); keep the same tile rather than creating a new one per revision.
  The tile keeps its height: pass `size="fit"` in the same update (`canvas.object.update(id=tile, props={"html": page}, size="fit")`) to refit it to the new page.
- Board files: `fetch('data/series.json')`, CSV, `<script src="chart.js">`, stylesheets, fonts, images and `<video src="clips/demo.mp4" controls>` load relative to the tile's root (the board root unless `root` overrides it). Authorized board assets work locally and from a remote host; loaded-file edits reload the live page without reopening its tile. Temporary-directory fallback is image-only. A standalone chart belongs in an image tile; a standalone clip belongs in a `video` tile. No base64 needed. Match the user's `view.get` `appearance` (dark: transparent background, light text).
- Sandboxed: no network (list hosts in `allowNetwork: ["localhost:3000", "*.example.com"]` when you truly need them), no native access, no approvals or credentials inside the tile, ever.
- On a remote board, allowed HTTP(S), including `localhost`, runs on the board host through SSH, never the viewer's localhost. Relative resources keep the page's granted origin. GET/HEAD only, no cookie/session, POST or private WebSocket proxy; unhandled network APIs can fail closed.
- Preloaded, nothing to include:
  - **Tailwind v4**, themed to the app. Use the semantic colors so the tile matches light and dark mode:
    `bg-background text-foreground`, `bg-card`, `bg-muted text-muted-foreground`, `border-border`, `bg-accent text-accent-foreground`, `bg-code`, `text-warn`, `text-ok`, `font-sans`, `font-mono`.
    Avoid hard-coded hex colors.
  - **Mermaid**: `<pre class="mermaid">flowchart LR …</pre>` renders as a diagram.
  - **easl components** (below).
- Optional page API: `window.canvasKit.openCode(path, {line | lines, symbol})`, `.excerpt(path, {lines, symbol})`, `.getState(key?)`, `.setState(key, value | null)`, `.onState(fn)`.

## Components

| Component | Use |
| --- | --- |
| `<canvas-code path="src/x.ts" lines="10-40"></canvas-code>` | Excerpt read from the real file. `lines` are line numbers in the file as it is now: they don't follow code that moves (a code tile's range and a note's fence do). `symbol="Board.update"` anchors to a symbol instead (re-found after edits; wins over `lines`): use it for code that may move. A stale badge means the symbol wasn't found or the lines are past the file's end. Long lines soft-wrap with a hanging indent, so don't widen the tile for them. Click opens a code tile. `path` is board-relative. |
| `<canvas-link path="src/x.ts" line="42">the retry loop</canvas-link>` | Inline file:line link (also `lines="10-20"`, `symbol=`). Empty text renders `path:line`. A click goes to the code tile already showing those lines (exactly, or a captioned tile whose range holds them), else opens one beside the page: an overview can link to its own stops. |
| `<canvas-decisions key="storage" question="Where should boards live?">` + `<canvas-option value="sqlite" label="SQLite">why / cost</canvas-option>`… | A choice the user makes in place. The pick is stored in the tile's `props.state.storage`; read it with `object.get`. Clicking again clears it. |
| `<canvas-compare>` + `<canvas-pane label="Before">…</canvas-pane>`… | Equal-width labeled columns, any count. |

Grounding rule: every claim about code points at code. Use `<canvas-code>` for the lines that prove it and `<canvas-link>` for passing references.
Never paste code you could anchor: pasted code is a copy that falls behind silently, an anchored excerpt shows the file as it is now.

## Style

- **Small first draft.** About one screen: the answer, one diagram or comparison, a few excerpts.
  Split a long explainer into several tiles in a group (one per stage or question) rather than one tall page, and add depth when the user asks.
- **Lead with the answer.** The first screen states the conclusion or the decision needed, in one or two sentences. Detail follows.
- **One idea per section**, each with a short heading that is a claim ("Restore reads the snapshot twice"), not a topic ("Restore").
- **Show, then tell.** Put the excerpt or diagram first and a two-line caption under it, not paragraphs around it.
- **Progressive disclosure.** Use `<details><summary>` for depth the user may not need: edge cases, logs, full traces.
- **Restraint.** A tile is ~640 px wide at 100%: single column by default, `canvas-compare` only for genuine side-by-side.
  Neutral surfaces (`bg-card`, `border-border`), accent color only for the one thing that matters, `text-warn`/`text-ok` only for status.
  Generous spacing (`p-6 space-y-6`), `text-sm` body, `font-mono` for identifiers.
- **Title the tile** (`title` prop) with what it is for: "Plan: tray persistence", "Why restore races".

## Mermaid

- **Give diagrams the full width.** Mermaid scales a diagram down to fit its container,
  so a sequence diagram squeezed into a narrow column (a grid cell, one `canvas-compare` pane) renders its message text at ~9 px, unreadable at 100%.
  Put diagrams in their own full-width section, keep them to 5–9 nodes or participants, and put the details in sections under them.
- **No `;` in sequence messages.** In a `sequenceDiagram`, `;` ends the statement, so `A->>B: read; retry` fails the whole diagram ("Syntax error in text").
  Use a comma, or `#59;` for a literal semicolon (`A->>B: read#59; retry`).
- **Building HTML in omp's `eval`:** a Python cell line that starts with `%%` (e.g. a Mermaid `%%{init: …}%%` directive) is taken as a cell magic.
  Keep the directive inside a string that doesn't start a line of the cell, or leave it out.

## Playbooks

### Plan

For work the user should approve before you start.

1. Goal and non-goals, two lines each.
2. Steps as an ordered list; each step names the files it touches with `<canvas-link>` and what changes.
3. Risky spots as `<canvas-code>` excerpts of the code you will change, with one-line "what changes here" captions.
4. Open questions as `<canvas-decisions>` blocks, one per question, so the user answers in place. Read the answers with `object.get` before you start, and wait for the user's go.

### Code walkthrough

For "how does X work", when the user wants it as one page (to share, say); otherwise build it on the board (SKILL.md, "When the user asks you to explain something").

1. One sentence: the path in plain words.
2. A Mermaid `sequenceDiagram` or `flowchart` of the path, 5–9 nodes, node labels are function names.
3. One section per hop: heading = what happens, `<canvas-code symbol=…>` of that function, caption = the one line to notice.
4. A "gotchas" `<details>` for surprising behavior, each with a `<canvas-link>`.

### Comparison

For options, before/after, or two implementations.

1. The verdict first ("B, because …") or the question if the user must choose.
2. `<canvas-compare>` with one pane per option: same structure in every pane (summary, cost, risk, code).
3. A small table of criteria × options when there are more than two criteria.
4. If the user chooses: end with `<canvas-decisions>` whose options match the panes.

### Decision record

For choices that should be remembered: context (two lines), the `<canvas-decisions>` block, consequences per option.
After the user decides, update the tile to state the decision at the top and keep it as the record (or write it into a note).

### Architecture map

For "how do these parts fit". Draw it on the board with groups, shapes and arrows by default, so the user can move boxes and mention them (SKILL.md, "When the user asks you to explain something").
As a page: a Mermaid `flowchart` of components (subgraphs for processes or packages), edges labeled with the protocol or call; under it, one row per component: name, one-line responsibility, `<canvas-link>` to its entry point.

### Review / findings

For review results or an investigation. Findings sorted by severity; each is a card (`bg-card border border-border rounded-lg p-4`) with a claim heading, `<canvas-code>` of the offending lines, why it matters, and the suggested fix.
Put a one-line summary count at the top ("2 bugs, 1 risk, 3 nits").

## Check your tile

After creating or updating an explainer, look at it: `easl view.snapshot`
(or `easl render <id> --full`, which renders the whole page offscreen and reports `overflow`) and read the image at the `path` it returns.
Without `--out` the image goes to a new file under `$TMPDIR/easl-renders/`, never in the repo (see SKILL.md, Known surprises).
Fix overflow, unreadable contrast, or broken diagrams before telling the user it's there. Then point at it with `view.attention` rather than moving their viewport.
