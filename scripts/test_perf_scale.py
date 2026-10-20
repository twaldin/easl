import collections
import importlib.util
import json
from pathlib import Path
import socketserver
import tempfile
import threading
import unittest


SPEC = importlib.util.spec_from_file_location("perf_scale", Path(__file__).with_name("perf-scale.py"))
SCALE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCALE)


class StreamReadinessTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.terminals = [f"terminal-{worker}" for worker in range(8)]

    def serve(self, respond):
        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                request = json.loads(self.rfile.readline())
                reply = {"id": request["id"], **respond(request)}
                self.wfile.write((json.dumps(reply) + "\n").encode())

        path = self.root / "rpc.sock"
        server = socketserver.UnixStreamServer(str(path), Handler)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()

        def stop():
            server.shutdown()
            thread.join(timeout=10)
            server.server_close()
            self.assertFalse(thread.is_alive())

        self.addCleanup(stop)
        return path

    def test_waits_for_eight_producers_after_unavailable_and_metadata_only_replies(self):
        reads = collections.Counter()
        emitted = set()

        def respond(request):
            target = request["params"]["target"]
            worker = int(target.rsplit("-", 1)[1])
            reads[target] += 1
            if reads[target] == 1:
                return {"ok": False, "error": {"code": "unavailable", "message": "No attached surface"}}
            marker = f"worker={worker} sequence={42:020d} status=running"
            if worker == 7 and reads[target] == 2:
                return {"ok": True, "result": {"text": "", "agent": {"program": marker}}}
            emitted.add(worker)
            return {"ok": True, "result": {"text": marker}}

        path = self.serve(respond)
        SCALE.wait_for_streams(path, self.terminals, self.root / "streams.json", seconds=5)
        self.assertEqual(emitted, set(range(8)))

    def test_does_not_wait_through_a_permanent_rpc_error(self):
        def respond(request):
            return {"ok": False, "error": {"code": "invalid_params", "message": "Wrong terminal target"}}

        path = self.serve(respond)
        with self.assertRaisesRegex(RuntimeError, "invalid_params"):
            SCALE.wait_for_streams(path, self.terminals, self.root / "streams.json", seconds=5)


if __name__ == "__main__":
    unittest.main()
