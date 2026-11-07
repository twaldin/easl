# Investigate with evidence beside each finding

Use this guide for a bounded question about behavior, code, or a failure. Do not turn an investigation into a task kanban or present a hypothesis as a diagnosis. Use [Readout](readout.md) when one finished measurement round needs an immutable result.

## Arrange the evidence

1. Claim `region/<work>/manifest` after checking its owner. Put the question and hypotheses on the left, findings in the middle, and source evidence on the right.
2. Create one finding note per claim. Link the claim to exact code, a log receipt, a measurement artifact, or a source URL.
3. Use code tiles for real code, with `range` and `pinnedCommit` when the claim concerns a particular revision. Join the finding and code with a bound arrow.
4. Cross out rejected hypotheses and state the observation that rejected each one. Keep unresolved hypotheses visibly unresolved.
5. Run `layout.check` after initial placement. Hand layout ownership to `user`, then refresh content without `frame`, `size`, or layout helpers.

Use `region/<work>` for the group and these member keys:

- `region/<work>/manifest` is the manifest note.
- `region/<work>/hypotheses` holds the question and hypothesis states.
- `region/<work>/finding/<id>` states one finding, confidence, and its evidence link.
- `region/<work>/code/<id>` or `region/<work>/evidence/<id>` shows the underlying artifact.
- `region/<work>/link/<id>` binds the finding to that artifact.

Create every object, including arrows, group, and manifest, with `expiresIn: "1d"`. These are task evidence, not permanent state. If a person must decide, use a question with a separate answer timeout and a one-day deletion lifetime in a [decision round](grill-or-decision.md).

## Keep claims tied to the source

A finding's source is the artifact, not the note describing it. Preserve the command, revision, sample time, and artifact path needed to distinguish an observation from an inference. Do not paste a remembered code excerpt when a live or pinned code tile can show it.

Refresh after a new observation, changed hypothesis, or changed live source. A pinned tile intentionally stays at its commit. If new code changes the conclusion, add evidence for the new revision rather than silently relabeling the old result. For live excerpts, read `object.get` metadata such as `rangeStatus` or note `fences` before relying on them. Missing or stale anchors are not proof.

When the answer is settled, write the durable finding in the task's source document, with evidence references. Delete your investigation objects at task end unless the user retains them. If retained, set the manifest owner to `user` or a named successor and choose an explicit retention deadline. Do not delete source logs or commits as board cleanup.

## Worked example: inspect the question schema at a commit

Prerequisites: Python with `easl_sdk`, git, an already running scratch easld selected by `EASL_SOCKET`, and `EASL_BOARD_ID` for a scratch board. The board root must be a committed easl checkout with `schema/easl-api.json` at `HEAD`. Set `EASL_BOARD_ROOT` to that root. No GUI or running agent is needed. The example derives the claim and excerpt range from the same committed file.

```python
import json, os, subprocess
from pathlib import Path
from easl_sdk import canvas

base = "region/question-schema-investigation"
keys = [base] + [f"{base}/{name}" for name in ("manifest", "hypotheses", "finding/required", "code/question", "link/required")]
assert not any(o.get("props", {}).get("key") in keys
	for o in canvas.board.get()["objects"]), "Choose an unused slug"
root = Path(os.environ["EASL_BOARD_ROOT"])
path = "schema/easl-api.json"
sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
text = subprocess.check_output(["git", "-C", str(root), "show", f"{sha}:{path}"], text=True)
required = json.loads(text)["definitions"]["QuestionProps"]["required"]
assert "options" in required
lines = text.splitlines()
start = next(i + 1 for i, line in enumerate(lines) if '"QuestionProps": {' in line)
end = next(i for i, line in enumerate(lines) if '"ShapeProps": {' in line)
owner = "agent:" + os.environ["EASL_TILE_ID"] if os.environ.get("EASL_TILE_ID") else "script:schema-investigation"
manifest = f"""- Purpose: Find the required question properties at a specific revision.
- Layout owner: {owner}
- Member keys: {', '.join(keys)}
- Sources of truth: {path} at {sha}.
- Refresh trigger: New investigation evidence; pinned source does not follow edits.
- Lifetimes: All objects 1d; delete at task end.
"""
finding = f"# Required question fields\n\nObserved at `{sha}`: {', '.join(required)}.\n\nEvidence: `{path}:{start}-{end}`. This is a schema claim, not a runtime test."
result = canvas.object.batch(ops=[
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[1], "markdown": manifest}}},
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[2], "markdown": "# Are question text and choices both required?\n\n~~Hypothesis: question text alone satisfies QuestionProps.~~ Rejected by the committed required list. Runtime validation is not exercised here."}}},
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[3], "markdown": finding}}},
	{"method": "object.create", "params": {"type": "code", "expiresIn": "1d", "props": {"key": keys[4], "path": str(root / path), "pinnedCommit": sha, "range": {"start": start, "end": end}, "caption": "Committed QuestionProps schema"}}},
	{"method": "layout.stack", "params": {"ids": ["$0", "$1", "$2", "$3"], "direction": "row", "gap": 64}},
	{"method": "object.create", "params": {"type": "arrow", "expiresIn": "1d", "props": {"key": keys[5], "from": {"object": "$2"}, "to": {"object": "$3", "lines": {"start": start + 2, "end": start + 2}}, "relation": "supported_by", "label": "required fields", "route": "avoid"}}},
	{"method": "object.create", "params": {"type": "group", "expiresIn": "1d", "props": {"key": base, "title": "Question schema investigation", "members": ["$0", "$1", "$2", "$3", "$5"]}}},
])
ids = [result["results"][i]["object"]["id"] for i in (0, 1, 2, 3, 5, 6)]
check = canvas.layout.check(ids=ids)
assert not check["overlaps"], check
canvas.object.update(id=ids[0], props={"markdown": manifest.replace(f"Layout owner: {owner}", "Layout owner: user")})
```

The code tile is deliberately scrollable. Headless source reads and object creation work without a viewer. Approximate text checks do not prove visual fit. See [code and anchor APIs](../api.md#objects), [arrows and groups](../shapes.md), and [rendering limits](../rendering.md).
