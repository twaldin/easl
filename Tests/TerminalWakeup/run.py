#!/usr/bin/env python3
"""Native AppKit behavior + fresh own-window pixels in an isolated GUI guest.

Prerequisites: authorized CuaDriver and Pillow. Build a testing-enabled native artifact:
  swift build --build-system native -c release -j 2 --product Easl -Xswiftc -enable-testing
  python3 Tests/TerminalWakeup/run.py --bin-path "$(swift build --build-system native -c release --show-bin-path)" --output /absolute/new/evidence

Viewport marker assertions establish parsed content; native captures independently check
phase-specific background pixels, foreground ink, and the unchanged blue sibling.
This is not OCR or key-to-pixel latency proof; scripts/terminal-echo owns the latter.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tempfile
import time
import uuid



DRIVER = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"


def compile_harness(root, build):
    link_file = build / "Easl.product/Objects.LinkFileList"
    if not link_file.is_file() or not (build / "description.json").is_file():
        raise RuntimeError("Build Easl with --build-system native -Xswiftc -enable-testing first")
    objects = [Path(p) for p in shlex.split(link_file.read_text())]
    objects = [p for p in objects if p.name not in {"main.swift.o", "main.o"}]
    if not any("CanvasApp.build" in p.parts for p in objects):
        raise RuntimeError("The native Easl link file does not contain CanvasApp objects")
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
    executable = build / "TerminalWakeup"
    command.append(str(root / "Tests/TerminalWakeup/TerminalWakeup.swift"))
    command.extend(str(p) for p in objects)
    command.extend(["-F", str(build), "-L", str(build), "-lghostty", "-framework", "AppKit",
                    "-framework", "QuartzCore", "-framework", "Carbon", "-lc++", "-o", str(executable)])
    subprocess.run(command, cwd=root, check=True)
    return executable, command


def pixel_evidence(path, request):
    from PIL import Image
    with Image.open(path) as source:
        image = source.convert("RGB")
    sx, sy = image.width / request["width"], image.height / request["height"]
    if abs(sx - sy) > 0.02 or sx < 0.5:
        raise RuntimeError(f"Unexpected own-window capture dimensions: {image.size}")

    def region(left, top, right, bottom):
        return image.crop(tuple(round(value * scale) for value, scale in
                               zip((left, top, right, bottom), (sx, sy, sx, sy))))

    def matching_fraction(crop, expected):
        pixels = list(crop.getdata())
        return sum(max(abs(a - b) for a, b in zip(pixel, expected)) <= 18
                   for pixel in pixels) / len(pixels)

    active = region(15, 80, request["activeWidth"] - 15, 440)
    quiet = region(660, 80, 1020, 440)
    # The marker occupies the first terminal row; a blank colored surface is not sufficient.
    glyphs = region(0, 0, min(400, request["activeWidth"]), 65)
    white = sum(min(pixel) > 210 for pixel in glyphs.getdata())
    result = {"size": image.size, "activeColorFraction": matching_fraction(active, request["color"]),
              "quietBlueFraction": matching_fraction(quiet, [20, 40, 180]), "markerInkPixels": white}
    if request.get("exitText"):
        result["exitInkPixels"] = sum(r > 180 and r > g * 1.3 and r > b * 1.3 for r, g, b in
                                     region(0, 0, request["activeWidth"], 440).getdata())
    result["matches"] = result["activeColorFraction"] > 0.95 and result["quietBlueFraction"] > 0.95 and white > 20
    if request.get("exitText"):
        result["matches"] = result["matches"] and result["exitInkPixels"] > 50
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-path", type=Path)
    parser.add_argument("--executable", type=Path, help="Run an already compiled stand-in without rebuilding it")
    parser.add_argument("--compile-only", action="store_true", help="Compile on a build Mac without launching a GUI")
    parser.add_argument("--window-helper", type=Path, help="Existing perf-window helper for native marker OCR")
    parser.add_argument("--output", required=True, type=Path, help="New evidence directory; never overwrite a prior run")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This regression requires an isolated macOS GUI guest")
    if bool(args.bin_path) == bool(args.executable):
        parser.error("Choose --bin-path or --executable")
    if args.compile_only and not args.bin_path:
        parser.error("--compile-only requires --bin-path")
    model = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
    if not args.compile_only and not model.startswith("VirtualMac"):
        parser.error("GUI execution requires the claimed VirtualMac guest")
    if not args.compile_only and not args.window_helper:
        parser.error("Native pixel proof requires --window-helper")
    if not args.compile_only and not Path(DRIVER).is_file():
        parser.error("CuaDriver must be installed and authorized in the GUI guest")
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    if args.executable:
        executable, command = args.executable.resolve(), None
    else:
        executable, command = compile_harness(root, args.bin_path.resolve())
    (output / "build.json").write_text(json.dumps({"command": command, "binary": str(executable),
        "sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}, indent=2) + "\n")
    if args.compile_only:
        print(executable)
        return
    session = "TerminalWakeup" + uuid.uuid4().hex
    captures = set()
    snapshots = set()
    used_driver = False
    with tempfile.TemporaryDirectory(prefix="easl-terminal-wakeup-") as temporary:
        environment = dict(os.environ, EASL_HOME=temporary, CFFIXED_USER_HOME=temporary,
                           XDG_CONFIG_HOME=temporary, EASL_NO_ACTIVATE="1", TERMINAL_WAKEUP_EVIDENCE=str(output))
        with (output / "stdout.log").open("w") as stdout, (output / "stderr.log").open("w") as stderr:
            process = subprocess.Popen([str(executable)], cwd=root, env=environment, stdout=stdout, stderr=stderr)
            (output / "ownership.json").write_text(json.dumps({"pid": process.pid, "executable": str(executable),
                "privateHome": temporary, "captureSession": session}, indent=2) + "\n")
            completed = set()
            deadline = time.monotonic() + 150
            try:
                while process.poll() is None:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Native wakeup regression exceeded 150 seconds")
                    for ready in sorted(output.glob("*.ready.json")):
                        request = json.loads(ready.read_text())
                        phase = request["phase"]
                        if phase in completed:
                            continue
                        if request["pid"] != process.pid or request["window"] <= 0:
                            raise RuntimeError(f"Harness capture ownership mismatch: {request}")
                        phase_deadline = time.monotonic() + 10
                        attempt = 0
                        while True:
                            if process.poll() is not None:
                                raise RuntimeError("Harness exited before native pixel capture completed")
                            attempt += 1
                            stem = output / f"{phase}-{attempt:02d}"
                            screenshot = stem.with_suffix(".png")
                            arguments = {"pid": process.pid, "window_id": request["window"],
                                "include_accessibility_tree": False, "max_image_dimension": 0,
                                "screenshot_out_file": str(screenshot), "session": session}
                            stem.with_suffix(".request.json").write_text(json.dumps(arguments, indent=2) + "\n")
                            used_driver = True
                            result = subprocess.run([DRIVER, "call", "get_window_state", json.dumps(arguments)],
                                                    capture_output=True, text=True, timeout=10)
                            stem.with_suffix(".capture.json").write_text(result.stdout)
                            stem.with_suffix(".capture.stderr").write_text(result.stderr)
                            if result.returncode:
                                raise RuntimeError(f"CuaDriver failed: {result.stdout}\n{result.stderr}")
                            response = json.loads(result.stdout)
                            receipt = response.get("structuredContent", response)
                            if not (receipt["pid"] == process.pid and receipt["window_id"] == request["window"]
                                    and receipt["screenshot_frame_valid"] is True and screenshot.is_file()
                                    and receipt["capture_id"] and receipt["snapshot_id"]):
                                raise RuntimeError(f"Invalid native capture receipt: {receipt}")
                            if receipt["capture_id"] in captures or receipt["snapshot_id"] in snapshots:
                                raise RuntimeError("Native capture reused an earlier capture/snapshot identity")
                            captures.add(receipt["capture_id"])
                            snapshots.add(receipt["snapshot_id"])
                            pixels = pixel_evidence(screenshot, request)
                            recognized = subprocess.run([str(args.window_helper), "--drawn", str(screenshot)],
                                                        capture_output=True, text=True, timeout=10)
                            stem.with_suffix(".ocr.json").write_text(recognized.stdout)
                            stem.with_suffix(".ocr.stderr").write_text(recognized.stderr)
                            recognized.check_returncode()
                            lines = json.loads(recognized.stdout)["lines"]
                            normalize = lambda value: "".join(character.lower() for character in value if character.isalnum())
                            pixels["markerRecognized"] = normalize(request["marker"]) in normalize(" ".join(lines))
                            pixels["matches"] = pixels["matches"] and pixels["markerRecognized"]
                            stem.with_suffix(".pixels.json").write_text(json.dumps(pixels, indent=2) + "\n")
                            if pixels["matches"]:
                                (output / f"{phase}.captured").write_text(screenshot.name + "\n")
                                completed.add(phase)
                                break
                            if time.monotonic() >= phase_deadline:
                                raise RuntimeError(f"Stale/wrong pixels for {phase}: {pixels}")
                            time.sleep(0.1)
                    time.sleep(0.02)
                if process.returncode != 0:
                    raise RuntimeError(f"Native harness exited {process.returncode}; see {output / 'stderr.log'}")
                if len(completed) != 9 or not (output / "result.txt").is_file():
                    raise RuntimeError(f"Incomplete native proof: captured {sorted(completed)}")
                print((output / "result.txt").read_text(), end="")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                (output / "exit.json").write_text(json.dumps({"pid": process.pid, "returncode": process.returncode,
                    "capturedPhases": sorted(completed)}, indent=2) + "\n")
                if used_driver:
                    result = subprocess.run([DRIVER, "call", "end_session", json.dumps({"session": session})],
                                            capture_output=True, text=True, timeout=10)
                    (output / "capture-session-end.json").write_text(result.stdout)
                    (output / "capture-session-end.stderr").write_text(result.stderr)
                    result.check_returncode()


if __name__ == "__main__":
    main()
