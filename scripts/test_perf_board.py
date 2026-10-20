import collections
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("perf-board.py")
KINDS = ("note", "html", "shape", "code", "image", "diagram")
SIZES = (50, 200, 500, 1000)


class PerfBoardTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.home = Path(self.scratch.name) / "home"
        self.root = Path(self.scratch.name) / "root"

    def generate(self, count, *extra, hash_seed="1"):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.home), str(self.root),
             "--objects", str(count), "--seed", "7", *extra],
            capture_output=True, text=True, check=True,
            env=dict(os.environ, PYTHONHASHSEED=hash_seed),
        )
        path = self.home / "boards" / f"{result.stdout.strip()}.json"
        return json.loads(path.read_text()), path.read_bytes(), result.stderr

    def test_exact_counts_assets_and_references_at_each_size(self):
        for count in SIZES:
            with self.subTest(count=count):
                board, _, _ = self.generate(count)
                self.assertEqual(board["format"], 2)
                self.assertEqual(board["root"], str(self.root))
                objects = board["objects"]
                self.assertEqual(len(objects), count)
                by_id = {obj["id"]: obj for obj in objects}
                self.assertEqual(len(by_id), count)
                kinds = collections.Counter(obj["type"] for obj in objects)
                self.assertEqual(set(kinds), {*KINDS, "group", "arrow", "terminal"})
                self.assertEqual(kinds["terminal"], 8)
                grouped = []
                routes, labels = set(), set()
                terminals = []
                source = (self.root / "service.py").read_text().splitlines()
                for obj in objects:
                    props = obj["props"]
                    if obj["type"] == "group":
                        self.assertGreater(len(props["members"]), 1)
                        group = obj["frame"]
                        for member in props["members"]:
                            self.assertIn(member, by_id)
                            child = by_id[member]
                            self.assertNotIn(child["type"], ("arrow", "group"))
                            frame = child["frame"]
                            self.assertLessEqual(group["x"], frame["x"])
                            self.assertLessEqual(group["y"], frame["y"])
                            self.assertGreaterEqual(group["x"] + group["w"], frame["x"] + frame["w"])
                            self.assertGreaterEqual(group["y"] + group["h"], frame["y"] + frame["h"])
                            self.assertLess(obj["z"], child["z"])
                        grouped.extend(props["members"])
                    elif obj["type"] == "arrow":
                        a, b = props["from"]["object"], props["to"]["object"]
                        self.assertIn(a, by_id)
                        self.assertIn(b, by_id)
                        self.assertNotEqual(a, b)
                        routes.add(props["route"])
                        labels.add("label" in props)
                    elif obj["type"] == "terminal":
                        terminals.append(obj)
                        self.assertEqual(props["cwd"], str(self.root))
                    elif obj["type"] == "code":
                        text = (self.root / props["path"]).read_text().splitlines()
                        self.assertGreaterEqual(props["range"]["start"], 1)
                        self.assertLessEqual(props["range"]["end"], len(text))
                    elif obj["type"] == "image":
                        self.assertTrue((self.root / props["path"]).read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))
                    elif obj["type"] == "diagram":
                        graph = props["graph"]
                        self.assertEqual(graph["aim"], {key: props[key] for key in ("kind", "path", "symbol", "direction")})
                        nodes = {node["id"]: node for node in graph["nodes"]}
                        self.assertIn(graph["root"], nodes)
                        for node in nodes.values():
                            self.assertIn(f"def {node['name']}(", source[node["line"] - 1])
                            for excerpt in node["excerpt"]:
                                self.assertEqual(excerpt["text"], source[excerpt["line"] - 1])
                        for edge in graph["edges"]:
                            self.assertIn(edge["from"], nodes)
                            self.assertIn(edge["to"], nodes)
                            for line in edge["lines"]:
                                self.assertIn(nodes[edge["to"]]["name"] + "(", source[line - 1])
                self.assertEqual(collections.Counter(grouped), collections.Counter(
                    obj["id"] for obj in objects if obj["type"] not in ("group", "arrow")))
                self.assertEqual(routes, {"straight", "avoid"})
                self.assertEqual(labels, {True, False})
                self.assertEqual(len({(obj["frame"]["x"], obj["frame"]["y"]) for obj in terminals}), 8)
                frames = [obj["frame"] for obj in objects if obj["type"] not in ("group", "arrow", "shape")]
                left = min(frame["x"] for frame in frames)
                right = max(frame["x"] + frame["w"] for frame in frames)
                opening_terminal = terminals[0]["frame"]
                self.assertEqual(opening_terminal["y"], min(frame["y"] for frame in frames))
                self.assertLessEqual(opening_terminal["x"], (left + right) / 2)
                self.assertGreaterEqual(opening_terminal["x"] + opening_terminal["w"], (left + right) / 2)

    def test_scaled_html_varies_script_and_state(self):
        class Page(HTMLParser):
            scripted = False

            def handle_starttag(self, tag, attrs):
                if tag == "script":
                    self.scripted = True

        for count in SIZES:
            with self.subTest(count=count):
                board, _, _ = self.generate(count)
                pages = [obj["props"] for obj in board["objects"] if obj["type"] == "html"]
                scripted = set()
                for props in pages:
                    page = Page()
                    page.feed(props["html"])
                    scripted.add(page.scripted)
                self.assertEqual(scripted, {False, True})
                self.assertEqual({props["state"]["open"] for props in pages}, {False, True})

    def test_seeded_output_ignores_hash_iteration_order(self):
        _, first, _ = self.generate(200, hash_seed="1")
        _, second, _ = self.generate(200, hash_seed="99")
        self.assertEqual(first, second)

    @unittest.skipUnless(sys.platform == "darwin", "Foundation path aliases are macOS-specific")
    def test_private_path_alias_opens_the_same_board(self):
        alias_scratch = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(alias_scratch.cleanup)
        self.root = Path(alias_scratch.name) / "root"
        board, _, _ = self.generate(50)
        self.root = Path("/private") / self.root.relative_to("/")
        aliased, _, _ = self.generate(50)
        self.assertEqual(board["id"], aliased["id"])

    def test_label_trim_preserves_exact_count(self):
        board, _, _ = self.generate(50, "--labels", "0")
        self.assertEqual(len(board["objects"]), 50)
        self.assertFalse(any("label" in obj["props"] for obj in board["objects"] if obj["type"] == "arrow"))

    def test_incompatible_modes_fail_without_writing_a_fixture(self):
        for options in (("--objects", "49"), ("--objects", "50", "--arrows", "9"),
                        ("--objects", "50", "--replica", "unused.json")):
            with self.subTest(options=options):
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), str(self.home), str(self.root), *options],
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.home.exists())

    def test_terminal_stream_pauses_and_resumes_with_sequence_counters(self):
        board, _, _ = self.generate(50)
        terminal = next(obj for obj in board["objects"] if obj["type"] == "terminal")
        quiet = self.root / ".perf-board-quiet"
        quiet.touch()
        process = subprocess.Popen(terminal["props"]["command"], cwd=self.root,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.addCleanup(process.stderr.close)
        self.addCleanup(process.stdout.close)

        def stop():
            process.terminate()
            process.wait(timeout=3)

        self.addCleanup(stop)
        fd = process.stdout.fileno()
        self.assertFalse(select.select([fd], [], [], 0.25)[0])
        quiet.unlink()
        data = bytearray()
        started = time.monotonic()
        while len(data) < 2048 and time.monotonic() - started < 3:
            if select.select([fd], [], [], 0.5)[0]:
                chunk = os.read(fd, 2048 - len(data))
                self.assertTrue(chunk, "terminal exited before producing output")
                data.extend(chunk)
        self.assertEqual(len(data), 2048)
        lines = data.splitlines(keepends=True)
        self.assertEqual(len(lines), 8)
        for i, line in enumerate(lines):
            self.assertEqual(len(line), 256)
            self.assertIn(f"sequence={i:020d}".encode(), line)
        elapsed = time.monotonic() - started
        self.assertGreater(elapsed, 0.7, "stream exceeded its bounded output rate")
        self.assertLess(elapsed, 3)
        quiet.touch()
        time.sleep(0.7)
        while select.select([fd], [], [], 0)[0]:
            self.assertTrue(os.read(fd, 4096), "terminal exited while paused")
        self.assertIsNone(process.poll())
        self.assertFalse(select.select([fd], [], [], 0.25)[0])
        quiet.unlink()
        self.assertTrue(select.select([fd], [], [], 1.5)[0])
        resumed = os.read(fd, 4096)
        self.assertIn(b"sequence=", resumed)
        counter = int(resumed.split(b"sequence=", 1)[1].split(b" ", 1)[0])
        self.assertGreaterEqual(counter, 8)


if __name__ == "__main__":
    unittest.main()
