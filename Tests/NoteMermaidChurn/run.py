#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import platform
import shlex
import subprocess
import tempfile
import time


def emit(record):
    print(json.dumps(record, sort_keys=True), flush=True)




def cleanup(process):
    signals = []
    if process.poll() is None:
        process.terminate()
        signals.append("SIGTERM")
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            signals.append("SIGKILL")
    process.wait(timeout=5)
    return {"event": "runner-cleanup", "ownedPid": process.pid, "signals": signals,
            "nativeReturnCode": process.returncode, "nativeReaped": process.poll() is not None}


def main():
    parser = argparse.ArgumentParser(
        description="Measure warm native NoteTile prose churn with real local Mermaid rasters. Never rebuilds Easl.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path,
                        help="Existing optimized native build with testable CanvasApp and CanvasCore modules.")
    parser.add_argument("--artifacts", type=pathlib.Path,
                        help="Directory for native note PNGs and runner cleanup metadata. Defaults under --bin-path.")
    parser.add_argument("--profile", action="store_true",
                        help="Keep image assertions, disable only the 50ms limit, and pause 3s after each churn-ready event for sampling.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS with a native window session.")
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link_file = build / "Easl.product" / "Objects.LinkFileList"
    description_file = build / "description.json"
    if not link_file.is_file() or not description_file.is_file():
        parser.error("Build optimized Easl with --build-system native and -enable-testing first. This runner never rebuilds the app.")
    objects = [pathlib.Path(p) for p in shlex.split(link_file.read_text())]
    description = json.loads(description_file.read_text())
    for module in ("CanvasApp", "CanvasCore"):
        if not any(f"{module}.build" in p.parts for p in objects):
            parser.error(f"The Easl link file does not contain {module}.build objects.")
        commands = [value for value in description["swiftCommands"].values() if value["moduleName"] == module]
        if not commands or any(not {"-O", "-Osize"}.intersection(command["otherArguments"])
                               or "-Onone" in command["otherArguments"] for command in commands):
            parser.error(f"{module} must use optimized release objects. A debug build is not a performance baseline.")
    missing = [str(p) for p in objects if not p.is_file()]
    if missing:
        parser.error(f"Missing compiled objects: {missing}")
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    command = [compiler, "-O", "-swift-version", "6", "-parse-as-library", "-enable-testing",
               "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx14.0",
               "-I", str(build / "Modules"), "-I", str(build)]
    app = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "CanvasApp")
    arguments = app["otherArguments"]
    for index, argument in enumerate(arguments[:-1]):
        if argument == "-Xcc":
            command.extend(["-Xcc", arguments[index + 1]])
        elif argument == "-I" and "libghostty" in arguments[index + 1]:
            command.extend(["-I", arguments[index + 1]])
    executable = build / "NoteMermaidChurn"
    command.append(str(root / "Tests/NoteMermaidChurn/NoteMermaidChurn.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-Xlinker", "-e", "-Xlinker", "_NoteMermaidChurnMain", "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    artifacts = (args.artifacts or build / "NoteMermaidChurn-artifacts").resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    cleanup_record = None
    timed_out = False
    with tempfile.TemporaryDirectory(prefix="easl-note-mermaid-churn-") as temporary:
        environment = os.environ.copy()
        environment.update(EASL_HOME=temporary, CFFIXED_USER_HOME=temporary,
                           XDG_CONFIG_HOME=temporary, XDG_CACHE_HOME=temporary,
                           EASL_NO_ACTIVATE="1", EASL_RESOURCES=str(root))
        environment.pop("EASL_ROOT", None)
        native_command = [str(executable), str(artifacts)]
        if args.profile:
            native_command.append("--profile")
        process = subprocess.Popen(native_command, cwd=root, env=environment)
        emit({"event": "runner-start", "ownedPid": process.pid,
              "build": str(build), "optimizedObjects": True, "isolatedHome": temporary,
              "artifacts": str(artifacts), "profile": args.profile})
        try:
            process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            cleanup_record = cleanup(process)
            cleanup_record.update(timedOut=timed_out, isolatedHome=temporary)
            (artifacts / "runner-cleanup.json").write_text(json.dumps(cleanup_record, indent=2, sort_keys=True) + "\n")
            emit(cleanup_record)
    cleanup_record["isolatedHomeRemoved"] = not pathlib.Path(temporary).exists()
    (artifacts / "runner-cleanup.json").write_text(json.dumps(cleanup_record, indent=2, sort_keys=True) + "\n")
    if timed_out:
        parser.exit(1, "Native churn regression exceeded 180s; owned process cleanup is recorded.\n")
    if process.returncode:
        parser.exit(1, f"Native churn regression failed with exit {process.returncode}; see native JSON records and PNG artifacts.\n")


if __name__ == "__main__":
    main()
