import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ProductPipelineShellTests(unittest.TestCase):
    def test_help_needs_no_fixture_metadata_or_native_process(self):
        result = subprocess.run(["bash", "scripts/quality-matrix.sh", "--product", "--help"],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SAIITY_PRODUCT_VERSION", result.stdout)
        self.assertIn("copied", result.stdout)

    def test_dirty_source_refuses_before_native_work(self):
        state = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"],
                                        cwd=ROOT, text=True)
        if not state:
            self.skipTest("This preflight regression requires a dirty source checkout")
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"]) as directory:
            owned = Path(directory)
            marker = owned / "native-started"
            spy = owned / "xcrun"
            spy.write_text("#!/bin/bash\ntouch " + shlex.quote(str(marker)) + "\nexit 99\n")
            spy.chmod(0o755)
            environment = dict(os.environ, PATH=str(owned) + os.pathsep + os.environ["PATH"],
                               SAIITY_RELEASE_FIXTURES=str(owned), SAIITY_PRODUCT_VERSION="test",
                               SAIITY_PRODUCT_BUILD="1", SAIITY_PRODUCT_MACHINE_ID="test-mac",
                               SAIITY_PRODUCT_POWER_MODE="normal", SAIITY_PRODUCT_THERMAL_STATE="nominal",
                               SAIITY_PRODUCT_MEMORY_PRESSURE="normal")
            result = subprocess.run(["bash", "scripts/quality-matrix.sh", "--product"], cwd=ROOT,
                                    env=environment, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("clean source", result.stderr)
            self.assertFalse(marker.exists(), "a native command ran before clean-source admission")


if __name__ == "__main__":
    unittest.main()
