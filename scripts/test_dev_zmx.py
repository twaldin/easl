from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class DevZmxTests(unittest.TestCase):
    def test_symlinks_cannot_escape_before_directories_are_created(self):
        script = Path(__file__).with_name("dev-zmx.py")
        for component in ("zmx", "state", "tmp", "zmx/logs"):
            with self.subTest(component=component), tempfile.TemporaryDirectory(prefix="ez-", dir="/tmp") as root:
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
                self.assertEqual((outside.stat().st_mtime_ns, marker.stat().st_mtime_ns, marker.read_bytes()), before)
                self.assertEqual(sorted(p.relative_to(home).as_posix() for p in home.rglob("*") if not p.is_symlink()), ["zmx"] if component == "zmx/logs" else [])

    def test_a_bundle_check_preserves_the_home_identity_and_absent_migration_target(self):
        script = Path(__file__).with_name("dev-zmx.py")
        with tempfile.TemporaryDirectory(prefix="ez-", dir="/tmp") as root:
            root = Path(root)
            target = root / "physical"
            target.mkdir()
            alias = root / "alias"
            alias.symlink_to(target, target_is_directory=True)
            home = alias / "migration-target"
            result = subprocess.run([sys.executable, str(script), str(root / "bundle"), f"EASL_HOME={home}"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), str(home))
            self.assertFalse((target / "migration-target").exists())

    def test_the_socket_limit_counts_utf8_bytes(self):
        script = Path(__file__).with_name("dev-zmx.py")
        with tempfile.TemporaryDirectory(prefix="ez-", dir="/tmp") as root:
            prefix = root + "/"
            valid = prefix + "x" * (69 - len(prefix.encode()))
            accepted = subprocess.run([sys.executable, str(script), valid], capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0)
            invalid = valid[:-1] + "é"
            refused = subprocess.run([sys.executable, str(script), invalid], capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(list(Path(root).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
