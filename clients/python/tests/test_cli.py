"""The `easl` CLI (cli/easl.ts, run with bun) against a fake app socket: what params it sends.
Run from clients/python: python3 -m unittest"""

from __future__ import annotations

import base64
import datetime
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tests.test_connection import EASL_ENV, FakeApp

CLI = Path(__file__).resolve().parents[3] / "cli" / "easl.ts"
CMUX_ENV = ("CMUX_SOCKET_PATH", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_SOCKET_PASSWORD")


@unittest.skipUnless(shutil.which("bun"), "the CLI runs on bun")
class CliParamsTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.app = FakeApp(str(self.dir / "easl.sock"))
        self.addCleanup(self.app.stop)

    def run_cli(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if key not in EASL_ENV}
        env["EASL_SOCKET"] = self.app.path
        return subprocess.run(["bun", str(CLI), *args], input=stdin, capture_output=True, text=True, cwd=self.dir, env=env, timeout=30)

    def sent(self) -> dict:
        self.assertEqual(len(self.app.requests), 1)
        return self.app.requests[0][1]

    def test_json_at_file_reads_params_relative_to_the_cwd(self) -> None:
        html = "<h1>" + "x" * 5000 + "</h1>"
        (self.dir / "params.json").write_text(json.dumps({"type": "html", "props": {"html": html}}))
        result = self.run_cli("object.create", "--json", "@params.json", "--frame.x", "10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"type": "html", "props": {"html": html}, "frame": {"x": 10}})

    def test_json_at_dash_reads_params_from_stdin(self) -> None:
        result = self.run_cli("agent.prompt", "--json", "@-", stdin='{"target": "fees", "text": "review\\nthe diff"}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"target": "fees", "text": "review\nthe diff"})

    def test_later_arguments_override_the_file(self) -> None:
        (self.dir / "p.json").write_text('{"target": "a", "lines": 5}')
        result = self.run_cli("agent.read", "--json", "@p.json", "--target", "b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"target": "b", "lines": 5})

    def test_string_params_keep_the_text_as_typed(self) -> None:
        # Answering Codex's "1. Trust and continue": text is a string param; lines stays a number.
        result = self.run_cli("agent.prompt", "--target", "codex", "--text", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"target": "codex", "text": "1"})
        self.app.requests.clear()
        result = self.run_cli("agent.read", "--target", "2", "--lines", "40")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"target": "2", "lines": 40})

    def test_array_params_take_one_item_a_list_or_repeated_flags(self) -> None:
        # `--until working` once went out as the string "working", and agent.wait fell back to its default states.
        cases = (
            (("agent.wait", "--target", "a", "--until", "working"), {"target": "a", "until": ["working"]}),
            (("agent.wait", "--target", "a", "--until", "working,blocked"), {"target": "a", "until": ["working", "blocked"]}),
            (("agent.wait", "--target", "a", "--until", "working", "--until", "idle"), {"target": "a", "until": ["working", "idle"]}),
            (("agent.wait", "--target", "a", "--until", '["done"]'), {"target": "a", "until": ["done"]}),
            (("agent.wait", "--json", '{"target": "a", "until": ["idle"]}', "--until", "working"), {"target": "a", "until": ["working"]}),
            (("layout.translate", "--ids", "obj_1,obj_2", "--dx", "5", "--dy", "0"), {"ids": ["obj_1", "obj_2"], "dx": 5, "dy": 0}),
            (("board.history", "--kinds", "created"), {"kinds": ["created"]}),
            (("view.render", "--target", "obj_1", "--exclude", "terminal"), {"target": "obj_1", "exclude": ["terminal"]}),
            (("agent.prompt", "--target", "a", "--text", "t", "--mentions", '{"object": "obj_1"}'), {"target": "a", "text": "t", "mentions": [{"object": "obj_1"}]}),
        )
        for args, params in cases:
            with self.subTest(args=args):
                self.app.requests.clear()
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.sent(), params)

    def test_unreadable_or_invalid_files_fail_before_sending(self) -> None:
        (self.dir / "bad.json").write_text("{not json")
        (self.dir / "list.json").write_text("[1, 2]")
        for argument, message in (("@missing.json", "cannot read"), ("@bad.json", "not JSON"), ("@list.json", "params must be a JSON object")):
            with self.subTest(argument=argument):
                result = self.run_cli("board.get", "--json", argument)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"invalid_params: --json {argument}: {message}", result.stderr)
        self.assertEqual(self.app.requests, [])


class FakeCmux:
    """Stands in for the app's cmux socket: records requests; answers `auth` lines and each method from `replies`."""

    def __init__(self, path: str, password: str | None = None) -> None:
        self.path = path
        self.password = password
        self.lines: list[str] = []
        self.requests: list[tuple[str, dict]] = []
        # method -> ("ok", result) or ("error", {"code", "message"}); others answer {}.
        self.replies: dict[str, tuple[str, dict]] = {}
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(path)
        self._listener.listen()
        threading.Thread(target=self._accept, daemon=True).start()

    def stop(self) -> None:
        self._listener.close()

    def _accept(self) -> None:
        while True:
            try:
                conn, _ = self._listener.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        authenticated = self.password is None
        with conn, conn.makefile("r", encoding="utf-8") as reader:
            for line in reader:
                self.lines.append(line.rstrip("\n"))
                if line.startswith("auth "):
                    authenticated = line[5:].rstrip("\n") == self.password
                    conn.sendall(b"OK: Authenticated\n" if authenticated else b"ERROR: Invalid password\n")
                    continue
                request = json.loads(line)
                if not authenticated:
                    reply = {"id": request["id"], "ok": False, "error": {"code": "unauthorized", "message": "send `auth <password>` first"}}
                else:
                    self.requests.append((request["method"], request["params"]))
                    kind, body = self.replies.get(request["method"], ("ok", {}))
                    reply = {"id": request["id"], "ok": kind == "ok", ("result" if kind == "ok" else "error"): body}
                conn.sendall((json.dumps(reply) + "\n").encode())


@unittest.skipUnless(shutil.which("bun"), "the CLI runs on bun")
class CliBrowserTest(unittest.TestCase):
    """`easl browser <verb>`: requests on the cmux socket (docs/contracts.md, cmux browser subset)."""

    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.serve()

    def serve(self, password: str | None = None) -> None:
        self.cmux = FakeCmux(str(self.dir / f"cmux-{password}.sock"), password)
        self.addCleanup(self.cmux.stop)

    def run_cli(self, *args: str, **env_overrides: str) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if key not in EASL_ENV + CMUX_ENV}
        env.update({"CMUX_SOCKET_PATH": self.cmux.path, "CMUX_SURFACE_ID": "obj_term", "TMPDIR": str(self.dir)})
        env.update(env_overrides)
        return subprocess.run(["bun", str(CLI), "browser", *args], capture_output=True, text=True, cwd=self.dir, env=env, timeout=30)

    def test_verbs_map_to_cmux_methods_on_the_given_tile(self) -> None:
        cases = [
            (["open", "http://localhost:3000"], ("browser.open_split", {"url": "http://localhost:3000", "surface_id": "obj_term"})),
            (["list"], ("surface.list", {"surface_id": "obj_term"})),
            (["list", "--workspace_id", "brd_other"], ("surface.list", {"workspace_id": "brd_other"})),
            (["close", "obj_page"], ("surface.close", {"surface_id": "obj_page"})),
            (["click", "obj_page", "--selector", "@e2"], ("browser.click", {"surface_id": "obj_page", "selector": "@e2"})),
            (["url.get", "obj_page"], ("browser.url.get", {"surface_id": "obj_page"})),
            (["eval", "--json", '{"surface_id": "obj_page", "script": "document.title"}'], ("browser.eval", {"surface_id": "obj_page", "script": "document.title"})),
        ]
        for args, request in cases:
            with self.subTest(args=args):
                self.cmux.requests.clear()
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.cmux.requests, [request])

    def test_string_params_keep_the_text_as_typed(self) -> None:
        for args, params in (
            (["type", "obj_page", "--selector", "#zip", "--text", "02139"], {"surface_id": "obj_page", "selector": "#zip", "text": "02139"}),
            (["press", "obj_page", "--key", "1"], {"surface_id": "obj_page", "key": "1"}),
            (["scroll", "obj_page", "--dy", "300"], {"surface_id": "obj_page", "dy": 300}),
            (["wait", "obj_page", "--load_state", "complete", "--timeout_ms", "5000"], {"surface_id": "obj_page", "load_state": "complete", "timeout_ms": 5000}),
            (["snapshot", "obj_page", "--interactive"], {"surface_id": "obj_page", "interactive": True}),
        ):
            with self.subTest(args=args):
                self.cmux.requests.clear()
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.cmux.requests[0][1], params)

    def test_a_password_is_sent_first_and_a_wrong_one_stops_the_request(self) -> None:
        self.serve(password="s3cret")
        result = self.run_cli("url.get", "obj_page", CMUX_SOCKET_PASSWORD="s3cret")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cmux.lines[0], "auth s3cret")
        self.assertEqual(self.cmux.requests, [("browser.url.get", {"surface_id": "obj_page"})])

        self.cmux.lines.clear()
        self.cmux.requests.clear()
        result = self.run_cli("url.get", "obj_page", CMUX_SOCKET_PASSWORD="wrong")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "unauthorized: Invalid password")
        self.assertEqual(self.cmux.lines, ["auth wrong"])

    def test_an_error_reply_prints_code_and_message_and_exits_1(self) -> None:
        self.cmux.replies["browser.click"] = ("error", {"code": "not_found", "message": "no element matches #missing"})
        result = self.run_cli("click", "obj_page", "--selector", "#missing")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "not_found: no element matches #missing")
        self.assertEqual(result.stdout, "")

    def test_screenshot_writes_the_png_and_prints_its_path(self) -> None:
        png = b"\x89PNG\r\n\x1a\nfake"
        self.cmux.replies["browser.screenshot"] = ("ok", {"png_base64": base64.b64encode(png).decode(), "width": 10, "height": 5, "surface_id": "obj_page"})
        result = self.run_cli("screenshot", "obj_page", "--out", "shot.png")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"width": 10, "height": 5, "surface_id": "obj_page", "path": str(self.dir.resolve() / "shot.png")})
        self.assertEqual((self.dir / "shot.png").read_bytes(), png)
        self.assertEqual(self.cmux.requests, [("browser.screenshot", {"surface_id": "obj_page"})])

        # Without --out, a new file under $TMPDIR/easl-renders/ (the app deletes it after a day).
        result = self.run_cli("screenshot", "obj_page")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(json.loads(result.stdout)["path"])
        self.assertEqual(path.parent.resolve(), self.dir.resolve() / "easl-renders")
        self.assertRegex(path.name, r"^screenshot-\d+-\d+\.png$")
        self.assertEqual(path.read_bytes(), png)


class FakeEventApp:
    """Stands in for the app's easl socket for `easl ask`: records every request (all connections, in arrival order),
    answers each method from `replies` ({} when unset; an ("error", {...}) tuple fails it) and acknowledges events.subscribe.
    After answering a method it pushes `pushes[method]` as event lines to every subscriber, then hangs them up if `hang_up_after` has it."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.requests: list[tuple[str, dict]] = []
        self.replies: dict[str, dict | tuple[str, dict]] = {}
        self.pushes: dict[str, list[dict]] = {}
        self.hang_up_after: set[str] = set()
        self._subscribers: list[socket.socket] = []
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(path)
        self._listener.listen()
        threading.Thread(target=self._accept, daemon=True).start()

    def stop(self) -> None:
        self._listener.close()

    def _accept(self) -> None:
        while True:
            try:
                conn, _ = self._listener.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        try:
            with conn, conn.makefile("r", encoding="utf-8") as reader:
                for line in reader:
                    request = json.loads(line)
                    method = request["method"]
                    self.requests.append((method, request["params"]))
                    reply = self.replies.get(method, {})
                    failed = isinstance(reply, tuple)
                    message = {"id": request["id"], "ok": not failed, ("error" if failed else "result"): reply[1] if failed else reply}
                    if method == "events.subscribe" and not failed:
                        self._subscribers.append(conn)
                    conn.sendall((json.dumps(message) + "\n").encode())
                    for subscriber in list(self._subscribers):
                        try:
                            for event in self.pushes.get(method, []):
                                subscriber.sendall((json.dumps(event) + "\n").encode())
                            if method in self.hang_up_after:
                                subscriber.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass  # a subscriber of an earlier run that is already gone
        except OSError:
            pass
        finally:
            # A subscriber that hung up (or was hung up on) is gone for the next run's pushes.
            if conn in self._subscribers:
                self._subscribers.remove(conn)


def question(status: str = "open", **props: object) -> dict:
    """A question object as the app returns it and announces it in events."""
    options = [{"id": "a", "label": "Now"}, {"id": "b", "label": "Later", "why": "the freeze is Friday"}]
    return {"id": "obj_q1", "type": "question", "props": {"question": "Ship it?", "options": options, "status": status, **props}}


def event(name: str, data: dict) -> dict:
    return {"event": name, "data": data, "board": "brd_home"}


ANSWER = {"option": "b", "note": "after the freeze", "at": "2026-10-05T17:00:00Z", "by": {"kind": "user"}}


@unittest.skipUnless(shutil.which("bun"), "the CLI runs on bun")
class CliAskTest(unittest.TestCase):
    """`easl ask`: the create/list/get/cancel params it sends, and the --wait loop driven by events."""

    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.app = FakeEventApp(str(self.dir / "easl.sock"))
        self.addCleanup(self.app.stop)
        self.app.replies["object.create"] = {"object": question()}

    def run_cli(self, *args: str, stdin: str | None = None, **env_overrides: str) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if key not in EASL_ENV}
        env["EASL_SOCKET"] = self.app.path
        env.update(env_overrides)
        return subprocess.run(["bun", str(CLI), "ask", *args], input=stdin, capture_output=True, text=True, cwd=self.dir, env=env, timeout=30)

    def sent(self) -> dict:
        self.assertEqual([method for method, _ in self.app.requests], ["object.create"])
        return self.app.requests[0][1]

    def assert_failed_before_sending(self, result: subprocess.CompletedProcess[str], message: str) -> None:
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(result.stderr.startswith(f"invalid_params: {message}"), result.stderr)
        self.assertEqual(self.app.requests, [])

    def assert_expires_in(self, props: dict, seconds: int) -> None:
        self.assertRegex(props["expiresAt"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        at = datetime.datetime.strptime(props["expiresAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        self.assertAlmostEqual(at.timestamp(), time.time() + seconds, delta=10)

    def test_flags_build_the_question_props(self) -> None:
        result = self.run_cli(
            "Ship it?",
            "--option", "a=Now",
            "--option", "b=Later:the freeze is Friday",
            "--option", "c=Never: ever: really",
            "--recommend", "a",
            "--context", "obj_abc123",
            "--context", "https://example.com/a?b=1",
            "--context", "http://localhost:3000",
            "--context", "mailto:tim@example.com",
            "--context", "src/store.ts:10-20",
            "--context", "notes.md:7",
            "--context", "README.md",
            "--asker", "cos@mini",
            "--board", "brd_x",
        )  # fmt: skip
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.sent(),
            {
                "type": "question",
                "board": "brd_x",
                "props": {
                    "question": "Ship it?",
                    "options": [
                        {"id": "a", "label": "Now"},
                        {"id": "b", "label": "Later", "why": "the freeze is Friday"},
                        {"id": "c", "label": "Never", "why": "ever: really"},
                    ],
                    "recommended": "a",
                    "context": [
                        {"object": "obj_abc123"},
                        {"url": "https://example.com/a?b=1"},
                        {"url": "http://localhost:3000"},
                        {"url": "mailto:tim@example.com"},
                        {"path": "src/store.ts", "lines": {"start": 10, "end": 20}},
                        {"path": "notes.md", "lines": {"start": 7, "end": 7}},
                        {"path": "README.md"},
                    ],
                    "asker": {"name": "cos", "host": "mini"},
                },
            },
        )
        self.assertEqual(json.loads(result.stdout), {"object": question()})

    def test_a_question_without_options_asks_for_a_note_and_a_bare_asker_has_no_host(self) -> None:
        result = self.run_cli("Name?", "--asker", "cos")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"type": "question", "props": {"question": "Name?", "options": [], "asker": {"name": "cos"}}})

    def test_expires_takes_durations_or_an_iso_time(self) -> None:
        for text, seconds in (("45s", 45), ("30m", 1800), ("2h", 7200), ("1d", 86400)):
            with self.subTest(text):
                self.app.requests.clear()
                self.assertEqual(self.run_cli("Q?", "--asker", "cos", "--expires", text).returncode, 0)
                self.assert_expires_in(self.sent()["props"], seconds)
        self.app.requests.clear()
        self.assertEqual(self.run_cli("Q?", "--asker", "cos", "--expires", "2026-12-01T09:00:00-05:00").returncode, 0)
        self.assertEqual(self.sent()["props"]["expiresAt"], "2026-12-01T09:00:00-05:00")

    def test_a_bad_expiry_fails_before_sending(self) -> None:
        self.assert_failed_before_sending(self.run_cli("Q?", "--expires", "soon"), '--expires takes a duration (45s, 30m, 2h, 1d) or an ISO 8601 date-time, got "soon"')

    def test_without_an_asker_a_terminal_sends_none_and_anyone_else_is_the_os_user(self) -> None:
        # In a tile the client fills `caller` from EASL_TILE_ID and the app makes the asker {tile: caller}.
        self.assertEqual(self.run_cli("Q?", EASL_TILE_ID="obj_term", EASL_BOARD_ID="brd_home").returncode, 0)
        self.assertEqual(self.sent(), {"type": "question", "board": "brd_home", "caller": "obj_term", "props": {"question": "Q?", "options": []}})
        self.app.requests.clear()
        self.assertEqual(self.run_cli("Q?").returncode, 0)
        asker = {"name": pwd.getpwuid(os.getuid()).pw_name, "host": socket.gethostname().split(".")[0]}
        self.assertEqual(self.sent(), {"type": "question", "props": {"question": "Q?", "options": [], "asker": asker}})

    def test_json_is_the_props_and_the_flags_add_to_or_replace_them(self) -> None:
        cos = {
            "question": "Ship it?",
            "options": [{"id": "a", "label": "Now", "why": "fast"}, {"id": "b", "label": "Later"}],
            "recommended": "a",
            "context": [{"url": "https://example.com"}],
            "asker": {"name": "cos", "host": "mini"},
            "expiresAt": "2026-12-01T09:00:00Z",
            "key": "ask-1",
        }
        (self.dir / "cos.json").write_text(json.dumps(cos))
        for args, stdin in ((("--json", json.dumps(cos)), None), (("--json", "@cos.json"), None), (("--json", "@-"), json.dumps(cos))):
            with self.subTest(args):
                self.app.requests.clear()
                result = self.run_cli(*args, stdin=stdin, EASL_TILE_ID="obj_term")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.sent(), {"type": "question", "caller": "obj_term", "props": cos})
        self.app.requests.clear()
        result = self.run_cli("--json", json.dumps(cos), "Which?", "--option", "c=Maybe:ask Bob", "--recommend", "c", "--context", "obj_z1", "--asker", "tim", "--expires", "1h")
        self.assertEqual(result.returncode, 0, result.stderr)
        props = self.sent()["props"]
        self.assert_expires_in(props, 3600)
        del props["expiresAt"]
        self.assertEqual(
            props,
            {
                "question": "Which?",
                "options": [*cos["options"], {"id": "c", "label": "Maybe", "why": "ask Bob"}],
                "recommended": "c",
                "context": [{"url": "https://example.com"}, {"object": "obj_z1"}],
                "asker": {"name": "tim"},
                "key": "ask-1",
            },
        )

    def test_bad_arguments_fail_before_sending(self) -> None:
        cases = (
            (("one", "two"), 'easl ask takes one question; quote it (got 2 arguments, "two" is the second)'),
            (("Q?", "--option", "nolabel"), '--option takes id=label[:why], got "nolabel"'),
            (("Q?", "--option"), "--option needs a value"),
            (("Q?", "--nope", "1"), "unknown flag --nope for easl ask"),
            (("list", "extra"), "easl ask list takes no arguments"),
            (("get",), "easl ask get takes one question id"),
            (("cancel", "obj_a", "obj_b"), "easl ask cancel takes one question id"),
            (("get", "obj_a", "--board", "brd_x"), "unknown flag --board for easl ask get"),
            (("Q?", "--json", '{"options": "a"}', "--option", "a=A"), "--option adds to options, but --json gave options that is not an array"),
        )
        for args, message in cases:
            with self.subTest(args):
                self.assert_failed_before_sending(self.run_cli(*args), message)

    def test_the_apps_error_prints_code_and_message(self) -> None:
        self.app.replies["object.create"] = ("error", {"code": "invalid_params", "message": "a question needs props.question, a non-empty string"})
        result = self.run_cli("--option", "a=A")
        self.assertEqual((result.returncode, result.stdout), (1, ""))
        self.assertEqual(result.stderr, "invalid_params: a question needs props.question, a non-empty string\n")

    def test_list_get_and_cancel_params(self) -> None:
        cases = (
            ((("list",), {}), ("object.find", {"type": "question"})),
            ((("list", "--open", "--board", "brd_x"), {}), ("object.find", {"type": "question", "status": "open", "board": "brd_x"})),
            ((("list", "--open"), {"EASL_BOARD_ID": "brd_home"}), ("object.find", {"type": "question", "status": "open", "board": "brd_home"})),
            ((("get", "obj_q1"), {"EASL_TILE_ID": "obj_term"}), ("object.get", {"id": "obj_q1"})),
            ((("cancel", "obj_q1"), {}), ("object.update", {"id": "obj_q1", "props": {"status": "cancelled"}})),
            ((("cancel", "obj_q1"), {"EASL_TILE_ID": "obj_term"}), ("object.update", {"id": "obj_q1", "props": {"status": "cancelled"}, "caller": "obj_term"})),
        )
        for (args, env), request in cases:
            with self.subTest(args, env=env):
                self.app.requests.clear()
                self.app.replies[request[0]] = {"objects": [question()]}
                result = self.run_cli(*args, **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.app.requests, [request])
                self.assertEqual(json.loads(result.stdout), {"objects": [question()]})

    def test_help_lists_the_ask_forms(self) -> None:
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        for form in ('easl ask "question" --option id=label[:why]', "easl ask --json", "easl ask list [--open]", "easl ask get <id> | cancel <id> | wait <id>", "[--wait]"):
            self.assertIn(form, result.stdout)
        self.assertEqual(self.run_cli().returncode, 2)
        self.assertEqual(self.app.requests, [])

    def ask_and_wait(self, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return self.run_cli("Ship it?", "--option", "a=Now", "--option", "b=Later", "--wait", *args, **env)

    def test_wait_subscribes_before_creating_and_prints_the_answer(self) -> None:
        self.app.pushes["object.create"] = [event("object.updated", question("answered", answer=ANSWER))]
        result = self.ask_and_wait(EASL_BOARD_ID="brd_home", EASL_TILE_ID="obj_term")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual([request[0] for request in self.app.requests], ["events.subscribe", "object.create"])
        self.assertEqual(self.app.requests[0][1], {"board": "brd_home"})
        answer = json.loads(result.stdout)
        self.assertEqual(answer, {"id": "obj_q1", "option": "b", "label": "Later", "note": "after the freeze", "at": "2026-10-05T17:00:00Z", "by": {"kind": "user"}})
        self.assertEqual(list(answer), ["id", "option", "label", "note", "at", "by"])

    def test_wait_without_a_known_board_hears_every_board_and_a_flag_names_one(self) -> None:
        self.app.pushes["object.create"] = [event("object.updated", question("answered", answer=ANSWER))]
        self.assertEqual(self.ask_and_wait().returncode, 0)
        self.assertEqual(self.app.requests[0], ("events.subscribe", {}))
        self.app.requests.clear()
        self.assertEqual(self.ask_and_wait("--board", "brd_x").returncode, 0)
        self.assertEqual(self.app.requests[0], ("events.subscribe", {"board": "brd_x"}))

    def test_wait_skips_other_objects_and_updates_that_leave_it_open(self) -> None:
        other = {**question("answered", answer=ANSWER), "id": "obj_other"}
        self.app.pushes["object.create"] = [
            event("object.created", other),
            event("object.updated", other),
            event("object.deleted", {"id": "obj_other"}),
            event("object.updated", question("open", question="Ship it today?")),
            {"event": "tray.changed", "data": {}},
            event("object.updated", question("answered", answer=ANSWER)),
        ]
        result = self.ask_and_wait()
        self.assertEqual((result.returncode, json.loads(result.stdout)["id"]), (0, "obj_q1"))

    def test_a_note_answer_has_no_option_or_label(self) -> None:
        answer = {"note": "call it Atlas", "at": "2026-10-05T17:00:00Z", "by": {"kind": "agent", "tile": "obj_t"}}
        self.app.pushes["object.create"] = [event("object.updated", question("answered", options=[], answer=answer))]
        result = self.ask_and_wait()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(json.loads(result.stdout)), ["id", "note", "at", "by"])

    def test_wait_exits_2_with_why_when_the_question_ends_unanswered(self) -> None:
        cases = (
            (event("object.updated", question("cancelled")), "cancelled: question obj_q1 was cancelled\n"),
            (event("object.updated", question("expired")), "expired: question obj_q1 expired\n"),
            (event("object.deleted", {"id": "obj_q1"}), "deleted: question obj_q1 was deleted\n"),
        )
        for pushed, message in cases:
            with self.subTest(message):
                self.app.pushes["object.create"] = [pushed]
                result = self.ask_and_wait()
                self.assertEqual((result.returncode, result.stdout, result.stderr), (2, "", message))

    def test_a_dropped_event_connection_is_an_error_but_a_delivered_answer_survives_it(self) -> None:
        self.app.hang_up_after.add("object.create")
        result = self.ask_and_wait()
        self.assertEqual((result.returncode, result.stdout), (1, ""))
        self.assertTrue(result.stderr.startswith("unavailable: the event connection closed before question obj_q1 was answered"), result.stderr)
        self.app.pushes["object.create"] = [event("object.updated", question("answered", answer=ANSWER))]
        result = self.ask_and_wait()
        self.assertEqual((result.returncode, json.loads(result.stdout)["option"]), (0, "b"))

    def test_a_refused_subscription_stops_before_creating(self) -> None:
        self.app.replies["events.subscribe"] = ("error", {"code": "invalid_params", "message": "unknown board"})
        result = self.ask_and_wait("--board", "brd_nope")
        self.assertEqual((result.returncode, result.stderr), (1, "invalid_params: unknown board\n"))
        self.assertEqual([request[0] for request in self.app.requests], ["events.subscribe"])

    def test_ask_wait_reads_a_question_that_is_already_closed_after_subscribing(self) -> None:
        self.app.replies["object.get"] = {"object": question("answered", answer=ANSWER)}
        result = self.run_cli("wait", "obj_q1", EASL_BOARD_ID="brd_home")
        self.assertEqual(result.returncode, 0, result.stderr)
        # Without --board it hears every board: the question may not be on the caller's own.
        self.assertEqual(self.app.requests, [("events.subscribe", {}), ("object.get", {"id": "obj_q1"})])
        self.assertEqual(json.loads(result.stdout)["label"], "Later")
        self.app.replies["object.get"] = {"object": question("cancelled")}
        result = self.run_cli("wait", "obj_q1", "--board", "brd_x")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (2, "", "cancelled: question obj_q1 was cancelled\n"))
        self.assertEqual(self.app.requests[-2], ("events.subscribe", {"board": "brd_x"}))

    def test_ask_wait_on_an_open_question_waits_for_its_event(self) -> None:
        self.app.replies["object.get"] = {"object": question()}
        self.app.pushes["object.get"] = [event("object.updated", question("expired"))]
        result = self.run_cli("wait", "obj_q1")
        self.assertEqual((result.returncode, result.stderr), (2, "expired: question obj_q1 expired\n"))
        self.app.pushes["object.get"] = []
        self.app.hang_up_after.add("object.get")
        result = self.run_cli("wait", "obj_q1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("`easl ask wait obj_q1` resumes", result.stderr)

    def test_ask_wait_refuses_an_object_that_is_not_a_question(self) -> None:
        self.app.replies["object.get"] = {"object": {"id": "obj_n1", "type": "note", "props": {}}}
        result = self.run_cli("wait", "obj_n1")
        self.assertEqual((result.returncode, result.stderr), (1, "invalid_params: obj_n1 is a note, not a question\n"))

    def test_ask_wait_on_a_deleted_question_is_the_deleted_outcome(self) -> None:
        # Deleted before `ask wait` ran, and deleted between its subscription and its read (the event is queued unread).
        self.app.replies["object.get"] = ("error", {"code": "not_found", "message": "no object obj_q1"})
        for pushed in ([], [event("object.deleted", {"id": "obj_q1"})]):
            with self.subTest(queued=bool(pushed)):
                self.app.pushes["events.subscribe"] = pushed
                result = self.run_cli("wait", "obj_q1")
                self.assertEqual((result.returncode, result.stdout, result.stderr), (2, "", "deleted: question obj_q1 was deleted\n"))
        # Any other failure of the read is still an error.
        self.app.replies["object.get"] = ("error", {"code": "unavailable", "message": "the app is quitting"})
        result = self.run_cli("wait", "obj_q1")
        self.assertEqual((result.returncode, result.stderr), (1, "unavailable: the app is quitting\n"))


if __name__ == "__main__":
    unittest.main()
