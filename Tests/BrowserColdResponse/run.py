#!/usr/bin/env python3
import argparse
import http.server
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tempfile
import threading


def main():
    parser = argparse.ArgumentParser(description="Check cold native browser commands with initial response headers held.")
    parser.add_argument("--bin-path", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This native WebKit regression requires macOS.")
    root = Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link_file = build / "Easl.product/Objects.LinkFileList"
    if not link_file.is_file() or not (build / "description.json").is_file():
        parser.error("Build Easl with --build-system native and testing enabled first. This runner never rebuilds the app.")
    objects = [Path(p) for p in shlex.split(link_file.read_text())]
    for module in ("CanvasApp.build", "CanvasCore.build"):
        if not any(module in p.parts for p in objects):
            parser.error(f"The Easl link file does not contain {module} objects.")
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    command = [compiler, "-swift-version", "6", "-parse-as-library", "-enable-testing",
               "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx14.0",
               "-I", str(build / "Modules"), "-I", str(build)]
    description = json.loads((build / "description.json").read_text())
    app = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "CanvasApp")
    arguments = app["otherArguments"]
    for index, argument in enumerate(arguments[:-1]):
        if argument == "-Xcc":
            command.extend(["-Xcc", arguments[index + 1]])
        elif argument == "-I" and "libghostty" in arguments[index + 1]:
            command.extend(["-I", arguments[index + 1]])
    executable = build / "BrowserColdResponse"
    command.append(str(root / "Tests/BrowserColdResponse/BrowserColdResponse.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-Xlinker", "-e", "-Xlinker", "_EaslBrowserColdResponseMain", "-o", str(executable)])
    output = (args.output or build / "browser-cold-response-evidence").resolve()
    output.mkdir(parents=True, exist_ok=True)
    with (output / "link.log").open("w") as log:
        subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
    gates = {name: (threading.Event(), threading.Event()) for name in
             ("click", "eval", "snapshot", "timeout", "action-timeout", "eval-budget")}
    requests = []
    lock = threading.Lock()
    fixture_log = (output / "fixture.jsonl").open("w")

    def record(**event):
        with lock:
            requests.append(event)
            fixture_log.write(json.dumps(event) + "\n")
            fixture_log.flush()

    class Handler(http.server.BaseHTTPRequestHandler):
        timeout = 40

        def log_message(self, *_):
            pass

        def respond(self, status, body):
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                record(event="disconnected", path=self.path)

        def do_GET(self):
            parts = self.path.strip("/").split("/")
            if len(parts) != 2 or parts[1] not in gates:
                return self.respond(404, b"not found")
            operation, name = parts
            arrived, released = gates[name]
            if operation == "arrived":
                return self.respond(200 if arrived.wait(5) else 504, b"arrived")
            if operation == "release":
                record(event="release", name=name)
                released.set()
                return self.respond(200, b"released")
            if operation != "page":
                return self.respond(404, b"not found")
            record(event="request", name=name)
            arrived.set()
            if not released.wait(35):
                record(event="safety_cap", name=name)
                return self.respond(504, b"initial response was never released")
            record(event="headers", name=name)
            body = (f'<!doctype html><title>Held {name}</title>'
                    '<button id="go" onclick="window.coldClicks=(window.coldClicks||0)+1">Go</button>'
                    '<script>window.coldClicks=0</script>').encode()
            self.respond(200, body)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="easl-browser-cold-response-") as temporary:
            environment = {**os.environ, "EASL_HOME": temporary, "CFFIXED_USER_HOME": temporary,
                           "XDG_CONFIG_HOME": temporary, "EASL_NO_ACTIVATE": "1", "EASL_BROWSER_PROFILE": "own",
                           "BROWSER_COLD_RESPONSE_ORIGIN": f"http://127.0.0.1:{server.server_port}"}
            environment.pop("EASL_ROOT", None)
            with (output / "native.log").open("w") as log:
                result = subprocess.run([str(executable)], cwd=root, env=environment,
                                        stdout=log, stderr=subprocess.STDOUT, timeout=120)
            print((output / "native.log").read_text(), end="")
            print(f"Evidence: {output}")
            result.check_returncode()
            for name in gates:
                assert sum(e == {"event": "request", "name": name} for e in requests) == 1, requests
                assert {"event": "release", "name": name} in requests, requests
            assert not any(e["event"] == "safety_cap" for e in requests), requests
    finally:
        for _, released in gates.values():
            released.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        fixture_log.close()


if __name__ == "__main__":
    main()
