"""easl Python SDK.

Recommended surface for agents with a persistent REPL:

    from easl_sdk import canvas
    board = canvas.board.get()
    canvas.object.create(type="note", props={"markdown": "# Hypothesis"})

The connection comes from EASL_SOCKET / EASL_TILE_ID / EASL_BOARD_ID, which every
easl terminal tile sets. A process that did not inherit them (e.g. a REPL kernel started
with a filtered environment) connects explicitly; `canvas` then uses that connection:

    from easl_sdk import connect
    canvas = connect(socket="/…/easl.sock", tile="obj_…", board="brd_…")

Every method mirrors schema/easl-api.json. `caller` and `board` are filled from the
client's tile and board. Params that are Python keywords take a trailing underscore:
`canvas.object.get(id="obj_…", as_="graph")`. Image methods take `out=` (relative paths
resolve against this process's cwd; the app writes the file); without it the app writes a new
file under $TMPDIR/easl-renders/. Either way the result's `path` names it.

After an app restart the next call reconnects on its own. Connection failures raise
`CanvasError` with code `unavailable`; when the request was already sent, the message says
it may have applied, so re-read before retrying. `agent.wait` is a read: when the app
restarts mid-wait the client asks again once it is back, keeping the remaining `timeout_ms`.

Reusable helpers live in compositions directories and load on first use:

    canvas.compositions.grid.arrange(["obj_…", "obj_…"])
    canvas.compositions.available()   # name -> summary
"""

from __future__ import annotations

import errno
import json
import os
import select
import socket
import sys
import threading
import time
from collections.abc import Mapping
from typing import Any

from ._generated import ENV_DEFAULTS, METHODS, RESEND_METHODS, SCHEMA_VERSION, GeneratedApi
from .compositions import Compositions


def default_socket(platform: str = sys.platform, env: Mapping[str, str] = os.environ, home: str | None = None) -> str:
    """Where the easl server listens when EASL_SOCKET is unset. On macOS, the app's support
    directory. Elsewhere, easld's home as `defaultHome` resolves it (easld/cmd/easld/main.go):
    $EASL_HOME, else $XDG_STATE_HOME/easl, else ~/.local/state/easl. The TS client agrees."""
    home = home if home is not None else os.path.expanduser("~")
    if platform == "darwin":
        return os.path.join(home, "Library/Application Support/Easl/easl.sock")
    if env.get("EASL_HOME"):
        return os.path.join(env["EASL_HOME"], "easl.sock")
    return os.path.join(env.get("XDG_STATE_HOME") or os.path.join(home, ".local/state"), "easl/easl.sock")


DEFAULT_SOCKET = default_socket()
# The app takes 5-10 s to restart; a request that never left waits this long for it.
RECONNECT_TIMEOUT = 15.0

__all__ = ["Easl", "CanvasError", "Compositions", "canvas", "connect", "METHODS", "SCHEMA_VERSION", "DEFAULT_SOCKET", "default_socket"]


class CanvasError(Exception):
    def __init__(self, code: str, message: str, data: Any = None) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.data = data


def _resolve_socket(explicit: str | os.PathLike[str] | None) -> str:
    if explicit:
        return os.fspath(explicit)
    if os.environ.get("EASL_SOCKET"):
        return os.environ["EASL_SOCKET"]
    if os.path.exists(DEFAULT_SOCKET):
        return DEFAULT_SOCKET
    raise CanvasError(
        "unavailable",
        f"EASL_SOCKET is unset and the default socket {DEFAULT_SOCKET} does not exist, so this process "
        "has no easl connection (it did not inherit the terminal tile's environment). In the easl "
        "terminal run `echo $EASL_SOCKET $EASL_TILE_ID $EASL_BOARD_ID`, then connect with those "
        "values: `canvas = easl_sdk.connect(socket=..., tile=..., board=...)`.",
    )


class _NotSent(Exception):
    """The request never reached the app, so it is safe to send again."""


class _ReplyLost(Exception):
    """The request left but the connection closed before its reply: it may have applied."""


def _sandboxed(path: str, error: OSError) -> bool:
    """A socket this process may not connect to, or can't see although it is there: a sandbox
    (Codex's seatbelt answers ENOENT), not a missing app. Waiting for the app wouldn't help."""
    return error.errno in (errno.EPERM, errno.EACCES) or (error.errno == errno.ENOENT and os.path.exists(path))


def _sandbox_message(path: str, error: OSError) -> str:
    return (
        f"easl socket {path} exists but connecting to it failed ({errno.errorcode.get(error.errno or 0, error)}): "
        "a sandbox (e.g. Codex's) may be blocking Unix-socket connections; run this outside the sandbox or allow it"
    )


class Easl(GeneratedApi):
    """One persistent, thread-safe connection to the easl API socket.

    `socket_path`, `tile`, `board`: explicit values win, then EASL_SOCKET / EASL_TILE_ID /
    EASL_BOARD_ID, then (socket only) the default path if it exists; otherwise CanvasError.
    `timeout`: per-call seconds (default none; agent.wait may block for minutes).
    `reconnect_timeout`: how long a call whose request was not sent waits for the socket to come back.
    """

    def __init__(
        self,
        socket_path: str | os.PathLike[str] | None = None,
        *,
        tile: str | None = None,
        board: str | None = None,
        timeout: float | None = None,
        reconnect_timeout: float = RECONNECT_TIMEOUT,
        compositions_dirs: list[str | os.PathLike[str]] | None = None,
    ) -> None:
        self.socket_path = _resolve_socket(socket_path)
        self.tile_id = tile or os.environ.get(ENV_DEFAULTS["caller"]) or None
        self.board_id = board or os.environ.get(ENV_DEFAULTS["board"]) or None
        self.timeout = timeout
        self.reconnect_timeout = reconnect_timeout
        self._sock: socket.socket | None = None
        self._reader: Any = None
        self._lock = threading.Lock()
        self._next_id = 0
        super().__init__(self.call)
        self.compositions = Compositions(self, compositions_dirs)

    def call(self, method: str, params: dict[str, Any], env_keys: list[str] | tuple[str, ...] = ()) -> Any:
        """Send one request. `env_keys` (e.g. ["caller", "board"]) are filled from this client when omitted.

        A RESEND_METHODS read (agent.wait) whose reply the connection lost is sent again once the
        app is back, with `timeoutMs` reduced by the time already spent."""
        params = {k: v for k, v in params.items() if v is not None}
        defaults = {"caller": self.tile_id, "board": self.board_id}
        for key in env_keys:
            if key not in params and defaults.get(key):
                params[key] = defaults[key]
        if isinstance(params.get("out"), (str, os.PathLike)):
            params["out"] = os.path.abspath(os.path.expanduser(os.fspath(params["out"])))
        resend = method in RESEND_METHODS
        started = time.monotonic()
        budget = params.get("timeoutMs") if resend and isinstance(params.get("timeoutMs"), (int, float)) else None
        while True:
            if budget is not None:
                params["timeoutMs"] = max(0, round(budget - (time.monotonic() - started) * 1000))
            try:
                message = self._deliver(method, params)
                break
            except _ReplyLost as lost:
                if not resend:
                    raise CanvasError("unavailable", str(lost)) from None
            # A read: the app restarted mid-call. Wait for it, then ask again with the time left.
            with self._lock:
                try:
                    if self._sock is None:
                        self._open(self.reconnect_timeout)
                except _NotSent as error:
                    raise CanvasError("unavailable", f"{error} ({method} was cut off and could not be re-sent)") from None
        if message.get("ok"):
            return message.get("result")
        error = message.get("error") or {}
        raise CanvasError(error.get("code", "internal"), error.get("message", "unknown error"), error.get("data"))

    def _deliver(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        """One request and its reply; one that was not sent is sent once more, waiting up to `reconnect_timeout` for the socket."""
        with self._lock:
            self._next_id += 1
            request_id = str(self._next_id)
            line = (json.dumps({"id": request_id, "method": method, "params": params}) + "\n").encode()
            try:
                self._send(line, wait=0)
            except _NotSent:
                # Stale connection or the app is restarting: nothing was delivered, so send once more.
                try:
                    self._send(line, wait=self.reconnect_timeout)
                except _NotSent as error:
                    raise CanvasError("unavailable", f"{error} ({method} was not sent)") from None
            return self._receive(request_id, method)

    def close(self) -> None:
        if self._sock is not None:
            self._sock.close()
        self._sock = None
        self._reader = None

    def _send(self, line: bytes, wait: float) -> None:
        if self._sock is not None and not self._alive(self._sock):
            self.close()
        if self._sock is None:
            self._open(wait)
        assert self._sock is not None
        try:
            self._sock.sendall(line)
        except OSError as error:
            # A partial line is discarded by the app (requests are newline-framed).
            self.close()
            raise _NotSent(f"easl socket {self.socket_path}: {error}") from error

    def _receive(self, request_id: str, method: str) -> dict[str, Any]:
        try:
            while True:
                line = self._reader.readline()
                if not line:
                    raise ConnectionError("closed by the app")
                message = json.loads(line)
                if message.get("id") == request_id:
                    return message
        except TimeoutError:
            self.close()
            raise CanvasError("timeout", f"{method} timed out after {self.timeout}s") from None
        except OSError as error:
            self.close()
            raise _ReplyLost(
                f"easl connection lost after sending {method} ({error}); it may or may not have applied — re-read before retrying",
            ) from None

    def _open(self, wait: float) -> None:
        deadline = time.monotonic() + wait
        missed_there = False
        while True:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            try:
                sock.connect(self.socket_path)
            except OSError as error:
                sock.close()
                if _sandboxed(self.socket_path, error):
                    # ENOENT with the file there is also an app binding its socket just after this
                    # connect missed it (a restart): only a second one in a row is a sandbox.
                    if error.errno == errno.ENOENT and not missed_there:
                        missed_there = True
                        continue
                    raise _NotSent(_sandbox_message(self.socket_path, error)) from None
                missed_there = False
                if time.monotonic() >= deadline:
                    waited = f" after waiting {wait:g}s for the app" if wait else ""
                    raise _NotSent(f"easl socket {self.socket_path}: {error.strerror or error}{waited}") from None
                time.sleep(0.2)
                continue
            self._sock = sock
            self._reader = sock.makefile("r", encoding="utf-8")
            return

    @staticmethod
    def _alive(sock: socket.socket) -> bool:
        """False when the app closed this connection (e.g. it restarted) since the last call."""
        try:
            readable, _, _ = select.select([sock], [], [], 0)
            return not readable or sock.recv(1, socket.MSG_PEEK) != b""
        except (OSError, ValueError):
            return False


class _LazyCanvas:
    """Module-level `canvas`: the last `connect()` result, else a client that connects on first use."""

    _instance: Easl | None = None

    def __getattr__(self, name: str) -> Any:
        if _LazyCanvas._instance is None:
            _LazyCanvas._instance = Easl()
        return getattr(_LazyCanvas._instance, name)


def connect(socket: str | os.PathLike[str] | None = None, tile: str | None = None, board: str | None = None) -> Easl:
    """Connect with explicit values (each falls back to EASL_SOCKET / EASL_TILE_ID / EASL_BOARD_ID).
    The module-level `canvas` uses this client from now on."""
    client = Easl(socket, tile=tile, board=board)
    previous, _LazyCanvas._instance = _LazyCanvas._instance, client
    if previous is not None:
        previous.close()
    return client


canvas: Easl = _LazyCanvas()  # type: ignore[assignment]
