#!/usr/bin/env python3
import argparse
import json
import pathlib
import platform
import plistlib
import shlex
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description="Run the real AppKit terminal rekey focus regression against an existing Easl build.")
    parser.add_argument("--bin-path", required=True, type=pathlib.Path,
                        help="The directory printed by swift build --show-bin-path after a native Easl build with testing enabled.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This AppKit regression requires macOS.")
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
    executable = build / "TerminalRekey"
    command.append(str(root / "Tests/TerminalRekey/TerminalRekey.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty",
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Carbon", "-lc++",
                    "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    with tempfile.TemporaryDirectory(prefix="easl-terminal-rekey-") as temporary:
        bundle = pathlib.Path(temporary) / "TerminalRekey.app" / "Contents"
        (bundle / "MacOS").mkdir(parents=True)
        launched = bundle / "MacOS" / "TerminalRekey"
        shutil.copy2(executable, launched)
        with (bundle / "Info.plist").open("wb") as info:
            plistlib.dump({"CFBundleIdentifier": "net.waldin.easl.terminal-rekey-test",
                          "CFBundleExecutable": "TerminalRekey", "CFBundlePackageType": "APPL",
                          "NSPrincipalClass": "NSApplication"}, info)
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle.parent)], check=True)
        log = pathlib.Path(temporary) / "runner.log"
        launch = ["open", "-n", "-W", "--stdout", str(log), "--stderr", str(log)]
        for key in ("EASL_HOME", "CFFIXED_USER_HOME", "XDG_CONFIG_HOME"):
            launch.extend(["--env", f"{key}={temporary}"])
        launch.extend(["--env", "EASL_NO_ACTIVATE=0", str(bundle.parent)])
        subprocess.run(launch, cwd=root, check=True, timeout=120)
        if log.exists():
            print(log.read_text(), end="")
        result = pathlib.Path(temporary) / "result"
        if not result.exists() or result.read_text() != "PASS":
            raise RuntimeError(result.read_text() if result.exists() else "native runner exited without a result")


if __name__ == "__main__":
    main()
