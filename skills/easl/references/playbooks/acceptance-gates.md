# Show measured acceptance gates

Use this when a release or task has named acceptance criteria with measurements and evidence. Use [a decision round](grill-or-decision.md) for preferences. A checklist written from memory does not prove acceptance.

## Put failing gates first

1. Choose `<work>`. Inspect the board and `region/<work>/manifest` before claiming a region. Never claim another owner's region or `tstack/*`.
2. Put `region/<work>/manifest` above `region/<work>/gates`, a 960-point-wide checklist note. Each row names the gate, measured value and unit, threshold, observation time, tested revision, and evidence link. Order failing gates first, missing or stale evidence next, and passing gates last.
3. Put `region/<work>/evidence/<gate>` artifacts below their gate summary, in reading order. Use existing report links, images, or pinned code tiles. Group the manifest, summary, and artifact tiles under `region/<work>`.
4. Record missing evidence as unmeasured, never zero or pass. Do not silently weaken a threshold to match the result. A passing row applies only to the revision and environment actually measured.

Source thresholds from the accepted task or release criteria. Source values from actual test reports, benchmark output, or deployment checks. Include the command or run URL that produced each result. Gate changes require an explicit criteria decision, not a content refresh.

## Refresh after a new result

Give each summary, artifact, group, and manifest `expiresIn: "1d"` at creation. Delete the region at task end unless explicitly retained. For a standing release gate region, use `expires: null` on every object and name its measurement producer and refresh cadence in the manifest.

Refresh when a measured run finishes, the tested revision changes, or criteria change. Mark old-revision results stale until replaced. Do not rerun measurements just to make the board look current. The initial owner is `agent:<EASL_TILE_ID>` until a clean `layout.check`, then `user`. For later content, find by key and update its id without `frame`, `size` or layout helpers. If it expired, claim a new region with explicit lifetimes. At handoff, name the successor or delete your task tiles, manifest and group.

## Display an existing gate report headlessly

Prerequisites: Python 3, installed `easl_sdk`, and `EASL_SOCKET`, `EASL_BOARD_ID`, and `EASL_TILE_ID` targeting a scratch server. Set `GATE_REPORT` to an existing JSON report from the measurement producer. Its shape is `{"revision":"…","observedAt":"…","gates":[{"name":"…","value":12,"unit":"ms","operator":"<=","threshold":20,"evidence":"https://…"}]}`. The producer must supply real measurements and approved thresholds. This is an input report shape, not an easl API field. This example supports numeric upper and lower bounds. It does not run tests or create files.

```sh
python3 - <<'PY'
import json, os
from easl_sdk import Easl
with open(os.environ["GATE_REPORT"]) as f:
	r = json.load(f)
def passing(g):
	assert g["operator"] in ("<=", ">="), "Use an explicit supported threshold"
	return g["value"] <= g["threshold"] if g["operator"] == "<=" else g["value"] >= g["threshold"]
rows = sorted(r["gates"], key=passing)
body = f"# Acceptance gates\n\nRevision: {r['revision']}\n\nObserved: {r['observedAt']}\n\n"
for gate in rows:
	body += f"- [{'x' if passing(gate) else ' '}] {gate['name']}: {gate['value']} {gate['unit']}; required {gate['operator']} {gate['threshold']} {gate['unit']}. [Evidence]({gate['evidence']})\n"
c = Easl()
w = "demo-acceptance"
g = f"region/{w}"
assert not c.object.find(key_prefix=g)["objects"], "Choose an unclaimed work slug"
def manifest(owner):
	return (f"Purpose: Inspect measured acceptance gates\n\nLayout owner: {owner}\n\nMember keys: {g}/manifest, {g}/gates\n\n"
		f"Sources of truth: {os.environ['GATE_REPORT']}; linked measured runs and approved thresholds\n\n"
		"Refresh trigger: New measured run or revision or approved criteria\n\nLifetimes: All task evidence expiresIn 1d; delete at task end")
m = c.object.create(type="note", props={"key": g+"/manifest", "markdown": manifest("agent:"+os.environ["EASL_TILE_ID"])}, size="fit", expires_in="1d")["object"]["id"]
a = c.object.create(type="note", props={"key": g+"/gates", "markdown": body}, size="fit", frame={"w": 960}, expires_in="1d")["object"]["id"]
c.object.create(type="group", props={"key": g, "title": "Acceptance gates", "members": [m, a]}, expires_in="1d")
c.layout.stack(ids=[m, a], direction="column", gap=60)
check = c.layout.check(ids=[m, a])
assert not any(v for k, v in check.items() if k not in ("approximate", "hints")), check
c.object.update(id=m, props={"markdown": manifest("user")}, size="fit")
PY
```

The summary links the report's evidence without duplicating every artifact. Add separate evidence tiles only when reviewers need to inspect them beside the gate. See [object API details](../api.md).
