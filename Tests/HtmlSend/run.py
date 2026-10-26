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
    parser = argparse.ArgumentParser(description="Run the native HTML send gesture and bridge proof against an existing Easl build.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path,
                        help="The directory printed by swift build --show-bin-path after a native Easl build with testing enabled.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit proof requires macOS.")
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link_file = build / "Easl.product" / "Objects.LinkFileList"
    if not link_file.is_file() or not (build / "description.json").is_file():
        parser.error("Build Easl with --build-system native first, then pass that build's --show-bin-path. This runner never rebuilds the app.")
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
    executable = build / "HtmlSend"
    command.append(str(root / "Tests/HtmlSend/HtmlSend.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    with tempfile.TemporaryDirectory(prefix="easl-html-send-") as temporary:
        environment = os.environ.copy()
        environment["EASL_HOME"] = temporary
        environment["CFFIXED_USER_HOME"] = temporary
        environment["XDG_CONFIG_HOME"] = temporary
        environment["EASL_NO_ACTIVATE"] = "1"
        environment.pop("EASL_ROOT", None)
        subprocess.run([str(executable)], cwd=root, env=environment, check=True, timeout=120)


if __name__ == "__main__":
    main()
