"""Connection config, reconnect, and error mapping against a real Unix-socket server.
Run from clients/python: python3 -m unittest"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import easl_sdk  # noqa: E402
from easl_sdk import Easl, CanvasError, connect  # noqa: E402

EASL_ENV = ("EASL_SOCKET", "EASL_TILE_ID", "EASL_BOARD_ID")


class FakeApp:
    """Stands in for the app: answers each request with its method and params, and records them."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.requests: list[tuple[str, dict]] = []
        self.drop_next_request = False
        # (method, seconds): the first such request restarts the app (socket gone that long) unanswered.
        self.restart_on: tuple[str, float] | None = None
        # method → replies, each `{"result": ...}` or `{"error": {...}}`, taken in order; once a method's
        # run out (or for any other method) the request's method and params are the result.
        self.replies: dict[str, list[dict]] = {}
        self._conns: list[socket.socket] = []
        self._listener: socket.socket | None = None
        self.listen()

    def listen(self) -> None:
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.path)
        listener.listen()
        listener.settimeout(0.05)
        self._listener = listener
        threading.Thread(target=self._accept, args=(listener,), daemon=True).start()

    def stop(self) -> None:
        """Like the app quitting: every connection closes and the socket file goes away."""
        listener, self._listener = self._listener, None
        if listener is not None:
            listener.close()
        for conn in self._conns:
            self._hang_up(conn)
        self._conns.clear()
        if os.path.exists(self.path):
            os.unlink(self.path)

    def restart(self, after: float) -> None:
        self.stop()
        threading.Timer(after, self.listen).start()

    def close_connections(self, stray_line: bytes = b"") -> None:
        """Close the client connections while still listening, optionally after an unsolicited line."""
        for conn in self._conns:
            if stray_line:
                conn.sendall(stray_line)
            self._hang_up(conn)
        self._conns.clear()
        time.sleep(0.05)

    @staticmethod
    def _hang_up(conn: socket.socket) -> None:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()

    def _accept(self, listener: socket.socket) -> None:
        while self._listener is listener:
            try:
                conn, _ = listener.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            conn.settimeout(None)
            self._conns.append(conn)
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        with conn.makefile("r", encoding="utf-8") as reader:
            try:
                for line in reader:
                    request = json.loads(line)
                    self.requests.append((request["method"], request["params"]))
                    if self.drop_next_request:
                        self.drop_next_request = False
                        self._hang_up(conn)
                        return
                    if self.restart_on is not None and self.restart_on[0] == request["method"]:
                        after, self.restart_on = self.restart_on[1], None
                        self.restart(after)
                        return
                    scripted = self.replies.get(request["method"])
                    answer = scripted.pop(0) if scripted else {"result": {"method": request["method"], "params": request["params"]}}
                    reply = {"id": request["id"], "ok": "error" not in answer, **answer}
                    conn.sendall((json.dumps(reply) + "\n").encode())
            except (OSError, ValueError):
                return


class ConnectionTest(unittest.TestCase):
    def setUp(self) -> None:
        # /tmp keeps the socket path under the 104-byte limit.
        temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.path = str(self.dir / "easl.sock")
        env = mock.patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        for key in EASL_ENV:
            os.environ.pop(key, None)
        default = mock.patch.object(easl_sdk, "DEFAULT_SOCKET", str(self.dir / "default.sock"))
        default.start()
        self.addCleanup(default.stop)
        lazy = mock.patch.object(easl_sdk._LazyCanvas, "_instance", None)
        lazy.start()
        self.addCleanup(lazy.stop)

    def serve(self) -> FakeApp:
        app = FakeApp(self.path)
        self.addCleanup(app.stop)
        return app

    def client(self, **options) -> Easl:
        client = Easl(self.path, **options)
        self.addCleanup(client.close)
        return client

    def test_no_socket_configured_fails_loudly_with_the_fix(self) -> None:
        for attempt in (Easl, connect, lambda: easl_sdk.canvas.board):
            with self.subTest(attempt=attempt), self.assertRaises(CanvasError) as raised:
                attempt()
            self.assertEqual(raised.exception.code, "unavailable")
            message = str(raised.exception)
            self.assertIn("EASL_SOCKET is unset", message)
            self.assertIn(easl_sdk.DEFAULT_SOCKET, message)
            self.assertIn("echo $EASL_SOCKET $EASL_TILE_ID $EASL_BOARD_ID", message)
            self.assertIn("connect(socket=..., tile=..., board=...)", message)

    def test_env_socket_is_used_when_no_explicit_path(self) -> None:
        app = self.serve()
        os.environ["EASL_SOCKET"] = self.path
        client = Easl()
        self.addCleanup(client.close)
        self.assertEqual(client.system.ping()["method"], "system.ping")
        self.assertEqual(len(app.requests), 1)

    def test_next_call_reconnects_after_an_app_restart(self) -> None:
        app = self.serve()
        client = self.client()
        client.board.get()
        app.restart(after=0.5)
        started = time.monotonic()
        result = client.board.get()
        self.assertEqual(result["method"], "board.get")
        self.assertGreaterEqual(time.monotonic() - started, 0.4)  # it waited for the socket to come back
        self.assertEqual([method for method, _ in app.requests], ["board.get", "board.get"])

    def test_socket_that_stays_down_is_unavailable_after_the_reconnect_window(self) -> None:
        app = self.serve()
        client = self.client(reconnect_timeout=0.3)
        client.board.get()
        app.stop()
        with self.assertRaises(CanvasError) as raised:
            client.board.get()
        self.assertEqual(raised.exception.code, "unavailable")
        self.assertIn("board.get was not sent", str(raised.exception))

    def test_an_app_binding_its_socket_just_after_a_connect_missed_it_is_not_a_sandbox(self) -> None:
        # The restart race: a connect while waiting for the app finds no socket (ENOENT), and the
        # app binds it before the client looks whether the file is there.
        app = self.serve()
        client = self.client()
        client.board.get()
        app.stop()
        connect = socket.socket.connect
        missed: list[str] = []

        def missing_then_bound(sock: socket.socket, address: str) -> None:
            try:
                connect(sock, address)
            except FileNotFoundError:
                missed.append(address)
                if len(missed) == 2:  # the first connect of the waiting reconnect
                    app.listen()
                raise

        with mock.patch.object(socket.socket, "connect", missing_then_bound):
            self.assertEqual(client.board.get()["method"], "board.get")
        self.assertEqual(len(missed), 2)
        self.assertEqual([method for method, _ in app.requests], ["board.get", "board.get"])

    def test_a_socket_that_is_there_but_refuses_this_process_names_a_sandbox_at_once(self) -> None:
        # What a sandbox does to the connect: the socket exists, this process may not use it.
        self.serve()
        os.chmod(self.path, 0)
        client = self.client()
        started = time.monotonic()
        with self.assertRaises(CanvasError) as raised:
            client.board.get()
        self.assertLess(time.monotonic() - started, 5, "no waiting for an app that is already there")
        self.assertEqual(raised.exception.code, "unavailable")
        self.assertIn(f"easl socket {self.path} exists", str(raised.exception))
        self.assertIn("a sandbox (e.g. Codex's) may be blocking", str(raised.exception))

    def test_a_socket_that_is_there_but_unseen_twice_names_a_sandbox_at_once(self) -> None:
        # Codex's seatbelt: the socket file is there, but every connect answers ENOENT.
        self.serve()
        client = self.client()

        def unseen(sock: socket.socket, address: str) -> None:
            raise FileNotFoundError(2, "No such file or directory")

        started = time.monotonic()
        with mock.patch.object(socket.socket, "connect", unseen), self.assertRaises(CanvasError) as raised:
            client.board.get()
        self.assertLess(time.monotonic() - started, 5, "no waiting for an app that is already there")
        self.assertIn(f"easl socket {self.path} exists but connecting to it failed (ENOENT)", str(raised.exception))

    def test_connection_lost_after_sending_is_not_resent(self) -> None:
        app = self.serve()
        client = self.client()
        app.drop_next_request = True
        with self.assertRaises(CanvasError) as raised:
            client.object.create(type="note", props={"markdown": "x"})
        self.assertEqual(raised.exception.code, "unavailable")
        self.assertIn("after sending object.create", str(raised.exception))
        self.assertIn("may or may not have applied", str(raised.exception))
        self.assertEqual([method for method, _ in app.requests], ["object.create"])
        # The client is not wedged: the next call opens a new connection.
        self.assertEqual(client.board.get()["method"], "board.get")

    def test_a_wait_the_app_restart_cut_off_is_asked_again_with_the_time_left(self) -> None:
        app = self.serve()
        client = self.client()
        app.restart_on = ("agent.wait", 0.5)
        started = time.monotonic()
        result = client.agent.wait(target="reviewer", timeout_ms=60000)
        self.assertEqual(result["method"], "agent.wait")
        self.assertGreaterEqual(time.monotonic() - started, 0.4)  # it waited for the app to come back
        (first, sent), (second, resent) = app.requests
        self.assertEqual((first, second), ("agent.wait", "agent.wait"))
        self.assertEqual(sent["timeoutMs"], 60000)
        self.assertLessEqual(resent["timeoutMs"], 60000 - 400)
        self.assertGreater(resent["timeoutMs"], 50000)

    def test_broken_pipe_on_send_retries_on_a_fresh_connection(self) -> None:
        app = self.serve()
        client = self.client()
        client.board.get()
        # Unread data keeps the dead connection looking open, so the next send hits EPIPE.
        app.close_connections(stray_line=b'{"id":"stray"}\n')
        result = client.object.delete(id="obj_1")
        self.assertEqual(result["method"], "object.delete")
        self.assertEqual([method for method, _ in app.requests], ["board.get", "object.delete"])

    def test_caller_and_board_come_from_connect_not_the_environment(self) -> None:
        app = self.serve()
        canvas = connect(socket=self.path, tile="obj_tile", board="brd_board")
        self.addCleanup(canvas.close)
        # `canvas` (module level) now targets this client; the environment has no EASL_* at all.
        easl_sdk.canvas.object.create(type="note", props={})
        easl_sdk.canvas.board.get(board="brd_explicit")
        easl_sdk.canvas.object.get(id="obj_1", as_="graph")
        create, get, obj = (params for _, params in app.requests)
        self.assertEqual((create["caller"], create["board"]), ("obj_tile", "brd_board"))
        self.assertEqual(get["board"], "brd_explicit")
        self.assertEqual(obj, {"id": "obj_1", "as": "graph"})

    def test_relative_out_resolves_against_the_cwd(self) -> None:
        app = self.serve()
        client = self.client()
        client.view.render(target="obj_1", out="shots/a.png")
        self.assertEqual(app.requests[0][1]["out"], os.path.join(os.getcwd(), "shots/a.png"))

    def test_a_camel_case_keyword_names_the_snake_case_parameter_and_sends_nothing(self) -> None:
        app = self.serve()
        client = self.client()
        with self.assertRaisesRegex(TypeError, r"'timeoutMs'; the Python SDK spells it 'timeout_ms'"):
            client.view.render(target="obj_1", timeoutMs=8000)
        with self.assertRaisesRegex(TypeError, r"'colGap'; the Python SDK spells it 'col_gap'"):
            client.layout.grid(cells=[], colGap=10)
        client.view.render(target="obj_1", timeout_ms=8000)
        self.assertEqual([(method, params["timeoutMs"]) for method, params in app.requests], [("view.render", 8000)])


if __name__ == "__main__":
    unittest.main()
