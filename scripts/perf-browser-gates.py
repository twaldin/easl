#!/usr/bin/env python3
"""Observe browser response gates on the macOS viewer, without provisioning a fixture.

Usage:
  python3 scripts/perf-browser-gates.py --config /tmp/gates.json --label window4 --block 1

Example config (all paths are on the macOS viewer):
{
  "scratch": "/tmp/gates", "dev_home": "/tmp/view",
  "board": "BOARD", "tile": "TILE", "pid": 123, "window": 456,
  "viewport": {"rect": {"x": 0, "y": 0}, "zoom": 1},
  "input_helper": "/tmp/timed-input", "mode": "relay",
  "ssh_wrapper": "/tmp/ssh", "ssh_host": "source", "hostHome": "/tmp/source",
  "count_region": [0, 160, 120, 50],
  "stream": "CURRENT_SURFACE_STREAM"
}

Direct mode measures local WebKit input without a streamed image. Its source RPC
still addresses easld through socket or SSH, never the app's unsupported browser.call.
Optional keys: count=60, deadline_s=15, rpc_timeout_s=30, click=[29,195], marker=[525,88],
content_top=68, pause_s=0, app_log=<dev_home>/app.log, cua_driver=<standard app path>,
count_script="Number(clicks)", arm_script=<JS using __COLOR__ JSON substitution>.
Coordinates use the retained observer's board/viewport mapping.
count_region is [x,y,width,height] in those same coordinates; calibrate it on the
actual fixture. The existing fixture must already expose #click, #rcMark and
rcCapture, rcExpectedType, rcNextColor. No fixture is installed or reset here.

Gate A requires the calibrated native RGB marker transition and exactly one
independently checked DOM increment. Retained count crops allow visual audit.

The supplied timed-input executable accepts one JSON string of string-valued pid,
kind,x,y, prints viewer-local epoch milliseconds taken immediately before posting
canvas.dev.input, and exits. Its hash, method and stdout are retained. Launch the
viewer with EASL_DEV_INPUT=1 EASL_DEV_SURFACE_TRACE=1. Gate B is the first matching
same-stream refresh assignment at the click's last queued sequence, not native
presentation or a quality score. No next input is sent before B completes or its
deadline fails. Every screenshot and full receipt has a unique path, including
before, intermediate and settled captures. Summary percentiles describe only the
completed subset; failed/missing/censored rows remain in the denominator. Clock
values are viewer-local epoch milliseconds; capture completion is a sampled
observation, not compositor presentation. No cross-machine clocks are subtracted.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import select
import shlex
import socket
import subprocess
import sys
import time
import uuid


def epoch_ms():
    return time.time_ns() / 1e6


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Source:
    def __init__(self, config):
        self.timeout = config.get("rpc_timeout_s", 30)
        self.child = None
        if config.get("socket"):
            self.socket = socket.socket(socket.AF_UNIX)
            self.socket.settimeout(self.timeout)
            self.socket.connect(config["socket"])
            self.reader = self.socket.makefile("rb")
            self.writer = self.socket.makefile("wb")
        else:
            command = [config["ssh_wrapper"], config["ssh_host"],
                       "nc -U " + shlex.quote(config["hostHome"] + "/easl.sock")]
            self.child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            self.reader, self.writer = self.child.stdout, self.child.stdin
        self.seq = 0

    def call(self, method, params):
        self.seq += 1
        self.writer.write((json.dumps({"id": self.seq, "method": method, "params": params}) + "\n").encode())
        self.writer.flush()
        deadline = time.monotonic() + self.timeout
        while True:
            if self.child and not select.select([self.reader], [], [], max(0, deadline - time.monotonic()))[0]:
                raise TimeoutError("Source RPC deadline")
            line = self.reader.readline()
            if not line:
                raise RuntimeError("Source RPC connection ended")
            reply = json.loads(line)
            if reply.get("id") == self.seq:
                if "error" in reply:
                    raise RuntimeError(f"Source RPC error: {reply['error']}")
                return reply["result"]
            if time.monotonic() >= deadline:
                raise TimeoutError("Source RPC deadline")

    def close(self):
        self.writer.close()
        self.reader.close()
        if self.child:
            self.child.terminate()
            self.child.wait(timeout=10)
        else:
            self.socket.close()


class Trace:
    def __init__(self, path):
        self.file = Path(path).open("rb")
        self.file.seek(0, os.SEEK_END)
        self.pending = b""

    def poll(self):
        self.pending += self.file.read()
        lines = self.pending.split(b"\n")
        self.pending = lines.pop()
        events = []
        for line in lines:
            text = line.decode("utf-8", errors="replace")
            prefix = "DevInput.surface "
            if prefix not in text:
                continue
            try:
                event = json.loads(text.split(prefix, 1)[1])
            except ValueError as error:
                raise RuntimeError(f"Malformed surface trace: {text}") from error
            if event.get("stage") in ("input.queued", "input.sent", "image.assigned"):
                events.append({**event, "raw": text})
        return events


def distance(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


class Observer:
    def __init__(self, config, directory):
        from PIL import Image
        self.Image = Image
        self.config = config
        self.directory = directory
        self.session = "browser-gates-" + uuid.uuid4().hex
        self.index = 0
        self.driver = config.get("cua_driver", "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")

    def point(self, x, y, scale=1, native=True):
        viewport = self.config["viewport"]
        rect, zoom = viewport["rect"], viewport["zoom"]
        return (round((x - rect["x"]) * zoom * scale),
                round(((y - rect["y"]) * zoom + (self.config.get("content_top", 68) if native else 0)) * scale))

    def capture(self, label):
        self.index += 1
        base = self.directory / f"{self.index:05d}-{label}"
        request = {"pid": self.config["pid"], "window_id": self.config["window"],
                   "include_accessibility_tree": False, "max_image_dimension": 0,
                   "screenshot_out_file": str(base.with_suffix(".png")), "session": self.session}
        started = epoch_ms()
        response = subprocess.run([self.driver, "call", "get_window_state", json.dumps(request)],
                                  capture_output=True, text=True, timeout=self.config.get("rpc_timeout_s", 30))
        ended = epoch_ms()
        base.with_suffix(".stdout").write_text(response.stdout)
        base.with_suffix(".stderr").write_text(response.stderr)
        response.check_returncode()
        receipt = json.loads(response.stdout)
        save(base.with_suffix(".json"), receipt)
        if (receipt.get("pid") != self.config["pid"] or receipt.get("window_id") != self.config["window"]
                or receipt.get("screenshot_frame_valid") is not True):
            raise RuntimeError(f"Invalid exact-window receipt: {base}")
        with self.Image.open(base.with_suffix(".png")) as image:
            image = image.convert("RGB")
            scale = receipt["screenshot_scale"]
            point = self.point(*self.config.get("marker", [525, 88]), scale=scale)
            pixel = image.getpixel(point)
            x, y, width, height = self.config["count_region"]
            left, top = self.point(x, y, scale=scale)
            right, bottom = self.point(x + width, y + height, scale=scale)
            if not (0 <= left < right <= image.width and 0 <= top < bottom <= image.height):
                raise ValueError("count_region falls outside exact-window screenshot")
            crop = base.with_name(base.name + "-count.png")
            image.crop((left, top, right, bottom)).save(crop)
        observation = {"started_ms": started, "ended_ms": ended, "png": str(base.with_suffix(".png")),
                       "receipt": str(base.with_suffix(".json")), "pixel": pixel, "count_crop": str(crop),
                       "capture_id": receipt.get("capture_id"), "snapshot_id": receipt.get("snapshot_id")}
        save(base.with_name(base.name + "-observation.json"), observation)
        return observation

    def close(self):
        subprocess.run([self.driver, "call", "end_session", json.dumps({"session": self.session})],
                       capture_output=True, timeout=30)


def endpoints(events, stream, started, deadline_ms):
    queued = [e for e in events if e["stage"] == "input.queued" and e["stream"] == stream and started <= e["ts_ms"] <= deadline_ms]
    watermark = max((e["seq"] for e in queued), default=None)
    last_input = max((e["ts_ms"] for e in queued if e["seq"] == watermark), default=None)
    assigned = [e for e in events if e["stage"] == "image.assigned" and e["stream"] == stream
                and started <= e["ts_ms"] <= deadline_ms and watermark is not None and e.get("input", -1) >= watermark]
    covering = min(assigned, key=lambda e: e["ts_ms"], default=None)
    refresh = min((e for e in assigned if e.get("refresh") is True and e.get("input") == watermark),
                  key=lambda e: e["ts_ms"], default=None)
    return watermark, last_input, covering, refresh


def summarize(rows, gate):
    complete = [r[gate]["latency_ms"] for r in rows if r[gate]["status"] == "complete"]
    statuses = {}
    for row in rows:
        status = row[gate]["status"]
        statuses[status] = statuses.get(status, 0) + 1
    ordered = sorted(complete)
    return {"denominator": len(rows), "outcomes": statuses, "completed_subset": {
        "n": len(ordered), "median_ms": (ordered[len(ordered)//2] + ordered[(len(ordered)-1)//2]) / 2 if ordered else None,
        "p95_ms": ordered[math.ceil(.95 * len(ordered))-1] if ordered else None,
        "max_ms": max(ordered, default=None)}}


def run(config, args):
    count = args.count if args.count is not None else config.get("count", 60)
    if count < 1 or config.get("deadline_s", 15) <= 0:
        raise ValueError("count and deadline_s must be positive")
    if config["mode"] not in ("direct", "relay"):
        raise ValueError("mode must be direct or relay")
    for key in ("scratch", "dev_home", "board", "tile", "pid", "window", "viewport", "input_helper", "count_region"):
        if key not in config:
            raise ValueError(f"Missing config key: {key}")
    if config["mode"] == "relay" and not config.get("stream"):
        raise ValueError("relay requires the exact current surface stream")
    directory = Path(config["scratch"]).expanduser().resolve() / ("gates-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    save(directory / "config.json", config)
    metadata = {"label": args.label, "block": args.block, "action": args.action, "mode": config["mode"],
                "requested": count, "input_helper": config["input_helper"], "input_helper_sha256": digest(config["input_helper"]),
                "input_method": "supplied helper epoch timestamp immediately before canvas.dev.input notification",
                "clock": "viewer-local epoch milliseconds", "marker_tolerance": 16, "started_ms": epoch_ms()}
    save(directory / "metadata.json", metadata)
    source = Source(config)
    observer = Observer(config, directory)
    trace = Trace(config.get("app_log", str(Path(config["dev_home"]) / "app.log"))) if config["mode"] == "relay" else None
    rows = []
    previous_target = None

    def page(script):
        return source.call("browser.call", {"id": config["tile"], "method": "browser.eval", "params": {"script": script}}).get("value")

    try:
        if page("Boolean(document.querySelector('#click') && document.querySelector('#rcMark'))") is not True:
            raise RuntimeError("Existing #click/#rcMark fixture is required")
        for sample in range(1, count + 1):
            row = {"sample": sample, "label": args.label, "block": args.block, "action": args.action,
                   "mode": config["mode"], "board": config["board"], "tile": config["tile"],
                   "gate_a": {"status": "deadline_failure"},
                   "gate_b": {"status": "deadline_failure" if trace else "not_applicable"}, "observations": [], "trace": []}
            rows.append(row)
            child = None
            try:
                if config.get("pause_s", 0):
                    row["pause_started_ms"] = epoch_ms()
                    time.sleep(config["pause_s"])
                    row["pause_ended_ms"] = epoch_ms()
                before = observer.capture(f"{sample:03d}-before")
                row["before"] = before
                candidates = [(50, 50, 75), (210, 180, 195), (50, 210, 75)]
                color = next(c for c in candidates if distance(c, before["pixel"]) > 32
                             and (previous_target is None or distance(c, previous_target) > 32))
                row["target"] = color
                if distance(before["pixel"], color) <= 16:
                    raise RuntimeError("Pre-click native marker already passes target16")
                previous_target = color
                row["source_before"] = page(config.get("count_script", "Number(clicks)"))
                if type(row["source_before"]) not in (int, float):
                    raise RuntimeError("Source count_script must return a number")
                arm = config.get("arm_script", "if(typeof rcCapture!=='function')throw Error('existing rcCapture required');rcExpectedType='click';rcNextColor=__COLOR__;true")
                page(arm.replace("__COLOR__", json.dumps("rgb(" + ",".join(map(str, color)) + ")")))
                if trace:
                    row["pre_input_trace"] = trace.poll()
                x, y = observer.point(*config.get("click", [29, 195]), native=False)
                fields = {"pid": str(config["pid"]), "kind": "click", "x": str(x), "y": str(y)}
                child = subprocess.Popen([config["input_helper"], json.dumps(fields)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if not select.select([child.stdout], [], [], config.get("rpc_timeout_s", 30))[0]:
                    raise RuntimeError("Timed input helper did not print its timestamp")
                stamp = child.stdout.readline()
                row["input_receipt"] = {"fields": fields, "stdout": stamp}
                started = float(stamp.strip())
                row["started_ms"] = started
                deadline_ms = started + config.get("deadline_s", 15) * 1000
                row["deadline_ms"] = deadline_ms
                deadline = time.monotonic() + max(0, (deadline_ms - epoch_ms()) / 1000)
                first_marker = None
                refresh = None
                while time.monotonic() < deadline:
                    if first_marker is None:
                        observation = observer.capture(f"{sample:03d}-obs")
                        row["observations"].append(observation)
                        if observation["ended_ms"] <= deadline_ms and distance(observation["pixel"], color) <= 16:
                            first_marker = observation
                            row["gate_a"] = {"status": "complete", "latency_ms": observation["ended_ms"] - started,
                                             "observed_ms": observation["ended_ms"], "observation": observation["png"]}
                    if trace:
                        row["trace"].extend(trace.poll())
                        watermark, last_input, covering, refresh = endpoints(row["trace"], config["stream"], started, deadline_ms)
                        row.update(input_watermark=watermark, internal_covering_assignment=covering, internal_refresh_assignment=refresh)
                        if refresh:
                            row["gate_b"] = {"status": "complete", "latency_ms": refresh["ts_ms"] - last_input,
                                             "native_start_latency_ms": refresh["ts_ms"] - started,
                                             "last_input_ms": last_input, "assigned_ms": refresh["ts_ms"]}
                    if first_marker is not None:
                        if not trace or refresh:
                            break
                        time.sleep(0.005)
                if trace:
                    row["trace"].extend(trace.poll())
                    watermark, last_input, covering, refresh = endpoints(row["trace"], config["stream"], started, deadline_ms)
                    row.update(input_watermark=watermark, internal_covering_assignment=covering, internal_refresh_assignment=refresh)
                    if refresh:
                        row["gate_b"] = {"status": "complete", "latency_ms": refresh["ts_ms"] - last_input,
                                         "native_start_latency_ms": refresh["ts_ms"] - started,
                                         "last_input_ms": last_input, "assigned_ms": refresh["ts_ms"]}
                    elif watermark is None:
                        row["gate_b"]["reason"] = "missing_input_watermark"
                if first_marker is None:
                    row["gate_a"] = {"status": "deadline_failure", "reason": "no_marker16_observation"}
                row["settled_capture"] = observer.capture(f"{sample:03d}-settled")
                row["source_after"] = page(config.get("count_script", "Number(clicks)"))
                row["source_increment_once"] = row["source_after"] == row["source_before"] + 1
                if not row["source_increment_once"]:
                    row["gate_a"] = {"status": "source_count_failure"}
                row["ended_ms"] = epoch_ms()
                row["deadline_s"] = config.get("deadline_s", 15)
            except Exception as error:
                row["error"] = f"{type(error).__name__}: {error}"
                row["gate_a"] = {"status": "error"}
                if trace and row["gate_b"]["status"] != "complete":
                    row["gate_b"] = {"status": "error"}
                row["ended_ms"] = epoch_ms()
            if child is not None:
                try:
                    stdout, stderr = child.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    stdout, stderr = child.communicate()
                receipt = row.setdefault("input_receipt", {})
                receipt["stdout"] = receipt.get("stdout", "") + stdout
                receipt.update(stderr=stderr, returncode=child.returncode)
                if child.returncode:
                    row["error"] = "Timed input helper failed or did not exit"
                    row["gate_a"] = {"status": "error"}
                    if trace:
                        row["gate_b"] = {"status": "error"}
            save(directory / f"row-{sample:03d}.json", row)
            save(directory / "results.json", {"metadata": metadata, "rows": rows,
                 "gate_a": summarize(rows, "gate_a"), "gate_b": summarize(rows, "gate_b")})
            print(json.dumps({"sample": sample, "gate_a": row["gate_a"], "gate_b": row["gate_b"], "directory": str(directory)}), flush=True)
            if "error" in row:
                break
        summary = {"directory": str(directory), "requested": count, "attempted": len(rows),
                   "unattempted": count - len(rows), "gate_a": summarize(rows, "gate_a"), "gate_b": summarize(rows, "gate_b")}
        save(directory / "summary.json", summary)
        print(json.dumps(summary), flush=True)
        return 0 if len(rows) == count and all(r["gate_a"]["status"] == "complete" and r["gate_b"]["status"] in ("complete", "not_applicable") for r in rows) else 1
    finally:
        if trace:
            trace.file.close()
        source.close()
        observer.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--block", type=int, default=1)
    parser.add_argument("--action", choices=["click"], default="click")
    parser.add_argument("--count", type=int, help="Override count (default 60).")
    args = parser.parse_args()
    try:
        return run(json.loads(args.config.read_text()), args)
    except (ImportError, OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"perf-browser-gates: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
