#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import platform
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description="Verify completed terminal frames against a native Easl build.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS.")
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link_file = build / "Easl.product/Objects.LinkFileList"
    if not link_file.is_file() or not (build / "description.json").is_file():
        parser.error("Build Easl with --build-system native first and pass its --show-bin-path.")
    objects = [pathlib.Path(p) for p in shlex.split(link_file.read_text())]
    objects = [p for p in objects if p.name not in {"main.swift.o", "main.o"}]
    if not any("CanvasApp.build" in p.parts for p in objects):
        parser.error("The link file does not contain CanvasApp objects.")
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
    with tempfile.TemporaryDirectory(prefix="easl-terminal-frames-") as temporary:
        executable = pathlib.Path(temporary) / "TerminalFrames"
        command.append(str(root / "Tests/TerminalFrames/TerminalFrames.swift"))
        command.extend(str(p) for p in objects)
        command.extend(["-F", str(build), "-L", str(build), "-lghostty", "-framework", "AppKit",
                        "-framework", "QuartzCore", "-framework", "IOSurface", "-framework", "Carbon",
                        "-lc++", "-o", str(executable)])
        subprocess.run(command, cwd=root, check=True)
        environment = os.environ.copy()
        environment.update(EASL_HOME=temporary, CFFIXED_USER_HOME=temporary,
                           XDG_CONFIG_HOME=temporary, EASL_NO_ACTIVATE="1")
        subprocess.run([str(executable)], cwd=root, env=environment, check=True)


if __name__ == "__main__":
    main()
