# Publish a dated measurement readout

Use this for one completed measurement round. Show the question, a one-line answer, two to four numbers, a chart, and the evidence. Use [live stats](live-stats.md) for values that change over time, or [acceptance gates](acceptance-gates.md) for release criteria.

## Freeze one round

On a board actively maintained by a configured tstack seat, write this round in its reports directory using the [engine report schema](https://github.com/twaldin/tstack/blob/main/docs/reference.md#project-config): `question`, `answer`, `evidence`, optional `numbers` with `label`, `value`, `unit`, `chart`, `at`, and `lane`. Let the engine render its report shelf. Do not create a duplicate region. The standalone layout and example below apply when no configured renderer maintains this board, including isolated fixture copies.

1. Choose `<work>` with the measurement date and a unique round suffix, such as `latency-2026-11-07-r1`. Inspect the board and `region/<work>/manifest` before claiming space. Never claim another owner's region or `tstack/*`.
2. Put `region/<work>/manifest` above the content. Put `region/<work>/answer` at the upper left with the question, one-line answer, measured interval, revision, environment, and limitations.
3. Put `region/<work>/numbers` to its right with two to four measured values and units. Put `region/<work>/chart/1` below the answer and `region/<work>/evidence` to the chart's right. Add `region/<work>/chart/2` only when the second chart answers a different part of the same question.
4. Group the members under `region/<work>`, titled with the measurement date. Use images of charts from that round, not live chart paths. Link the underlying report, input data, command or run, and method.

Source every value and the answer from a completed measurement report. Preserve the interval, sample size, units, and comparison basis needed to interpret the result. Do not replace unavailable measurements with zero. Do not use a live browser as point-in-time evidence.

## Never refresh the measurement in place

Create every member, group, and manifest with `expiresIn: "1d"`. Delete the task region at task end unless explicitly retained. For an explicitly retained readout, set every object's `expires: null` and name the archive owner. Retention does not turn the readout into standing live state.

The refresh trigger is a new measurement round, which creates a new dated region and keys. Never update the old round's values or overwrite its chart or report files. If a correction is necessary, publish a new round that identifies the superseded one. Keep the old result identifiable as superseded rather than silently rewriting history.

The initial layout owner is `agent:<EASL_TILE_ID>` for placement only. After a clean `layout.check`, set Layout owner to `user`. This ownership handoff is metadata, not a measurement refresh. Do not rerun layout helpers or pass frames on later metadata updates. Hand retained artifacts to a named archive owner, or delete your members, manifest, and group.

## Publish an existing round headlessly

Prerequisites: Python 3, installed `easl_sdk`, and `EASL_SOCKET`, `EASL_BOARD_ID`, and `EASL_TILE_ID` targeting a scratch server. Set `READOUT_REPORT` to an existing frozen JSON measurement report. Its shape is `{"round":"latency-2026-11-07-r1","measuredAt":"…","question":"…","answer":"…","revision":"…","environment":"…","method":"…","limitations":"…","numbers":[{"name":"…","value":12,"unit":"ms"},{"name":"samples","value":100,"unit":"requests"}],"chartPath":"/absolute/frozen-chart.png","evidenceUrl":"https://…"}`. Use an existing chart path accessible to the server and never overwrite it. This is a report input shape, not an easl API extension. No measurement is run and no new file is required.

```sh
python3 - <<'PY'
import json, os
from pathlib import Path
from easl_sdk import Easl
with open(os.environ["READOUT_REPORT"]) as f:
	r = json.load(f)
assert 2 <= len(r["numbers"]) <= 4
assert Path(r["chartPath"]).is_file(), "Use an existing frozen host-local chart"
c = Easl()
w = r["round"]
g = f"region/{w}"
assert not c.object.find(key_prefix=g)["objects"], "A readout round is immutable; choose a new round"
answer = f"# {r['question']}\n\n{r['answer']}\n\nMeasured: {r['measuredAt']}\n\nRevision: {r['revision']}\n\nEnvironment: {r['environment']}\n\nLimitations: {r['limitations']}"
numbers = "\n\n".join(f"{n['name']}: {n['value']} {n['unit']}" for n in r["numbers"])
evidence = f"[Measurement report]({r['evidenceUrl']})\n\nMethod: {r['method']}\n\nFrozen input: {os.environ['READOUT_REPORT']}"
specs = [
	("answer", "note", {"markdown": answer}, {"w": 760}),
	("numbers", "note", {"markdown": numbers}, {"w": 480}),
	("chart/1", "image", {"path": r["chartPath"], "caption": "Measured round "+w+" at "+r["measuredAt"]}, {"w": 760, "h": 440}),
	("evidence", "note", {"markdown": evidence}, {"w": 480}),
]
keys = [g+"/"+s[0] for s in specs]
def manifest(owner):
	return (f"Purpose: Immutable measurement round {w}\n\nLayout owner: {owner}\n\nMember keys: {', '.join([g+'/manifest', *keys])}\n\n"
		f"Sources of truth: {os.environ['READOUT_REPORT']}; {r['chartPath']}; {r['evidenceUrl']}\n\n"
		"Refresh trigger: Never in place; publish a new dated round\n\nLifetimes: All task evidence expiresIn 1d; delete at task end unless retained")
m = c.object.create(type="note", props={"key": g+"/manifest", "markdown": manifest("agent:"+os.environ["EASL_TILE_ID"])}, size="fit", expires_in="1d")["object"]["id"]
ids = []
for k, (_, t, p, f) in zip(keys, specs):
	params = {"type": t, "props": {**p, "key": k}, "frame": f, "expires_in": "1d"}
	if t == "note":
		params["size"] = "fit"
	ids.append(c.object.create(**params)["object"]["id"])
c.object.create(type="group", props={"key": g, "title": "Readout "+r["measuredAt"], "members": [m, *ids]}, expires_in="1d")
c.layout.grid(cells=[{"id": m, "row": 0, "col": 0}, *[{"id": v, "row": 1+i//2, "col": i%2} for i, v in enumerate(ids)]], col_gap=60, row_gap=60)
check = c.layout.check(ids=[m, *ids])
assert not any(v for k, v in check.items() if k not in ("approximate", "hints")), check
c.object.update(id=m, props={"markdown": manifest("user")}, size="fit")
PY
```

Image tiles reload when their source file changes. Immutability therefore requires frozen files as well as unchanged tile props. See [image behavior](../api.md).
The chart uses its explicit frame instead of `size="fit"`, so SVG creation does not need a viewer. Only the notes use text fitting.
