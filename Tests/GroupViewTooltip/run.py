#!/usr/bin/env python3
import argparse
import json
import pathlib
import platform
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description="Compile and run the real GroupView tooltip lifetime regression against an existing CanvasCoreTests build.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path, help="The directory printed by swift build --show-bin-path, after building CanvasCoreTests.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS.")
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link_file = build / "CanvasCoreTests.product" / "Objects.LinkFileList"
    if not link_file.is_file() or not (build / "description.json").is_file():
        native = ["swift", "build", "--build-system", "native", "--scratch-path", str(root / ".build/tooltip-native")]
        subprocess.run([*native, "-j", "2", "--product", "CanvasCoreTests"], cwd=root, check=True)
        build = pathlib.Path(subprocess.check_output([*native, "--show-bin-path"], cwd=root, text=True).strip())
        link_file = build / "CanvasCoreTests.product/Objects.LinkFileList"
    objects = [pathlib.Path(p) for p in shlex.split(link_file.read_text())]
    objects = [p for p in objects if "CanvasCoreTests.build" not in p.parts]
    if not objects or not any("CanvasCore.build" in p.parts for p in objects):
        parser.error("The test runner link file does not contain CanvasCore objects.")
    missing = [str(p) for p in objects if not p.is_file()]
    if missing:
        parser.error(f"Missing compiled objects: {missing}")
    executable = build / "GroupViewTooltip"
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    command = [compiler, "-swift-version", "6", "-parse-as-library", "-sdk", sdk,
               "-target", f"{platform.machine()}-apple-macosx14.0", "-I", str(build / "Modules"),
               "-I", str(build), "-framework", "AppKit", "-framework", "QuartzCore", "-lc++"]
    description = json.loads((build / "description.json").read_text())
    core = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "CanvasCore")
    arguments = core["otherArguments"]
    for index, argument in enumerate(arguments[:-1]):
        if argument == "-Xcc":
            command.extend(["-Xcc", arguments[index + 1]])
    command.extend([str(root / "Sources/CanvasApp/Scene/GroupView.swift"),
                    str(root / "Sources/CanvasApp/DevPerf.swift"),
                    str(root / "Tests/GroupViewTooltip/TooltipLifetime.swift")])
    command.extend(str(p) for p in objects)
    command.extend(["-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    subprocess.run([str(executable)], cwd=root, check=True)


if __name__ == "__main__":
    main()
