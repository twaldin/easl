#!/usr/bin/env python3
"""The performance loop: runs the benchmark scenarios against one or more easl bundles, `--runs`
times interleaved, and prints medians with the targets as pass/fail (docs/testing.md,
"Performance benchmark").

    python3 scripts/perf-loop.py --app base=/tmp/a.app --app fix=/tmp/b.app [--board synthetic|<sanitized.json>]
        [--scenarios visible-serial,hidden-serial,visible-batch,poll-idle] [--runs 3] [--out rows.jsonl]

Bundles are frozen release builds (`EASL_BUNDLE_APP=/tmp/a.app scripts/bundle.sh release`). Each
run starts every bundle in turn (the order alternating between runs) on a development home of its
own (a new scratch directory under `--tmp`, default /tmp, deleted when the bundle stops; nothing
else is ever deleted, so an existing `EASL_DEV_HOME` is never touched) holding the board from
scripts/perf-board.py, shows it at 100% over the densest html area, then runs the scenarios:

- `visible-serial` / `hidden-serial`: scripts/perf-load.py's serial burst with the window shown
  (on the testing Space) or minimized;
- `visible-batch`: the same writes as one `object.batch`;
- `poll-idle`: 60 s of `board.get` every 10 s, nothing else;
- `pan-zoom`: pans 3000 pt across the html cards and back, then zooms out three steps and in
  again, twice (parked HTML pages: `html.reuse` against `html.load` in `app.metrics`).

A row per scenario run records the app's CPU from the burst's start until it is quiet again
(`ps`), the burst's wall time and RPC latencies, and the `DevPerf` span around it (main thread
busy time, the longest stretch it didn't sleep, and `route.board` routings), plus `app.metrics`
where the bundle has it. Needs yabai and a virtual screen (`EASL_DEV_DISPLAY`) like scripts/dev.sh.
"""
import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
YABAI = os.environ.get("YABAI") or os.path.expanduser("~/Applications/Yabai.app/Contents/MacOS/yabai")
TARGETS = "burst CPU < 3 s, longest main stretch < 100 ms, <= 2 board routings per burst; idle poll stretch < 16 ms; hidden within 2x of visible"


def sh(*args, env=None, check=True, capture=True):
    result = subprocess.run(args, env=env, check=check, capture_output=capture, text=True)
    return result.stdout if capture else ""


def cpu_seconds(pid):
    """The process's CPU time so far (`ps -o time`: [[dd-]hh:]mm:ss.cc)."""
    out = sh("/bin/ps", "-o", "time=", "-p", str(pid), check=False).strip()
    if not out:
        return None
    total = 0.0
    for part in out.replace("-", ":").split(":"):
        total = total * 60 + float(part)
    return total


class Instance:
    def __init__(self, label, app, tmp, board, display):
        self.label, self.app, self.board = label, app, board
        # Created here and owned by this run: the only directory `stop` deletes.
        self.scratch = tempfile.mkdtemp(prefix="easl-perf-loop-", dir=tmp)
        self.home, self.root = os.path.join(self.scratch, "home"), os.path.join(self.scratch, "root")
        home = self.home
        self.env = dict(os.environ, EASL_DEV_HOME=home, EASL_DEV_APP=app, EASL_DEV_DISPLAY=display,
                        EASL_DEV_PARK_SPACE=os.environ.get("EASL_DEV_PARK_SPACE", "9"), EASL_SOCKET=os.path.join(home, "easl.sock"))
        self.variant = 0
        self.pid = None
        self.window = None
        self.has_metrics = None

    def dev(self, *args, check=True):
        return sh(os.path.join(REPO, "scripts/dev.sh"), *args, env=self.env, check=check)

    def cli(self, method, params=None):
        out = sh("bun", os.path.join(REPO, "cli/easl.ts"), method, "--json", json.dumps(params or {}), env=self.env, check=False)
        try:
            return json.loads(out) if out.strip() else None
        except json.JSONDecodeError:
            return None

    def start(self):
        args = ["python3", os.path.join(REPO, "scripts/perf-board.py"), self.home, self.root]
        if self.board != "synthetic":
            args += ["--replica", self.board]
        sh(*args)
        print(f"  start {self.label}: {self.dev('start', self.root).strip()}", flush=True)
        self.pid = int(open(os.path.join(self.home, "pid")).read().strip())
        windows = json.loads(sh(YABAI, "-m", "query", "--windows"))
        self.window = next(w["id"] for w in windows if w["pid"] == self.pid)
        self.quiet(timeout=120)
        self.has_metrics = self.cli("app.metrics") is not None
        self.zoom_to_cards()

    def stop(self):
        self.dev("stop", check=False)
        shutil.rmtree(self.scratch, ignore_errors=True)

    def quiet(self, timeout=90, below=0.05, interval=1.0):
        """Waits until the app uses less than `below` of a core for two intervals in a row."""
        deadline = time.time() + timeout
        last, calm = cpu_seconds(self.pid), 0
        while time.time() < deadline:
            time.sleep(interval)
            now = cpu_seconds(self.pid)
            calm = calm + 1 if now - last < below * interval else 0
            last = now
            if calm >= 2:
                return True
        return False

    def visible(self, shown):
        if shown:
            sh(YABAI, "-m", "window", "--deminimize", str(self.window), check=False)
        else:
            sh(YABAI, "-m", "window", str(self.window), "--minimize", check=False)
        for _ in range(30):
            view = self.cli("view.get") or {}
            if view.get("visible") == shown:
                return
            time.sleep(0.2)
        raise RuntimeError(f"window never became {'visible' if shown else 'hidden'}")

    def zoom_to_cards(self):
        """100% zoom, the viewport centred on the html tiles' densest area (the first column's top)."""
        self.visible(True)
        objects = self.cli("board.get")["objects"]
        html = sorted((o["frame"] for o in objects if o["type"] == "html"), key=lambda f: (f["y"] // 2000, f["x"]))
        target = html[len(html) // 8] if html else None
        self.dev("input", "mainmenu", "View/Zoom to Fit")
        time.sleep(1)
        self.dev("input", "mainmenu", "View/Actual Size")
        time.sleep(1)
        if not target:
            return
        for _ in range(4):
            rect = self.cli("view.get")["viewport"]["rect"]
            dx = target["x"] + target["w"] / 2 - (rect["x"] + rect["w"] / 2)
            dy = target["y"] + target["h"] / 2 - (rect["y"] + rect["h"] / 2)
            if abs(dx) < 200 and abs(dy) < 200:
                break
            steps = 60
            # A precise scroll moves the content with the fingers: the viewport goes the other way.
            self.dev("input", "scroll", "700", "400", f"{-dx / steps:.1f}", f"{-dy / steps:.1f}", "--repeat", str(steps))
            time.sleep(1)
        self.quiet(timeout=60)

    def span_begin(self):
        self.log_offset = os.path.getsize(os.path.join(self.home, "app.log"))
        self.dev("input", "perf", "900000")

    def span_end(self):
        self.dev("input", "perf", "1")
        time.sleep(0.5)
        with open(os.path.join(self.home, "app.log"), errors="replace") as f:
            f.seek(self.log_offset)
            lines = [l for l in f.read().splitlines() if "DevPerf: idle idle" in l]
        return parse_devperf(lines[0]) if lines else {}

    def metrics(self, reset=False):
        if not self.has_metrics:
            return None
        return self.cli("app.metrics", {"reset": True} if reset else {})


def pan_zoom(inst):
    """Pans the view 3000 pt right and back, then zooms out three steps and back in, twice; the
    window is restored to where it started."""
    started = time.time()
    steps = 60
    for _ in range(2):
        for dx in (-3000, 3000):
            inst.dev("input", "scroll", "700", "400", f"{dx / steps:.1f}", "0", "--repeat", str(steps))
            time.sleep(1)
        for item in ["View/Zoom Out"] * 3 + ["View/Zoom In"] * 3:
            inst.dev("input", "mainmenu", item)
            time.sleep(0.7)
    return {"wall_s": round(time.time() - started, 1)}


def parse_devperf(line):
    out = {}
    m = re.search(r"main busy (\d+) ms, hitches (\d+) \(longest ([\d.]+) ms\)", line)
    if m:
        out.update(main_busy_ms=int(m.group(1)), hitches=int(m.group(2)), longest_ms=float(m.group(3)))
    m = re.search(r"route\.board=(\d+)/([\d.]+)/([\d.]+)", line)
    out.update(routings=int(m.group(1)) if m else 0, routing_ms=float(m.group(2)) if m else 0.0, routing_max_ms=float(m.group(3)) if m else 0.0)
    return out


def run_scenario(inst, name):
    shown = not name.startswith("hidden")
    inst.visible(shown)
    inst.quiet(timeout=60)
    inst.metrics(reset=True)
    inst.span_begin()
    c0 = cpu_seconds(inst.pid)
    started = time.time()
    if name == "poll-idle":
        load = json.loads(sh("python3", os.path.join(REPO, "scripts/perf-load.py"), "poll", "--duration", "60", env=inst.env))
    elif name == "pan-zoom":
        load = pan_zoom(inst)
    else:
        inst.variant += 1
        mode = "batch" if name.endswith("batch") else "serial"
        load = json.loads(sh("python3", os.path.join(REPO, "scripts/perf-load.py"), mode, "--variant", str(inst.variant % 2), env=inst.env))
    c1 = cpu_seconds(inst.pid)
    inst.quiet(timeout=180)
    settled = time.time() - started
    c2 = cpu_seconds(inst.pid)
    span = inst.span_end()
    metrics = inst.metrics()
    row = {"app": inst.label, "scenario": name, "visible": shown, "cpu_s": round(c2 - c0, 2), "cpu_during_s": round(c1 - c0, 2),
           "settled_s": round(settled, 1), **span, "load": load}
    if metrics:
        row["metrics"] = metrics
        total = lambda counter: ((metrics.get("counters") or {}).get(counter) or {}).get("total", {}).get("n", 0)
        row["html_loads"], row["html_reuses"] = total("html.load"), total("html.reuse")
    return row


def gate(name, t):
    """PASS only when every measurement the scenario's targets need is present and within them."""
    if name == "poll-idle":
        checks = [("stretch", t["longest"], lambda v: v < 16)]
    elif name == "pan-zoom":
        checks = [("stretch", t["longest"], lambda v: v < 100)]
    else:
        checks = [("cpu", t["cpu"], lambda v: v < 3), ("stretch", t["longest"], lambda v: v < 100), ("routings", t["routes"], lambda v: v <= 2)]
    missing = [n for n, v, _ in checks if v is None]
    failed = [n for n, v, ok in checks if v is not None and not ok(v)]
    if not missing and not failed:
        return "PASS"
    return "FAIL (" + ", ".join(failed + [f"{n} missing" for n in missing]) + ")"


def summarize(rows, apps, scenarios):
    def med(values):
        values = [v for v in values if v is not None]
        return round(statistics.median(values), 1) if values else None

    def rng(values):
        values = [v for v in values if v is not None]
        return f"{min(values):g}–{max(values):g}" if len(values) > 1 else ""

    table = {}
    print(f"\nmedians over runs (range); targets: {TARGETS}")
    header = f"{'app':10} {'scenario':15} {'cpu s':>14} {'wall s':>12} {'longest ms':>16} {'routings':>10} {'update p50':>11} {'poll p50':>9}  verdict"
    print(header)
    print("-" * len(header))
    for app in apps:
        for name in scenarios:
            mine = [r for r in rows if r["app"] == app and r["scenario"] == name]
            if not mine:
                continue
            cpu = [r["cpu_s"] for r in mine]
            wall = [r["load"].get("wall_s", r["load"].get("duration_s")) for r in mine]
            longest = [r.get("longest_ms") for r in mine]
            routes = [r.get("routings") for r in mine]
            upd = [r["load"].get("rpc", {}).get("object.update", r["load"].get("rpc", {}).get("object.batch", {})).get("p50") for r in mine]
            poll = [r["load"].get("poll", {}).get("p50") for r in mine]
            table[(app, name)] = dict(cpu=med(cpu), wall=med(wall), longest=med(longest), routes=med(routes), update=med(upd), poll=med(poll))
            t = table[(app, name)]
            verdict = gate(name, t)
            print(f"{app:10} {name:15} {t['cpu']!s:>6} {rng(cpu):>7} {t['wall']!s:>5} {rng(wall):>6} {t['longest']!s:>7} {rng(longest):>8} "
                  f"{t['routes']!s:>10} {t['update']!s:>11} {t['poll']!s:>9}  {verdict}")
            if name == "pan-zoom":
                print(f"{'':10} {'':15} html page loads {med([r.get('html_loads') for r in mine])}, reuses {med([r.get('html_reuses') for r in mine])}")
        hidden, visible = table.get((app, "hidden-serial")), table.get((app, "visible-serial"))
        if hidden and visible:
            ratio_wall = hidden["wall"] / visible["wall"] if hidden["wall"] and visible["wall"] else None
            ratio_upd = hidden["update"] / visible["update"] if hidden["update"] and visible["update"] else None
            ok = ratio_wall is not None and ratio_upd is not None and ratio_wall <= 2 and ratio_upd <= 2
            shown = lambda r: "missing" if r is None else f"{r:.2f}x"
            print(f"{app:10} hidden/visible: wall {shown(ratio_wall)}, update p50 {shown(ratio_upd)}  {'PASS' if ok else 'FAIL'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", action="append", required=True, help="label=path of a frozen bundle")
    ap.add_argument("--board", default="synthetic", help="synthetic, or a sanitized board file (scripts/perf-sanitize.py)")
    ap.add_argument("--scenarios", default="visible-serial,hidden-serial,visible-batch,poll-idle,pan-zoom")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--out", default="/tmp/easl-perf-loop.jsonl")
    ap.add_argument("--tmp", default="/tmp", help="where each bundle's scratch home is created (and deleted)")
    ap.add_argument("--display", default=os.environ.get("EASL_DEV_DISPLAY", "CanvasTest"))
    ap.add_argument("--summarize", action="store_true", help="only print the table for --out's rows")
    args = ap.parse_args()
    apps = [a.split("=", 1) for a in args.app]
    scenarios = args.scenarios.split(",")
    if args.summarize:
        rows = [json.loads(l) for l in open(args.out)]
        summarize(rows, [a for a, _ in apps], scenarios)
        return
    rows = []
    with open(args.out, "a") as out:
        for run in range(args.runs):
            order = apps if run % 2 == 0 else list(reversed(apps))
            for label, app in order:
                print(f"run {run + 1}/{args.runs} {label}", flush=True)
                inst = Instance(label, app, args.tmp, args.board, args.display)
                try:
                    inst.start()
                    for name in scenarios:
                        row = run_scenario(inst, name)
                        row["run"] = run + 1
                        row["board"] = args.board
                        rows.append(row)
                        out.write(json.dumps(row) + "\n")
                        out.flush()
                        print(f"  {name}: cpu {row['cpu_s']} s, wall {row['load'].get('wall_s', '-')} s, longest {row.get('longest_ms')} ms, "
                              f"routings {row.get('routings')}", flush=True)
                finally:
                    inst.stop()
    summarize(rows, [a for a, _ in apps], scenarios)


if __name__ == "__main__":
    main()
