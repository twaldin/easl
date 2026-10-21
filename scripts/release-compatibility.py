#!/usr/bin/env python3
"""Run the remote Core journey on the latest reachable stable release and its SDK on HEAD.

Requires macOS, Swift 6.4, Go from easld/go.mod, Bun, Python 3.11+, git, and tar.
Use --client-ref 1e857a2 to copy only the new Core suite into the release candidate.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
SUITE = Path("Tests/CanvasCoreTests/ReleaseCompatibilityTests.swift")


def git(*arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True).strip()


def previous_release() -> str:
    releases = []
    for tag in git("tag", "--merged", "HEAD", "--list").splitlines():
        match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag)
        if match:
            releases.append((tuple(map(int, match.groups())), tag))
    if not releases:
        raise RuntimeError("No reachable stable release tag. Fetch the full history and tags first.")
    return max(releases)[1]


def run(arguments: list[str], *, cwd: Path, log: Path, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(map(str, arguments)), flush=True)
    with log.open("w") as output:
        try:
            subprocess.run(arguments, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT,
                           check=True, timeout=1800)
        finally:
            print(log.read_text(), end="", flush=True)


def archive(ref: str, destination: Path, *paths: str) -> None:
    destination.mkdir()
    producer = subprocess.Popen(["git", "archive", ref, *paths], cwd=ROOT, stdout=subprocess.PIPE)
    try:
        subprocess.run(["tar", "-xf", "-", "-C", str(destination)], stdin=producer.stdout, check=True)
    finally:
        producer.stdout.close()
        status = producer.wait()
    if status:
        raise RuntimeError(f"git archive {ref} failed with {status}")


class Daemon:
    def __init__(self, executable: Path, home: Path, address: Path, log: Path):
        self.executable = executable
        self.home = home
        self.address = address
        self.log = log
        self.process: subprocess.Popen | None = None
        self.output = None

    def start(self) -> None:
        self.output = self.log.open("a")
        self.process = subprocess.Popen([str(self.executable), "--home", str(self.home),
                                         "--socket", str(self.address)], stdout=self.output, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"Daemon exited during startup: {self.log.read_text()}")
            try:
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.connect(str(self.address))
                return
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.025)
        raise RuntimeError(f"Daemon did not create {self.address}: {self.log.read_text()}")

    def stop(self) -> None:
        if self.process is None:
            return
        process, self.process = self.process, None
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise RuntimeError(f"Daemon failed to flush and stop: {self.log}")
        self.output.close()
        if process.returncode != 0:
            raise RuntimeError(f"Daemon exited with {process.returncode}: {self.log.read_text()}")


def load_released_sdk(source: Path):
    package = source / "clients/python/easl_sdk"
    spec = importlib.util.spec_from_file_location("easl_release_sdk", package / "__init__.py",
                                                submodule_search_locations=[str(package)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def legacy_journey(sdk, address: Path, root: Path, saved: dict | None = None) -> dict:
    client = sdk.Easl(socket_path=str(address), timeout=20)
    try:
        board = client.call("board.open", {"root": str(root)})["board"]
        if saved is None:
            def create(kind, props):
                return client.call("object.create", {"board": board, "type": kind, "props": props})["object"]["id"]

            note = create("note", {"markdown": "from the released Python SDK"})
            revision = client.call("object.get", {"id": note})["object"]["rev"]
            client.call("object.update", {"id": note, "rev": revision,
                                          "props": {"markdown": "legacy client edit persists"}})
            browser = create("browser", {"url": "https://example.com/legacy-client"})
            question = create("question", {"question": "Keep old clients working?",
                                           "options": [{"id": "yes", "label": "Yes"}],
                                           "asker": {"name": "released SDK"}, "archiveAfter": 86400})
            client.call("object.update", {"id": question, "props": {"status": "answered",
                                          "answer": {"option": "yes", "note": "old fields only"}}})
            saved = {"board": board, "note": note, "browser": browser, "question": question}
            client.call("board.close", {"board": board})
            require(client.call("board.open", {"root": str(root)})["board"] == board,
                    "Released SDK reopened another board")
        require(board == saved["board"], "Released SDK board identity changed across daemon restart")
        objects = {item["id"]: item for item in client.call("board.get", {"board": board})["objects"]}
        require(len(objects) == 3, "Released SDK objects did not persist")
        require(objects[saved["note"]]["props"]["markdown"] == "legacy client edit persists",
                "Released SDK edit did not persist")
        require(objects[saved["browser"]]["props"]["url"] == "https://example.com/legacy-client",
                "Released SDK browser URL did not persist")
        answer = objects[saved["question"]]["props"]
        require(answer["status"] == "answered" and answer["answer"]["option"] == "yes"
                and answer["answer"]["note"] == "old fields only", "Released SDK answer did not persist")
        return saved
    finally:
        client.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client-ref", help="Build this git revision with only the new compatibility suite added")
    parser.add_argument("--output-dir", type=Path, help="New directory for sources, scratch state, and logs")
    args = parser.parse_args()
    require(platform.system() == "Darwin", "The remote Core release gate requires macOS")
    require(sys.version_info >= (3, 11), "Python 3.11 or newer is required by the released SDK")
    for executable in ["swift", "go", "bun", "git", "tar"]:
        require(shutil.which(executable) is not None, f"Missing dependency: {executable}")
    swift = subprocess.check_output(["swift", "--version"], text=True)
    print(swift, end="", flush=True)
    require(re.search(r"Swift version 6\.4(?:\.|\s)", swift) is not None, "Select the Swift 6.4 toolchain")
    release = previous_release()
    client_ref = git("rev-parse", args.client_ref or "HEAD")
    if args.output_dir:
        output = args.output_dir.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        (ROOT / ".build").mkdir(exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="release-compat-", dir=ROOT / ".build"))
    print(f"Release compatibility evidence: {output}", flush=True)
    selection = {"release": release, "releaseCommit": git("rev-parse", release + "^{commit}"),
                 "clientCommit": client_ref, "daemonCommit": git("rev-parse", "HEAD")}
    (output / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")
    print(json.dumps(selection, indent=2), flush=True)
    previous = output / "previous"
    archive(release, previous, "easld", "conformance", "clients/python", "schema", "VERSION")
    old_bin = output / "previous-easld"
    new_bin = output / "current-easld"
    build_environment = {**os.environ, "GOWORK": "off"}
    run(["go", "build", "-p", "2", "-o", str(old_bin), "./cmd/easld"], cwd=previous / "easld",
        log=output / "build-previous.log", env=build_environment)
    run(["go", "build", "-p", "2", "-o", str(new_bin), "./cmd/easld"], cwd=ROOT / "easld",
        log=output / "build-current.log", env=build_environment)
    client_source = ROOT
    if args.client_ref:
        client_source = output / "client"
        archive(client_ref, client_source)
        shutil.copyfile(ROOT / SUITE, client_source / SUITE)
    journey = output / "journey"
    (journey / "root").mkdir(parents=True)
    transport = journey / "local-ssh"
    transport.write_text('#!/bin/sh\nfor command; do :; done\nexec /bin/sh -c "$command"\n')
    transport.chmod(0o755)
    legacy_root = output / "legacy-root"
    legacy_root.mkdir()
    sdk = load_released_sdk(previous)
    with tempfile.TemporaryDirectory(prefix="ec-", dir="/tmp") as sockets:
        old = Daemon(old_bin, output / "old-home", Path(sockets) / "old.sock", output / "old-daemon.log")
        current = Daemon(new_bin, output / "new-home", Path(sockets) / "new.sock", output / "new-daemon.log")
        try:
            old.start()
            environment = {**os.environ, "EASL_RELEASE_COMPATIBILITY": "1", "EASL_COMPAT_DIRECTORY": str(journey),
                           "EASL_COMPAT_SOCKET": str(old.address), "EASL_COMPAT_PHASE": "create"}
            command = ["swift", "run", "-j", "2", "CanvasCoreTests", "--no-parallel", "--filter", "ReleaseCompatibilityTests"]
            run(command, cwd=client_source, log=output / "core-journey.log", env=environment)
            old.stop()
            old.start()
            environment["EASL_COMPAT_PHASE"] = "reopen"
            run(["swift", "run", "--skip-build", *command[2:]], cwd=client_source,
                log=output / "core-reopen.log", env=environment)
            old.stop()
            current.start()
            saved = legacy_journey(sdk, current.address, legacy_root)
            current.stop()
            current.start()
            legacy_journey(sdk, current.address, legacy_root, saved)
            (output / "legacy-journey.json").write_text(json.dumps(saved, indent=2) + "\n")
            print(f"PASS: Core against {release}, saved-board restart, and the released SDK against HEAD", flush=True)
        finally:
            try:
                old.stop()
            finally:
                current.stop()


if __name__ == "__main__":
    main()
