#!/usr/bin/env python3
"""Exercise wheel access to all four edges of an oversized browser tile."""
import argparse
import json
import os
from pathlib import Path
import socket
import sys
import subprocess
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "RemoteClosedBoard"))
from native import DRIVER, capture, end_session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="A prebuilt easl.app; this runner never builds the app.")
    parser.add_argument("--out", type=Path, help="Keep the native capture, capture receipts, and app log in this directory.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    app = args.app.resolve(strict=True)
    if not Path(DRIVER).is_file():
        parser.error("This manual GUI regression requires an installed, capture-authorized CuaDriver.app.")
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="easl-browser-scroll-", dir="/tmp") as temporary:
        home = Path(temporary)
        pixels = home / "pixels"
        subprocess.run(["xcrun", "swiftc", str(Path(__file__).with_name("Pixels.swift")),
                        "-framework", "AppKit", "-o", str(pixels)], check=True)
        board_root = home / "board"
        board_root.mkdir()
        page = board_root / "scroll.html"
        page.write_text("""<!doctype html><meta charset="utf-8"><title>Scrolling regression</title>
<style>html,body{margin:0}main{position:relative;width:3600px;height:9000px;
background:repeating-linear-gradient(#fff 0 199px,#ddd 200px)}
html{scrollbar-width:none}::-webkit-scrollbar{display:none}
#start,#end{position:absolute;width:100px;height:40px;background:#acf;
border:4px solid #f0f;box-sizing:border-box}
#start{top:0;left:0}#end{bottom:0;right:0}</style>
<main><div id="start">START</div><div id="end">END</div></main>""")
        environment = dict(os.environ, EASL_DEV_HOME=str(home), EASL_DEV_APP=str(app),
                           XDG_CONFIG_HOME=str(home), EASL_DEV_FRAME="100 100 800 600")

        def dev(*arguments):
            subprocess.run([str(root / "scripts/dev.sh"), *map(str, arguments)], cwd=root,
                           env=environment, check=True, capture_output=True, text=True, timeout=30)

        def call(method, params, browser=False):
            path = home / ("cmux.sock" if browser else "easl.sock")
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(20)
                connection.connect(str(path))
                connection.sendall((json.dumps({"id": "scroll", "method": method, "params": params}) + "\n").encode())
                with connection.makefile() as replies:
                    for line in replies:
                        reply = json.loads(line)
                        if reply.get("id") == "scroll":
                            if not reply.get("ok"):
                                raise RuntimeError(reply.get("error"))
                            return reply["result"]
            raise RuntimeError(f"{method} closed without a reply")

        try:
            dev("start", board_root)
            board = call("board.open", {"root": str(board_root), "select": True})["board"]
            dev("input", "mainmenu", "Help/Get Started")
            for item in call("board.get", {"board": board})["objects"]:
                call("object.delete", {"id": item["id"]})
            viewport = call("view.get", {"board": board})["viewport"]
            visible = viewport["rect"]
            frame = {"x": visible["x"] + 20, "y": visible["y"] + 80,
                     "w": visible["w"] * 2, "h": visible["h"] * 3}
            tile = call("object.create", {"board": board, "type": "browser", "frame": frame,
                                          "props": {"url": page.as_uri(), "title": "Scrolling regression"}})["object"]
            surface = tile["id"]
            call("view.render", {"board": board, "target": surface, "out": str(home / "loaded.png")})
            x, y = visible["w"] * viewport["zoom"] / 2, visible["h"] * viewport["zoom"] / 2
            page_viewport = call("browser.eval", {"surface_id": surface,
                "script": "({width:innerWidth,height:innerHeight})"}, browser=True)["value"]
            log = home / "app.log"
            offset = log.stat().st_size
            dev("input", "state")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                line = next((line for line in log.read_text()[offset:].splitlines(keepends=True)
                             if "DevInput.state " in line and line.endswith("\n")), None)
                if line is not None:
                    states = json.loads(line.split("DevInput.state ", 1)[1])
                    selected = next(state for state in states if state["board"] == board and state["selected"])
                    window = int(selected["window"])
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("The native scroll fixture did not report its selected window")

            if args.out:
                capture(home, window, args.out / "initial.png")

            def geometry(marker):
                script = f"""(() => {{
const node = document.getElementById({json.dumps(marker)});
const rect = node.getBoundingClientRect();
return {{left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom,
        width:innerWidth,height:innerHeight,x:scrollX,y:scrollY}};
}})()"""
                page_geometry = call("browser.eval", {"surface_id": surface, "script": script}, browser=True)["value"]
                view = call("view.get", {"board": board})["viewport"]
                rect, zoom = view["rect"], view["zoom"]
                origin_x = frame["x"] - rect["x"]
                origin_y = frame["y"] - rect["y"] + frame["h"] - page_geometry["height"]
                return {"left": (origin_x + page_geometry["left"]) * zoom,
                        "right": (origin_x + page_geometry["right"]) * zoom,
                        "top": (origin_y + page_geometry["top"]) * zoom,
                        "bottom": (origin_y + page_geometry["bottom"]) * zoom,
                        "windowWidth": rect["w"] * zoom, "windowHeight": rect["h"] * zoom,
                        "pageX": page_geometry["x"], "pageY": page_geometry["y"],
                        "canvasX": rect["x"], "canvasY": rect["y"], "zoom": zoom}

            def unobscured():
                path = (args.out if args.out else home) / "visible.png"
                time.sleep(1.1)
                value = geometry("end")
                receipt = capture(home, window, path)
                inset = 2 * value["zoom"]
                left, right = value["left"] + inset, value["right"] - inset
                top, bottom = value["top"] + inset, value["bottom"] - inset
                border = [(left + (right - left) * fraction, py)
                          for fraction in (0.25, 0.5, 0.75) for py in (top, bottom)]
                border += [(px, top + (bottom - top) * fraction)
                           for fraction in (0.25, 0.5, 0.75) for px in (left, right)]
                request = {"contentTop": selected["contentTop"],
                           "scale": receipt["screenshot_scale"], "points": border}
                samples = json.loads(subprocess.check_output(
                    [str(pixels), str(path)], input=json.dumps(request), text=True,
                ))
                if args.out:
                    (args.out / "pixels.json").write_text(json.dumps(
                        {"geometry": value, "request": request, "colors": samples}, indent=2))
                return all(red >= 240 and green <= 20 and blue >= 240 for red, green, blue in samples)

            def reach(marker, delta, options, label):
                previous = None
                stalled = 0
                value = geometry(marker)
                for index in range(150):
                    horizontal = index % 2 == 0
                    dev("input", "scroll", x, y, delta if horizontal else 0, 0 if horizontal else delta,
                        *options, "--window", window)
                    time.sleep(0.05)
                    value = geometry(marker)
                    if (value["left"] >= -1 and value["top"] >= -1
                            and value["right"] <= value["windowWidth"] + 1
                            and value["bottom"] <= value["windowHeight"] + 1):
                        if args.out:
                            capture(home, window, args.out / (label.replace(" ", "-").replace("/", "-") + ".png"))
                        print(f"PASS {label}: {marker} marker inside native window", flush=True)
                        return
                    stalled = stalled + 1 if value == previous else 0
                    if stalled >= 3:
                        break
                    previous = value
                if args.out:
                    capture(home, window, args.out / (label.replace(" ", "-").replace("/", "-") + "-clipped.png"))
                raise AssertionError(f"{label}: {marker} remains clipped after native scrolling: {value}")

            for label, amount, options in (
                ("precise", 240, ()),
                ("mouse wheel", 12, ("--lines",)),
            ):
                reach("end", -amount, options, f"{label} down/right")
                reach("start", amount, options, f"{label} up/left")
            call("browser.eval", {"surface_id": surface, "script": """(() => {
const main = document.querySelector("main");
main.style.width = innerWidth + "px";
main.style.height = innerHeight + "px";
scrollTo(0, 0);
return true;
})()"""}, browser=True)
            dev("input", "scroll", x, y, -10000, -10000, "--window", window)
            reach("start", 120, ("--repeat", "4", "--gesture"), "phased canvas up/left")
            reach("end", -120, ("--repeat", "4", "--gesture"), "phased canvas down/right")
            dev("input", "scroll", x, y, -120, -120, "--repeat", "4", "--gesture", "--window", window)
            edge = call("view.get", {"board": board})["viewport"]
            dev("input", "scroll", x, y, -120, -120, "--repeat", "4", "--gesture", "--window", window)
            assert call("view.get", {"board": board})["viewport"] == edge, "Scrolling at the revealed edge moved the canvas"
            assert call("object.get", {"id": surface})["object"]["frame"] == frame
            assert call("browser.eval", {"surface_id": surface,
                "script": "({width:innerWidth,height:innerHeight})"}, browser=True)["value"] == page_viewport
            print("PASS tile frame and WebKit viewport unchanged", flush=True)
            assert unobscured(), "Native chrome covers the final END marker"
            print("PASS final END marker unobscured in WindowServer capture", flush=True)
        finally:
            if args.out and (home / "app.log").exists():
                (args.out / "app.log").write_text((home / "app.log").read_text())
            try:
                end_session()
            finally:
                dev("stop")


if __name__ == "__main__":
    main()
