# Run a grill or decision round

Use this guide when a person must choose, approve a plan, or answer a design question. Do not post a question for information you can read or measure yourself. Use [Investigation](investigation.md) for that work.

## Build one round

1. Choose a work slug and round number. Check that `region/<work>-round-<n>/manifest` has no other owner before claiming the region.
2. Put a short context note on the left and native question tiles on the right. Keep one decision per question. Include options, their consequences, and a recommendation.
3. Link each question's `context` to the note, real evidence objects, source paths, or URLs. Keep unknowns explicit.
4. Group the round. Fix the initial layout until `layout.check` is clean, then change the manifest owner from `agent:<EASL_TILE_ID>` to `user`.
5. Read answers from the question objects or `easl ask get <id>`. Record the answer in the decision source before starting the next round.

Use these exact key patterns:

- `region/<work>-round-<n>` is the group.
- `region/<work>-round-<n>/manifest` is the plain manifest note.
- `region/<work>-round-<n>/context` is the context note.
- `region/<work>-round-<n>/question/<decision>` is one native question per decision.

The manifest lists member keys, actual sources, refresh trigger, lifetimes, and layout owner. Questions, context, group and manifest are task evidence created with `expiresIn: "1d"`. Question `props.expiresAt` separately sets the answer timeout; deletion must leave time to read and record the answer. If using convenience `easl ask`, supply the question's region key with `--json '{"key":"region/<work>-round-<n>/question/<decision>"}'` and an actual answer timeout, then immediately set the chosen deletion deadline. Unkeyed questions are moved onto tstack's shelves.
For blocking waits, create the question with `object.create` and a one-day lifetime, then call `easl ask wait <id>`. The convenience `ask --wait` does not print its id until the answer, so do not use it before the deletion lifetime is set.

## Refresh and close the round

Refresh context when its source changes. Do not silently change the options while someone is answering. Cancel a superseded open question, then create a new question with a new decision key. Closed questions cannot be reopened or rewritten into another question.

Keep later content updates in place. Omit `frame`, `size`, and layout helpers. Never select an object or take typing to demand an answer. Use `view.attention` when attention is needed.

A question's `answer` and the linked decision record are the evidence. Do not infer approval from a page-state value or an unanswered recommended option. Use `correct` and `askConfidence` only for a genuinely graded question, not a preference.

On answer, cancel, or timeout, update the source decision record. Let closed questions archive normally, with no `keep`. At task end, delete your round's question, context, manifest, and group unless explicitly retained. If handing off a retained region, keep `Layout owner: user` and name the successor as refresher.

## Worked example: ask about a file-backed plan

Prerequisites: Python with `easl_sdk`, an already running scratch easld server selected by `EASL_SOCKET`, and `EASL_BOARD_ID` for a scratch board. Set `PLAN_FILE` to a real Markdown plan readable on that board's host. Use an unused round slug. This example creates the question headlessly; a human answers in a viewer. Without a terminal caller, the script names itself and reads answers explicitly.
Set `PLAN_SUMMARY` to a short, sourced summary of the real plan. The question also links the plan file; do not paste the whole document into a tall note.

```python
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from easl_sdk import CanvasError, canvas

base = "region/plan-review-round-1"
keys = [base, f"{base}/manifest", f"{base}/context", f"{base}/question/approve"]
assert not any(o.get("props", {}).get("key") in keys
	for o in canvas.board.get()["objects"]), "Choose an unused round"
plan = Path(os.environ["PLAN_FILE"]).resolve()
caller = os.environ.get("EASL_TILE_ID")
owner = f"agent:{caller}" if caller else "script:plan-review"
asker = {"tile": caller} if caller else {"name": "plan-review"}
manifest = f"""- Purpose: Decide whether to proceed with the linked plan.
- Layout owner: {owner}
- Member keys: {', '.join(keys)}
- Sources of truth: {plan}; question answer; recorded decision in the plan.
- Refresh trigger: Plan changes or a question answer.
- Lifetimes: All non-terminal objects 1d; answer timeout 2h; record answers before deleting task evidence.
"""
deadline = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
result = canvas.object.batch(ops=[
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[1], "markdown": manifest}}},
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[2], "title": "Plan context", "markdown": f"Authored plan summary.\n\nSource: `{plan}`\n\n" + os.environ["PLAN_SUMMARY"]}}},
	{"method": "object.create", "params": {"type": "question", "expiresIn": "1d", "props": {"key": keys[3], "question": "Proceed with this plan?", "options": [{"id": "proceed", "label": "Proceed", "why": "Accept the scope and risks in the plan."}, {"id": "revise", "label": "Revise first", "why": "Describe the required change in the answer note."}], "recommended": "revise", "context": [{"object": "$1"}, {"path": str(plan), "lines": {"start": 1, "end": 1}}], "asker": asker, "expiresAt": deadline}}},
	{"method": "layout.stack", "params": {"ids": ["$0", "$1", "$2"], "direction": "row", "gap": 48}},
	{"method": "object.create", "params": {"type": "group", "expiresIn": "1d", "props": {"key": base, "title": "Plan review, round 1", "members": ["$0", "$1", "$2"]}}},
])
ids = [result["results"][i]["object"]["id"] for i in (0, 1, 2, 4)]
check = canvas.layout.check(ids=ids)
if any(v for k, v in check.items() if k not in ("approximate", "hints")):
	question = canvas.object.get(id=ids[2])["object"]
	if question["props"]["status"] == "open":
		try:
			question = canvas.object.update(id=ids[2], rev=question["rev"], props={"status": "cancelled"})["object"]
		except CanvasError as error:
			if error.code != "conflict":
				raise
			question = canvas.object.get(id=ids[2])["object"]
	if question["props"]["status"] not in ("cancelled", "expired"):
		print("Round retained:", ids[2], question["props"]["status"], question["props"].get("answer"))
		raise RuntimeError(f"Layout failed; record any answer in the plan before cleanup or retry: {check}")
	for identity in ids:
		canvas.object.delete(id=identity)
	raise RuntimeError(f"Round removed after layout failure; correct the inputs before retrying: {check}")
canvas.object.update(id=ids[0], props={"markdown": manifest.replace(f"Layout owner: {owner}", "Layout owner: user")})
print("Read the answer with: easl ask get", ids[2])
```

The recommendation is deliberately conservative for this demonstration, not a review verdict. Choose the real recommendation from the evidence before posting a real round. Headless layout checks can use approximate text measurements. Run `easl methods QuestionProps` for the question schema; see [client conventions](../api.md) for API usage.
