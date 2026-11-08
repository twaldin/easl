#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import platform
import shlex
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description="Run native browser admission, remote wheel, or remote undo regressions against an existing Easl build.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path)
    parser.add_argument("--case", choices=("initial-admission", "remote-wheel", "remote-undo"), default="initial-admission")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS.")
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link_file = build / "Easl.product" / "Objects.LinkFileList"
    if not link_file.is_file() or not (build / "description.json").is_file():
        parser.error("Build Easl with --build-system native and testing enabled first. This runner never rebuilds the app.")
    objects = [pathlib.Path(p) for p in shlex.split(link_file.read_text())]
    objects = [p for p in objects if p.name not in {"main.swift.o", "main.o"}]
    for module in ("CanvasApp.build", "CanvasCore.build"):
        if not any(module in p.parts for p in objects):
            parser.error(f"The Easl link file does not contain {module} objects.")
    missing = [str(p) for p in objects if not p.is_file()]
    if missing:
        parser.error(f"Missing compiled objects: {missing}")
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
    executable = build / "BrowserInitialAdmission"
    command.append(str(root / "Tests/BrowserInitialAdmission/BrowserInitialAdmission.swift"))
    command.append(str(root / "Tests/BrowserInitialAdmission/BrowserUndo.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    def run_case(case_arguments, *, phase=None):
        with tempfile.TemporaryDirectory(prefix="easl-browser-admission-", dir="/tmp") as temporary:
            environment = os.environ.copy()
            environment["EASL_HOME"] = temporary
            environment["CFFIXED_USER_HOME"] = temporary
            environment["XDG_CONFIG_HOME"] = temporary
            environment["EASL_BROWSER_PROFILE"] = "own"
            environment["EASL_NO_ACTIVATE"] = "0" if phase else "1"
            environment.pop("EASL_ROOT", None)
            if case_arguments:
                relay = pathlib.Path(temporary) / "ssh-unix-relay"
                relay.write_text(
                    f"#!{sys.executable}\n"
                    "import os, shlex, sys\n"
                    "path, = shlex.split(sys.argv[-1])\n"
                    "os.execv('/usr/bin/nc', ['nc', '-U', path])\n"
                )
                relay.chmod(0o700)
                environment["EASL_DEV_SSH"] = str(relay)
            if phase:
                environment["EASL_DEV_INPUT"] = "0"
                environment["EASL_UNDO_PHASE"] = phase
            result = subprocess.run([str(executable), *case_arguments], cwd=root, env=environment,
                                    check=False, timeout=240 if phase else 120 if case_arguments else 45)
            print(f"RESULT case={args.case} phase={phase} exit={result.returncode}", flush=True)
            return result.returncode

    if args.case == "remote-undo":
        failed = False
        for phase in ("direct", "relay"):
            code = run_case(["remote-undo"], phase=phase)
            failed = failed or code != 0
        if failed:
            raise SystemExit("Remote undo regression failed; inspect every direct and relay case above.")
    else:
        raise SystemExit(run_case([] if args.case == "initial-admission" else [args.case]))


if __name__ == "__main__":
    main()
