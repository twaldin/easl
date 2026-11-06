#!/usr/bin/env python3
import argparse
import fnmatch
import hashlib
import json
import os
import pathlib
import platform
import shlex
import subprocess
import tempfile
import time


def capture(command, directory, *, cwd, env=None, timeout=120):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    started = time.monotonic()
    with (directory / "stdout.log").open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
        process = None
        try:
            process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stdout, stderr=stderr)
            (directory / "process.json").write_text(json.dumps({"pid": process.pid, "command": command}, indent=2) + "\n")
            verdict = {"returncode": process.wait(timeout=timeout), "timed_out": False}
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            verdict = {"returncode": None, "timed_out": True}
        except KeyboardInterrupt:
            if process is not None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            verdict = {"returncode": None, "timed_out": False, "interrupted": True}
        except OSError as error:
            stderr.write(str(error) + "\n")
            verdict = {"returncode": None, "timed_out": False, "error": str(error)}
    verdict["duration_seconds"] = time.monotonic() - started
    (directory / "result.json").write_text(json.dumps(verdict, indent=2) + "\n")
    return verdict


def main():
    parser = argparse.ArgumentParser(description="Run active native selection/typing cases in a claimed macOS GUI against existing testing-enabled Easl objects. The app is never rebuilt.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--resources", type=pathlib.Path, help="Recorded app resources checkout, default: this checkout.")
    parser.add_argument("--harness-source", type=pathlib.Path, help="Use this exact Swift harness for both baseline and candidate objects.")
    parser.add_argument("--scenario", action="append", default=[], help="Case name or glob; repeat to select several cases.")
    parser.add_argument("--list", action="store_true", help="Link the harness and list cases without opening a window.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS and a guest GUI claim.")
    root = (args.resources or pathlib.Path(__file__).resolve().parents[2]).resolve()
    build = args.bin_path.resolve()
    output = args.output.resolve()
    resources = (args.resources or root).resolve()
    source = (args.harness_source or root / "Tests/SelectionTyping/SelectionTyping.swift").resolve()
    if not source.is_file():
        parser.error("--harness-source must name the native SelectionTyping Swift harness.")
    source_bytes = source.read_bytes()
    output.mkdir(parents=True, exist_ok=True)
    link_file = build / "Easl.product/Objects.LinkFileList"
    description_file = build / "description.json"
    if not link_file.is_file() or not description_file.is_file():
        parser.error("Pass an existing native, testing-enabled Easl build. This runner never rebuilds it.")
    if not (resources / "schema/easl-api.json").is_file():
        parser.error("--resources must contain the app's schema/easl-api.json.")
    objects = [pathlib.Path(p) for p in shlex.split(link_file.read_text())]
    for module in ("CanvasApp.build", "CanvasCore.build"):
        if not any(module in p.parts for p in objects):
            parser.error(f"The Easl link file does not contain {module} objects.")
    missing = [str(p) for p in objects if not p.is_file()]
    if missing:
        parser.error(f"Missing compiled objects: {missing}")
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    command = [compiler, "-O", "-swift-version", "6", "-parse-as-library", "-enable-testing",
               "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx14.0",
               "-I", str(build / "Modules"), "-I", str(build)]
    description = json.loads(description_file.read_text())
    app = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "CanvasApp")
    arguments = app["otherArguments"]
    for index, argument in enumerate(arguments[:-1]):
        if argument == "-Xcc":
            command.extend(["-Xcc", arguments[index + 1]])
        elif argument == "-I" and "libghostty" in arguments[index + 1]:
            command.extend(["-I", arguments[index + 1]])
    executable = output / "SelectionTyping"
    command.append(str(source))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty", "-framework", "AppKit",
                    "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-Xlinker", "-e", "-Xlinker", "_SelectionTypingMain", "-o", str(executable)])
    (output / "inputs.json").write_text(json.dumps({"bin_path": str(build), "resources": str(resources),
        "link_file": str(link_file), "objects": [str(p) for p in objects], "sdk": sdk,
        "harness_source": str(source), "harness_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "runner_sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
        "build_binary_sha256": hashlib.sha256((build / "Easl").read_bytes()).hexdigest(),
        "normal_events": "AppKit queue with an observed dispatch marker, then an asynchronous main-run-loop wake",
        "wheel_events": "DevInput.replay into the recorded native window and hit-tested point; assert document movement and keyboard ownership",
        "immediate_html_events": "back-to-back NSApp.sendEvent mouseDown and keyDown without yielding"}, indent=2) + "\n")
    compiled = capture(command, output / "link", cwd=root)
    if compiled["returncode"] != 0:
        raise SystemExit(f"Harness link failed: {compiled}; see {output / 'link'}")
    listing = capture([str(executable), "--list"], output / "list", cwd=root)
    if listing["returncode"] != 0:
        raise SystemExit(f"Harness listing failed: {listing}; see {output / 'list/stderr.log'}")
    (output / "executable.json").write_text(json.dumps({
        "sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}, indent=2) + "\n")
    cases = json.loads((output / "list/stdout.log").read_text())
    if args.scenario:
        unknown = [pattern for pattern in args.scenario if not any(fnmatch.fnmatchcase(case["name"], pattern) for case in cases)]
        if unknown:
            parser.error("No cases match: " + ", ".join(unknown))
        cases = [case for case in cases if any(fnmatch.fnmatchcase(case["name"], pattern) for pattern in args.scenario)]
    (output / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
    if args.list:
        for case in cases:
            print(f"{case['name']}\t{case['baseline']}")
        return
    results = []
    for case in cases:
        directory = output / case["name"]
        with tempfile.TemporaryDirectory(prefix="easl-selection-", dir="/tmp") as temporary:
            environment = os.environ.copy()
            environment.update(EASL_HOME=temporary, CFFIXED_USER_HOME=temporary,
                XDG_CONFIG_HOME=temporary, XDG_STATE_HOME=temporary + "/state", EASL_NO_ACTIVATE="0",
                EASL_DEV_INPUT="0", EASL_RESOURCES=str(resources), EASL_BROWSER_PROFILE="own", SHELL="/bin/sh",
                ZMX_DIR=temporary + "/zmx", TMPDIR=temporary + "/tmp",
                GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_COUNT="0")
            for key in ("EASL_ROOT", "EASL_SOCKET", "EASL_BOARD", "EASL_TILE", "ZMX_SESSION",
                        "GIT_CONFIG", "GIT_CONFIG_PARAMETERS"):
                environment.pop(key, None)
            for child in ("zmx", "tmp", "state"):
                (pathlib.Path(temporary) / child).mkdir()
            ghostty = pathlib.Path(temporary) / "ghostty"
            ghostty.mkdir()
            (ghostty / "config").write_text("shell-integration = none\n")
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "environment.json").write_text(json.dumps({key: environment[key] for key in (
                "HOME", "EASL_HOME", "CFFIXED_USER_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_COUNT",
                "XDG_CONFIG_HOME", "EASL_RESOURCES", "EASL_NO_ACTIVATE", "EASL_DEV_INPUT", "SHELL", "ZMX_DIR", "TMPDIR")}, indent=2) + "\n")
            try:
                verdict = capture([str(executable), case["name"]], directory, cwd=root, env=environment, timeout=90)
            finally:
                sessions = pathlib.Path(temporary) / "sessions.json"
                if sessions.exists():
                    (directory / "sessions.json").write_bytes(sessions.read_bytes())
                for receipt in (pathlib.Path(temporary) / "board").glob("input-*.bin"):
                    (directory / receipt.name).write_bytes(receipt.read_bytes())
                cleanup = capture([str(root / "scripts/dev.sh"), "stop"], directory / "cleanup", cwd=root,
                    env={**environment, "EASL_DEV_HOME": temporary}, timeout=30)
            stdout = (directory / "stdout.log").read_text()
            stderr = (directory / "stderr.log").read_text()
            passed = verdict["returncode"] == 0 and f"PASS {case['name']}\n" in stdout and cleanup["returncode"] == 0
            record = {**case, **verdict, "passed": passed, "cleanup": cleanup}
            results.append(record)
            (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"{'PASS' if passed else 'FAIL'} {case['name']} [{case['baseline']}]", flush=True)
            if not passed:
                print(stdout + stderr, end="", flush=True)
            if verdict.get("interrupted"):
                raise SystemExit("Selection/typing interrupted; partial records retained.")
    if not all(result["passed"] for result in results):
        raise SystemExit("Selection/typing failures: " + ", ".join(result["name"] for result in results if not result["passed"]))


if __name__ == "__main__":
    main()
