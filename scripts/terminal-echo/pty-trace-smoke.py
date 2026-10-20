#!/usr/bin/env python3
"""Parent-run, guest-local smoke check. This does not measure native glyph latency."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import tty

READY = b"EASL_PTY_SMOKE_READY"


def write_all(fd, data):
    while data:
        count = os.write(fd, data)
        if count <= 0:
            raise RuntimeError("short fixture write")
        data = data[count:]


def fixture():
    original = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        write_all(1, READY)
        seq = 0
        while seq < 100:
            data = os.read(0, 4096)
            if not data or any(byte != ord("a") for byte in data):
                raise RuntimeError("fixture requires exactly 100 ASCII a bytes")
            output = bytearray()
            for _ in data:
                seq += 1
                if seq > 100:
                    raise RuntimeError("too many fixture keys")
                row, col = divmod(seq - 1, 10)
                output.extend(
                    f"\x1b[{row + 1};{col + 1}H\x1b[37;44mX\x1b[0m"
                    f"\x1b]777;easl-echo;{seq}\a".encode("ascii")
                )
            split = len(output) - 1
            write_all(1, output[:split])
            time.sleep(0.003)
            write_all(1, output[split:])
        time.sleep(1)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, original)


def read_available(fd, timeout):
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return None
    try:
        return os.read(fd, 65536)
    except OSError as error:
        if error.errno == errno.EIO:
            return b""
        raise


def check(log_path, client_pid):
    rows = [json.loads(line) for line in log_path.read_text().splitlines()]
    tracked = [row for row in rows if row["stage"] == "host_pty_tracked"]
    assert len(tracked) == 1, "missing or duplicate forkpty interception"
    owner = tracked[0]
    assert owner["pid"] not in (client_pid, owner["child_pid"]), "wrong process traced"
    assert all(row["pid"] == owner["pid"] for row in rows), "mixed process trace"
    assert not any(row["stage"] == "host_trace_error" for row in rows), "invalid cohort"
    summary = [row for row in rows if row["stage"] == "host_trace_summary"]
    assert len(summary) == 1 and summary[0]["dropped"] == 0, "trace missing or overflowed"
    assert summary[0]["input_keys"] == summary[0]["output_markers"] == 100
    writes = [row for row in rows if row["stage"] == "host_pty_write"]
    reads = [row for row in rows if row["stage"] == "host_output_read"]
    assert [row["seq"] for row in writes] == list(range(1, 101))
    assert [row["seq"] for row in reads] == list(range(1, 101))
    assert [row["offset"] for row in writes] == list(range(1, 101))
    assert all(a["offset"] < b["offset"] for a, b in zip(reads, reads[1:]))
    for stage in ("host_pty_write_call", "host_output_read_call"):
        calls = [row for row in rows if row["stage"] == stage]
        assert calls, "missing actual syscall records"
        assert all(row["enter_ms"] <= row["ts_ms"] == row["return_ms"] for row in calls)
        assert all(row["result"] >= 0 or row["error"] != 0 for row in calls)
        if stage == "host_pty_write_call":
            assert sum(row["bytes"] for row in calls) == 100
        else:
            for marker in reads:
                assert any(
                    call["return_ms"] == marker["return_ms"]
                    and call["offset"] < marker["offset"] <= call["offset"] + call["bytes"]
                    for call in calls
                ), "marker has no containing actual PTY read"
                assert marker["offset"] - marker["marker_start_offset"] == len(
                    f'\x1b]777;easl-echo;{marker["seq"]}\a'.encode("ascii")
                )
                assert any(
                    call["offset"] < marker["marker_start_offset"] <= call["offset"] + call["bytes"]
                    for call in calls
                ), "glyph end has no containing actual PTY read"
    assert any(row["stage"] in ("host_pty_closed", "host_process_exit") and row["result"] == 0 for row in rows)
    print(json.dumps({"smoke": "passed", "trace": str(log_path),
                      "daemon_pid": owner["pid"], "fixture_pid": owner["child_pid"],
                      "input_keys": 100, "output_markers": 100}))


def run(args):
    root = Path(tempfile.mkdtemp(prefix="easl-pty-trace-", dir=args.output_root)).resolve()
    log_path = root / "host.jsonl"
    print(f"Smoke evidence directory: {root}", flush=True)
    env = os.environ.copy()
    env.pop("ZMX_SESSION", None)
    env.pop("ZMX_SESSION_PREFIX", None)
    env.update({"ZMX_DIR": str(root / "sockets"), "ZMX_TRACK_ENV": "",
                "DYLD_INSERT_LIBRARIES": str(Path(args.library).resolve()),
                "EASL_PTY_TRACE_PATH": str(log_path), "TERM": "xterm-256color"})
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    child = None
    completed = False
    try:
        child = subprocess.Popen(
            [str(Path(args.zmx).resolve()), "attach", "smoke",
             sys.executable, str(Path(__file__).resolve()), "--fixture"],
            stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True,
        )
        os.close(slave)
        slave = -1
        deadline = time.monotonic() + 60
        tail = b""
        while READY not in tail:
            if time.monotonic() >= deadline:
                raise TimeoutError("fixture did not become ready")
            data = read_available(master, 0.1)
            if data == b"":
                raise RuntimeError("client exited before fixture readiness")
            if data:
                tail = (tail + data)[-4096:]
        if args.spacing_ms == 0:
            write_all(master, b"a" * 100)
        else:
            for _ in range(100):
                write_all(master, b"a")
                time.sleep(args.spacing_ms / 1000)
        while child.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError("zmx did not exit and flush its trace")
            read_available(master, 0.1)
        assert child.returncode == 0, f"zmx returned {child.returncode}"
        while time.monotonic() < deadline:
            if log_path.exists():
                text = log_path.read_text()
                if text.endswith("\n") and '"host_trace_summary"' in text.splitlines()[-1]:
                    break
            time.sleep(0.05)
        check(log_path, child.pid)
        completed = True
    finally:
        if not completed and log_path.exists():
            try:
                first = json.loads(log_path.read_text().splitlines()[0])
                if first.get("stage") == "host_pty_tracked":
                    for pid in (first["pid"], first["child_pid"]):
                        try:
                            os.kill(pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
            except (ValueError, IndexError):
                pass
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        os.close(master)
        if slave >= 0:
            os.close(slave)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", action="store_true")
    parser.add_argument("--zmx")
    parser.add_argument("--library")
    parser.add_argument("--output-root", default="/tmp")
    parser.add_argument("--spacing-ms", type=float, default=0)
    args = parser.parse_args()
    if args.fixture:
        fixture()
    else:
        if not args.zmx or not args.library or args.spacing_ms < 0:
            parser.error("--zmx and --library are required; spacing must be nonnegative")
        run(args)
