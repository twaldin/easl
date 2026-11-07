# Run a grill or decision round

Use this guide when a person must choose, approve a plan, or answer a design question. Do not post a question for information you can read or measure yourself. Use [Investigation](investigation.md) for that work.

## Build one round

1. Choose a work slug and round number. Check that `region/<work>-round-<n>/manifest` has no other owner before claiming the region.
2. Put a short context note on the left and native question tiles on the right. Keep one decision per question. Include options, their consequences, and a recommendation.
3. Link each question's `context` to the note, real evidence objects, source paths, or URLs. Keep unknowns explicit.
4. Group the round. Run `layout.check` once after initial placement, then change the manifest's layout owner from `agent:<EASL_TILE_ID>` to `user`.
5. Read answers from the question objects or `easl ask get <id>`. Record the answer in the decision source before starting the next round.

Use these exact key patterns:

- `region/<work>-round-<n>` is the group.
- `region/<work>-round-<n>/manifest` is the plain manifest note.
- `region/<work>-round-<n>/context` is the context note.
- `region/<work>-round-<n>/question/<decision>` is one native question per decision.

The manifest lists member keys, actual sources, refresh trigger, lifetimes, and layout owner. Questions, context, group and manifest are task evidence created with `expiresIn: "1d"`. Question `props.expiresAt` separately sets the answer timeout. Keep the deletion deadline later than that timeout so the answer can be read and recorded. `easl ask --expires 2h` sets only the timeout; immediately set the returned object's deletion deadline with `object.update --id <id> --expires 1d`. Extend retention before expiry if the answer remains needed.

## Refresh and close the round

Refresh context when its source changes. Do not silently change the options while someone is answering. Cancel a superseded open question, then create a new question with a new decision key. Closed questions cannot be reopened or rewritten into another question.

Keep later content updates in place. Omit `frame`, `size`, and layout helpers. Never select an object or take typing to demand an answer. Use `view.attention` when attention is needed.

A question's `answer` and the linked decision record are the evidence. Do not infer approval from a page-state value or an unanswered recommended option. Use `correct` and `askConfidence` only for a genuinely graded question, not a preference.

On answer, cancel, or timeout, update the source decision record. Let closed questions archive normally, with no `keep`. At task end, delete your round's question, context, manifest, and group unless explicitly retained. If handing off a retained region, name `user` or the successor as layout owner.

## Worked example: ask about a file-backed plan

Prerequisites: Python with `easl_sdk`, an already running scratch easld server selected by `EASL_SOCKET`, and `EASL_BOARD_ID` for a scratch board. Set `PLAN_FILE` to a real Markdown plan readable on that board's host. Use an unused round slug. This example creates the question headlessly; a human answers in a viewer. Without a terminal caller, the script names itself and reads answers explicitly.

```python
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from easl_sdk import canvas

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
- Lifetimes: All objects 1d; answer timeout 2h; record answers before deleting task evidence.
"""
deadline = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
result = canvas.object.batch(ops=[
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[1], "markdown": manifest}}},
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[2], "title": "Plan context", "markdown": f"Source: `{plan}`\n\n" + plan.read_text()}}},
	{"method": "object.create", "params": {"type": "question", "expiresIn": "1d", "props": {"key": keys[3], "question": "Proceed with this plan?", "options": [{"id": "proceed", "label": "Proceed", "why": "Accept the scope and risks in the plan."}, {"id": "revise", "label": "Revise first", "why": "Describe the required change in the answer note."}], "recommended": "revise", "context": [{"object": "$1"}], "asker": asker, "expiresAt": deadline}}},
	{"method": "layout.stack", "params": {"ids": ["$0", "$1", "$2"], "direction": "row", "gap": 48}},
	{"method": "object.create", "params": {"type": "group", "expiresIn": "1d", "props": {"key": base, "title": "Plan review, round 1", "members": ["$0", "$1", "$2"]}}},
])
ids = [result["results"][i]["object"]["id"] for i in (0, 1, 2, 4)]
check = canvas.layout.check(ids=ids)
assert not check["overlaps"], check
canvas.object.update(id=ids[0], props={"markdown": manifest.replace(f"Layout owner: {owner}", "Layout owner: user")})
print("Read the answer with: easl ask get", ids[2])
```

The recommendation is deliberately conservative for this demonstration, not a review verdict. Choose the real recommendation from the evidence before posting a real round. Headless layout checks can use approximate text measurements. See the [question API](../../../../schema/easl-api.json) and [client conventions](../api.md) for the full schema.
