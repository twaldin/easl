import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "release_compatibility", Path(__file__).with_name("release-compatibility.py")
)
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)


class ReleaseSelectionTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="easl-release-tags-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.environment = {
            **os.environ,
            "GIT_AUTHOR_NAME": "Compatibility fixture",
            "GIT_AUTHOR_EMAIL": "compatibility@example.invalid",
            "GIT_COMMITTER_NAME": "Compatibility fixture",
            "GIT_COMMITTER_EMAIL": "compatibility@example.invalid",
        }
        self.git("init", "--quiet")
        self.root_patch = patch.object(compatibility, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.root, env=self.environment, text=True
        ).strip()

    def commit(self, name):
        self.git("commit", "--quiet", "--allow-empty", "-m", name)

    def test_baseline_advances_after_a_release_but_never_compares_a_tag_to_itself(self):
        self.commit("first release")
        self.git("tag", "v0.2.8")
        self.commit("next release")
        self.git("tag", "-a", "v0.3.0", "-m", "release")
        self.commit("release candidate")
        self.assertEqual(compatibility.previous_release(), "v0.3.0")
        self.git("tag", "v0.3.1")
        self.assertEqual(compatibility.previous_release(), "v0.3.0")
        self.commit("next development cycle")
        self.assertEqual(compatibility.previous_release(), "v0.3.1")

    def test_selection_uses_semantic_versions_and_ignores_prereleases(self):
        self.commit("release nine")
        self.git("tag", "v0.9.0")
        self.commit("release ten")
        self.git("tag", "v0.10.0")
        self.git("tag", "v9.0.0-rc1")
        self.commit("development")
        self.assertEqual(compatibility.previous_release(), "v0.10.0")

    def test_a_first_release_has_no_previous_baseline(self):
        self.commit("first release")
        self.git("tag", "v0.1.0")
        with self.assertRaises(RuntimeError):
            compatibility.previous_release()


if __name__ == "__main__":
    unittest.main()
