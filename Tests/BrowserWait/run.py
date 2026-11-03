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
import urllib.parse


def main():
    parser = argparse.ArgumentParser(description="Check native browser waits across POST/303 document replacement.")
    parser.add_argument("--bin-path", required=True, type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This WebKit regression requires macOS.")
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
    executable = build / "BrowserWait"
    command.append(str(root / "Tests/BrowserWait/BrowserWait.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-Xlinker", "-e", "-Xlinker", "_EaslBrowserWaitMain", "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    gates = {name: threading.Event() for name in ("present", "absent")}
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        timeout = 10

        def log_message(self, *_):
            pass

        def respond(self, status, body, **headers):
            requests.append((self.command, self.path, status))
            print(json.dumps({"method": self.command, "path": self.path, "status": status}), flush=True)
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            for key, value in headers.items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.startswith("/armed/"):
                name = self.path.rsplit("/", 1)[1]
                gates[name].set()
                return self.respond(200, b"armed")
            if self.path.startswith("/account/"):
                name = self.path.rsplit("/", 1)[1]
                marker = ' id="authenticated"' if name == "present" else ""
                return self.respond(200, ('<!doctype html><h1' + marker + '>Dummy account</h1>').encode())
            name = self.path.strip("/")
            if name not in gates:
                return self.respond(404, b"not found")
            self.respond(200, ('<!doctype html><form method="POST" action="/login/' + name + '">'
                              '<input id="username" name="username"><input id="password" name="password" type="password">'
                              '<button id="signin">Sign in</button></form>').encode())

        def do_POST(self):
            name = self.path.rsplit("/", 1)[1]
            length = int(self.headers.get("Content-Length", "0"))
            if name not in gates or not 0 < length < 1024:
                return self.respond(400, b"invalid request")
            form = urllib.parse.parse_qs(self.rfile.read(length).decode())
            if form != {"username": ["dummy@example.invalid"], "password": ["dummy-only"]}:
                return self.respond(403, b"invalid dummy credentials")
            if not gates[name].wait(5):
                return self.respond(504, b"old document never entered selector wait")
            self.respond(303, b"", Location="/account/" + name)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="easl-browser-wait-") as temporary:
            environment = {**os.environ, "EASL_HOME": temporary, "CFFIXED_USER_HOME": temporary,
                           "XDG_CONFIG_HOME": temporary, "EASL_NO_ACTIVATE": "1", "EASL_BROWSER_PROFILE": "own",
                           "BROWSER_WAIT_ORIGIN": f"http://127.0.0.1:{server.server_port}"}
            environment.pop("EASL_ROOT", None)
            result = subprocess.run([str(executable)], cwd=root, env=environment, timeout=60)
            for name in gates:
                assert ("POST", "/login/" + name, 303) in requests, requests
                assert ("GET", "/account/" + name, 200) in requests, requests
            result.check_returncode()
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        assert not worker.is_alive()


if __name__ == "__main__":
    main()
