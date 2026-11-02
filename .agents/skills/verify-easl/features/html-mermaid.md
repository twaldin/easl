# HTML Mermaid

HTML tiles render Mermaid syntax with Pele 1.9.1 only. Diagrams preserve declared direction and start at natural viewBox size with overflow scrolling. Fit can shrink labels; 100% restores natural size. This file is a verification recipe, not a record of passing GUI proof.

## Sub-features

- `html-mermaid-entry` covers `<pre class="mermaid">`, fenced `mermaid` blocks inside `<pre>`, `pre > code.language-mermaid`, and `canvasKit.renderMermaid()`.
- `html-mermaid-family` covers renderer family compatibility and sampled directive and class styling.
- `html-mermaid-fit` covers labelled keyboard-reachable Fit/100% controls and real horizontal scrolling.
- `html-mermaid-fallback` covers source plus diagnostic rather than a blank diagram.
- `html-mermaid-export` covers settled renders and scriptless HTML exports.
- `html-mermaid-storage` covers byte-preserving mixed-version storage.

## Prepare the coverage pages

Follow the parent skill's guest claim, Launch, Doctor, evidence, and cleanup procedures. Build outside the claim where possible. Use only scratch local and remote boards. Record the exact head, candidate binary hash, guest, PID, and window ID.

Copy these inputs into the run's evidence directory and retain their hashes:

- `/home/tim/lane-evidence/easl/easl-pele-html-1/prototype/corpus.json`, all 15 `{id, title, source, origin}` cases.
- `/home/tim/lane-evidence/easl/easl-easl-pele-switch-1/family-cases.json`, the `{id, source}` family and styling cases.
- `/home/tim/lane-evidence/easl/easl-easl-pele-switch-1/family-expanded-cases.json`, the additional detector and syntax cases.

If the retained inputs are unavailable, obtain the original fixtures before claiming coverage. Do not replace them with easier diagrams. The family set must include gitGraph, journey, timeline, quadrantChart, sankey, xychart, block, requirement, architecture, packet, kanban, radar with quoted labels, all five C4 forms, treemap, info, init directives, and `classDef` colours and stroke widths.

Check every diagram detector in the pinned baseline, not only its published syntax index. Include cynefin, event modeling, Ishikawa, railroad with EBNF, ABNF, and PEG, swimlane, tree view, Venn, Wardley, and legacy renderer selections. Separate invalid syntax and baseline defects from missing family support. zenuml renders in neither pinned renderer.

Generate one page per case so every result has a named tile and can be inspected separately. This command writes API request bodies, not passing evidence. Set `CASES` to each copied JSON array and `OUT` to a fresh directory:

```sh
CASES="$G/corpus.json" OUT="$G/corpus-requests" bun -e '
const fs = require("node:fs");
const path = require("node:path");
const cases = JSON.parse(fs.readFileSync(process.env.CASES, "utf8"));
const escape = value => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
fs.mkdirSync(process.env.OUT, { recursive: true });
for (const [index, item] of cases.entries()) {
	const html = `<h1>${escape(item.id)}</h1><pre class="mermaid">${escape(item.source)}</pre><p>After the diagram.</p>`;
	const request = { type: "html", props: { title: item.id, html }, frame: { x: index * 460, y: 0, w: 420, h: 600 } };
	fs.writeFileSync(path.join(process.env.OUT, `${item.id}.json`), JSON.stringify(request));
}'
```

Create each request with `scripts/dev.sh cli object.create --json "$(cat REQUEST.json)"`. Retain the returned IDs and the exact input files. Repeat generation for `family-cases.json` using a separate directory.

## Drive the coverage journey

1. Navigate to each named tile through Command-P. Capture all 15 corpus cases at tile widths 420, 800, and 1200 pt, in light and dark. Change tile width through `object.update`, leaving its source unchanged. Capture the full diagram through scrolling where needed, not only the first clipped region. Compare labels, edges, declared LR direction at narrow width, palette, and trailing prose. Avoid incidental pixel-dimension assertions.
2. Repeat the family cases in actual tiles. Retain a result per case, its source, and captures. Compare the same sources with the pre-cutover Mermaid.js 11.17.2 artifact in an isolated baseline page, not a fallback shipped in the candidate. A family rendered by the baseline but not Pele is a stop condition. Family success does not establish full syntax parity. Check sampled `classDef` fill, stroke, and stroke width. Record that sampled init directives parse but `themeVariables.primaryColor` is ignored; the app palette comes from CSS.
3. Seed the other markup forms with the same small LR source. Use a literal fenced block inside `<pre>`, then `<pre><code class="language-mermaid">…</code></pre>`. For the page API, append a `pre.mermaid` after page load and call `canvasKit.renderMermaid()`. Require visible labels and arrows for every entry point. Keep the exact HTML. The removed undocumented `window.mermaid` global is not an entry point.
4. On a wide diagram at 420 pt, capture natural size before input. Click Fit with real guest input and capture the fitted diagram. Click 100% and require natural geometry again. With visible macOS scroll bars, require the entire SVG height, including bottom node and subgraph borders, without nested vertical scrolling. Fit must not leave a scrollbar-sized empty band. Repeat these bounds checks in flex, table, and centred shrink-to-fit layouts. The shrink-to-fit container must use the available diagram width, not just the control's width. Resize across the diagram's natural width and require the scrollbar space to appear and disappear without clipping the SVG or overlapping trailing prose. Give the selected HTML tile keyboard ownership with native Return, then use Tab to reach the labelled control and Space or Return to toggle. Record focus, accessible label, key receipts, and both states. Synthetic DOM clicks do not qualify.
5. At 100%, put the pointer over the diagram and send real guest horizontal wheel or trackpad input through the parent skill's input route. Capture before and after, plus input receipts. Require a previously clipped labelled node to become visible without moving the tile or panning the canvas. A DOM-dispatched `WheelEvent`, assigning `scrollLeft`, or merely reading overflow dimensions is not scroll proof. If real horizontal scroll cannot work in a tile, stop and hand back.
6. Supply malformed syntax through each source markup form. Require intact source and a short diagnostic, never a blank box. Confirm links, images, script-bearing labels, and external content do not become active or load resources. Keep network/process evidence separate from screenshots.

## Export without scripts

Use native Save as HTML and Open in Browser on a settled tile. Inspect the saved file for the diagram SVG, inlined CSS, and absence of scripts. Open the actual saved file in the guest browser with scripting disabled. Require visible labels and real horizontal wheel scrolling for a wide diagram. Repeat export after using Fit so the saved result does not depend on a live control. Capture both exports and retain their files and hashes. Exercise `view.render` while lazy rendering is pending and require completed diagram pixels rather than an unsettled source-only page. Remote viewer export restrictions remain unchanged; do not bypass them.

## Mixed-version storage

Use a real v0.3.3 app and the candidate sequentially with one isolated scratch app home and the same local board. Preserve backups and close one writer before opening the other. Include HTML examples for all documented entry points and the complete note corpus.

1. Save exact UTF-8 `props.html` and `props.markdown` values to evidence files before either app edits the board. Preserve whitespace, escapes, fences, directives, and final newlines.
2. In v0.3.3, edit HTML through its documented `object.update` API and Markdown through the native note editor, then save. There is no native HTML-source editor. Save those committed source values as the comparison baseline. Reopen in the candidate and require byte-identical values, then save and reopen again. Compare both API readback and persisted board props against the baseline.
3. Reverse the sequence with an API HTML edit and native Markdown edit in the candidate, then save and reopen in v0.3.3 and again in the candidate. Require byte-identical committed HTML and Markdown. Compare source bytes, not JSON serialization order, screenshots, or diagram dimensions. Different layouts are expected. No migration or stored renderer state is required.

Retain every comparison and failure. These journeys do not establish a GUI pass until exercised on the exact candidate. Follow [note Mermaid](note-mermaid.md) for static bitmap centring, bounds, local and remote coverage, cold launch, deadline termination, pool, retries, cancellation, and churn. Record vendor and application bundle bytes before and after separately from layout proof.

## Run the native behaviour regression

Inside the claimed guest, build the candidate once and run the existing HTML keyboard runner. The runner forces space-consuming scroll bars for its own process and checks the actual scroll bar condition. Its Mermaid checks cover the documented entry points, narrow LR direction, source diagnostics, shrink-to-fit width, scrollbar changes on resize, native-click Fit/100%, and scriptless export. They do not replace the real-wheel or visual corpus journey.

```sh
swift build --build-system native -j 2 --product Easl -Xswiftc -enable-testing
BIN=$(swift build --build-system native --show-bin-path)
python3 Tests/HtmlKeyboard/run.py --bin-path "$BIN"
```
