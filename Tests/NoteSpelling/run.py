#!/usr/bin/env python3
import argparse
import contextlib
import hashlib
import json
import os
import pathlib
import platform
import plistlib
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
        description="Link native NoteTile spelling coverage against an existing optimized Easl build. Never rebuilds Easl.",
        epilog="Strict regression is the default. --diagnostic records behavioral violations and continues through every phase; it is not a passing regression. --stacks adds actual singleton request stacks. --stage-seconds writes stage.json with the exact native PID/window number before each capture pause.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path)
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2])
    parser.add_argument("--scratch", type=pathlib.Path)
    parser.add_argument("--artifacts", type=pathlib.Path)
    parser.add_argument("--stage-seconds", type=float, default=0)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--diagnostic", action="store_true")
    parser.add_argument("--stacks", action="store_true")
    parser.add_argument("--defaults", choices=("all", "unset", "off", "on"), default="all",
                        help="Each permutation uses a fresh process and isolated global defaults. Default all runs unset, off and on.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS with a native window session.")
    if not 0 <= args.stage_seconds <= 60 or not 0 < args.timeout < float("inf"):
        parser.error("--stage-seconds must be in 0...60 and --timeout must be positive and finite.")
    owner = tempfile.TemporaryDirectory(prefix="easl-note-spelling-") if args.scratch is None else contextlib.nullcontext(str(args.scratch.resolve()))
    with owner as scratch:
        run(args, parser, pathlib.Path(scratch))


def run(args, parser, scratch):
    root = args.repo.resolve()
    sources = [root / "Tests/NoteSpelling/NoteSpelling.swift", root / "Tests/NoteSpelling/SpellProbe.c"]
    for source in sources:
        if not source.is_file():
            parser.error(f"Missing native proof source: {source}")
    scratch.mkdir(parents=True, exist_ok=True)
    build = args.bin_path.resolve()
    link_file = build / "Easl.product/Objects.LinkFileList"
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
            parser.error(f"{module} must use optimized release objects.")
    missing = [str(p) for p in objects if not p.is_file()]
    if missing:
        parser.error(f"Missing compiled objects: {missing}")
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = f"{platform.machine()}-apple-macosx14.0"
    probe = scratch / "SpellProbe.o"
    subprocess.run(["xcrun", "clang", "-O2", "-isysroot", sdk, "-target", target,
                    "-c", str(sources[1]), "-o", str(probe)], cwd=root, check=True)
    command = [compiler, "-O", "-swift-version", "6", "-parse-as-library", "-enable-testing",
               "-sdk", sdk, "-target", target, "-I", str(build / "Modules"), "-I", str(build)]
    app = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "CanvasApp")
    arguments = app["otherArguments"]
    for index, argument in enumerate(arguments[:-1]):
        if argument == "-Xcc":
            command.extend(["-Xcc", arguments[index + 1]])
        elif argument == "-I" and "libghostty" in arguments[index + 1]:
            command.extend(["-I", arguments[index + 1]])
    executable = scratch / "NoteSpelling"
    command.extend([str(sources[0]), str(probe)])
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty", "-framework", "AppKit",
                    "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-Xlinker", "-e", "-Xlinker", "_NoteSpellingMain", "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    default_artifacts = scratch / "artifacts" if args.scratch is not None else build / "NoteSpelling-artifacts"
    artifacts = (args.artifacts or default_artifacts).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    permutations = ("unset", "off", "on") if args.defaults == "all" else (args.defaults,)
    failed = []
    keys = ("NSAllowContinuousSpellChecking", "NSContinuousSpellCheckingEnabled", "NSGrammarCheckingEnabled",
            "NSAutomaticSpellingCorrectionEnabled", "NSAutomaticTextCompletionEnabled",
            "NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticDashSubstitutionEnabled",
            "NSAutomaticTextReplacementEnabled", "NSAutomaticLinkDetectionEnabled",
            "NSAutomaticDataDetectionEnabled")
    for permutation in permutations:
        directory = artifacts / permutation
        directory.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=f"home-{permutation}-", dir=scratch) as temporary:
            preferences = pathlib.Path(temporary) / "Library/Preferences"
            preferences.mkdir(parents=True)
            defaults = {"AppleLanguages": ["en"], "AppleLocale": "en_US"}
            if permutation != "unset":
                defaults.update({key: permutation == "on" for key in keys})
            (preferences / ".GlobalPreferences.plist").write_bytes(plistlib.dumps(defaults))
            environment = os.environ.copy()
            environment.update(EASL_HOME=temporary, CFFIXED_USER_HOME=temporary,
                               XDG_CONFIG_HOME=temporary, XDG_CACHE_HOME=temporary,
                               EASL_NO_ACTIVATE="1", EASL_RESOURCES=str(root))
            environment.pop("EASL_ROOT", None)
            native_command = [str(executable), str(directory), "--stage-seconds", str(args.stage_seconds)]
            if args.diagnostic:
                native_command.append("--diagnostic")
            if args.stacks:
                native_command.append("--stacks")
            timed_out = False
            native_log = directory / "native.jsonl"
            with native_log.open("w") as log:
                process = subprocess.Popen(native_command, cwd=root, env=environment,
                                           stdout=log, stderr=subprocess.STDOUT)
                emit({"event": "runner-start", "ownedPid": process.pid, "build": str(build),
                      "optimizedObjects": True, "isolatedHome": temporary, "defaultsPermutation": permutation,
                      "seededGlobalDefaults": defaults, "artifacts": str(directory),
                      "diagnostic": args.diagnostic, "stacks": args.stacks, "stageSeconds": args.stage_seconds,
                      "probeSha256": hashlib.sha256(executable.read_bytes()).hexdigest()})
                try:
                    process.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    timed_out = True
                finally:
                    receipt = cleanup(process)
                    receipt.update(timedOut=timed_out, isolatedHome=temporary, defaultsPermutation=permutation)
                    (directory / "runner-cleanup.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
                    emit(receipt)
            print(native_log.read_text(), end="", flush=True)
        receipt["isolatedHomeRemoved"] = not pathlib.Path(temporary).exists()
        (directory / "runner-cleanup.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        if timed_out or process.returncode:
            failed.append(permutation)
    if failed:
        parser.exit(1, f"Native spelling regression failed for {', '.join(failed)}; see native JSON records.\n")
    emit({"event": "runner-result", "status": "diagnostic-only" if args.diagnostic else "passed",
          "defaultsPermutations": list(permutations)})


if __name__ == "__main__":
    main()
