#!/usr/bin/env python3
"""Fixture-only SSH byte observer for the macOS guest.

EASL_DEV_SSH points here. ECHO_SSH_CONFIG and ECHO_TRACE_FILE are required.
ECHO_COMPRESSION=yes|no overrides terminal compression before existing options.
ECHO_TRACE_PAYLOAD=1 opts into fixture byte hex; otherwise no payload is logged.

Rows are JSONL with a single guest mach_absolute_time clock. Byte ranges are
zero-based, half-open cumulative offsets, separately for input and output.
ssh.input is timestamped after the write returns, and its byte count describes
accepted bytes, including short writes. The entry timestamp is retained as
write_begin_ms. viewer.received is timestamped immediately after read, before
logging or forwarding. Marker rows retain the containing read timestamp.

For tty input, the slave inherits the original modes for SSH's remote tty-mode
negotiation. The outer tty becomes raw and forwarding waits for SSH to make its
slave raw/no-echo. Output uses a pipe, not the PTY, so no extra OPOST or ONLCR
translation occurs. stderr stays separate. For pipe input, the slave starts raw;
this intentionally makes -t allocate where unwrapped SSH would refuse. Such a
smoke run is not evidence for original tty-mode negotiation. The remote fixture
must set its own raw/no-echo modes for that case.

Observer costs include Python scheduling, copies, JSON, append syscalls, extra
PTY/pipe hops, and marker parsing. observer.trace brackets the primary trace
append only; its own append and forwarding are not included in that bracket.
No fsync is performed. No timing correction is assumed by this program.

Parent validation: compare modes and winsize at remote startup, verify one input
'a' produces one marker with no local echo or CRLF changes, verify split markers
and burst offsets, then compare instrumented/uninstrumented native frames.
Inspect effective compression separately, never inside a timed invocation:
/usr/bin/ssh -G -F "$ECHO_SSH_CONFIG" -o Compression=yes <original ssh args> |
  python3 -c 'import sys; keys={"compression","controlmaster","requesttty"}; print("".join(s for s in sys.stdin if s.split() and s.split()[0] in keys),end="")'
Use Compression=no for the other arm. Only the selected config keys are printed.
"""

import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import termios
import time
import tty


class MachClock:
    def __init__(self):
        if sys.platform != "darwin":
            raise RuntimeError("terminal traces require the guest's mach_absolute_time clock")
        self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.lib.mach_absolute_time.restype = ctypes.c_uint64

        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

        base = Timebase()
        if self.lib.mach_timebase_info(ctypes.byref(base)) != 0 or base.denom == 0:
            raise RuntimeError("mach_timebase_info failed")
        self.scale = base.numer / base.denom / 1_000_000

    def now(self):
        return self.lib.mach_absolute_time() * self.scale


class Trace:
    def __init__(self, path, clock, payload, options, debug):
        self.fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.clock = clock
        self.payload = payload
        self.pid = None
        self.options = options
        self.debug = debug
        self.transport_recorded = False

    def append(self, row):
        data = (json.dumps(row, separators=(",", ":")) + "\n").encode("ascii")
        # A single append syscall keeps rows from separate wrappers indivisible.
        if os.write(self.fd, data) != len(data):
            raise RuntimeError("short append to trace file")

    def emit(self, stage, ts_ms=None, **fields):
        start = self.clock.now()
        row = {"stage": stage, "ts_ms": start if ts_ms is None else ts_ms,
               "pid": os.getpid(), "child_pid": self.pid, **fields}
        row["trace_begin_ms"] = start
        self.append(row)
        end = self.clock.now()
        self.append({"stage": "observer.trace", "ts_ms": end,
                     "pid": os.getpid(), "child_pid": self.pid,
                     "observed_stage": stage, "begin_ms": start,
                     "end_ms": end})

    def byte_fields(self, data, offset):
        result = {"bytes": len(data), "offset_start": offset,
                  "offset_end": offset + len(data)}
        if self.payload:
            result["hex"] = data.hex()
        return result

    def transport(self):
        if self.transport_recorded:
            return
        pairs = re.findall(rb"kex:\s+(server->client|client->server).*?compression:\s+(\S+)", self.debug.read_bytes())
        negotiated = {direction.decode("ascii"): algorithm.decode("ascii") for direction, algorithm in pairs}
        self.emit("ssh.transport", options=self.options, negotiated_compression=negotiated, debug_file=str(self.debug))
        self.transport_recorded = True


class Markers:
    pattern = re.compile(rb"\x1b\]777;easl-echo;([0-9]{1,6})\x07")

    def __init__(self):
        self.tail = b""

    def receive(self, data, start, ts_ms, trace):
        joined = self.tail + data
        base = start - len(self.tail)
        for match in self.pattern.finditer(joined):
            if base + match.end() > start:
                trace.emit("viewer.received.marker", ts_ms=ts_ms,
                           seq=int(match.group(1)),
                           offset_start=base + match.start(),
                           offset_end=base + match.end(), bytes=len(match.group()))
        self.tail = joined[-32:]


def requests_terminal(args):
    # Stop at the destination. Remote command arguments must not affect routing.
    takes_value = set("BbcDEeFIiJLlmOopQRSWw")
    terminal = False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--" or not arg.startswith("-") or arg == "-":
            break
        for position, option in enumerate(arg[1:], 1):
            if option == "t":
                terminal = True
            elif option == "T":
                terminal = False
            if option in takes_value:
                if position == len(arg) - 1:
                    index += 1
                break
        index += 1
    return terminal


def relay(argv, trace):
    master, slave = os.openpty()
    original = termios.tcgetattr(0) if os.isatty(0) else None
    if original is not None:
        termios.tcsetattr(slave, termios.TCSANOW, original)
    else:
        tty.setraw(slave, termios.TCSANOW)

    def resize():
        for fd in (0, 1, 2):
            if os.isatty(fd):
                size = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
                fcntl.ioctl(master, termios.TIOCSWINSZ, size)
                return

    resize()

    def child_setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    child = None
    old_handlers = {}
    pending_signal = []
    pending_resize = []
    stdout_blocking = os.get_blocking(1)
    input_offset = output_offset = 0
    input_data = bytearray()
    output_data = bytearray()
    markers = Markers()
    input_eof = output_eof = False
    stdin_close_sent = False
    deadline = None
    escalated = False
    ready = original is None
    exit_seen = None

    def request_stop(signum, _frame):
        pending_signal.append(signum)

    def request_resize(_signum, _frame):
        pending_resize.append(True)

    def stop(signum):
        if child.poll() is None:
            try:
                os.kill(child.pid, signum)
            except ProcessLookupError:
                pass

    try:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
            old_handlers[sig] = signal.signal(sig, request_stop)
        old_handlers[signal.SIGWINCH] = signal.signal(signal.SIGWINCH, request_resize)
        child = subprocess.Popen(argv, stdin=slave, stdout=subprocess.PIPE,
                                 stderr=None, close_fds=True, preexec_fn=child_setup)
        trace.pid = child.pid
        os.close(slave)
        slave = -1
        os.set_blocking(master, False)
        os.set_blocking(child.stdout.fileno(), False)
        os.set_blocking(1, False)
        if original is not None:
            tty.setraw(0, termios.TCSANOW)
        trace.emit("ssh.observer.started", original_stdin_tty=original is not None,
                   payload_enabled=trace.payload, compression=os.environ.get("ECHO_COMPRESSION"))
        while True:
            now = time.monotonic()
            if pending_resize:
                pending_resize.clear()
                resize()
            if pending_signal:
                signum = pending_signal.pop(0)
                stop(signum)
                deadline = now + 2.0 if deadline is None else deadline
                input_eof = True
                trace.emit("ssh.observer.signal", signal=signum)
            status = child.poll()
            if status is not None and exit_seen is None:
                exit_seen = now
                input_eof = True
                trace.emit("ssh.observer.exit", returncode=status)
            if status is not None and output_eof and not output_data:
                break
            if exit_seen is not None and now - exit_seen >= 2.0:
                trace.emit("ssh.observer.drain_timeout", bytes=len(output_data))
                break
            if deadline is not None and now >= deadline:
                if not escalated:
                    stop(signal.SIGTERM)
                    escalated = True
                    deadline = now + 1.0
                else:
                    stop(signal.SIGKILL)
                    child.wait(timeout=1.0)
                    deadline = None
            if not ready and status is None:
                modes = termios.tcgetattr(master)
                ready = not (modes[3] & (termios.ICANON | termios.ECHO))
            readers = []
            writers = []
            if not input_eof and len(input_data) < 65536:
                readers.append(0)
            if not output_eof and len(output_data) < 65536:
                readers.append(child.stdout.fileno())
            if ready and input_data and status is None:
                writers.append(master)
            if output_data:
                writers.append(1)
            readable, writable, _ = select.select(readers, writers, [], 0.02 if not ready else 0.1)
            if child.stdout.fileno() in readable:
                begin = trace.clock.now()
                data = os.read(child.stdout.fileno(), 4096)
                received = trace.clock.now()
                if data:
                    trace.transport()
                    trace.emit("viewer.received", ts_ms=received, read_begin_ms=begin,
                               read_end_ms=received, **trace.byte_fields(data, output_offset))
                    markers.receive(data, output_offset, received, trace)
                    output_offset += len(data)
                    output_data.extend(data)
                else:
                    output_eof = True
            if 0 in readable:
                data = os.read(0, 4096)
                if data:
                    input_data.extend(data)
                else:
                    input_eof = True
                    if deadline is None:
                        deadline = time.monotonic() + 2.0
            if master in writable:
                chunk = bytes(input_data[:4096])
                begin = trace.clock.now()
                try:
                    count = os.write(master, chunk)
                except BlockingIOError:
                    count = 0
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    count = 0
                    input_eof = True
                    input_data.clear()
                end = trace.clock.now()
                if count:
                    trace.emit("ssh.input", ts_ms=end, write_begin_ms=begin,
                               write_end_ms=end, **trace.byte_fields(chunk[:count], input_offset))
                    input_offset += count
                    del input_data[:count]
            if 1 in writable:
                try:
                    count = os.write(1, output_data)
                except BlockingIOError:
                    count = 0
                del output_data[:count]
            if input_eof and not input_data and not stdin_close_sent and status is None:
                stop(signal.SIGHUP)
                stdin_close_sent = True
                if deadline is None:
                    deadline = time.monotonic() + 2.0
                trace.emit("ssh.observer.stdin_closed")
        return child.returncode if child.returncode >= 0 else 128 - child.returncode
    finally:
        try:
            if child is not None:
                if child.poll() is None:
                    stop(signal.SIGTERM)
                    try:
                        child.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        stop(signal.SIGKILL)
                        child.wait(timeout=1.0)
        finally:
            if child is not None:
                child.stdout.close()
            if slave >= 0:
                os.close(slave)
            os.close(master)
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
            try:
                if original is not None:
                    termios.tcsetattr(0, termios.TCSANOW, original)
            finally:
                os.set_blocking(1, stdout_blocking)


def main():
    config = os.environ["ECHO_SSH_CONFIG"]
    args = sys.argv[1:]
    argv = ["/usr/bin/ssh", "-F", config]
    if not requests_terminal(args):
        os.execv(argv[0], argv + args)
    compression = os.environ.get("ECHO_COMPRESSION")
    if compression is not None:
        if compression not in ("yes", "no"):
            raise ValueError("ECHO_COMPRESSION must be yes or no")
        argv += ["-o", "Compression=" + compression]
    effective = subprocess.check_output([argv[0], "-G"] + argv[1:] + args, text=True)
    options = [line for line in effective.splitlines() if line.split() and line.split()[0] in
               ("compression", "controlmaster", "controlpath", "ipqos", "obscurekeystroketiming", "requesttty")]
    debug = Path(os.environ["ECHO_TRACE_FILE"]).parent / ("ssh-transport-%d.log" % os.getpid())
    fd = os.open(debug, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    os.close(fd)
    trace = Trace(os.environ["ECHO_TRACE_FILE"], MachClock(),
                  os.environ.get("ECHO_TRACE_PAYLOAD") == "1", options, debug)
    try:
        return relay(argv + ["-v", "-E", str(debug)] + args, trace)
    finally:
        trace.transport()
        os.close(trace.fd)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, KeyError) as exc:
        print("ssh-echo-observed: " + str(exc), file=sys.stderr)
        sys.exit(125)
