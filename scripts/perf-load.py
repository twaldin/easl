#!/usr/bin/env python3
"""Replays an agent's write pattern over an easl socket (docs/testing.md, "Performance benchmark").

    python3 scripts/perf-load.py serial  [--variant N] [--html 76] [--shapes 25] [--poll 10]
    python3 scripts/perf-load.py batch   [--variant N] …
    python3 scripts/perf-load.py poll    --duration 60 [--poll 10]

The burst is what a mission-control reconcile sends (docs/design/next.md, "Performance and
monitoring"): for `--html` html tiles a new page (`object.measure` it, then `object.update` with the
page and its measured height; frames change, so their groups refit), `--shapes` text shape edits
and one new html tile. `serial` sends every write as its own RPC, one at a time with no pacing;
`batch` measures first, then sends the writes as one `object.batch`. Both keep polling `board.get`
every `--poll` seconds on a second connection, as the agent does; `poll` only polls. `--variant`
picks the page contents (alternate 0 and 1 so frames change on every run); the created tile is
deleted after the burst is timed.

Prints one JSON object: burst wall time, per-method RPC latency (n, p50, p95, max ms), the events
the burst caused, and the poll latencies. EASL_SOCKET names the socket (scripts/dev.sh sets it).
"""
import argparse
import json
import os
import socket
import statistics
import sys
import threading
import time

WORDS = "status review deploy queue build ticket owner metric latency retry budget sprint signal draft merge".split()


class Conn:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.file = self.sock.makefile("rb")
        self.next = 0

    def call(self, method, params=None):
        self.next += 1
        rid = str(self.next)
        self.sock.sendall((json.dumps({"id": rid, "method": method, "params": params or {}}) + "\n").encode())
        while True:
            line = self.file.readline()
            if not line:
                raise RuntimeError("socket closed")
            reply = json.loads(line)
            if reply.get("id") == rid:
                if not reply.get("ok"):
                    raise RuntimeError(f"{method}: {reply.get('error')}")
                return reply["result"]


def stats(values):
    if not values:
        return {"n": 0}
    ordered = sorted(values)
    return {"n": len(values), "p50": round(statistics.median(ordered), 1),
            "p95": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))], 1), "max": round(ordered[-1], 1)}


def page(n, variant):
    """A card whose length (so height) depends on the variant."""
    rows = 4 + (n * 7 + variant * 5) % 9 + (3 if variant % 2 else 0)
    body = "".join(f"<tr><td>{WORDS[(n + i + variant) % len(WORDS)]} {i}</td><td>{(n * 31 + i * variant) % 997}</td></tr>" for i in range(rows))
    return (f"<!doctype html><html><head><style>body{{font:13px -apple-system;margin:10px}}td{{padding:2px 6px}}</style></head>"
            f"<body><h3>card {n} v{variant}</h3><table>{body}</table></body></html>")


class Poller(threading.Thread):
    """`board.get` every `interval` seconds on its own connection."""

    def __init__(self, path, interval):
        super().__init__(daemon=True)
        self.conn = Conn(path)
        self.interval = interval
        self.latencies = []
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            start = time.perf_counter()
            self.conn.call("board.get")
            self.latencies.append((time.perf_counter() - start) * 1000)
            self.stop.wait(self.interval)


class Events(threading.Thread):
    """Counts `object.*` events by kind and object type."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.sock.sendall(b'{"id":"s","method":"events.subscribe","params":{}}\n')
        self.file = self.sock.makefile("rb")
        self.counts = {}
        self.bytes = 0

    def run(self):
        for line in self.file:
            message = json.loads(line)
            if "event" not in message:
                continue
            data = message.get("data") or {}
            kind = (data.get("object") or {}).get("type", "")
            key = f"{message['event']}:{kind}" if kind else message["event"]
            self.counts[key] = self.counts.get(key, 0) + 1
            self.bytes += len(line)


def targets(conn, html_count, shape_count):
    objects = conn.call("board.get")["objects"]
    # Tiles inside groups, as the agent's cards are, so their groups refit.
    members = set()
    for o in objects:
        if o["type"] == "group":
            members.update(o["props"].get("members", []))
    html = sorted((o for o in objects if o["type"] == "html" and o["id"] in members and o["frame"]["h"] < 900), key=lambda o: o["id"])
    shapes = sorted((o for o in objects if o["type"] == "shape" and o["props"].get("kind") == "text"), key=lambda o: o["id"])
    return html[:html_count], shapes[:shape_count]


def burst(path, mode, variant, html_count, shape_count, poll):
    conn = Conn(path)
    html, shapes = targets(conn, html_count, shape_count)
    events = Events(path)
    events.start()
    poller = Poller(path, poll) if poll > 0 else None
    latency = {}

    def timed(method, params):
        start = time.perf_counter()
        result = conn.call(method, params)
        latency.setdefault(method, []).append((time.perf_counter() - start) * 1000)
        return result

    time.sleep(0.3)  # the subscription is in place
    if poller:
        poller.start()
    start = time.perf_counter()
    ops = []
    # A distinct page per tile (and variant): the same page measured twice comes from easl's
    # 30 s measure cache, which an agent's distinct cards never hit.
    for n, o in enumerate(html):
        content = page(n, variant)
        size = timed("object.measure", {"type": "html", "props": {"html": content}, "width": o["frame"]["w"]})
        update = {"id": o["id"], "props": {"html": content}, "frame": {"h": size["frame"]["h"] if "frame" in size else size["h"]}}
        if mode == "serial":
            timed("object.update", update)
        else:
            ops.append({"method": "object.update", "params": update})
    for i, o in enumerate(shapes):
        update = {"id": o["id"], "props": {"text": f"{WORDS[(i + variant) % len(WORDS)]} {variant} {i}"}}
        if mode == "serial":
            timed("object.update", update)
        else:
            ops.append({"method": "object.update", "params": update})
    create = {"type": "html", "props": {"html": page(999, variant), "title": "perf-load card"}, "frame": {"x": -900, "y": -1400, "w": 560, "h": 200}}
    if mode == "serial":
        created = timed("object.create", create)["object"]["id"]
    else:
        ops.append({"method": "object.create", "params": create})
        result = timed("object.batch", {"ops": ops})
        created = result["results"][-1]["object"]["id"]
    wall = time.perf_counter() - start
    if poller:
        poller.stop.set()
    time.sleep(0.5)  # trailing events
    conn.call("object.delete", {"id": created})
    return {"mode": mode, "variant": variant, "html": len(html), "shapes": len(shapes), "wall_s": round(wall, 2),
            "rpc": {m: stats(v) for m, v in latency.items()},
            "writes": sum(len(v) for m, v in latency.items() if m != "object.measure"),
            "events": dict(sorted(events.counts.items())), "event_count": sum(events.counts.values()), "event_bytes": events.bytes,
            "poll": stats(poller.latencies) if poller else {"n": 0}}


def poll_only(path, duration, poll):
    poller = Poller(path, poll)
    poller.start()
    time.sleep(duration)
    poller.stop.set()
    poller.join(timeout=30)
    return {"mode": "poll", "duration_s": duration, "poll": stats(poller.latencies)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["serial", "batch", "poll"])
    ap.add_argument("--variant", type=int, default=0)
    ap.add_argument("--html", type=int, default=76)
    ap.add_argument("--shapes", type=int, default=25)
    ap.add_argument("--poll", type=float, default=10)
    ap.add_argument("--duration", type=float, default=60)
    ap.add_argument("--socket", default=os.environ.get("EASL_SOCKET"))
    args = ap.parse_args()
    if not args.socket:
        sys.exit("no socket: set EASL_SOCKET or pass --socket")
    if args.mode == "poll":
        result = poll_only(args.socket, args.duration, args.poll)
    else:
        result = burst(args.socket, args.mode, args.variant, args.html, args.shapes, args.poll)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
