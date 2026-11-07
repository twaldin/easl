# Keep a rolling ship log

Use this to answer what merged, deployed, or shipped within a named window. Do not use it for current work, a release plan, or an unbounded archive.

## Build the region from delivery records

1. Choose `<work>` and check the board and `region/<work>/manifest` for an existing owner. Do not claim another owner's region or `tstack/*`.
2. Put `region/<work>/manifest` above `region/<work>/log`, a 1000-point-wide note. Show newest items first with event type, UTC event date, revision, and source link. Keep separate merged and deployed sections. A merge is not a deployment.
3. Put `region/<work>/sources` to the right, 480 points wide, with source queries, the observation time, window boundaries, and any unavailable deployment feed. Group these tiles under `region/<work>`.
4. Keep only the chosen rolling window, normally seven days. Preserve the durable history in the source system, not by growing the board.

Use merged PR records for merge dates and links. Use successful deployment records for deploy dates, environment, deployed revision, and deployment link. Release records prove release publication, not deployment. If deployment records are absent, say that deployment is unverified. Never infer deployment from a merged PR, a green build, or a reachable site.

## Refresh without moving the log

For a standing log, give every non-terminal tile, group, and manifest `expires: null`. Name the producer, source query, and refresh cadence in the manifest. Refresh after a recorded merge or deployment and at the window boundary so old entries disappear. Display the last successful observation time. A failed query leaves the previous observation visibly dated, not newly current.

For a one-off delivery review, give all non-terminal objects `expiresIn: "1d"` and delete them at task end unless retained. Initially record `agent:<EASL_TILE_ID>` as Layout owner. Hand layout to `user` only after a clean `layout.check`. Later, find each object by key and update its id without `frame`, `size` or layout helpers. If it expired, claim a new region with explicit lifetimes. Hand off the standing producer, or delete your region when you stop maintaining it.

## Create a source-backed merge log

Prerequisites: Python 3, installed `easl_sdk`, authenticated `gh`, and `EASL_SOCKET`, `EASL_BOARD_ID`, and `EASL_TILE_ID` targeting a scratch server. Set `GH_REPO` to the repository in `owner/name` form. This one-off example queries merges only and does not claim deployments or install a refresher. No new file is required.

```sh
python3 - <<'PY'
import json, os, subprocess
from datetime import datetime, timedelta, timezone
from easl_sdk import Easl
now = datetime.now(timezone.utc)
start = now - timedelta(days=7)
repo = os.environ["GH_REPO"]
query = f"merged:>={start.date()}"
rows = json.loads(subprocess.check_output(["gh", "pr", "list", "--repo", repo, "--state", "merged", "--search", query, "--limit", "1000", "--json", "title,url,mergedAt,mergeCommit"], text=True))
assert len(rows) < 1000, "Paginate the source before claiming complete coverage"
rows = sorted((r for r in rows if start <= datetime.fromisoformat(r["mergedAt"].replace("Z", "+00:00")) <= now), key=lambda r: r["mergedAt"], reverse=True)
body = "# Merged in the last seven days\n\n" + "\n".join(f"- {r['mergedAt']} [{r['title']}]({r['url']}) `{(r['mergeCommit'] or {}).get('oid', 'revision unavailable')}`" for r in rows)
body += "\n\n" + ("" if rows else "No merges in this window.\n\n") + "Deployment status unverified. No deployment source queried."
c = Easl()
w = "demo-ship-log"
g = f"region/{w}"
assert not c.object.find(key_prefix=g)["objects"], "Choose an unclaimed work slug"
keys = [g+"/log", g+"/sources"]
source = f"Repository: {repo}\n\nQuery: gh pr list --state merged --search {query}\n\nWindow: {start.isoformat()} to {now.isoformat()}\n\nObserved: {now.isoformat()}\n\nDeployment feed: not configured"
def manifest(owner):
	return (f"Purpose: Seven-day delivery log\n\nLayout owner: {owner}\n\nMember keys: {', '.join([g+'/manifest', *keys])}\n\n"
		f"Sources of truth: GitHub merged PR records for {repo}\n\nRefresh trigger: Manual republish after merges or the window boundary; no refresher installed\n\nLifetimes: All non-terminal task evidence expiresIn 1d; this invocation owns cleanup")
m = c.object.create(type="note", props={"key": g+"/manifest", "markdown": manifest("agent:"+os.environ["EASL_TILE_ID"])}, size="fit", frame={"w": 1000}, expires_in="1d")["object"]["id"]
ids = [c.object.create(type="note", props={"key": k, "markdown": text}, size="fit", frame={"w": width}, expires_in="1d")["object"]["id"] for k, text, width in [(keys[0], body, 1000), (keys[1], source, 480)]]
c.object.create(type="group", props={"key": g, "title": "Seven-day ship log", "members": [m, *ids]}, expires_in="1d")
c.layout.grid(cells=[{"id": m, "row": 0, "col": 0}, {"id": ids[0], "row": 1, "col": 0}, {"id": ids[1], "row": 1, "col": 1}], col_gap=60, row_gap=60)
check = c.layout.check(ids=[m, *ids])
assert not any(v for k, v in check.items() if k not in ("approximate", "hints")), check
c.object.update(id=m, props={"markdown": manifest("user")}, size="fit")
PY
```

For later observations, find each [object by key](../api.md) and update its id without layout fields. If it expired, claim a new region with explicit lifetimes. Switch all non-terminal objects to `expires: null` only after a real refresher is scheduled and named in the manifest.
