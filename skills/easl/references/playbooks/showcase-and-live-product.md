# Show the running product and captured evidence

Use this for a product walkthrough, a demo, or a review of screens and behavior. Use [acceptance gates](acceptance-gates.md) for measured pass criteria. A live browser shows the running product, not proof of what happened at a particular time.

## Place the region

1. Choose `<work>` and inspect the board and `region/<work>/manifest` before claiming space. Never claim another owner's region or any `tstack/*` key.
2. Put `region/<work>/manifest` above the content. Put `region/<work>/live` at the left, 960 by 700 points. Put `region/<work>/capture/<screen>` screenshots in a column to its right. Put `region/<work>/clip/<scenario>` clips below the browser, with capture time, build, and scenario in their captions or adjacent notes. Capture every screen in the agreed review scope, not only the landing page.
3. Group all members under `region/<work>`. The manifest records Purpose, Layout owner, Member keys, Sources of truth, Refresh trigger, and Lifetimes.

Use browser tiles for the running product URL, `video` tiles for clip files on the board host, and image tiles for screenshots. See [browser controls](../browser.md) and [image and video props](../api.md#objects) rather than embedding another browser driver.

## Keep evidence distinct from live state

- Source the browser URL from the running service or deployment record. Record the environment and build identity. A reachable URL alone does not establish which revision was deployed.
- Source screenshots and clips from actual captures. Keep their capture time and build identity. Do not overwrite a capture file while calling it historical evidence.
- Give the browser, screenshots, clips, group, and manifest `expiresIn: "1d"` at creation. Delete task evidence at review end unless explicitly retained.
- For a standing product region, use `expires: null` for each retained member, group, and manifest. Name its producer and refresh trigger in the manifest. Captures remain dated even in a standing region.
- Reload the browser after the running build changes. Add new capture keys for a new capture round. Remove superseded task captures after the review.

The initial layout owner is `agent:<EASL_TILE_ID>` until a clean `layout.check`, then `user`. Content refreshes use update-by-id without `frame`, `size` or layout helpers. Respect the user's moves. At handoff, name the successor or delete your members, manifest and group.

## Create a headless review example

Prerequisites: Python 3, installed `easl_sdk`, and `EASL_SOCKET`, `EASL_BOARD_ID`, and `EASL_TILE_ID` targeting a scratch server. Set `PRODUCT_URL` to an existing running product. Set `SCREENSHOT_PATH` to an existing absolute screenshot path accessible to the server. Set `CAPTURE_IDENTITY` to its actual capture time, build, and screen name. This example covers one screen. Add a capture member per remaining screen before calling a full-screen review complete. No GUI or new file is required.

```sh
python3 - <<'PY'
import os
from easl_sdk import Easl
c = Easl()
w = "demo-product-review"
g = f"region/{w}"
assert not c.object.find(key_prefix=g)["objects"], "Choose an unclaimed work slug"
specs = [
	("live", "browser", {"url": os.environ["PRODUCT_URL"], "title": "Running product, not captured proof"}, {"w": 960, "h": 700}),
	("capture/screen-1", "image", {"path": os.environ["SCREENSHOT_PATH"], "caption": os.environ["CAPTURE_IDENTITY"]}, {"w": 640, "h": 480}),
]
keys = [f"{g}/{s[0]}" for s in specs]
def manifest(owner):
	return (f"Purpose: Review the running product and a dated capture\n\nLayout owner: {owner}\n\n"
		f"Member keys: {', '.join([g+'/manifest', *keys])}\n\nSources of truth: {os.environ['PRODUCT_URL']}; "
		f"{os.environ['SCREENSHOT_PATH']}; {os.environ['CAPTURE_IDENTITY']}\n\n"
		"Refresh trigger: Running build changes; new capture round\n\nLifetimes: All task evidence expiresIn 1d; delete at review end")
m = c.object.create(type="note", props={"key": g+"/manifest", "markdown": manifest("agent:"+os.environ["EASL_TILE_ID"])}, size="fit", expires_in="1d")["object"]["id"]
ids = [c.object.create(type=t, props={**p, "key": k}, frame=f, expires_in="1d")["object"]["id"] for k, (_, t, p, f) in zip(keys, specs)]
c.object.create(type="group", props={"key": g, "title": "Product review", "members": [m, *ids]}, expires_in="1d")
c.layout.grid(cells=[{"id": m, "row": 0, "col": 0}, *[{"id": v, "row": 1, "col": i} for i, v in enumerate(ids)]], col_gap=60, row_gap=60)
check = c.layout.check(ids=[m, *ids])
assert not any(v for k, v in check.items() if k not in ("approximate", "hints")), check
c.object.update(id=m, props={"markdown": manifest("user")}, size="fit")
PY
```
