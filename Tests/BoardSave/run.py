#!/usr/bin/env python3
"""Exercise BoardStore's real slow atomic-write boundary and main-run-loop monitor."""
import argparse
import json
import os
import pathlib
import platform
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-path", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--baseline", action="store_true", help="Compile against the synchronous save API with the identical write-injection seam.")
    parser.add_argument("--ci-timing-report-only", action="store_true", help="Report the 50 ms stretch limit without enforcing it on shared CI; keep thread, durability, and atomicity checks strict.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This native regression requires macOS.")
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link = build / "Easl.product" / "Objects.LinkFileList"
    if not link.is_file() or not (build / "description.json").is_file():
        parser.error("Build optimized Easl with --build-system native and -enable-testing first.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    objects = [pathlib.Path(p) for p in shlex.split(link.read_text())]
    if not all(any(module in p.parts for p in objects) for module in ("CanvasApp.build", "CanvasCore.build")):
        parser.error("The link file must contain the real app and core objects.")
    if any(not p.is_file() for p in objects):
        parser.error("The link file contains missing compiled objects.")
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    command = [compiler, "-swift-version", "6", "-parse-as-library", "-enable-testing", "-O", "-g", "-sdk", sdk,
               "-target", f"{platform.machine()}-apple-macosx14.0", "-I", str(build / "Modules"), "-I", str(build)]
    description = json.loads((build / "description.json").read_text())
    app = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "CanvasApp")
    arguments = app["otherArguments"]
    for index, argument in enumerate(arguments[:-1]):
        if argument == "-Xcc":
            command.extend(["-Xcc", arguments[index + 1]])
        elif argument == "-I" and "libghostty" in arguments[index + 1]:
            command.extend(["-I", arguments[index + 1]])
    if args.baseline:
        command.extend(["-D", "SAVE_BASELINE"])
    executable = output / "BoardSaveRegression"
    command.append(str(root / "Tests/BoardSave/BoardSave.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty", "-framework", "AppKit", "-framework", "QuartzCore",
                    "-framework", "Carbon", "-lc++", "-Xlinker", "-e", "-Xlinker", "_EaslBoardSaveRegressionMain", "-o", str(executable)])
    (output / "compile-command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (output / "compile.log").open("w") as log:
        subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    home = pathlib.Path(tempfile.mkdtemp(prefix="home-", dir=output))
    environment = os.environ.copy()
    for key in ("EASL_ROOT", "EASL_DEV_PERF", "EASL_BOARD_ID", "EASL_TILE_ID"):
        environment.pop(key, None)
    environment.update(EASL_HOME=str(home), EASL_NO_ACTIVATE="1")
    with (output / "child.log").open("w") as log:
        child = subprocess.Popen([str(executable), str(home), "slow-report" if args.ci_timing_report_only else "slow"],
                                 cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            status = child.wait(timeout=20)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)
            raise RuntimeError(f"Owned regression PID {child.pid} exceeded 20 seconds")
    print((output / "child.log").read_text(), end="", flush=True)
    if not args.baseline:
        for case in ("modal", "close-race", "completion", "completion-modal"):
            case_home = pathlib.Path(tempfile.mkdtemp(prefix=f"{case}-", dir=output))
            environment["EASL_HOME"] = str(case_home)
            log_path = output / f"{case}.log"
            with log_path.open("w") as log:
                subprocess.run([str(executable), str(case_home), case], env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=20)
            print(log_path.read_text(), end="", flush=True)
    hook = output / "atomic-write-hook.dylib"
    subprocess.run(["xcrun", "clang", "-dynamiclib", "-O2", str(root / "Tests/BoardSave/atomic-write-hook.c"), "-o", str(hook)], check=True, timeout=60)
    subprocess.run(["codesign", "--force", "--sign", "-", str(hook)], check=True, timeout=30)
    atomic_home = pathlib.Path(tempfile.mkdtemp(prefix="atomic-", dir=output))
    environment["EASL_HOME"] = str(atomic_home)
    with (output / "atomic-seed.log").open("w") as log:
        subprocess.run([str(executable), str(atomic_home), "seed"], env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=20)
    files = list((atomic_home / "boards").glob("*.json"))
    if len(files) != 1:
        raise RuntimeError(f"Atomic seed produced {len(files)} board files")
    previous = files[0].read_bytes()
    environment.update(DYLD_INSERT_LIBRARIES=str(hook), EASL_TEST_CRASH_RENAME=str(files[0]))
    with (output / "atomic-crash.log").open("w") as log:
        crash = subprocess.run([str(executable), str(atomic_home), "crash"], env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=20)
    if crash.returncode != 73 or files[0].read_bytes() != previous:
        raise RuntimeError(f"Crash at atomic rename failed: exit {crash.returncode}, previous file intact: {files[0].read_bytes() == previous}")
    if b"previous complete file" not in previous:
        raise RuntimeError("Seeded board did not contain the previous complete snapshot")
    print("PASS crash at the real atomic rename leaves the previous board byte-exact", flush=True)
    print(f"Evidence: {output}", flush=True)
    raise SystemExit(status)


if __name__ == "__main__":
    main()
