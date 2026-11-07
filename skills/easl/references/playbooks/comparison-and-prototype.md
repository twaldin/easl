# Compare labelled prototypes

Use this to choose between two to four variants on explicitly fake data. Do not use it for live product monitoring or evidence that a design works in production.

## Keep the comparison apart from live work

1. Inspect the board and choose an empty area separate from live regions. Check `region/<work>/manifest` for another owner. Never claim another owner's region or `tstack/*`.
2. Put `region/<work>/manifest` above the comparison. Label the group and every variant `PROTOTYPE`. Use `region/<work>/variant/a` through `region/<work>/variant/d` as stable keys.
3. Place variants side by side at equal size, with a 60-point gap. Hold viewport, sample data, and scenario constant. Put `region/<work>/criteria` above the variants with the decision criteria and fake-data disclosure.
4. Put one `region/<work>/pick` question below the variants. Link the variants as context. Ask for one choice, and allow rejection when none meets the criteria. Group all members under `region/<work>`.

Source the scenario and criteria from the task. Source fake fixtures from labelled example data or declare them inline as invented. Do not insert customer data or mirror live status into a prototype. Use [HTML explainers](../html-explainers.md) for richer variants and [question API details](../api.md) for the choice. Do not change selection or focus to take typing from the user.

## Retire the comparison after the choice

Give variants, criteria, question, group and manifest `expiresIn: "1d"` at creation. A question keeps the chosen answer until its deletion deadline. Keep that deadline later than its separate answer timeout and the time needed to record the answer. For `easl ask`, `--expires` controls only the answer timeout; set the returned object's deletion deadline separately. Extend retention before expiry when needed.

Refresh only when the comparison inputs change. Keep equal scenarios across all variants. Do not alter a closed question to solicit another choice. Start a new round with new keys. Initial layout ownership is `agent:<EASL_TILE_ID>` until a clean `layout.check`, then `user`. Later content updates omit frames and layout helpers. At decision end, record the choice in the task's durable record and delete your prototype tiles, question, manifest, and group unless explicitly retained. Never delete the adjacent live region.

## Create a headless two-variant comparison

Prerequisites: Python 3, installed `easl_sdk`, and `EASL_SOCKET`, `EASL_BOARD_ID`, and `EASL_TILE_ID` targeting a scratch server. Inspect the board first. Set `PROTOTYPE_X` and `PROTOTYPE_Y` to a free area's upper-left coordinates, away from live regions. All names and counts below are invented prototype fixtures. No server, GUI, or new file is required.

```sh
python3 - <<'PY'
import os
from datetime import datetime, timedelta, timezone
from easl_sdk import Easl
c = Easl()
w = "demo-prototype-choice"
g = f"region/{w}"
assert not c.object.find(key_prefix=g)["objects"], "Choose an unclaimed work slug"
x, y = float(os.environ["PROTOTYPE_X"]), float(os.environ["PROTOTYPE_Y"])
keys = [g+"/criteria", g+"/variant/a", g+"/variant/b", g+"/pick"]
def manifest(owner):
	return (f"Purpose: Choose a prototype summary layout\n\nLayout owner: {owner}\n\nMember keys: {', '.join([g+'/manifest', *keys])}\n\n"
		"Sources of truth: Inline invented fixtures, not live product state\n\nRefresh trigger: Comparison inputs change; new round after a closed question\n\nLifetimes: All task evidence expiresIn 1d; record the answer before deletion")
m = c.object.create(type="note", props={"key": g+"/manifest", "markdown": manifest("agent:"+os.environ["EASL_TILE_ID"])}, size="fit", expires_in="1d")["object"]["id"]
criteria = c.object.create(type="note", props={"key": keys[0], "markdown": "PROTOTYPE. Invented data: Cedar 12, Birch 7. Choose the layout that makes the larger count easier to find. No production claims."}, size="fit", expires_in="1d")["object"]["id"]
variants = []
for i, html in enumerate(["<h1>PROTOTYPE A</h1><p>Cedar: 12</p><p>Birch: 7</p>", "<h1>PROTOTYPE B</h1><table><tr><th>Name</th><th>Count</th></tr><tr><td>Cedar</td><td>12</td></tr><tr><td>Birch</td><td>7</td></tr></table>"]):
	variants.append(c.object.create(type="html", props={"key": keys[i+1], "title": "PROTOTYPE "+"AB"[i], "html": html}, frame={"w": 480, "h": 320}, expires_in="1d")["object"]["id"])
q = c.object.create(type="question", props={"key": keys[3], "question": "Which PROTOTYPE layout makes the larger count easier to find?", "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}, {"id": "neither", "label": "Neither"}], "context": [{"object": v} for v in variants], "expiresAt": (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()}, expires_in="1d")["object"]["id"]
ids = [m, criteria, *variants, q]
c.object.create(type="group", props={"key": g, "title": "PROTOTYPE comparison", "members": ids}, expires_in="1d")
c.layout.grid(cells=[{"id": m, "row": 0, "col": 0}, {"id": criteria, "row": 1, "col": 0}, *[{"id": v, "row": 2, "col": i} for i, v in enumerate(variants)], {"id": q, "row": 3, "col": 0}], col_gap=60, row_gap=60, origin={"x": x, "y": y})
check = c.layout.check(ids=ids)
assert not any(v for k, v in check.items() if k not in ("approximate", "hints")), check
c.object.update(id=m, props={"markdown": manifest("user")}, size="fit")
PY
```
