#!/usr/bin/env python3
"""A page-owned wheel gesture stays page-owned when its browser becomes oversized."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--arrival", action="store_true", help="Move a browser under a gesture that began on empty canvas.")
    mode.add_argument("--drift", action="store_true", help="Keep minor sideways drift from stealing a vertical page gesture.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    app = args.app.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="easl-scroll-resize-", dir="/tmp") as temporary:
        home = Path(temporary)
        (home / "get-started.json").write_text('{"dismissed":true}')
        board_root = home / "board"
        board_root.mkdir()
        page = board_root / "scroll.html"
        page.write_text('<!doctype html><style>body{height:9000px}</style>Resize gesture')
        environment = dict(os.environ, EASL_DEV_HOME=str(home), EASL_DEV_APP=str(app),
                           XDG_CONFIG_HOME=str(home), EASL_DEV_FRAME="0 0 1200 760")

        def dev(*arguments):
            subprocess.run([str(root / "scripts/dev.sh"), *map(str, arguments)], cwd=root,
                           env=environment, check=True, capture_output=True, text=True, timeout=30)

        def call(method, params, browser=False):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(20)
                connection.connect(str(home / ("cmux.sock" if browser else "easl.sock")))
                connection.sendall((json.dumps({"id": "resize", "method": method, "params": params}) + "\n").encode())
                for line in connection.makefile():
                    reply = json.loads(line)
                    if reply.get("id") == "resize":
                        if not reply.get("ok"):
                            raise RuntimeError(reply.get("error"))
                        return reply["result"]
            raise RuntimeError(f"{method} closed without a reply")

        def wait(predicate, message):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(0.025)
            raise AssertionError(message)

        try:
            dev("start", board_root)
            board = call("board.open", {"root": str(board_root), "select": True})["board"]
            for item in call("board.get", {"board": board})["objects"]:
                call("object.delete", {"id": item["id"]})
            viewport = call("view.get", {"board": board})["viewport"]
            rect, zoom = viewport["rect"], viewport["zoom"]
            frame = {"x": rect["x"] + (350 if args.arrival else 60), "y": rect["y"] + 100, "w": 650, "h": 400}
            if args.drift:
                frame.update(w=rect["w"] * 2, h=rect["h"] * 3)
            tile = call("object.create", {"board": board, "type": "browser", "frame": frame,
                                          "props": {"url": page.as_uri()}})["object"]["id"]
            call("view.render", {"board": board, "target": tile, "out": str(home / "loaded.png")})
            log = home / "app.log"
            if args.drift:
                dev("input", "scroll", 160 * zoom, 230 * zoom, 0, -10000)
                before = call("view.get", {"board": board})["viewport"]
                page_y = call("browser.eval", {"surface_id": tile, "script": "scrollY"}, browser=True)["value"]
                offset = log.stat().st_size
                dev("input", "scroll", 160 * zoom, 230 * zoom, -1, -12,
                    "--repeat", 4, "--interval", 100, "--gesture")
                wait(lambda: "DevInput: burst of 4 scroll" in log.read_text()[offset:],
                     "The slightly diagonal page gesture did not finish")
                after = call("view.get", {"board": board})["viewport"]
                assert after == before, f"Sideways drift stole a vertical page gesture: {before} -> {after}"
                wait(lambda: call("browser.eval", {"surface_id": tile, "script": "scrollY"}, browser=True)["value"] > page_y,
                     "The vertical gesture did not reach the page")
                print("PASS minor sideways drift does not steal a vertical page gesture", flush=True)
                return
            offset = log.stat().st_size
            dev("input", "scroll", 160 * zoom, 230 * zoom, 0, -12,
                "--repeat", 30, "--interval", 100, "--gesture")
            if args.arrival:
                wait(lambda: call("view.get", {"board": board})["viewport"]["rect"]["y"] > rect["y"],
                     "The gesture never began panning the empty canvas")
            else:
                wait(lambda: call("browser.eval", {"surface_id": tile, "script": "scrollY"}, browser=True)["value"] > 0,
                     "The gesture never began scrolling the normal-sized page")
            assert "DevInput: burst of 30 scroll" not in log.read_text()[offset:], "The gesture ended before the geometry change"
            before = call("view.get", {"board": board})["viewport"]
            if args.arrival:
                moved = dict(frame, x=before["rect"]["x"] + 60, y=before["rect"]["y"] + 100)
                call("object.update", {"id": tile, "frame": moved})
                before = call("view.get", {"board": board})["viewport"]
            else:
                call("object.update", {"id": tile, "frame": dict(frame, h=rect["h"] * 3)})
            assert "DevInput: burst of 30 scroll" not in log.read_text()[offset:], "The gesture ended before the geometry change was applied"
            wait(lambda: "DevInput: burst of 30 scroll" in log.read_text()[offset:],
                 "The phased wheel burst did not finish")
            after = call("view.get", {"board": board})["viewport"]
            if args.arrival:
                assert after["rect"]["y"] > before["rect"]["y"], f"Browser swallowed an arriving canvas gesture: {before} -> {after}"
                assert call("browser.eval", {"surface_id": tile, "script": "scrollY"}, browser=True)["value"] == 0
                print("PASS arriving canvas gesture keeps panning over a normal browser", flush=True)
            else:
                assert after == before, f"Page-owned gesture changed to canvas after resize: {before} -> {after}"
                print("PASS page-owned gesture stays page-owned after browser enlargement", flush=True)
        finally:
            dev("stop")


if __name__ == "__main__":
    main()
