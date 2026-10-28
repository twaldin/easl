#!/usr/bin/env python3
import argparse
import contextlib
import hashlib
import json
import os
import pathlib
import platform
import shlex
import subprocess
import tempfile


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
        description="Link an optimized native NoteTile proof against an existing build, then measure geometry, lifecycle and warm prose churn. Never rebuilds Easl.",
        epilog="Old hostile inputs are plain Mermaid source files supplied as repeated --fixture NAME=PATH, for example sequence590, nested-cross, treemap and radar1100. --stage-seconds writes stage.json with the exact native PID/window number before each screenshot pause; capture that window, not the desktop.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path,
                        help="Existing optimized native build with testable CanvasApp and CanvasCore modules.")
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2],
                        help="Repository checkout containing this runner's Swift source and Easl resources. Defaults to this script's checkout.")
    parser.add_argument("--scratch", type=pathlib.Path,
                        help="Work directory for the linked proof executable and isolated temporary home. Defaults to an owned temporary directory.")
    parser.add_argument("--fixture", action="append", default=[], metavar="NAME=PATH",
                        help="External UTF-8 Mermaid source to render, display and include in largest-raster selection. Repeat for each old hostile source.")
    parser.add_argument("--stage-seconds", type=float, default=0,
                        help="Pause at native geometry/scroll/selection stages for exact PID/window capture. Default 0.")
    parser.add_argument("--timeout", type=float, default=600,
                        help="Whole native process deadline in seconds, including screenshot pauses. Default 600.")
    parser.add_argument("--artifacts", type=pathlib.Path,
                        help="Directory for PNGs, JSONL and cleanup metadata. Defaults under explicit --scratch, otherwise under --bin-path.")
    parser.add_argument("--recovery-only", action="store_true",
                        help="Run only the natural-timeout/ordinary-diagram recovery regression.")
    parser.add_argument("--spell-probe", action="store_true")
    parser.add_argument("--profile", action="store_true",
                        help="Keep image assertions, disable only the 50ms limit, and pause 3s after each churn-ready event for sampling.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS with a native window session.")
    owner = tempfile.TemporaryDirectory(prefix="easl-native-proof-") if args.scratch is None else contextlib.nullcontext(str(args.scratch.resolve()))
    with owner as scratch:
        run(args, parser, pathlib.Path(scratch))


def run(args, parser, scratch):
    root = args.repo.resolve()
    source = root / "Tests/NoteMermaidChurn/NoteMermaidChurn.swift"
    if not source.is_file():
        parser.error(f"Missing native proof source: {source}")
    if not 0 <= args.stage_seconds <= 60 or not 0 < args.timeout < float("inf"):
        parser.error("--stage-seconds must be in 0...60 and --timeout must be positive and finite.")
    fixtures = []
    for value in args.fixture:
        name, separator, filename = value.partition("=")
        if not separator or not name or not all(c.isalnum() or c in "-_" for c in name):
            parser.error("--fixture requires NAME=PATH with an alphanumeric, hyphen or underscore name.")
        path = pathlib.Path(filename).resolve()
        if not path.is_file():
            parser.error(f"Missing fixture {name}: {path}")
        if any(existing[0] == name for existing in fixtures):
            parser.error(f"Duplicate fixture name: {name}")
        fixtures.append((name, path))
    scratch.mkdir(parents=True, exist_ok=True)
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
    probe_object = scratch / "GapProbe.o"
    subprocess.run(["xcrun", "clang", "-O2", "-g", "-fno-omit-frame-pointer",
                    "-target", f"{platform.machine()}-apple-macosx14.0",
                    "-c", str(root / "Tests/NoteMermaidChurn/GapProbe.c"),
                    "-o", str(probe_object)], cwd=root, check=True)
    spell_object = scratch / "SpellProbe.o"
    subprocess.run(["xcrun", "clang", "-O2", "-target", f"{platform.machine()}-apple-macosx14.0",
                    "-c", str(root / "Tests/NoteMermaidChurn/SpellProbe.c"),
                    "-o", str(spell_object)], cwd=root, check=True)
    command = [compiler, "-O", "-g", "-swift-version", "6", "-parse-as-library", "-enable-testing",
               "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx14.0",
               "-I", str(build / "Modules"), "-I", str(build)]
    app = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "CanvasApp")
    arguments = app["otherArguments"]
    for index, argument in enumerate(arguments[:-1]):
        if argument == "-Xcc":
            command.extend(["-Xcc", arguments[index + 1]])
        elif argument == "-I" and "libghostty" in arguments[index + 1]:
            command.extend(["-I", arguments[index + 1]])
    executable = scratch / "NoteMermaidChurn"
    command.append(str(source))
    command.append(str(probe_object))
    command.append(str(spell_object))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-Xlinker", "-e", "-Xlinker", "_NoteMermaidChurnMain", "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    default_artifacts = scratch / "artifacts" if args.scratch is not None else build / "NoteMermaidChurn-artifacts"
    artifacts = (args.artifacts or default_artifacts).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    cleanup_record = None
    timed_out = False
    with tempfile.TemporaryDirectory(prefix="easl-note-mermaid-churn-", dir=scratch) as temporary:
        environment = os.environ.copy()
        environment.update(EASL_HOME=temporary, CFFIXED_USER_HOME=temporary,
                           XDG_CONFIG_HOME=temporary, XDG_CACHE_HOME=temporary,
                           EASL_NO_ACTIVATE="1", EASL_RESOURCES=str(root))
        environment.pop("EASL_ROOT", None)
        native_command = [str(executable), str(artifacts), "--stage-seconds", str(args.stage_seconds)]
        for name, path in fixtures:
            native_command.extend(["--fixture", f"{name}={path}"])
            emit({"event": "fixture-input", "fixture": name, "path": str(path),
                  "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
        if args.profile:
            native_command.append("--profile")
        if args.recovery_only:
            native_command.append("--recovery-only")
        if args.spell_probe:
            native_command.append("--spell-probe")
        native_log = artifacts / "native.jsonl"
        log = native_log.open("w")
        process = subprocess.Popen(native_command, cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
        emit({"event": "runner-start", "ownedPid": process.pid,
              "build": str(build), "optimizedObjects": True, "isolatedHome": temporary,
              "artifacts": str(artifacts), "profile": args.profile,
              "stageSeconds": args.stage_seconds, "repo": str(root), "scratch": str(scratch),
              "probeSha256": hashlib.sha256(executable.read_bytes()).hexdigest()})
        try:
            process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            cleanup_record = cleanup(process)
            cleanup_record.update(timedOut=timed_out, isolatedHome=temporary)
            (artifacts / "runner-cleanup.json").write_text(json.dumps(cleanup_record, indent=2, sort_keys=True) + "\n")
            emit(cleanup_record)
            log.close()
            print(native_log.read_text(), end="", flush=True)
    cleanup_record["isolatedHomeRemoved"] = not pathlib.Path(temporary).exists()
    (artifacts / "runner-cleanup.json").write_text(json.dumps(cleanup_record, indent=2, sort_keys=True) + "\n")
    if timed_out:
        parser.exit(1, f"Native regression exceeded {args.timeout}s; owned process cleanup is recorded.\n")
    if process.returncode:
        parser.exit(1, f"Native churn regression failed with exit {process.returncode}; see native JSON records and PNG artifacts.\n")


if __name__ == "__main__":
    main()
