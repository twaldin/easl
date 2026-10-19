import json
from pathlib import Path
import subprocess
import uuid


DRIVER = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
SESSION = "RemoteClosedBoard" + uuid.uuid4().hex
used = False


def capture(home, window, destination, accessibility=False):
    global used
    home = Path(home)
    destination = Path(destination).resolve()
    pid = int((home / "pid").read_text().strip())
    holders = subprocess.check_output(["lsof", "-t", str(home / "instance.lock")], text=True).split()
    assert holders == [str(pid)], "The native capture PID does not exactly own this development home"
    arguments = {"pid": pid, "window_id": int(window), "include_accessibility_tree": accessibility,
                 "max_image_dimension": 0, "screenshot_out_file": str(destination), "session": SESSION}
    used = True
    result = subprocess.run([DRIVER, "call", "get_window_state", json.dumps(arguments)], capture_output=True, text=True)
    destination.with_suffix(".capture.json").write_text(result.stdout)
    destination.with_suffix(".capture.stderr").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(result.stdout + "\n" + result.stderr)
    response = json.loads(result.stdout)
    receipt = response.get("structuredContent", response)
    assert receipt["pid"] == pid and receipt["window_id"] == int(window), receipt
    assert receipt["screenshot_frame_valid"] is True, receipt
    assert receipt["capture_id"] and receipt["snapshot_id"], receipt
    assert destination.is_file(), "CuaDriver did not write the owned window capture"
    return receipt


def press_close(home, window, destination, label):
    destination = Path(destination).resolve()
    snapshot = capture(home, window, destination, accessibility=True)
    matches = [element for element in snapshot["elements"]
               if element.get("role") == "AXButton" and element.get("label") == label]
    assert len(matches) == 1, {"label": label, "matches": matches, "snapshot": snapshot}
    element = matches[0]
    assert "AXPress" in element.get("actions", []), element
    assert element["element_token"].startswith(snapshot["snapshot_id"] + ":"), element
    arguments = {"pid": snapshot["pid"], "window_id": snapshot["window_id"], "session": SESSION,
                 "element_token": element["element_token"], "action": "press", "delivery_mode": "background"}
    result = subprocess.run([DRIVER, "call", "click", json.dumps(arguments)], capture_output=True, text=True)
    destination.with_suffix(".action-request.json").write_text(json.dumps(arguments, indent=2) + "\n")
    destination.with_suffix(".action.json").write_text(result.stdout)
    destination.with_suffix(".action.stderr").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(result.stdout + "\n" + result.stderr)
    return json.loads(result.stdout)


def end_session():
    if used:
        subprocess.run([DRIVER, "call", "end_session", json.dumps({"session": SESSION})], check=True)
