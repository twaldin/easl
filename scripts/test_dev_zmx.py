from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class DevZmxTests(unittest.TestCase):
    def test_symlinks_cannot_escape_before_directories_are_created(self):
        script = Path(__file__).with_name("dev-zmx.py")
        for component in ("zmx", "state", "tmp", "zmx/logs"):
            with self.subTest(component=component), tempfile.TemporaryDirectory(prefix="easl-isolation-") as root:
                root = Path(root)
                home = root / "dev"
                outside = root / "outside"
                outside.mkdir()
                marker = outside / "keep"
                marker.write_text("not development state")
                before = (outside.stat().st_mtime_ns, marker.stat().st_mtime_ns, marker.read_bytes())
                target = home / component
                target.parent.mkdir(parents=True)
                target.symlink_to(outside, target_is_directory=True)
                result = subprocess.run([sys.executable, str(script), str(home)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("outside its home", result.stderr)
                self.assertEqual((outside.stat().st_mtime_ns, marker.stat().st_mtime_ns, marker.read_bytes()), before)
                self.assertEqual(sorted(p.relative_to(home).as_posix() for p in home.rglob("*") if not p.is_symlink()), ["zmx"] if component == "zmx/logs" else [])


if __name__ == "__main__":
    unittest.main()
