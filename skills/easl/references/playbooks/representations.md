# Board representations

A representation answers one reading task. A kanban answers "where is work in its process?", a plot answers "how is a measurement changing?", and a question asks a person to act. A card grid compares peers without implying stages. A board can combine these without repeating the same facts in every form.

## Representation table

| Representation | Fits | Does not fit | Existing implementation and evidence |
|---|---|---|---|
| Stat card | One value, delta, and target, with unit and sample time. | A number that needs a paragraph to interpret. | A tstack configured stat card, or a short native note. Source is the producer's measured data. There is no native `stat` object type. See [Live stats](live-stats.md). |
| Trend chart | Change over time and comparison with a threshold. | Fewer than three observations, or unrelated categories. | An `image` tile backed by a saved chart, or the tstack stat sparkline. A scalar series is observation order unless sample times are available. |
| Kanban | Work items moving through named stages. Spatial position carries state. | An unordered list or a scalar measurement. | tstack's area HTML cards, derived from task, lane, and PR sources. There is no native `kanban` type. See [Orchestration](orchestration.md). |
| Card grid | Parallel peers such as lanes or PRs, with short status labels. | Long prose or a sequence that depends on order. | Native tiles arranged with `layout.grid`, or cards inside an `html` tile. Status comes from peer source records, not hand-picked colors. |
| Question tile | A decision or human action, with context, options, and a recommendation. | Information only, or a fact the agent can obtain itself. | Native `question` objects or `easl ask`. The question's answer is authoritative for the choice. See [Grill or decision](grill-or-decision.md). |
| Timeline or log | Dated changes, reduced to important events. | Current state or an endless transcript. | A rolling note or HTML log with dates and artifact links. See [Ship log](ship-log.md). |
| Side by side | Choosing between two to four variants under the same criteria. | More than four variants or unrelated work. | Separate tiles or HTML `canvas-compare`. Fake-data trials are labelled PROTOTYPE and separated from live work. See [Comparison and prototype](comparison-and-prototype.md). |
| Table | Exact lookup across many rows and named fields. | A distant glance at progress. | A Markdown note table or HTML table, with source links. Dense tables do not replace stage position or card status. |
| Clip or screenshot | Behavior, interaction, and appearance. | Numerical evidence on its own. | `video` and `image` tiles backed by actual files. A screenshot captures one point in time. See [Showcase and live product](showcase-and-live-product.md). |
| Live browser | The running product, including current interactions. | Proof of how the product looked at a past time. | A `browser` tile with a real reachable URL. Preserve a screenshot or clip for dated proof. |
| Code or changes tile | Exact lines and actual differences. | A high-level conclusion without explanation. | Native `code` with a range and optional pinned commit, or `changes` with real git refs. See [Investigation](investigation.md). |
| Diagram | Flow, dependencies, or states. | A list whose position has no meaning. | Native shapes and bound arrows, a native `diagram`, or Mermaid. The edges must name real relationships, not decorative connections. |

## Lifetimes and ownership

Answer objects use top-level `expiresIn: "2h"`. Task evidence uses `expiresIn: "1d"` and is deleted at task end unless retained. Standing state uses `expires: null`, with a named producer, refresh trigger, and retirement owner. The group and plain manifest note use the same task deadline, or `expires: null` for a standing region. These are API fields, not custom props.

Every agent-created region has `region/<work>` and `region/<work>/manifest`. The manifest records Purpose, Layout owner, Member keys, Sources of truth, Refresh trigger, and Lifetimes. Initial placement belongs to the creating agent, then to `user` after the first `layout.check`. Content refreshes omit layout fields and helpers. `renderer:tstack` owns its existing `tstack/*` objects, which are standing objects without a deletion deadline. Other agents do not retrofit or claim them.

An object selection is not a request to take typing. Scripts do not focus a terminal, click a page, or select objects to announce new content. User-activated object links navigate without programmatically transferring typing. Use attention markers for an important result.

## Worked example: compare two representation cards

Prerequisites: Python with `easl_sdk`, an already running scratch easld selected by `EASL_SOCKET`, and `EASL_BOARD_ID`. Use an unused slug. This is an educational card grid, not live work or fabricated metrics. It creates native notes and a group headlessly. Exact text measurement and display require a viewer.

```python
import os
from easl_sdk import canvas

base = "region/representation-example"
keys = [base, f"{base}/manifest", f"{base}/card/kanban", f"{base}/card/trend"]
assert not any(o.get("props", {}).get("key") in keys
	for o in canvas.board.get()["objects"]), "Choose an unused slug"
owner = "agent:" + os.environ["EASL_TILE_ID"] if os.environ.get("EASL_TILE_ID") else "script:representation-example"
manifest = f"""Purpose: Compare representation meanings, example only.
Layout owner: {owner}
Member keys: {', '.join(keys)}
Sources of truth: The representation table in this guide, not live project data.
Refresh trigger: This example is static; replace it when the question changes.
Lifetimes: All objects 1d; delete after the comparison.
"""
result = canvas.object.batch(ops=[
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[1], "markdown": manifest}}},
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[2], "title": "Example: kanban", "markdown": "# Items moving through stages\n\nUse stage position for workflow. Do not plot task state as a measured trend."}}},
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[3], "title": "Example: trend", "markdown": "# A measurement changing over time\n\nUse a plot for at least three observations. Do not turn unrelated measurements into workflow stages."}}},
	{"method": "layout.grid", "params": {"cells": [{"id": "$0", "row": 0, "col": 0}, {"id": "$1", "row": 1, "col": 0}, {"id": "$2", "row": 1, "col": 1}], "colGap": 48, "rowGap": 48}},
	{"method": "object.create", "params": {"type": "group", "expiresIn": "1d", "props": {"key": base, "title": "Representation example", "members": ["$0", "$1", "$2"]}}},
])
ids = [result["results"][i]["object"]["id"] for i in (0, 1, 2, 4)]
print(canvas.layout.check(ids=ids))
canvas.object.update(id=ids[0], props={"markdown": manifest.replace(f"Layout owner: {owner}", "Layout owner: user")})
```

The [API reference](../api.md), [HTML components](../html-explainers.md), [shapes](../shapes.md), and [browser reference](../browser.md) describe the existing mechanisms. Headless object storage is not proof that a browser, chart, video, or Mermaid diagram rendered. See [rendering](../rendering.md) for reported placeholders and viewer limits.
