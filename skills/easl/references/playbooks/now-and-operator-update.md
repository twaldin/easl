# Replace the operator's now note in place

Use this guide for a short authored update: what changed, decisions, and what happens next. Do not use the note as a live task database or substitute it for derived lane, CI, or deployment facts. Use [Orchestration](orchestration.md) for those facts and [Ship log](ship-log.md) for dated completed work.

## Write the next useful update

1. Read the task, decision, PR, and run sources. Separate observations from the author's interpretation.
2. Write a short update in its source Markdown file. Include links for claims, an observed timestamp, and unresolved decisions.
3. Claim `region/<work>/manifest` after checking its owner. Put `region/<work>/now` first, with the manifest beside it. Label the note as authored, and show when its source changed.
4. Group them under `region/<work>`. Run `layout.check` once after placement, then set layout owner to `user`.
5. Refresh the same now key after a meaningful change or operator handoff. Do not create a stack of nearly identical updates.

The default note fits one screen. Use headings such as `Changed`, `Decisions`, and `Next`. Keep an actual operator decision in a [question tile](grill-or-decision.md), linked from the note. Information alone is not an ask.

If the update needs separate supporting notes, use `region/<work>/decisions`, `region/<work>/operating-model`, and `region/<work>/cleanup`. Add their keys to the manifest and IDs to the group's `members`. Do not create empty supporting tiles.

## Make age and ownership explicit

Create the now note, any supporting notes, group, and manifest with `expiresIn: "1d"`. These are task evidence. For an ongoing operator feed, use `expires: null` only when the manifest names the content producer, refresh trigger, and retirement owner. The layout owner becomes `user` after initial placement, even when the original agent continues to refresh content.

The source Markdown is an authored report, not a measurement. Preserve its update time and link its factual claims to authoritative artifacts. Showing a new publication time does not make old evidence current. If a source cannot be checked, say so instead of repeating its last state as present fact.

Refresh only your content. Use `object.upsert` with the existing key and omit `frame`, `size`, and layout helpers, so the user's position and dimensions remain unchanged. Keep the update short enough for the existing frame. Do not select the tile or change typing focus to announce it. Raise `view.attention` if the operator needs to look.

At task end, delete the now note, your supporting notes, group, and manifest unless explicitly retained. For a retained feed, name its next producer and set the manifest owner to `user` or the named successor. Delete neither source documents nor someone else's tiles.

## Worked example: publish a file-backed update

Prerequisites: Python with `easl_sdk`, an already running scratch easld selected by `EASL_SOCKET`, and `EASL_BOARD_ID` for its scratch board. Set `UPDATE_FILE` to a real, short Markdown update readable on the host. It must already state what changed, the decisions, and the next action with evidence links. Use an unused slug. No viewer or agent process is required to create it.

```python
import os
from datetime import datetime, timezone
from pathlib import Path
from easl_sdk import canvas

base = "region/operator-update"
keys = [base, f"{base}/manifest", f"{base}/now"]
assert not any(o.get("props", {}).get("key") in keys
	for o in canvas.board.get()["objects"]), "Choose an unused slug"
source = Path(os.environ["UPDATE_FILE"]).resolve()
updated = datetime.fromtimestamp(source.stat().st_mtime, timezone.utc).isoformat()
markdown = f"Authored operator update. Source updated {updated}.\n\nSource: `{source}`\n\n" + source.read_text()
owner = "agent:" + os.environ["EASL_TILE_ID"] if os.environ.get("EASL_TILE_ID") else "script:operator-update"
manifest = f"""- Purpose: Give the operator the latest authored update.
- Layout owner: {owner}
- Member keys: {', '.join(keys)}
- Sources of truth: {source}; evidence links in that document.
- Refresh trigger: A meaningful source update or operator handoff; operator-update publishes it.
- Lifetimes: All objects 1d; delete at task end unless retained.
"""
result = canvas.object.batch(ops=[
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[1], "markdown": manifest}}},
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[2], "title": "Now, authored update", "markdown": markdown}}},
	{"method": "layout.stack", "params": {"ids": ["$1", "$0"], "direction": "row", "gap": 48}},
	{"method": "object.create", "params": {"type": "group", "expiresIn": "1d", "props": {"key": base, "title": "Operator update", "members": ["$0", "$1"]}}},
])
ids = [result["results"][i]["object"]["id"] for i in (0, 1, 3)]
check = canvas.layout.check(ids=ids)
assert not check["overlaps"], check
canvas.object.update(id=ids[0], props={"markdown": manifest.replace(f"Layout owner: {owner}", "Layout owner: user")})
```

For the next update in the same Python session, replace only the content by id. Omission preserves an existing deletion deadline. If the tile expired, `object.update` fails with `not_found` instead of creating an orphan. Start a new region with explicit lifetimes when needed.

```python
updated = datetime.fromtimestamp(source.stat().st_mtime, timezone.utc).isoformat()
markdown = f"Authored operator update. Source updated {updated}.\n\nSource: `{source}`\n\n" + source.read_text()
canvas.object.update(id=ids[1], props={"markdown": markdown})
```

This shows an absolute source time, not a ticking age. It does not install a feed or claim that the file's contents are derived facts. Headless text measurement can be approximate. See [object keys and updates](../api.md#objects) and [rendering](../rendering.md).
