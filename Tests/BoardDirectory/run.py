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
    parser = argparse.ArgumentParser(description="Compile and run the real AppKit board-directory picker regression against an existing Easl build.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path, help="The directory printed by swift build --show-bin-path, after building Easl.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS.")
    root = pathlib.Path(__file__).resolve().parents[2]
    build = args.bin_path.resolve()
    link_file = build / "Easl.product" / "Objects.LinkFileList"
    if not link_file.is_file() or not (build / "description.json").is_file():
        parser.error("Build Easl with --build-system native first, then pass that build's --show-bin-path. This runner never rebuilds the app.")
    objects = [pathlib.Path(p) for p in shlex.split(link_file.read_text())]
    # The app's own entry point: the harness supplies its own @main.
    objects = [p for p in objects if p.name not in {"main.swift.o", "main.o"}]
    if not objects or not any("CanvasApp.build" in p.parts for p in objects):
        parser.error("The Easl link file does not contain CanvasApp objects.")
    if not any("CanvasCore.build" in p.parts for p in objects):
        parser.error("The Easl link file does not contain CanvasCore objects.")
    missing = [str(p) for p in objects if not p.is_file()]
    if missing:
        parser.error(f"Missing compiled objects: {missing}")
    executable = build / "BoardDirectoryPicker"
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    command = [compiler, "-swift-version", "6", "-parse-as-library", "-enable-testing",
               "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx14.0",
               "-I", str(build / "Modules"), "-I", str(build)]
    # The app module's Clang module maps (tree-sitter, Markdown, Ghostty headers) are part of its
    # compile command, not its link file.
    description = json.loads((build / "description.json").read_text())
    app = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "CanvasApp")
    arguments = app["otherArguments"]
    for index, argument in enumerate(arguments[:-1]):
        if argument == "-Xcc":
            command.extend(["-Xcc", arguments[index + 1]])
        elif argument == "-I" and "libghostty" in arguments[index + 1]:
            # The C API headers behind `import GhosttyKit` (libghostty).
            command.extend(["-I", arguments[index + 1]])
    command.extend([str(root / "Tests/BoardDirectory/BoardDirectoryPicker.swift")])
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)

    # One process per preference. The preference is an NSArgumentDomain launch argument, so no
    # user defaults are touched; EASL_HOME and CFFIXED_USER_HOME keep every file in the temp tree.
    with tempfile.TemporaryDirectory(prefix="easl-board-directory-") as temporary:
        temporary = pathlib.Path(temporary)
        for preference in ("valid", "unset", "invalid"):
            case_home = temporary / preference
            case_home.mkdir()
            account = temporary / "account" / preference
            account.mkdir(parents=True)
            preference_path = case_home / ("preferred-board" if preference != "invalid" else "missing-preferred-board")
            environment = os.environ.copy()
            environment["EASL_HOME"] = str(case_home)
            environment["CFFIXED_USER_HOME"] = str(account)
            environment["EASL_PICKER_PREFERENCE"] = preference
            environment["EASL_PICKER_PREFERENCE_PATH"] = str(preference_path)
            environment["EASL_NO_ACTIVATE"] = "1"
            environment.pop("EASL_ROOT", None)
            launch = [str(executable)]
            if preference != "unset":
                launch.extend(["-canvas.boardDirectory", str(preference_path)])
            subprocess.run(launch, cwd=root, env=environment, check=True)


if __name__ == "__main__":
    main()
