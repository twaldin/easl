#!/usr/bin/env python3
"""A board for performance runs, written straight into a development home (docs/testing.md,
"Performance benchmark").

    python3 scripts/perf-board.py <home> <root> [--seed 7] [--arrows 84] [--labels 65] [--terminals]
    python3 scripts/perf-board.py <home> <root> --replica <sanitized.json> [--arrows N] [--labels N]

Synthetic (default): the shape of a real agent-driven board (docs/design/next.md, "Performance and
monitoring"), from a fixed seed: 112 html tiles in 16 grouped columns (pages of 0.5–3 KB, one of
311 KB, 18 with a script, 17 with `state`), 56 notes in 8 groups, 49 text shapes (column headers,
legend groups), 84 `avoid` arrows (65 labelled: note→note, html→html, one html→image), 2 code
tiles, a browser on a local page and an image. `--terminals` adds a terminal printing every 80 ms
and an idle shell. `--replica` instead re-roots a board from scripts/perf-sanitize.py (terminals
dropped, so the copy runs no commands). `--arrows`/`--labels` keep only that many arrows/labels
(arrows 0/42/84 and labels on/off probe how routing scales).

`<root>` (created) is the board's directory; the board file is `<home>/boards/<id>.json`, the id
easl derives from the root's path, so `scripts/dev.sh start <root>` with `EASL_DEV_HOME=<home>`
opens it. Prints the board id.
"""
import argparse
import hashlib
import json
import os
import random
import struct
import sys
import zlib

TITLE = 32.0  # GroupSpec.titleHeight
PAD = 24.0  # GroupSpec.defaultPadding
DATE = "2026-01-01T00:00:00Z"
WORDS = ("status review deploy queue build ticket owner metric latency retry budget sprint signal draft merge "
         "branch release design vendor import export rollout cohort funnel survey backlog incident alert").split()


def board_id(root):
    """`BoardStore.pathID`: brd_ + 20 hex digits of SHA-256 of the root's path."""
    return "brd_" + hashlib.sha256(os.path.normpath(root).encode()).hexdigest()[:20]


class Gen:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.objects = []
        self.z = 0.0
        self.serial = 0

    def oid(self):
        self.serial += 1
        alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        return "obj_01PERF" + "".join(self.rng.choice(alphabet) for _ in range(12)) + f"{self.serial:04d}"

    def words(self, lo, hi):
        return " ".join(self.rng.choice(WORDS) for _ in range(self.rng.randint(lo, hi)))

    def add(self, type_, frame, props, z=None):
        self.z += 1
        o = {"id": self.oid(), "type": type_, "frame": dict(zip("xywh", frame)), "z": self.z if z is None else z, "rev": 1,
             "createdBy": {"kind": "agent", "tile": "obj_01PERFAGENT0000000000000"}, "createdAt": DATE, "updatedAt": DATE,
             "props": props}
        self.objects.append(o)
        return o

    def group(self, members, title, flow=None):
        xs = [m["frame"]["x"] for m in members]
        ys = [m["frame"]["y"] for m in members]
        x2 = [m["frame"]["x"] + m["frame"]["w"] for m in members]
        y2 = [m["frame"]["y"] + m["frame"]["h"] for m in members]
        frame = (min(xs) - PAD, min(ys) - PAD - TITLE, max(x2) - min(xs) + 2 * PAD, max(y2) - min(ys) + 2 * PAD + TITLE)
        props = {"members": [m["id"] for m in members], "title": title}
        if flow:
            props["flow"] = flow
        # Groups sit below their members.
        return self.add("group", frame, props, z=-1000.0 + len(self.objects) / 1000)


def page(rng, size, script, n):
    """A card page of about `size` bytes."""
    rows = []
    body_size = 0
    while body_size < size - 260:
        row = f"<tr><td>{' '.join(rng.choice(WORDS) for _ in range(3))}</td><td>{rng.randint(1, 999)}</td></tr>"
        rows.append(row)
        body_size += len(row)
    js = f"<script>document.getElementById('n').textContent='{n}'</script>" if script else ""
    return (f"<!doctype html><html><head><style>body{{font:13px -apple-system;margin:10px}}td{{padding:2px 6px}}</style></head>"
            f"<body><h3 id='n'>card {n}</h3><table>{''.join(rows)}</table>{js}</body></html>")


def page_height(html):
    return 26 + 60 + 22 * html.count("<tr>")


def png(path, w=320, h=200):
    raw = b"".join(b"\x00" + b"".join(bytes((x * 255 // w, y * 255 // h, 160)) for x in range(w)) for y in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def synthetic(root, seed, terminals):
    g = Gen(seed)
    rng = g.rng
    # Files the code, browser and image tiles show.
    with open(os.path.join(root, "service.py"), "w") as f:
        f.write("".join(f"def handler_{i}(event):\n    return {{'status': {i}, 'ok': True}}\n\n" for i in range(120)))
    with open(os.path.join(root, "page.html"), "w") as f:
        f.write("<!doctype html><title>local</title><h1>local page</h1>" + "<p>row</p>" * 50)
    png(os.path.join(root, "chart.png"))

    # 16 columns of 7 html cards, each column a group with a header text shape.
    html, html_groups, headers = [], [], []
    sizes = [rng.choice([600, 900, 1200, 1500, 1500, 1800, 2100, 2500, 2900, 3200]) for _ in range(112)]
    sizes[37] = 311_000
    scripted = set(rng.sample(range(112), 18))
    stateful = set(rng.sample(range(112), 17))
    for c in range(16):
        x = -900 + c * 650
        header = g.add("shape", (x, -1000, 560, 40), {"kind": "text", "text": f"lane {c} {g.words(1, 3)}"})
        headers.append(header)
        y = -940
        column = [header]
        for r in range(7):
            n = c * 7 + r
            content = page(rng, sizes[n], n in scripted, n)
            h = min(page_height(content), 640)
            props = {"html": content, "title": f"card {n} {g.words(1, 2)}", "key": f"perf:card:{n}"}
            if n in stateful:
                props["state"] = {"count": n, "open": n % 2 == 0}
            tile = g.add("html", (x, y, 560, h), props)
            html.append(tile)
            column.append(tile)
            y += h + 40
        html_groups.append(g.group(column, f"lane {c}", flow="down"))

    # 8 groups of 7 notes (2 columns × 4 rows of notes each), spread over the board below.
    notes, note_groups = [], []
    for k in range(8):
        gx = -900 + (k % 4) * 2600
        gy = 3400 + (k // 4) * 5600
        members = []
        for i in range(7):
            text = "\n".join(f"- {g.words(2, 6)}" for _ in range(rng.randint(2, 7)))
            h = 60 + 22 * text.count("\n")
            note = g.add("note", (gx + (i % 2) * 420, gy + (i // 2) * 420, 320, h), {"markdown": f"## {g.words(1, 3)}\n{text}", "title": g.words(1, 2)})
            members.append(note)
            notes.append(note)
        note_groups.append(g.group(members, f"area {k}", flow="right" if k % 2 else None))

    # 33 more text shapes: legends of 4 (or 3) below each note group, and 3 loose.
    legend_counts = [4, 4, 4, 4, 4, 4, 3, 3]
    for k, count in enumerate(legend_counts):
        frame = note_groups[k]["frame"]
        members = [g.add("shape", (frame["x"] + 30 + i * 200, frame["y"] + frame["h"] + 160, 180, 30), {"kind": "text", "text": g.words(1, 3)})
                   for i in range(count)]
        g.group(members, f"legend {k}")
    for i in range(3):
        g.add("shape", (9700, 2400 + i * 60, 260, 30), {"kind": "text", "text": g.words(2, 4)})

    # Other tiles.
    g.add("code", (9700, -1000, 720, 520), {"path": "service.py", "range": {"start": 1, "end": 40}})
    g.add("code", (9700, -400, 720, 520), {"path": "service.py", "range": {"start": 200, "end": 260}})
    g.add("browser", (9700, 200, 900, 600), {"url": "file://" + os.path.join(root, "page.html")})
    image = g.add("image", (9700, 900, 340, 236), {"path": "chart.png"})

    # 84 avoid arrows: 65 note→note (5 inside each note group, 25 across groups), 18 html→html
    # between neighbouring columns, 1 html→image. The first 65 carry labels.
    pairs = []
    for k in range(8):
        group_notes = notes[k * 7:(k + 1) * 7]
        for i in range(5):
            pairs.append((group_notes[i], group_notes[min(i + 1 + rng.randint(0, 1), 6)]))
    while len(pairs) < 65:
        a, b = rng.sample(notes, 2)
        if notes.index(a) // 7 != notes.index(b) // 7:
            pairs.append((a, b))
    for i in range(18):
        c = rng.randrange(15)
        pairs.append((html[c * 7 + rng.randrange(7)], html[(c + 1) * 7 + rng.randrange(7)]))
    pairs.append((html[rng.randrange(112)], image))
    for i, (a, b) in enumerate(pairs):
        props = {"from": {"object": a["id"]}, "to": {"object": b["id"]}, "route": "avoid"}
        if i < 65:
            props["label"] = g.words(1, 3)
        g.add("arrow", (0, 0, 0, 0), props)

    if terminals:
        g.add("terminal", (9700, 1300, 640, 360), {"cwd": root, "command": ["sh", "-c", "while :; do printf '\\r%s' $RANDOM; sleep 0.08; done"], "title": "stream"})
        g.add("terminal", (9700, 1800, 640, 360), {"cwd": root, "command": ["sh"], "title": "idle"})
    return g.objects


def replica(path):
    source = json.load(open(path))
    objects = source["objects"] if isinstance(source["objects"], list) else list(source["objects"].values())
    return [o for o in objects if o["type"] != "terminal"], source.get("format")


def trim(objects, arrows, labels):
    """Keeps the first `arrows` arrows (by id) and the first `labels` labels among them."""
    kept_arrows = sorted((o for o in objects if o["type"] == "arrow"), key=lambda o: o["id"])[:arrows]
    keep = {o["id"] for o in kept_arrows}
    out, labelled = [], 0
    for o in objects:
        if o["type"] == "arrow":
            if o["id"] not in keep:
                continue
            if "label" in o["props"]:
                if labelled >= labels:
                    o = dict(o, props={k: v for k, v in o["props"].items() if k != "label"})
                else:
                    labelled += 1
        out.append(o)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("home")
    ap.add_argument("root")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--replica")
    ap.add_argument("--arrows", type=int, default=10_000)
    ap.add_argument("--labels", type=int, default=10_000)
    ap.add_argument("--terminals", action="store_true")
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    os.makedirs(root, exist_ok=True)
    os.makedirs(os.path.join(args.home, "boards"), exist_ok=True)
    fmt = 2
    if args.replica:
        objects, fmt = replica(args.replica)
    else:
        objects = synthetic(root, args.seed, args.terminals)
    objects = trim(objects, args.arrows, args.labels)
    bid = board_id(root)
    board = {"id": bid, "root": root, "revision": 1, "objects": objects}
    if fmt is not None:
        board["format"] = fmt
    with open(os.path.join(args.home, "boards", f"{bid}.json"), "w") as f:
        json.dump(board, f, sort_keys=True)
    # A first launch would open Help › Get Started over the board.
    with open(os.path.join(args.home, "get-started.json"), "w") as f:
        f.write('{"dismissed":true}')
    kinds = {}
    for o in objects:
        kinds[o["type"]] = kinds.get(o["type"], 0) + 1
    print(bid, json.dumps(kinds, sort_keys=True), file=sys.stderr)
    print(bid)


if __name__ == "__main__":
    main()
