#!/usr/bin/env python3
"""The performance loop: runs the benchmark scenarios against one or more easl bundles, `--runs`
times interleaved, and prints medians with the targets as pass/fail (docs/testing.md,
"Performance benchmark").

    python3 scripts/perf-loop.py --app base=/tmp/a.app --app fix=/tmp/b.app [--board synthetic|<sanitized.json>]
        [--scenarios visible-serial,hidden-serial,visible-batch,poll-idle,pan-zoom,agent-titles] [--runs 3] [--out rows.jsonl] [--headless]

Bundles are frozen release builds (`EASL_BUNDLE_APP=/tmp/a.app scripts/bundle.sh release`). Each
run starts every bundle in turn (the order alternating between runs) on a development home of its
own (a new scratch directory under `--tmp`, default /tmp, deleted when the bundle stops; nothing
else is ever deleted, so an existing `EASL_DEV_HOME` is never touched) holding the board from
scripts/perf-board.py, shows it at 100% over the densest html area, then runs the scenarios:

- `visible-serial` / `hidden-serial`: scripts/perf-load.py's serial burst with the window shown
  (on the testing Space) or minimized;
- `visible-batch`: the same writes as one `object.batch`;
- `poll-idle`: 60 s of `board.get` every 10 s, nothing else;
- `pan-zoom`: pans 3000 pt across the html cards and back, zooms out three steps and in again,
  then out to the whole board (every tile its card) and back, twice (parked HTML pages:
  `html.reuse` against `html.load` in `app.metrics`).
- `agent-titles`: 8 live terminals each running an agent-like program (a title with a spinner
  and a status line every 80 ms, as omp does while working), 60 s with nothing else: the app's
  CPU, interrupt wakeups and main-thread time per second (A/B only, no target).

A row per scenario run records the app's CPU from the burst's start until it is quiet again
(`ps`), the burst's wall time and RPC latencies, and the `DevPerf` spans over it (main thread
busy time, the longest stretch it didn't sleep, and `route.board` routings), plus `app.metrics`
where the bundle has it. Needs yabai and a virtual screen (`EASL_DEV_DISPLAY`) like scripts/dev.sh,
or `--headless`: the window then stays on the parking Space nobody views, where it is always
occluded (it renders but composites nothing), so `visible-*` means not minimized.
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
TARGETS = "burst CPU < 3 s, longest main stretch < 100 ms, <= 2 board routings per burst; idle poll stretch < 16 ms; hidden within 2x of visible; agent-titles A/B only"


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


def rusage(pid):
    """The process's CPU time (s) and interrupt wakeups so far, from `proc_pid_rusage`
    (RUSAGE_INFO_V4: `ri_user_time` + `ri_system_time` in ns, `ri_interrupt_wkups`; docs/testing.md,
    "Performance probes"); None when the process is gone."""
    import ctypes
    import struct
    buffer = ctypes.create_string_buffer(16 + 8 * 40)
    if ctypes.CDLL(None).proc_pid_rusage(pid, 4, buffer) != 0:
        return None
    user, system, _, wakeups = struct.unpack_from("<4Q", buffer.raw, 16)
    return {"cpu_s": (user + system) / 1e9, "wakeups": wakeups}


class Instance:
    def __init__(self, label, app, tmp, board, display, headless=False):
        self.label, self.app, self.board = label, app, board
        # Created here and owned by this run: the only directory `stop` deletes.
        self.scratch = tempfile.mkdtemp(prefix="easl-perf-loop-", dir=tmp)
        self.home, self.root = os.path.join(self.scratch, "home"), os.path.join(self.scratch, "root")
        home = self.home
        park = os.environ.get("EASL_DEV_PARK_SPACE", "9")
        self.env = dict(os.environ, EASL_DEV_HOME=home, EASL_DEV_APP=app, EASL_DEV_DISPLAY=display,
                        EASL_DEV_PARK_SPACE=park, EASL_SOCKET=os.path.join(home, "easl.sock"))
        # Run from an easl tile, the CLI would address the tile's own board, which the instance
        # doesn't have (`not_found`): the instance's board is the one on its socket.
        for key in ("EASL_BOARD_ID", "EASL_TILE_ID"):
            self.env.pop(key, None)
        # Headless: the window stays on the parking Space, which nobody views (no virtual screen).
        if headless:
            self.env["EASL_DEV_SPACE"] = park
        self.headless = headless
        self.variant = 0
        self.pid = None
        self.window = None
        self.has_metrics = None
        self.notch = None

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
        self.check_space()
        self.zoom_to_cards()

    def check_space(self):
        """Headless: the window must still sit on the parking Space nobody views (a Space the
        user views would be disturbed, and a window there renders and composites differently).
        Raises when it moved: the run is not valid on another Space."""
        if not self.headless:
            return
        window = json.loads(sh(YABAI, "-m", "query", "--windows", "--window", str(self.window)))
        if str(window.get("space")) != self.env["EASL_DEV_SPACE"]:
            raise RuntimeError(f"{self.label}'s window {self.window} is on Space {window.get('space')}, not {self.env['EASL_DEV_SPACE']}")

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
            # A window on a Space nobody views is always occluded: headless, shown is not minimized.
            if self.headless:
                done = json.loads(sh(YABAI, "-m", "query", "--windows", "--window", str(self.window))).get("is-minimized") != shown
            else:
                done = (self.cli("view.get") or {}).get("visible") == shown
            if done:
                return
            time.sleep(0.2)
        raise RuntimeError(f"window never became {'visible' if shown else 'hidden'}")

    def viewport(self):
        view = self.cli("view.get")["viewport"]
        return view["rect"], view["zoom"]

    def bursts_ended(self):
        """How many replayed input bursts have ended their DevPerf span (its `settle` line)."""
        with open(os.path.join(self.home, "app.log"), errors="replace") as f:
            return sum(1 for l in f if "DevPerf: burst of " in l and re.search(r"DevPerf: burst of \d+ \w+ settle ", l))

    def scroll_burst(self, *args, n, at=("700", "400")):
        """A burst of `n` scroll steps, returning once its DevPerf span has ended. DevInput ends
        it unconditionally 1.5 s after the last step (`DevPerf.settle`), whatever span is open
        then, so a span opened before that would be cut short."""
        ended = self.bursts_ended()
        self.dev("input", "scroll", *at, *args, "--repeat", str(n))
        if n < 2:
            return
        deadline = time.time() + n * 0.008 + 10
        while self.bursts_ended() <= ended and time.time() < deadline:
            time.sleep(0.1)

    def pan(self, dx, dy=0, steps=60, at=("700", "400")):
        """Moves the viewport about (dx, dy) canvas points in a burst of mouse-wheel notches.
        Sideways ones are ⌘-scrolls, which the window hands to the canvas whatever tile is under
        the pointer (a plain notch over a live page scrolls the page); vertical ones only pan over
        cards (zoomed out). A trackpad's precise scroll is NSScrollView's own and moves nothing in
        a window on a Space nobody views. The viewport goes against the notches."""
        _, zoom = self.viewport()
        for delta, axis in ((dx, 0), (dy, 1)):
            notches = round(abs(delta) * zoom / self.notch)
            if notches == 0:
                continue
            n = min(steps, notches)
            per = max(1, round(notches / n))
            step = [0, 0]
            step[axis] = -per if delta > 0 else per
            mods = ["--mods", "cmd"] if axis == 0 else []
            self.scroll_burst(str(step[0]), str(step[1]), "--lines", *mods, n=n, at=at)

    def zoom_to_cards(self):
        """100% zoom, the viewport centred on the html tiles' densest area (the first column's top):
        centred while the whole board shows (every tile a card, so wheel notches pan it from
        anywhere), then Actual Size around the centre."""
        self.visible(True)
        self.dev("input", "mainmenu", "View/Actual Size")
        time.sleep(1)
        # Screen points one ⌘-wheel notch pans.
        before, _ = self.viewport()
        self.scroll_burst("-1", "0", "--lines", "--mods", "cmd", n=10)
        after, _ = self.viewport()
        self.notch = abs(after["x"] - before["x"]) / 10 or 10
        objects = self.cli("board.get")["objects"]
        html = sorted((o["frame"] for o in objects if o["type"] == "html"), key=lambda f: (f["y"] // 2000, f["x"]))
        target = html[len(html) // 8] if html else None
        self.dev("input", "mainmenu", "View/Zoom to Fit")
        time.sleep(1)
        if target:
            for _ in range(3):
                rect, zoom = self.viewport()
                dx = target["x"] + target["w"] / 2 - (rect["x"] + rect["w"] / 2)
                dy = target["y"] + target["h"] / 2 - (rect["y"] + rect["h"] / 2)
                if abs(dx) < 100 and abs(dy) < 100:
                    break
                self.pan(dx, dy, at=("700", "450"))
                time.sleep(0.5)
        self.dev("input", "mainmenu", "View/Actual Size")
        time.sleep(1)
        self.quiet(timeout=60)

    def span_begin(self):
        self.log_offset = os.path.getsize(os.path.join(self.home, "app.log"))
        self.span_resume()

    def span_resume(self):
        """(Re)opens the idle DevPerf span: an input burst opens a span of its own, which ends the
        open one (both log their lines), and nothing is measured once the burst's has ended."""
        self.dev("input", "perf", "900000")

    def span_end(self):
        self.dev("input", "perf", "1")
        time.sleep(0.5)
        with open(os.path.join(self.home, "app.log"), errors="replace") as f:
            f.seek(self.log_offset)
            lines = [l for l in f.read().splitlines() if "DevPerf: " in l]
        return parse_devperf(lines)

    def metrics(self, reset=False):
        if not self.has_metrics:
            return None
        return self.cli("app.metrics", {"reset": True} if reset else {})


def pan_zoom(inst):
    """Pans the view 3000 pt right and back; zooms out three steps and back in; zooms to fit the
    whole board (every tile its card) and goes back; twice. The window ends where it started."""
    started = time.time()
    for _ in range(2):
        for dx in (3000, -3000):
            inst.pan(dx)
            inst.span_resume()
            time.sleep(1)
        for item in ["View/Zoom Out"] * 3 + ["View/Zoom In"] * 3 + ["View/Zoom to Fit", "View/Back"]:
            inst.dev("input", "mainmenu", item)
            time.sleep(0.7)
        time.sleep(1)
    return {"wall_s": round(time.time() - started, 1)}


# An agent-like program for a terminal tile: omp's working title (a braille spinner, every 80 ms,
# deduplicated so each is a change) and a status line, from one process with no children. It
# ends by itself after 10 minutes, so a run that dies leaves no session spinning.
AGENT = ("import sys, time\n"
         "frames = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'\n"
         "for i in range(7500):\n"
         "    sys.stdout.write(f'\\033]0;π {frames[i % 10]} task {sys.argv[1]}\\007\\r{frames[i % 10]} step {i}')\n"
         "    sys.stdout.flush()\n"
         "    time.sleep(0.08)\n")


def agent_titles(inst, terminals=8, seconds=60):
    """`terminals` live terminal tiles running AGENT in an empty part of the board (20,000 pt to
    the right, at the view's own height: a sideways pan works over any tile), measured for
    `seconds` once they are up: CPU, interrupt wakeups and DevPerf's main thread time, all per
    second. The tiles are deleted (ending their sessions) and the view panned back before the
    row's own quiet. Nothing of the burst machinery applies."""
    start, _ = inst.viewport()
    program = os.path.join(inst.root, "agent.py")
    with open(program, "w") as f:
        f.write(AGENT)
    columns, lines = min(terminals, 4), (terminals + 3) // 4
    # At the view's own vertical centre, so only sideways (⌘-wheel) pans are ever needed.
    x0, y0 = start["x"] + 20000, start["y"] + start["h"] / 2 - (lines * 220 - 20) / 2
    ids = []
    for i in range(terminals):
        frame = {"x": x0 + (i % 4) * 340, "y": y0 + (i // 4) * 220, "w": 320, "h": 200}
        made = inst.cli("object.create", {"type": "terminal", "frame": frame, "props": {
            "cwd": inst.root, "command": ["python3", "-u", program, str(i)], "title": f"agent {i}"}})
        ids.append(made["object"]["id"])
    # Centre the view on the terminals (a wheel pan is approximate: correct it up to three times).
    centre = (x0 + (columns * 340 - 20) / 2, y0 + (lines * 220 - 20) / 2)
    for _ in range(3):
        rect, _ = inst.viewport()
        dx, dy = centre[0] - (rect["x"] + rect["w"] / 2), centre[1] - (rect["y"] + rect["h"] / 2)
        if abs(dx) < 100 and abs(dy) < 100:
            break
        inst.pan(dx, dy)
        time.sleep(0.5)
    rect, _ = inst.viewport()
    shown = sum(1 for i in range(terminals) if rect["x"] <= x0 + (i % 4) * 340 and x0 + (i % 4) * 340 + 320 <= rect["x"] + rect["w"]
                and rect["y"] <= y0 + (i // 4) * 220 and y0 + (i // 4) * 220 + 200 <= rect["y"] + rect["h"])
    time.sleep(8)  # sessions start, surfaces attach, the first titles arrive
    inst.metrics(reset=True)
    inst.span_begin()
    r0, started = rusage(inst.pid), time.time()
    time.sleep(seconds)
    r1, elapsed = rusage(inst.pid), time.time() - started
    span = inst.span_end()
    metrics = inst.metrics()
    for tile in ids:
        inst.cli("object.delete", {"id": tile})
    time.sleep(2)
    for _ in range(3):
        rect, _ = inst.viewport()
        dx, dy = start["x"] - rect["x"], start["y"] - rect["y"]
        if abs(dx) < 100 and abs(dy) < 100:
            break
        inst.pan(dx, dy)
        time.sleep(0.5)
    row = {"cpu_s": round(r1["cpu_s"] - r0["cpu_s"], 2), "wakeups_s": round((r1["wakeups"] - r0["wakeups"]) / elapsed, 1),
           "main_ms_s": round(span.get("main_busy_ms", 0) / elapsed, 1), "settled_s": round(elapsed, 1), **span,
           "load": {"wall_s": round(elapsed, 1), "terminals": terminals, "terminals_in_view": shown}}
    if metrics:
        row["metrics"] = metrics
    return row


def parse_devperf(lines):
    """The scenario's DevPerf lines (one per span phase, the spans one after another) summed:
    main-thread busy time and hitches, the longest stretch, and the board routings."""
    out = {}
    for line in lines:
        m = re.search(r"main busy (\d+) ms, hitches (\d+) \(longest ([\d.]+) ms\)", line)
        if m:
            out["main_busy_ms"] = out.get("main_busy_ms", 0) + int(m.group(1))
            out["hitches"] = out.get("hitches", 0) + int(m.group(2))
            out["longest_ms"] = max(out.get("longest_ms", 0.0), float(m.group(3)))
        m = re.search(r"route\.board=(\d+)/([\d.]+)/([\d.]+)", line)
        if m:
            out["routings"] = out.get("routings", 0) + int(m.group(1))
            out["routing_ms"] = round(out.get("routing_ms", 0.0) + float(m.group(2)), 1)
            out["routing_max_ms"] = max(out.get("routing_max_ms", 0.0), float(m.group(3)))
    if lines:
        out.setdefault("routings", 0)
        out.setdefault("routing_ms", 0.0)
        out.setdefault("routing_max_ms", 0.0)
    return out


def run_scenario(inst, name):
    shown = not name.startswith("hidden")
    inst.visible(shown)
    inst.quiet(timeout=60)
    inst.check_space()
    if name == "agent-titles":
        row = agent_titles(inst)
        inst.quiet(timeout=180)
        return {"app": inst.label, "scenario": name, "visible": shown, **row}
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
    elif name == "agent-titles":
        checks = [("cpu", t["cpu"], lambda v: True), ("wakeups", t["wakeups"], lambda v: True)]
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
            wakeups = [r.get("wakeups_s") for r in mine]
            main_ms = [r.get("main_ms_s") for r in mine]
            table[(app, name)] = dict(cpu=med(cpu), wall=med(wall), longest=med(longest), routes=med(routes), update=med(upd), poll=med(poll),
                                      wakeups=med(wakeups), main=med(main_ms))
            t = table[(app, name)]
            verdict = gate(name, t)
            print(f"{app:10} {name:15} {t['cpu']!s:>6} {rng(cpu):>7} {t['wall']!s:>5} {rng(wall):>6} {t['longest']!s:>7} {rng(longest):>8} "
                  f"{t['routes']!s:>10} {t['update']!s:>11} {t['poll']!s:>9}  {verdict}")
            if name == "pan-zoom":
                print(f"{'':10} {'':15} html page loads {med([r.get('html_loads') for r in mine])}, reuses {med([r.get('html_reuses') for r in mine])}")
            if name == "agent-titles":
                print(f"{'':10} {'':15} wakeups/s {t['wakeups']} ({rng(wakeups)}), main thread ms/s {t['main']} ({rng(main_ms)})")
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
    ap.add_argument("--headless", action="store_true",
                    help="no virtual screen: the window stays on the parking Space (EASL_DEV_PARK_SPACE, default 9), which nobody views")
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
                inst = Instance(label, app, args.tmp, args.board, args.display, headless=args.headless)
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
