#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description="Check real first-command results on cold browser tiles.")
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
    executable = build / "BrowserColdCommands"
    command.append(str(root / "Tests/BrowserColdCommands/BrowserColdCommands.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-Xlinker", "-e", "-Xlinker", "_EaslBrowserColdCommandsMain", "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    output = (args.output or build / "browser-cold-commands-evidence").resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="easl-browser-cold-") as temporary:
        environment = {**os.environ, "EASL_HOME": temporary, "CFFIXED_USER_HOME": temporary,
                       "XDG_CONFIG_HOME": temporary, "EASL_NO_ACTIVATE": "1", "EASL_BROWSER_PROFILE": "own",
                       "BROWSER_COLD_OUTPUT": str(output)}
        environment.pop("EASL_ROOT", None)
        subprocess.run([str(executable)], cwd=root, env=environment, check=True, timeout=180)


if __name__ == "__main__":
    main()
