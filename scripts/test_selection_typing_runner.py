import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "selection_typing_runner",
    Path(__file__).resolve().parents[1] / "Tests/SelectionTyping/run.py",
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SelectionTypingRunnerTests(unittest.TestCase):
    def test_consecutive_timeouts_stop_after_cleanup_and_non_timeouts_reset_the_streak(self):
        for outcomes, stopped_after, first_timeout in (
            (["timeout"] * 3 + ["pass"] * 2, 3, "case-0"),
            (["timeout", "timeout", "fail"] + ["timeout"] * 3 + ["pass"] * 2, 6, "case-3"),
            (["timeout", "timeout", "pass"] + ["timeout"] * 3 + ["pass"] * 2, 6, "case-3"),
            (["timeout", "timeout", "pass", "timeout", "timeout", "fail", "timeout", "timeout"], 8, None),
        ):
            with self.subTest(outcomes=outcomes), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                build = root / "build"
                output = root / "output"
                source = root / "harness.swift"
                source.write_text("synthetic harness input\n")
                (root / "schema").mkdir()
                (root / "schema/easl-api.json").write_text("{}")
                objects = []
                for module in ("CanvasApp.build", "CanvasCore.build"):
                    obj = build / module / "fixture.o"
                    obj.parent.mkdir(parents=True)
                    obj.write_bytes(b"synthetic object")
                    objects.append(str(obj))
                (build / "Easl.product").mkdir()
                (build / "Easl.product/Objects.LinkFileList").write_text("\n".join(objects))
                (build / "description.json").write_text(json.dumps({
                    "swiftCommands": {"app": {"moduleName": "CanvasApp", "otherArguments": []}},
                }))
                (build / "Easl").write_bytes(b"synthetic binary")
                cases = [{"name": f"case-{index}", "baseline": "fixture"} for index in range(len(outcomes))]
                homes = []

                def popen(command, *, cwd, env, stdout, stderr):
                    outcome = "pass"
                    if command[0] == "fixture-swiftc":
                        (output / "SelectionTyping").write_bytes(b"synthetic executable")
                    elif command[-1] == "--list":
                        stdout.write(json.dumps(cases))
                    elif command[-1] == "stop":
                        stdout.write("fixture cleanup complete\n")
                    else:
                        name = command[-1]
                        outcome = outcomes[int(name.split("-")[1])]
                        home = Path(env["EASL_HOME"])
                        homes.append(home)
                        (home / "sessions.json").write_text(json.dumps({"case": name}))
                        (home / "board").mkdir()
                        (home / "board/input-fixture.bin").write_bytes(name.encode())
                        stdout.write(f"PASS {name}\n" if outcome == "pass" else f"started {name}\n")
                        stderr.write(f"diagnostic {name}\n")

                    def wait(timeout=None):
                        if outcome == "timeout" and timeout is not None:
                            raise subprocess.TimeoutExpired(command, timeout)
                        return 0 if outcome == "pass" else 1

                    return SimpleNamespace(pid=12345, wait=wait, kill=lambda: None, terminate=lambda: None)

                argv = [str(spec.origin), "--bin-path", str(build), "--output", str(output),
                        "--resources", str(root), "--harness-source", str(source)]
                with patch.object(sys, "argv", argv), \
                        patch.object(runner.platform, "system", return_value="Darwin"), \
                        patch.object(runner.subprocess, "check_output", side_effect=["fixture-swiftc", "/fixture-sdk"]), \
                        patch.object(runner.subprocess, "Popen", side_effect=popen), \
                        patch.dict(os.environ, {"HOME": str(root)}), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaises(SystemExit) as raised:
                    runner.main()

                message = str(raised.exception)
                self.assertEqual(len(message.splitlines()), 1)
                results = json.loads((output / "results.json").read_text())
                self.assertEqual([result["name"] for result in results], [case["name"] for case in cases[:stopped_after]])
                self.assertTrue(all(not home.exists() for home in homes))
                for case, outcome, result in zip(cases, outcomes, results):
                    directory = output / case["name"]
                    self.assertEqual(result["timed_out"], outcome == "timeout")
                    self.assertEqual(result["passed"], outcome == "pass")
                    self.assertEqual(result["cleanup"]["returncode"], 0)
                    self.assertEqual(json.loads((directory / "result.json").read_text())["timed_out"], outcome == "timeout")
                    self.assertEqual(json.loads((directory / "sessions.json").read_text()), {"case": case["name"]})
                    self.assertEqual((directory / "input-fixture.bin").read_bytes(), case["name"].encode())
                    self.assertEqual((directory / "cleanup/stdout.log").read_text(), "fixture cleanup complete\n")
                    self.assertIn(case["name"], (directory / "stdout.log").read_text())
                    self.assertIn(case["name"], (directory / "stderr.log").read_text())
                if first_timeout is not None:
                    self.assertIn(first_timeout, message)
                    self.assertIn("3 consecutive case timeouts", message)
                    self.assertEqual(json.loads((output / "aborted.json").read_text()), {
                        "first_timed_out_case": first_timeout,
                        "not_run_cases": cases[stopped_after:],
                    })
                    for case in cases[stopped_after:]:
                        self.assertFalse((output / case["name"]).exists())
                else:
                    self.assertIn("Selection/typing failures:", message)
                    self.assertFalse((output / "aborted.json").exists())


if __name__ == "__main__":
    unittest.main()
