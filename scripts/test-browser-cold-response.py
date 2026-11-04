#!/usr/bin/env python3
"""Check a cold browser's first click against an explicitly held HTTP response.

Run on the same machine as an already started scratch dev app. The sockets must
be the app's own easl.sock and unauthenticated cmux.sock, not easld's sockets.
This runner never starts, stops, focuses, or clears the app or its board.
"""

import argparse
import http.server
import json
from pathlib import Path
import socket
import sys
import threading
import time
import uuid


SOCKET_TIMEOUT = 35


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-socket", required=True)
    parser.add_argument("--cmux-socket", required=True)
    parser.add_argument("--output", required=True, type=Path,
                        help="JSONL evidence, including failures and cleanup")
    args = parser.parse_args()
    failures = []
    requested = threading.Event()
    release = threading.Event()
    answered = threading.Event()
    log_lock = threading.Lock()
    click = {}
    tile = None
    worker = None
    request_count = 0
    token = uuid.uuid4().hex
    page_path = "/cold-" + token
    title = "Cold response " + token
    body = ("<!doctype html><meta charset='utf-8'><title>" + title + "</title>"
            "<script>window.clicks=0;window.lastClick=null;function go(){"
            "window.clicks++;window.lastClick={url:location.href,title:document.title,"
            "readyState:document.readyState};}</script>"
            "<button id='go' onclick='go()'>Go</button>").encode()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as output:
        def record(event, **fields):
            with log_lock:
                stamp = time.monotonic_ns()
                output.write(json.dumps({"monotonic_ns": stamp, "event": event, **fields}) + "\n")
                output.flush()
                return stamp

        def call(path, method, params, request_id):
            wire = json.dumps({"id": request_id, "method": method, "params": params}) + "\n"
            try:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(SOCKET_TIMEOUT)
                    connection.connect(path)
                    record("socket.request", socket=path, raw=wire)
                    connection.sendall(wire.encode())
                    with connection.makefile("rb") as reader:
                        raw = reader.readline()
                    stamp = record("socket.reply", socket=path, request_id=request_id,
                                   raw=raw.decode("utf-8", errors="replace"))
                if not raw.endswith(b"\n"):
                    raise RuntimeError(f"{method}: connection closed without a complete reply")
                reply = json.loads(raw)
                if reply.get("id") != request_id:
                    raise RuntimeError(f"{method}: unexpected reply id: {reply!r}")
                return reply, stamp
            except Exception as error:
                record("socket.error", socket=path, request_id=request_id, error=repr(error))
                raise

        def result(reply):
            if reply.get("ok") is not True:
                raise RuntimeError(f"Socket command failed: {reply!r}")
            return reply["result"]

        class Handler(http.server.BaseHTTPRequestHandler):
            timeout = 5

            def log_message(self, *_):
                pass

            def do_GET(self):
                nonlocal request_count
                record("fixture.request", method=self.command, path=self.path)
                if self.path != page_path:
                    self.send_error(404)
                    return
                with log_lock:
                    request_count += 1
                requested.set()
                release.wait()
                record("fixture.response.begin", path=self.path, status=200)
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(body)
                    self.wfile.flush()
                    record("fixture.response.end", path=self.path)
                except (BrokenPipeError, ConnectionResetError) as error:
                    record("fixture.response.error", path=self.path, error=repr(error))

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = False

        server = Server(("127.0.0.1", 0), Handler)
        fixture = threading.Thread(target=server.serve_forever, name="cold-response-http")
        fixture.start()
        url = f"http://127.0.0.1:{server.server_port}{page_path}"
        record("run.start", url=url, title=title, api_socket=args.api_socket,
               cmux_socket=args.cmux_socket, observation_seconds=1,
               clock="time.monotonic_ns", socket_watchdog_seconds=SOCKET_TIMEOUT)
        try:
            view = result(call(args.api_socket, "view.get", {}, "view")[0])
            rect = view["viewport"]["rect"]
            created = result(call(args.api_socket, "object.create", {
                "board": view["board"], "type": "browser",
                "frame": {"x": rect["x"] + rect["w"] + 1_000_000,
                          "y": rect["y"] + rect["h"] + 1_000_000,
                          "w": 640, "h": 480},
                "props": {"url": url, "title": title},
            }, "create")[0])
            tile = created["object"]["id"]

            def first_click():
                try:
                    click["fixture_requested_before_click"] = requested.is_set()
                    record("click.start", surface_id=tile,
                           fixture_requested_before_click=click["fixture_requested_before_click"])
                    click["reply"], click["reply_ns"] = call(args.cmux_socket, "browser.click", {
                        "surface_id": tile, "selector": "#go",
                    }, "first-click")
                except Exception as error:
                    click["error"] = repr(error)
                finally:
                    answered.set()

            if requested.is_set():
                failures.append("Fixture requested before first command; browser was not cold")
            worker = threading.Thread(target=first_click, name="cold-first-click")
            worker.start()
            if not requested.wait(10):
                raise RuntimeError("Initial HTTP request never arrived within 10 seconds")
            record("observation.begin", command_answered=answered.is_set())
            threading.Event().wait(1)
            early = answered.is_set()
            record("observation.end", command_answered=early, click=click.copy())
            release_ns = record("fixture.release")
            release.set()
            if not answered.wait(SOCKET_TIMEOUT):
                raise RuntimeError("First click worker exceeded transport watchdog")
            worker.join()
            if early or click.get("reply_ns", release_ns) < release_ns:
                failures.append("First click answered while its initial HTTP response was held")
            if "error" in click:
                failures.append("First click transport failed: " + click["error"])
            elif click["reply"].get("ok") is not True:
                failures.append("First click failed: " + json.dumps(click["reply"]))
            if click.get("fixture_requested_before_click"):
                failures.append("Fixture requested before click dispatch; cold precondition was not met")

            result(call(args.cmux_socket, "browser.wait", {
                "surface_id": tile, "load_state": "complete", "timeout_ms": 2000,
            }, "settled-document")[0])
            readback = result(call(args.cmux_socket, "browser.eval", {
                "surface_id": tile,
                "script": "({url:location.href,title:document.title,readyState:document.readyState,"
                          "clicks:window.clicks,lastClick:window.lastClick})",
            }, "independent-readback")[0])["value"]
            record("readback", value=readback)
            if not isinstance(readback, dict) or not (
                readback.get("url") == url and readback.get("title") == title
                and readback.get("clicks") == 1
                and isinstance(readback.get("lastClick"), dict)
                and readback["lastClick"].get("url") == url
                and readback["lastClick"].get("title") == title
            ):
                failures.append("Independent readback did not prove exactly one click in the correct document")
        except Exception as error:
            failures.append(repr(error))
            record("run.error", error=repr(error))
        finally:
            if not release.is_set():
                record("fixture.release", cleanup=True)
                release.set()
            if worker is not None:
                worker.join(timeout=SOCKET_TIMEOUT + 1)
                if worker.is_alive():
                    failures.append("First click thread did not stop")
            if tile is not None:
                try:
                    result(call(args.api_socket, "object.delete", {"id": tile}, "cleanup")[0])
                except Exception as error:
                    failures.append("Created browser cleanup failed: " + repr(error))
            server.shutdown()
            server.server_close()
            fixture.join(timeout=5)
            if fixture.is_alive():
                failures.append("Fixture thread did not stop")
            if request_count != 1:
                failures.append(f"Expected one initial fixture request, got {request_count}")
            record("run.finish", passed=not failures, failures=failures,
                   initial_request_count=request_count)
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    if not failures:
        print("PASS: first cold click waited for release and clicked its own document exactly once")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
