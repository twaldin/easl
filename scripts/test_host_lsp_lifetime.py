import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


def host_launcher():
    source = (ROOT / "Sources/CanvasCore/LanguageService/HostLanguageSource.swift").read_text()
    literal = re.search(r'    static let launcher = #"""\n(.*?)\n    """#', source, re.S)
    if literal is None:
        raise AssertionError("HostLanguageSource.launcher must be a shell program")
    return textwrap.dedent(literal.group(1))


def wait_until(condition, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.02)
    return condition()


def process_exists(pid):
    result = subprocess.run(["ps", "-o", "pid=", "-p", str(pid)], capture_output=True)
    return result.returncode == 0 and bool(result.stdout.strip())


def read_header(stream):
    data = b""
    with selectors.DefaultSelector() as selector:
        selector.register(stream, selectors.EVENT_READ)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(stream.fileno(), 4096)
            if not chunk:
                break
            data += chunk
            if b"\r\n\r\n" in data:
                head, body = data.split(b"\r\n\r\n", 1)
                length = int(head.removeprefix(b"Content-Length: "))
                if len(body) == length:
                    return json.loads(body)
    raise AssertionError(f"No complete host PID frame arrived: {data!r}")


class HostLSPLifetimeTests(unittest.TestCase):
    def test_link_death_before_pid_delivery_ends_the_host_server(self):
        with tempfile.TemporaryDirectory(prefix="host-lsp-") as directory:
            directory = Path(directory)
            record = directory / "server.json"
            server = directory / "server"
            server.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import json, os, signal, sys
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                with open(sys.argv[1] + ".writing", "w") as out:
                    json.dump({"pid": os.getpid(), "cwd": os.getcwd(), "args": sys.argv[2:], "path": os.environ["PATH"]}, out)
                os.replace(sys.argv[1] + ".writing", sys.argv[1])
                while True:
                    signal.pause()
                '''))
            server.chmod(0o755)
            reader, writer = os.pipe()
            link = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                    stdin=subprocess.DEVNULL, stdout=writer, start_new_session=True)
            os.close(writer)
            host = subprocess.Popen(["/bin/sh", "-c", host_launcher(), "easl", str(server), str(directory),
                                     "/usr/bin:/bin", str(record), "an argument with spaces"],
                                    stdin=reader, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            os.close(reader)
            pid = None
            try:
                self.assertTrue(wait_until(record.exists), "the owned host server never started")
                metadata = json.loads(record.read_text())
                pid = metadata["pid"]
                self.assertEqual(metadata["cwd"], str(directory.resolve()))
                self.assertEqual(metadata["args"], ["an argument with spaces"])
                self.assertEqual(metadata["path"], "/usr/bin:/bin")
                self.assertTrue(process_exists(pid), "the server must exist before the link dies")
                header = read_header(host.stdout)
                self.assertEqual(header, {"jsonrpc": "2.0", "method": "easl/hostProcess", "params": {"pid": pid}})
                link.kill()
                link.wait(timeout=5)
                ended = wait_until(lambda: host.poll() is not None and not process_exists(pid), timeout=3)
                self.assertTrue(ended, f"host language server {pid} survived link death before PID delivery")
                self.assertFalse(process_exists(pid), "the server was reaped, not merely signalled")
            finally:
                if link.poll() is None:
                    link.kill()
                link.wait(timeout=5)
                if pid is not None and process_exists(pid):
                    os.kill(pid, signal.SIGKILL)
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait(timeout=5)
                host.stdout.close()
                host.stderr.close()

    def test_server_stdio_survives_the_supervisor_unchanged(self):
        with tempfile.TemporaryDirectory(prefix="host-lsp-") as directory:
            process = subprocess.Popen(["/bin/sh", "-c", host_launcher(), "easl", "/bin/cat", directory, ""],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            pid = None
            try:
                header = read_header(process.stdout)
                pid = header["params"]["pid"]
                self.assertEqual(header["method"], "easl/hostProcess")
                self.assertTrue(process_exists(pid))
                payload = b"Content-Length: 3\r\n\r\n\x00\xff\n"
                process.stdin.write(payload)
                process.stdin.flush()
                received = b""
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    deadline = time.monotonic() + 5
                    while len(received) < len(payload) and time.monotonic() < deadline:
                        if not selector.select(max(0, deadline - time.monotonic())):
                            break
                        chunk = os.read(process.stdout.fileno(), len(payload) - len(received))
                        if not chunk:
                            break
                        received += chunk
                self.assertEqual(received, payload)
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    if pid is not None and process_exists(pid):
                        os.kill(pid, signal.SIGKILL)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()

    def test_launcher_does_not_load_environment_files(self):
        with tempfile.TemporaryDirectory(prefix="host-lsp-") as directory:
            Path(directory, ".env").write_text("EASL_LSP_UNEXPECTED_ENV=from-unrelated-dotenv\n")
            environment = dict(os.environ)
            environment.pop("EASL_LSP_UNEXPECTED_ENV", None)
            program = "import os,sys; sys.stdin.buffer.readline(); print(os.environ.get('EASL_LSP_UNEXPECTED_ENV', 'unset'), flush=True); sys.stdin.buffer.read()"
            process = subprocess.Popen(["/bin/sh", "-c", host_launcher(), "easl", sys.executable, directory, "", "-c", program],
                                       cwd=directory, env=environment, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            pid = None
            try:
                pid = read_header(process.stdout)["params"]["pid"]
                process.stdin.write(b"inspect\n")
                process.stdin.flush()
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(5), "the language server did not answer")
                    self.assertEqual(os.read(process.stdout.fileno(), 4096), b"unset\n")
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    if pid is not None and process_exists(pid):
                        os.kill(pid, signal.SIGKILL)
                    process.kill()
                    process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()


if __name__ == "__main__":
    unittest.main()
