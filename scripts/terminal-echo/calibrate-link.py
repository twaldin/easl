#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import select
import shlex
import statistics
import subprocess
import time

REMOTE = """import os,sys
os.write(1,b'READY')
while True:
    op=os.read(0,1)
    if not op: break
    if op==b'e': os.write(1,b'e')
    elif op==b'd':
        for i in range(64): os.write(1,bytes([i])*1024)
    elif op==b'u':
        count=0
        while count<65536:
            data=os.read(0,65536-count)
            if not data: raise RuntimeError('truncated upload')
            count+=len(data)
        os.write(1,b'U')
    else: raise RuntimeError('invalid command')
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scratch", type=Path)
    parser.add_argument("profile")
    args = parser.parse_args()
    child = subprocess.Popen([str(args.scratch / "ssh"), "-T", "easl-guest", "python3", "-u", "-c", shlex.quote(REMOTE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def read_exact(size):
        data = b""
        deadline = time.monotonic() + 60
        while len(data) < size:
            assert time.monotonic() < deadline, "calibration read timeout"
            ready, _, _ = select.select([child.stdout], [], [], max(0, deadline - time.monotonic()))
            assert ready, "calibration read timeout"
            block = os.read(child.stdout.fileno(), size - len(data))
            assert block, "calibration SSH closed"
            data += block
        return data

    samples = []
    try:
        assert read_exact(5) == b"READY"
        for _ in range(10):
            start = time.monotonic()
            child.stdin.write(b"e")
            child.stdin.flush()
            assert read_exact(1) == b"e"
            samples.append(1000 * (time.monotonic() - start))
        start = time.monotonic()
        child.stdin.write(b"d")
        child.stdin.flush()
        data = read_exact(65536)
        download_s = time.monotonic() - start
        assert data == b"".join(bytes([i]) * 1024 for i in range(64))
        start = time.monotonic()
        child.stdin.write(b"u" + bytes(65536))
        child.stdin.flush()
        assert read_exact(1) == b"U"
        upload_s = time.monotonic() - start
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.terminate()
            child.wait(timeout=5)
    assert child.returncode == 0, child.stderr.read().decode()
    result = {"profile": args.profile, "rtt_ms": samples, "rtt_median_ms": statistics.median(samples), "download_s": download_s, "upload_s": upload_s, "download_kbit_s": 65536 * 8 / download_s / 1000, "upload_kbit_s": 65536 * 8 / upload_s / 1000, "payload_bytes_per_direction": 65536, "failures": 0}
    print(json.dumps(result, indent=2), flush=True)
    (args.scratch / ("calibration-" + args.profile + ".json")).write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
