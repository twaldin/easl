#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from PIL import Image, ImageChops
from lsp_gate import SOURCE, URL
from native import capture as native_capture, end_session, press_close


def main():
    parser = argparse.ArgumentParser(description="Exercise a closed remote board through an isolated development viewer.")
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--viewer-home", type=Path, required=True)
    parser.add_argument("--host-socket", required=True)
    parser.add_argument("--host-home", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fixture-directory", type=Path, required=True,
                        help="The prepared host root, also visible to this runner, containing the real LSP reply gate")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, EASL_DEV_HOME=str(args.viewer_home), EASL_DEV_REMOTE_HOME=args.host_home)
    observations = {}
    failures = []

    def call(method, params, socket_path=None):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(20)
            connection.connect(socket_path or args.host_socket)
            connection.sendall((json.dumps({"id": "probe", "method": method, "params": params}) + "\n").encode())
            with connection.makefile() as stream:
                for line in stream:
                    reply = json.loads(line)
                    if reply.get("id") == "probe":
                        if not reply.get("ok"):
                            raise RuntimeError(reply.get("error"))
                        return reply["result"]
        raise RuntimeError(f"{method} closed without a reply")

    def input_event(*arguments):
        subprocess.run([str(args.checkout / "scripts/dev.sh"), "input", *map(str, arguments)],
                       cwd=args.checkout, env=environment, check=True, capture_output=True, text=True)

    def state():
        log = args.viewer_home / "app.log"
        offset = log.stat().st_size
        input_event("state")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            with log.open() as stream:
                stream.seek(offset)
                for line in stream:
                    if "DevInput.state " in line:
                        return json.loads(line.split("DevInput.state ", 1)[1])
            time.sleep(0.05)
        raise RuntimeError("The development viewer did not report its window state")

    def remote_state():
        return next(window for window in state() if window["board"] == board)

    def expect(name, condition, detail):
        observations[name] = detail
        print(f"{'PASS' if condition else 'FAIL'} {name}", flush=True)
        if not condition:
            failures.append(name)

    def capture(name, window):
        return native_capture(args.viewer_home, window, args.out / name)

    def exercise_code():
        fixture = args.fixture_directory.resolve(strict=True)
        control = fixture / ".closed-board-lsp"
        metadata = json.loads((control / "fixture.json").read_text())
        assert metadata["root"] == args.root, "Use the host root printed by lsp_gate.py prepare"
        assert (fixture / "main.swift").read_text() == SOURCE, "The host source fixture changed"
        code = call("object.create", {"board": board, "type": "code", "props": {"path": "main.swift"},
                                      "frame": {"x": 0, "y": 550, "w": 840, "h": 430}})["object"]
        created = {code["id"]}
        tokens = []

        def protocol_events():
            path = control / "events.jsonl"
            if not path.exists():
                return []
            data = path.read_text()
            return [json.loads(line) for line in data.splitlines(keepends=True) if line.endswith("\n")]

        def language_reads():
            cleanup = {"textDocument/didClose", "$/cancelRequest", "shutdown", "exit"}
            return [event for event in protocol_events() if event["kind"] == "launch"
                    or (event["kind"] == "request" and event["message"].get("method") not in cleanup)]

        def wait_for(description, read_value, predicate, seconds=15):
            deadline = time.monotonic() + seconds
            while True:
                value = read_value()
                if predicate(value):
                    return value
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"{description}: {value!r}")
                time.sleep(0.05)

        def availability(closed):
            return wait_for("Board availability did not change", remote_state, lambda value: value["closed"] == closed)

        def writes():
            counters = call("app.metrics", {}, str(args.viewer_home / "easl.sock"))["counters"]
            return counters.get("board.write", {}).get("total", {}).get("n", 0)

        def inspection(value):
            return {key: value[key] for key in
                    ("objects", "selectedObjects", "selectedTextHashes", "responder", "viewport", "closed", "selected")}

        def host_snapshot():
            manifest = call("board.get", {"board": board})
            objects = [call("object.get", {"id": item["id"]})["object"] for item in manifest["objects"]]
            snapshot = {"revision": manifest["revision"], "objects": sorted(objects, key=lambda item: item["id"]),
                        "attention": manifest.get("attention", [])}
            observations.setdefault("raw host snapshots", []).append(snapshot)
            stable = [{key: math.floor(value) if key in ("createdAt", "updatedAt") and isinstance(value, (int, float)) else value
                       for key, value in obj.items()} for obj in snapshot["objects"]]
            return {**snapshot, "objects": stable}

        def point(dx, dy):
            current = remote_state()
            rect = current["viewport"]["rect"]
            zoom = current["viewport"]["zoom"]
            return (round((code["frame"]["x"] - rect["x"] + dx) * zoom),
                    round((code["frame"]["y"] - rect["y"] + dy) * zoom))

        def show_code():
            input_event("shortcut", "0", "--mods", "cmd")
            current = remote_state()
            rect = current["viewport"]["rect"]
            zoom = current["viewport"]["zoom"]
            input_event("drag", 700, 600, round(700 + (rect["x"] - code["frame"]["x"] + 40) * zoom),
                        round(600 + (rect["y"] - code["frame"]["y"] + 70) * zoom), "--middle")
            time.sleep(0.2)
            input_event("click", *point(200, 12))
            input_event("click", *point(65, 80))

        def copy_code(label):
            show_code()
            expected_hash = hashlib.sha256(SOURCE.encode()).hexdigest()

            def copied_source():
                input_event("shortcut", "a", "--mods", "cmd")
                input_event("shortcut", "c", "--mods", "cmd")
                return {"state": remote_state(), "clipboard": subprocess.check_output(["pbpaste"])}

            copied = wait_for("Code did not load the literal host source", copied_source,
                              lambda value: value["state"]["selectedTextHashes"] == [expected_hash]
                              and value["clipboard"] == SOURCE.encode())
            expect(label, copied["clipboard"] == SOURCE.encode()
                   and copied["state"]["selectedTextHashes"] == [expected_hash],
                   {"state": copied["state"], "clipboardSHA256": hashlib.sha256(copied["clipboard"]).hexdigest()})
            input_event("click", *point(65, 80))

        def blocked(label, operation):
            before = remote_state()
            before_writes = writes()
            before_requests = language_reads()
            clipboard = subprocess.check_output(["pbpaste"])
            operation()
            time.sleep(0.5)
            after = remote_state()
            after_writes = writes()
            after_requests = language_reads()
            expect(label, before["closed"] and inspection(after) == inspection(before)
                   and before_writes == after_writes and before_requests == after_requests
                   and subprocess.check_output(["pbpaste"]) == clipboard,
                   {"before": before, "after": after, "writesBefore": before_writes, "writesAfter": after_writes,
                    "protocolBefore": before_requests, "protocolAfter": after_requests})

        def added_object(label, operation, expected_type, expected_props):
            old = {item["id"] for item in call("board.get", {"board": board})["objects"]}
            before_writes = writes()
            operation()

            def added():
                objects = call("board.get", {"board": board})["objects"]
                result = [item for item in objects if item["id"] not in old]
                created.update(item["id"] for item in result)
                return result

            result = wait_for(label + " did not create the expected host object", added, lambda value: len(value) == 1)
            obj = result[0]
            created.add(obj["id"])
            expect(label, obj["type"] == expected_type
                   and all(obj["props"].get(key) == value for key, value in expected_props.items())
                   and writes() > before_writes,
                   {"object": obj, "state": remote_state(), "writesBefore": before_writes, "writesAfter": writes()})
            call("object.delete", {"id": obj["id"]})
            created.remove(obj["id"])
            wait_for("The viewer retained a deleted control object", remote_state,
                     lambda value: obj["id"] not in {item["id"] for item in value["objects"]})

        def arm(token):
            assert not (control / "arm.json").exists(), "An earlier reply gate is still armed"
            tokens.append(token)
            pending = control / "arm.tmp"
            pending.write_text(json.dumps({"method": "textDocument/definition", "token": token}) + "\n")
            pending.replace(control / "arm.json")

        def held(token):
            path = control / (token + ".held.json")
            receipt = wait_for("The real server did not answer the gated definition",
                               lambda: json.loads(path.read_text()) if path.exists() else None,
                               lambda value: value is not None)
            answer = receipt["message"].get("result")
            locations = answer if isinstance(answer, list) else [answer]
            valid = len(locations) == 1 and isinstance(locations[0], dict)
            location = locations[0] if valid else {}
            valid = (receipt["method"] == "textDocument/definition" and valid
                     and location.get("uri", location.get("targetUri")) == Path(args.root, "main.swift").as_uri()
                     and location.get("targetSelectionRange", location.get("range", {})).get("start") == {"line": 2, "character": 5})
            expect(token + " holds a real definition at main.swift line 3", valid, receipt)
            if not valid or "error" in receipt["message"]:
                raise RuntimeError("The real server did not return the fixture definition")
            return receipt

        def release(token):
            (control / (token + ".release")).touch()
            return wait_for("The real server reply was not forwarded", protocol_events,
                            lambda events: any(event["kind"] == "delivered" and event.get("token") == token for event in events))

        definition = {"path": "main.swift", "range": {"start": 3, "end": 3}}

        def positive_controls(prefix):
            for label, operation in (
                    ("context definition", lambda: input_event("menu", *point(65, 80), "Open Definition in New Tile")),
                    ("menubar definition", lambda: input_event("mainmenu", "Code/Open Definition in New Tile")),
                    ("Cmd-click definition", lambda: input_event("click", *point(65, 80), "--mods", "cmd+opt")),
                    ("Cmd-click URL", lambda: input_event("click", *point(200, 62), "--mods", "cmd"))):
                show_code()
                added_object(prefix + " " + label, operation, "browser" if label.endswith("URL") else "code",
                             {"url": URL} if label.endswith("URL") else definition)

        def accessibility_close_control(prefix):
            show_code()
            obj = call("object.create", {"board": board, "type": "code", "props": {"path": "ax-control.swift"},
                                         "frame": code["frame"]})["object"]
            created.add(obj["id"])
            wait_for("The accessibility control tile did not reach the viewer", remote_state,
                     lambda value: obj["id"] in {item["id"] for item in value["objects"]})
            before = host_snapshot()
            viewer_before = remote_state()
            before_writes = writes()
            receipt = press_close(args.viewer_home, viewer_before["window"], args.out / (prefix + "-ax-control.png"),
                                  "Close ax-control.swift")
            after = wait_for("The native accessibility Close did not delete its host object", host_snapshot,
                             lambda value: obj["id"] not in {item["id"] for item in value["objects"]})
            viewer_after = wait_for("The native accessibility Close did not remove its viewer tile", remote_state,
                                    lambda value: obj["id"] not in {item["id"] for item in value["objects"]})
            expect(prefix + " accessibility Close deletes exactly its code tile",
                   after["objects"] == [item for item in before["objects"] if item["id"] != obj["id"]]
                   and after["revision"] == before["revision"] + 1
                   and viewer_after["objects"] == [item for item in viewer_before["objects"] if item["id"] != obj["id"]]
                   and writes() == before_writes + 1,
                   {"hostBefore": before, "hostAfter": after, "viewerBefore": viewer_before, "viewerAfter": viewer_after,
                    "writesBefore": before_writes, "writesAfter": writes(), "nativeAction": receipt})
            created.remove(obj["id"])

        try:
            input_event("remote", args.host, board, args.host_home)
            wait_for("The remote board did not become the selected tab", remote_state,
                     lambda value: not value["closed"] and value["selected"])
            show_code()
            time.sleep(2)
            capture("code-open.png", remote_state()["window"])
            positive_controls("open")
            accessibility_close_control("open")
            show_code()
            before_closed = host_snapshot()
            protocol_before_close = language_reads()
            call("board.close", {"board": board})
            availability(True)
            copy_code("closed code copies the literal cached source")
            capture("code-closed.png", remote_state()["window"])
            closed_requests = language_reads()
            expect("closed code inspection performs no new language requests or server launches",
                   closed_requests == protocol_before_close, closed_requests)
            blocked("closed terminal menubar preserves model focus selection viewport and clipboard",
                    lambda: input_event("mainmenu", "File/New Terminal"))
            for title in ("Go to Definition", "Open Definition in New Tile", "Find References", "Outline"):
                blocked("closed code context " + title,
                        lambda title=title: input_event("menu", *point(65, 80), title))
                blocked("closed code menubar " + title,
                        lambda title=title: input_event("mainmenu", "Code/" + title))
            blocked("closed Cmd-click URL preserves model focus selection viewport and clipboard",
                    lambda: input_event("click", *point(200, 62), "--mods", "cmd"))
            blocked("closed Cmd-click definition preserves model focus selection viewport and clipboard",
                    lambda: input_event("click", *point(65, 80), "--mods", "cmd"))
            blocked("closed Open Definition shortcut preserves inspection",
                    lambda: input_event("shortcut", "j", "--mods", "ctrl+opt+cmd"))
            call("board.open", {"root": args.root, "select": False})
            availability(False)
            expect("closed code actions leave host contents revision and attention unchanged",
                   host_snapshot() == before_closed, {"before": before_closed, "after": host_snapshot()})
            positive_controls("reopened")
            accessibility_close_control("reopened")
            for closes in (True, False):
                show_code()
                input_event("click", *point(200, 12))
                input_event("drag", 700, 600, -7300, 600, "--middle")
                time.sleep(0.5)
                offscreen = remote_state()
                rect = offscreen["viewport"]["rect"]
                assert offscreen["selectedObjects"] == [code["id"]], offscreen
                assert code["frame"]["x"] + code["frame"]["w"] < rect["x"] or code["frame"]["x"] > rect["x"] + rect["w"], offscreen
                token = "close-before-definition" if closes else "open-delayed-definition"
                arm(token)
                operation = lambda: input_event("shortcut", "j", "--mods", "ctrl+opt+cmd")
                if not closes:
                    def open_delayed():
                        operation()
                        held(token)
                        release(token)
                    added_object("open offscreen delayed definition creates the exact host code target", open_delayed, "code", definition)
                    continue
                operation()
                receipt = held(token)
                before_late = host_snapshot()
                call("board.close", {"board": board})
                availability(True)
                before = remote_state()
                before_writes = writes()
                clipboard = subprocess.check_output(["pbpaste"])
                release(token)
                samples = []
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline:
                    samples.append(remote_state())
                    time.sleep(0.05)
                expect("closing an offscreen tile rejects the delayed real definition without provisional edits",
                       all(inspection(value) == inspection(before) for value in samples)
                       and writes() == before_writes and subprocess.check_output(["pbpaste"]) == clipboard,
                       {"before": before, "samples": samples, "writesBefore": before_writes, "writesAfter": writes(),
                        "heldReply": receipt})
                capture("closed-after-delayed-definition.png", remote_state()["window"])
                call("board.open", {"root": args.root, "select": False})
                availability(False)
                expect("late closed navigation leaves host contents revision and attention unchanged",
                       host_snapshot() == before_late, {"before": before_late, "after": host_snapshot()})
            expect("navigation leaves the host source file byte-for-byte unchanged",
                   (fixture / "main.swift").read_bytes() == SOURCE.encode(), {"expectedSHA256": hashlib.sha256(SOURCE.encode()).hexdigest(),
                                                                            "actualSHA256": hashlib.sha256((fixture / "main.swift").read_bytes()).hexdigest()})
            show_code()
            call("board.close", {"board": board})
            availability(True)
            copy_code("closed code copies its cached source before accessibility Close")
            blocked("closed accessibility Close preserves model focus selection viewport clipboard and admission",
                    lambda: press_close(args.viewer_home, remote_state()["window"], args.out / "closed-ax-main.png",
                                        "Close main.swift"))
            copy_code("closed code retains the literal cached source after accessibility Close")
            capture("code-closed-after-accessibility.png", remote_state()["window"])
        finally:
            original_error = sys.exc_info()[1]
            cleanup_error = None
            try:
                (control / "arm.json").unlink(missing_ok=True)
                for token in tokens:
                    (control / (token + ".release")).touch()
                call("board.open", {"root": args.root, "select": False})
                existing = {item["id"] for item in call("board.get", {"board": board})["objects"]}
                for identifier in sorted(created & existing):
                    call("object.delete", {"id": identifier})
            except Exception as error:
                cleanup_error = error
            try:
                args.out.joinpath("lsp-events.json").write_text(json.dumps(protocol_events(), indent=2) + "\n")
            except Exception as error:
                if original_error is None and cleanup_error is None and not failures:
                    raise
                print(f"Protocol evidence retention also failed: {error!r}", file=sys.stderr)
            if cleanup_error is not None:
                if original_error is None and not failures:
                    raise cleanup_error
                print(f"Host cleanup also failed: {cleanup_error!r}", file=sys.stderr)

    board = call("board.open", {"root": args.root, "select": False})["board"]
    existing = call("board.get", {"board": board})["objects"]
    assert existing == [], "Use a new, empty scratch board root"
    markdown = "# Closed board inspection\n\nCopy this closed-board text.\n\n" + "\n\n".join(f"Retained paragraph {n}." for n in range(1, 31))
    note = call("object.create", {"board": board, "type": "note", "props": {"markdown": markdown},
                                  "frame": {"x": 0, "y": 0, "w": 560, "h": 360}})["object"]
    input_event("remote", args.host, board, args.host_home)
    deadline = time.monotonic() + 30
    while True:
        try:
            opened = remote_state()
            break
        except (StopIteration, RuntimeError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.2)
    input_event("shortcut", "0", "--mods", "cmd")
    time.sleep(0.5)
    initial = remote_state()["viewport"]
    rect = initial["rect"]
    zoom = initial["zoom"]
    input_event("drag", 700, 600, round(700 + (rect["x"] + 40) * zoom),
                round(600 + (rect["y"] + 70) * zoom), "--middle")
    call("object.create", {"board": board, "type": "question",
                           "props": {"question": "Hidden closed-board question", "asker": {"name": "closed-board regression"},
                                     "options": [{"id": "a", "label": "Keep unanswered"}], "keep": True},
                           "frame": {"x": 5000, "y": 5000, "w": 300, "h": 200}})
    visible_question = call("object.create", {"board": board, "type": "question",
                                             "props": {"question": "Keep this question open", "asker": {"name": "closed-board regression"},
                                                       "options": [{"id": "a", "label": "Do not answer"}], "keep": True},
                                             "frame": {"x": 650, "y": 0, "w": 400, "h": 260}})["object"]
    input_event("drag", 700, 600, -7300, 600, "--middle")
    time.sleep(2)
    call("board.close", {"board": board})
    deadline = time.monotonic() + 10
    while not remote_state()["closed"]:
        if time.monotonic() >= deadline:
            raise RuntimeError("The viewer did not observe host close")
        time.sleep(0.1)
    input_event("drag", 700, 600, 8700, 600, "--middle")
    time.sleep(0.5)
    before = remote_state()
    capture("closed-before.png", before["window"])
    rect = before["viewport"]["rect"]
    zoom = before["viewport"]["zoom"]
    menu_x = int((visible_question["frame"]["x"] - rect["x"] + 30) * zoom)
    menu_y = int((visible_question["frame"]["y"] - rect["y"] + 50) * zoom)
    input_event("menu", menu_x, menu_y, "Close")
    after_menu = remote_state()
    expect("closed question context menu refuses edits",
           after_menu["objects"] == before["objects"] and after_menu["selectedObjects"] == before["selectedObjects"], after_menu)
    x = int((note["frame"]["x"] - rect["x"] + 80) * zoom)
    y = int((note["frame"]["y"] - rect["y"] + 100) * zoom)
    input_event("click", x, y)
    input_event("shortcut", "a", "--mods", "cmd")
    input_event("shortcut", "c", "--mods", "cmd")
    selected = remote_state()
    expected_text = "\n".join(["Closed board inspection", "Copy this closed-board text."] + [f"Retained paragraph {n}." for n in range(1, 31)])
    expected_hash = hashlib.sha256(expected_text.encode()).hexdigest()
    expect("closed note selects text to copy", selected["selectedTextHashes"] == [expected_hash], selected["selectedTextHashes"])
    if selected["selectedTextHashes"] == [expected_hash]:
        copied = subprocess.check_output(["pbpaste"])
        expect("closed note copies its selected text", hashlib.sha256(copied).hexdigest() == expected_hash, {"matchesFixture": hashlib.sha256(copied).hexdigest() == expected_hash})
    input_event("scroll", x, y, 0, -80)
    input_event("scroll", 900, 400, -160, 0)
    input_event("drag", 900, 400, 1040, 450, "--middle")
    time.sleep(0.5)
    panned = remote_state()
    expect("closed board pans", panned["viewport"]["rect"] != before["viewport"]["rect"],
           {"before": before["viewport"], "after": panned["viewport"]})
    capture("closed-panned.png", panned["window"])
    input_event("shortcut", "-", "--mods", "cmd")
    time.sleep(0.4)
    zoomed = remote_state()
    expect("closed board zooms", zoomed["viewport"]["zoom"] < panned["viewport"]["zoom"], zoomed["viewport"])
    capture("closed-panned-zoomed.png", zoomed["window"])
    with Image.open(args.out / "closed-panned.png") as panned_image, Image.open(args.out / "closed-panned-zoomed.png") as zoomed_image:
        crop = (0, 300, panned_image.width, panned_image.height - 150)
        difference = ImageChops.difference(panned_image.convert("RGB").crop(crop), zoomed_image.convert("RGB").crop(crop)).getbbox()
    expect("closed board visibly zooms", difference is not None, {"pixelDifference": difference})
    input_event("shortcut", "n", "--mods", "cmd")
    input_event("key", "delete")
    input_event("text", "THIS EDIT MUST BE REFUSED")
    input_event("key", "escape")
    input_event("key", "delete")
    input_event("mainmenu", "Edit/Select All")
    after_edit = remote_state()
    expect("closed board refuses edits", after_edit["objects"] == before["objects"], after_edit["objects"])
    expect("closed menu Select All does not select board objects", after_edit["selectedObjects"] == before["selectedObjects"], after_edit["selectedObjects"])
    before_terminal = remote_state()
    input_event("shortcut", "t", "--mods", "cmd")
    after_terminal = remote_state()
    expect("closed New Terminal shortcut preserves the viewport, selection and focus",
           after_terminal["closed"] and after_terminal["objects"] == before_terminal["objects"]
           and after_terminal["selectedObjects"] == before_terminal["selectedObjects"]
           and after_terminal["responder"] == before_terminal["responder"]
           and after_terminal["viewport"] == before_terminal["viewport"],
           {"before": before_terminal, "after": after_terminal})
    tour_root = args.viewer_home.parent / "easl-followups-tour"
    tour_root.mkdir(exist_ok=True)
    local = call("board.open", {"root": str(tour_root), "select": True}, str(args.viewer_home / "easl.sock"))["board"]
    time.sleep(0.4)
    hidden_before = remote_state()
    input_event("shortcut", "j", "--mods", "cmd")
    input_event("mainmenu", "View/Go to Next Needs-You")
    time.sleep(0.4)
    hidden_after = remote_state()
    expect("needs-you skips the hidden closed tab",
           hidden_after["viewport"] == hidden_before["viewport"] and hidden_after["responder"] == hidden_before["responder"] and not hidden_after["selected"],
           {"before": hidden_before, "after": hidden_after, "local": local})
    call("board.open", {"root": args.root, "select": False})
    deadline = time.monotonic() + 10
    while remote_state()["closed"]:
        if time.monotonic() >= deadline:
            raise RuntimeError("The viewer did not observe host reopen")
        time.sleep(0.1)
    retained = call("object.get", {"id": note["id"]})["object"]
    expect("host retained the note", retained["props"]["markdown"] == markdown and retained["frame"] == note["frame"], retained)
    try:
        exercise_code()
    finally:
        original_error = sys.exc_info()[1]
        try:
            args.out.joinpath("observations.json").write_text(json.dumps(observations, indent=2) + "\n")
        except Exception as error:
            if original_error is None and not failures:
                raise
            print(f"Observation retention also failed: {error!r}", file=sys.stderr)
    if failures:
        raise SystemExit("Failed: " + ", ".join(failures))


if __name__ == "__main__":
    try:
        main()
    finally:
        original_error = sys.exc_info()[1]
        try:
            end_session()
        except Exception as error:
            if original_error is None:
                raise
            print(f"Native session cleanup also failed: {error!r}", file=sys.stderr)
