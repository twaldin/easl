#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import platform
import re
import shlex
import signal
import subprocess
import tempfile


CASES = [(kind, duration) for kind in ("busy", "blocked") for duration in (300, 600, 1500)] + [("late-busy", 300), ("late-blocked", 300)]


def main_frames(text):
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if re.search(r"(?:Thread[^\n]*(?:com\.apple\.main-thread|\bmain thread\b)|^Main thread(?: backtrace| stack)?:?\s*$)", line, re.I):
            end = index + 1
            while end < len(lines):
                if re.search(r"^\s*(?:\+\s*)?\d*\s*Thread(?:\b|_)", lines[end]):
                    break
                if lines[end].startswith(("Total number in stack", "Binary Images:")):
                    break
                end += 1
            return "\n".join(lines[index + 1:end])
    raise ValueError("saved record has no identifiable main-thread stack")


def validate(home, kind, duration, result, ci_timing_report_only):
    metrics = json.loads((home / "metrics.json").read_text())
    stalls = metrics.get("stalls", {})
    longest = metrics.get("longest", {})
    result["longest"] = longest
    latency_timing = {"event": "capture-latency", "captureLatencyMs": None,
                      "minimumExclusiveMs": 0, "limitMs": 300, "withinLimit": False,
                      "assertsTiming": not ci_timing_report_only}
    window = json.loads((home / "stall-window.json").read_text())
    turn_timing = {"event": "capture-inside-stall", "captureUptimeNs": None,
                   "startedNs": window["startedNs"], "endedNs": window["endedNs"],
                   "withinLimit": False, "assertsTiming": result["mandatory"]}
    record_timing = {"event": "record-before-turn-end", "sampledBeforeTurnEnd": window["sampledBeforeTurnEnd"],
                     "withinLimit": window["sampledBeforeTurnEnd"] == 1,
                     "assertsTiming": not ci_timing_report_only and duration > 300}
    result["timings"] = [latency_timing, turn_timing, record_timing]
    newest = stalls.get("newest", "")
    relative = pathlib.PurePosixPath(newest)
    if relative.is_absolute() or len(relative.parts) != 2 or relative.parts[0] != "stalls":
        raise ValueError(f"invalid app.metrics stalls.newest: {newest!r}")
    record = home / newest
    text = record.read_text()
    result["record"] = newest
    match = re.search(r"(?m)^Capture latency ms: ([0-9.]+)$", text)
    latency = float(match[1]) if match else None
    latency_timing.update(captureLatencyMs=latency, withinLimit=latency is not None and 0 < latency < 300)
    captured = re.search(r"(?m)^Capture uptime ns: ([0-9]+)$", text)
    captured_ns = int(captured[1]) if captured else None
    turn_timing.update(captureUptimeNs=captured_ns,
                       withinLimit=captured_ns is not None and window["startedNs"] <= captured_ns < window["endedNs"])
    if stalls.get("sampled") != 1:
        raise ValueError(f"app.metrics stalls.sampled must be 1, got {stalls!r}")
    if not text.strip():
        raise ValueError("saved stall record is empty")
    cause = longest.get("cause", "")
    if newest not in cause:
        raise ValueError(f"app.metrics longest.cause does not name saved record {newest!r}: {cause!r}")
    if longest.get("ms", 0) < 250:
        raise ValueError("app.metrics longest does not describe a >=250 ms turn")
    frames = main_frames(text)
    expected = r"stallBusyLoop" if kind.endswith("busy") else r"(?:semaphore_wait(?:_trap)?|dispatch_semaphore_wait|DispatchSemaphore\.wait)"
    if not re.search(expected, frames):
        raise ValueError(f"main-thread stack does not contain actual {kind} work; idle-only stacks are not sufficient")
    walked = "\n".join(line for line in frames.splitlines() if "[LR candidate;" not in line)
    if kind.endswith("blocked") and "stallBlockedWait" not in walked:
        raise ValueError("main-thread walk must identify the function blocked in the wait")
    state = "on-CPU" if kind.endswith("busy") else "blocked in a wait"
    if not ci_timing_report_only and f"State: {state}" not in text:
        raise ValueError(f"saved record does not classify the main thread as {state}")
    if not turn_timing["withinLimit"]:
        raise ValueError("capture must start after its turn begins and before that same turn ends")
    if latency_timing["assertsTiming"] and not latency_timing["withinLimit"]:
        raise ValueError("capture latency must be positive and below 300 ms")
    if record_timing["assertsTiming"] and not record_timing["withinLimit"]:
        raise ValueError("qualified record must exist before the longer main-thread turn ends")


def main():
    parser = argparse.ArgumentParser(description="Run real main-thread stall captures against a native testing-enabled Easl build.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--ci-timing-report-only", action="store_true",
                        help="CI only: report all 300 ms cases without gating; require work captures inside 600/1500 ms turns, but do not enforce the 300 ms capture-latency target.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This native regression requires macOS.")
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link_file = build / "Easl.product" / "Objects.LinkFileList"
    if not link_file.is_file() or not (build / "description.json").is_file():
        parser.error("Build Easl release with --build-system native and testing enabled first; this runner never rebuilds the app.")
    output = args.output.resolve() if args.output else pathlib.Path(tempfile.mkdtemp(prefix="easl-stall-proof-", dir="/tmp"))
    output.mkdir(parents=True, exist_ok=True)
    print(f"Evidence: {output}", flush=True)
    objects = [pathlib.Path(p) for p in shlex.split(link_file.read_text())]
    for module in ("CanvasApp.build", "CanvasCore.build"):
        if not any(module in p.parts for p in objects):
            parser.error(f"The Easl link file does not contain {module} objects.")
    missing = [str(p) for p in objects if not p.is_file()]
    if missing:
        parser.error(f"Missing compiled objects: {missing}")
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    command = [compiler, "-swift-version", "6", "-parse-as-library", "-enable-testing", "-O", "-g",
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
    executable = output / "StallSamplerRegression"
    command.append(str(root / "Tests/StallSampler/StallSampler.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-Xlinker", "-e", "-Xlinker", "_EaslStallRegressionMain", "-o", str(executable)])
    (output / "compile-command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (output / "compile.log").open("w") as log:
        subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    results = []
    for kind, duration in CASES:
        name = f"{kind}-{duration}"
        home = pathlib.Path(tempfile.mkdtemp(prefix=f"{name}-", dir=output))
        environment = os.environ.copy()
        environment.update(HOME=str(home), EASL_HOME=str(home), CFFIXED_USER_HOME=str(home),
                           XDG_CONFIG_HOME=str(home), EASL_NO_ACTIVATE="1", TMPDIR=str(home))
        for key in ("EASL_ROOT", "EASL_DEV_PERF"):
            environment.pop(key, None)
        result = {"case": name, "home": str(home), "passed": False,
                  "mandatory": not args.ci_timing_report_only or duration > 300}
        try:
            with (home / "child.log").open("w") as log:
                child = subprocess.Popen([str(executable), kind, str(duration)], cwd=root, env=environment,
                                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    status = child.wait(timeout=25)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                    raise ValueError("child exceeded its 25 s lifetime")
            if status:
                raise ValueError(f"child exited with status {status}")
            validate(home, kind, duration, result, args.ci_timing_report_only)
            result["passed"] = True
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result["error"] = str(error)
        results.append(result)
        label = "PASS" if result["passed"] else "FAIL" if result["mandatory"] else "REPORT"
        print(f"{label} {name}: {result.get('error', result.get('record'))}", flush=True)
        for timing in result.get("timings", []):
            print(json.dumps({"case": name, **timing}, sort_keys=True), flush=True)
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    mandatory = [result for result in results if result["mandatory"]]
    failures = sum(not result["passed"] for result in mandatory)
    print(f"{len(results)} cases run; {len(mandatory) - failures}/{len(mandatory)} required cases passed; "
          f"{len(results) - len(mandatory)} report-only; {failures} failures; evidence: {output}")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
