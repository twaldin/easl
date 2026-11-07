# Show live stats and trends

Use a stat card for one measured value, its delta, and its target. Add a trend chart when at least three observations make change over time meaningful. Do not use a plot for two variants or a paragraph that needs context. See [Representations](representations.md).

## Pick the producer before the card

1. Name the measurement source, unit, sample timestamp, producer, and refresh trigger. Preserve the producer's timestamp, including when it is old.
2. On a tstack board, configure `stats` in the seat's `state/board.json` and use its existing header cards. Do not duplicate them in another dashboard.
3. For a standalone region, claim `region/<work>/manifest`. Put the stat note on the left and its chart on the right. Keep the source link and timestamp visible.
4. Run `layout.check` after initial placement, then hand layout ownership to `user`. Later updates omit `frame`, `size`, and layout helpers.

The tstack engine reads configured JSON files only. `stats` entries use `name`, a seat-relative `file` with no `..`, and optional `stale_after`. The project producer, not the renderer, writes each file. There are no stat plugins, command runners, or network adapters in the engine. An external producer can obtain data elsewhere and publish the JSON file. Its credentials and scheduling remain outside the board.

A stat file requires finite numeric `value` and UTC ISO-8601 `at`. Optional fields are `unit`, `label`, `target`, numeric `series`, and `good: "up"` or `"down"`. The engine derives delta from the latest two points and uses the latest 60 points for its sparkline. Missing, unreadable, and stale cards stay visibly marked. See [tstack's stat schema](https://github.com/twaldin/tstack/blob/main/docs/reference.md#project-config).

## Keep the region current

Use `region/<work>`, `region/<work>/manifest`, `region/<work>/stat/<metric>`, and `region/<work>/trend/<metric>`. Use the same chart path and object keys on every refresh. An image tile reloads when its file changes.

For a continuing measurement, create each tile, the manifest, and the group with `expires: null`. The manifest must name the producer, source file, sample cadence, stale threshold, refresh owner, and trigger. Standing does not mean unattended forever. If no producer or refresher owns the region, use task evidence with `expiresIn: "1d"` instead.

Refresh after the producer publishes, not when a number is convenient. Keep failed reads visible as unavailable or stale, without replacing the last sample timestamp with now. Write source JSON and chart files atomically where practical. Do not derive a current value from a screenshot or an old readout.

When measurement stops, remove your stat and chart tiles, group, manifest, and generated chart, or hand the retained region to a named successor. Do not delete the producer's source data as board cleanup. Engine-managed `tstack/*` cards remain the renderer's responsibility.

## Worked example: publish a producer's measurement

Prerequisites: Python with `easl_sdk`, an already running scratch easld selected by `EASL_SOCKET`, and `EASL_BOARD_ID`. Set `EASL_BOARD_ROOT` to that scratch board's host-local root, `STAT_FILE` to a real stat JSON file in the schema above with at least three series points, and `STAT_PRODUCER` to its actual producing job or script name. Set `STAT_REFRESH` to its real publication cadence and stale threshold. This is a standalone region, not an addition to `tstack/*`. It publishes one source read; it does not install a watcher.

```python
import json, os
from pathlib import Path
from easl_sdk import canvas

base = "region/live-metric"
keys = [base, f"{base}/manifest", f"{base}/stat/value", f"{base}/trend/value"]
assert not any(o.get("props", {}).get("key") in keys
	for o in canvas.board.get()["objects"]), "Choose an unused slug"
source = Path(os.environ["STAT_FILE"]).resolve()
data = json.loads(source.read_text())
series = data["series"][-60:]
assert len(series) >= 3, "Use a stat alone until there are three points"
chart = Path(os.environ["EASL_BOARD_ROOT"]) / "out/live-metric.svg"
chart.parent.mkdir(parents=True, exist_ok=True)
low, high = min(series), max(series)
points = " ".join(f"{24 + i * 592 / (len(series) - 1):.1f},{210 - (v - low) * 180 / (high - low or 1):.1f}" for i, v in enumerate(series))
chart.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="640" height="240"><rect width="640" height="240" fill="#102033"/><polyline fill="none" stroke="#7dd3fc" stroke-width="3" points="{points}"/></svg>')
markdown = f"# {data.get('label', 'Measured value')}\n\n{data['value']} {data.get('unit', '')}\n\nDelta: {series[-1] - series[-2]:+g}\n\nSampled: {data['at']}\n\nSource: `{source}`"
if "target" in data:
	markdown += f"\n\nTarget: {data['target']}, good direction: {data.get('good', 'up')}"
owner = "agent:" + os.environ["EASL_TILE_ID"] if os.environ.get("EASL_TILE_ID") else "script:stats-publisher"
manifest = f"""- Purpose: Show the producer's latest metric and observation-order trend.
- Layout owner: {owner}
- Member keys: {', '.join(keys)}
- Sources of truth: {source}; producer {os.environ['STAT_PRODUCER']}.
- Refresh trigger: Manual republish after a sample from {os.environ['STAT_PRODUCER']}; source cadence {os.environ['STAT_REFRESH']}. No refresher is installed.
- Lifetimes: All objects 1d; this invocation owns cleanup at task end.
"""
result = canvas.object.batch(ops=[
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[1], "markdown": manifest}}},
	{"method": "object.create", "params": {"type": "note", "expiresIn": "1d", "props": {"key": keys[2], "title": "Latest source sample", "markdown": markdown}}},
	{"method": "object.create", "params": {"type": "image", "expiresIn": "1d", "frame": {"w": 640, "h": 296}, "props": {"key": keys[3], "path": str(chart), "caption": f"Observation order, {low:g} to {high:g}; sampled {data['at']}"}}},
	{"method": "layout.stack", "params": {"ids": ["$0", "$1", "$2"], "direction": "row", "gap": 48}},
	{"method": "object.create", "params": {"type": "group", "expiresIn": "1d", "props": {"key": base, "title": "Live metric", "members": ["$0", "$1", "$2"]}}},
])
ids = [result["results"][i]["object"]["id"] for i in (0, 1, 2, 4)]
check = canvas.layout.check(ids=ids)
assert not check["overlaps"], check
canvas.object.update(id=ids[0], props={"markdown": manifest.replace(f"Layout owner: {owner}", "Layout owner: user")})
```

This chart spaces samples by observation order, not elapsed time. The scalar `series` schema has no per-point timestamps. The explicit image dimensions avoid SVG size measurement, which requires a viewer. Creation works headlessly, not as visual proof. For a later sample, rebuild the same SVG, find each tile by key and update its id without layout fields. A missing tile requires a new claim and lifetime. Switch all objects to `expires: null` only after a real refresher is scheduled and named in the manifest. That refresher must mark late or failed source reads.
