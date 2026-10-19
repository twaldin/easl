#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import threading
import time


URL = "http://127.0.0.1:9/closed-board-navigation"
SOURCE = "// " + URL + "\ntarget()\nfunc target() {}"


def main():
    parser = argparse.ArgumentParser(description="Delay an actual sourcekit-lsp reply for the closed-board regression.")
    parser.add_argument("mode", choices=["prepare", "serve"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--server", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    server = args.server.resolve(strict=True)
    control = root / ".closed-board-lsp"
    if args.mode == "prepare":
        root.mkdir(parents=True, exist_ok=True)
        control.mkdir()
        for name in ("main.swift", "ax-control.swift"):
            with (root / name).open("x") as stream:
                stream.write(SOURCE)
        command = [sys.executable, str(Path(__file__).resolve()), "serve", "--root", str(root), "--server", str(server)]
        launcher = control / "sourcekit-gate"
        launcher.write_text("#!/bin/sh\nexec " + shlex.join(command) + "\n")
        launcher.chmod(0o755)
        (control / "fixture.json").write_text(json.dumps({"root": str(root), "server": str(server), "source": SOURCE, "url": URL}, indent=2) + "\n")
        print(json.dumps({"EASL_LSP_SWIFT": str(launcher), "fixtureDirectory": str(root)}))
        return

    child = subprocess.Popen([str(server)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr.buffer, cwd=root)
    lock = threading.Lock()
    requests = {}
    held = {}
    finished = threading.Event()
    errors = []

    def record(kind, **fields):
        with lock:
            with (control / "events.jsonl").open("a") as stream:
                stream.write(json.dumps({"kind": kind, "pid": os.getpid(), "serverPID": child.pid, "at": time.monotonic_ns(), **fields}) + "\n")

    def frame(stream):
        header = bytearray()
        length = None
        while True:
            line = stream.readline()
            if not line:
                if header:
                    raise RuntimeError("Truncated LSP header")
                return None
            header.extend(line)
            if line in (b"\r\n", b"\n"):
                break
            name, value = line.split(b":", 1)
            if name.lower() == b"content-length":
                length = int(value.strip())
        if length is None:
            raise RuntimeError("LSP frame has no Content-Length")
        body = stream.read(length)
        if len(body) != length:
            raise RuntimeError("Truncated LSP body")
        return bytes(header) + body, json.loads(body)

    def forward_requests():
        try:
            while True:
                incoming = frame(sys.stdin.buffer)
                if incoming is None:
                    break
                raw, message = incoming
                method = message.get("method")
                if method and "id" in message:
                    with lock:
                        requests[message["id"]] = method
                    arm = control / "arm.json"
                    if arm.exists():
                        request = json.loads(arm.read_text())
                        if request["method"] == method:
                            with lock:
                                held[message["id"]] = request["token"]
                            arm.unlink()
                record("request", message=message)
                child.stdin.write(raw)
                child.stdin.flush()
        except BaseException as error:
            errors.append(repr(error))
        finally:
            child.stdin.close()
            finished.set()

    def forward_replies():
        try:
            while True:
                incoming = frame(child.stdout)
                if incoming is None:
                    break
                raw, message = incoming
                with lock:
                    method = requests.get(message.get("id"))
                    token = held.pop(message.get("id"), None)
                record("reply", method=method, message=message)
                if token is not None:
                    receipt = control / (token + ".held.json")
                    pending = receipt.with_suffix(".tmp")
                    pending.write_text(json.dumps({"method": method, "message": message}, indent=2) + "\n")
                    pending.replace(receipt)
                    release = control / (token + ".release")
                    deadline = time.monotonic() + 20
                    while not release.exists() and not finished.is_set():
                        if time.monotonic() >= deadline:
                            raise RuntimeError("The runner did not release " + token)
                        time.sleep(0.01)
                    if finished.is_set():
                        break
                    release.unlink()
                sys.stdout.buffer.write(raw)
                sys.stdout.buffer.flush()
                record("delivered", method=method, token=token, message=message)
        except BaseException as error:
            errors.append(repr(error))
        finally:
            finished.set()

    record("launch", server=str(server))
    threading.Thread(target=forward_requests, daemon=True).start()
    threading.Thread(target=forward_replies, daemon=True).start()
    finished.wait()
    if errors:
        record("error", errors=errors)
        raise RuntimeError("; ".join(errors))


if __name__ == "__main__":
    main()
