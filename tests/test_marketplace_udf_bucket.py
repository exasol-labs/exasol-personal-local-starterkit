"""UDF file copy and BucketFS mapping with a local deployment fixture."""

from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402
from udf_bucket import locate  # noqa: E402
from udf_cli import udf_file  # noqa: E402


class UdfBucketTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.deployment = self.base / "deployment"
        self.exa = self.deployment / "local/runtime/exa"
        self.exa.joinpath("bucketfs").mkdir(parents=True)
        self.home = self.base / "kit"
        self.home.mkdir()
        self.store = Manifest(self.home / "manifest.json")
        self.store.path.write_text(json.dumps({"runtime": {"deployment_dir": str(self.deployment)},
                                               "components": {"udf_devkit": {"version": "0.1.0"}}}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.store, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_default_bucket_created_and_file_copied_atomically(self) -> None:
        source = self.base / "training data.csv"
        source.write_text("id,value\n1,2\n")
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(0, udf_file(self.ctx, [str(source), "models/data.csv"]))
        target = self.exa / "bucketfs/bfsdefault/default/models/data.csv"
        self.assertEqual(source.read_bytes(), target.read_bytes())
        self.assertIn("/buckets/bfsdefault/default/models/data.csv", output.getvalue())
        self.assertFalse(list(target.parent.glob("*.part")))

    def test_config_mapping_and_nonmutating_probe(self) -> None:
        (self.exa / "bucketfs.conf").write_text("/exa/custom/data bfsdefault default /buckets/custom/data\n")
        mapped = locate(self.deployment, create=False)
        self.assertEqual(self.exa / "custom/data", mapped.directory)
        self.assertEqual("/buckets/custom/data", mapped.udf_root)
        self.assertTrue(mapped.created)
        self.assertFalse(mapped.directory.exists())

    def test_missing_mapping_and_traversal_refused_before_copy(self) -> None:
        (self.exa / "bucketfs.conf").write_text("/exa/else another bucket /buckets/else\n")
        with self.assertRaisesRegex(AddonFailure, "maps no bucket"):
            locate(self.deployment)
        (self.exa / "bucketfs.conf").write_text("/exa/../../escape bfsdefault default /buckets/default\n")
        with self.assertRaisesRegex(AddonFailure, "leaves"):
            locate(self.deployment)
        self.assertFalse((self.base / "escape").exists())

    def test_file_path_escape_and_missing_addon_refused(self) -> None:
        source = self.base / "model.pkl"
        source.write_bytes(b"model")
        with self.assertRaises(AddonFailure):
            udf_file(self.ctx, [str(source), "../escape"])
        self.store.delete("components.udf_devkit")
        with self.assertRaisesRegex(AddonFailure, "not installed"):
            udf_file(self.ctx, [str(source)])

    def test_both_exakit_entry_points_reach_python_file_copy(self) -> None:
        source = self.base / "input with spaces.txt"
        source.write_text("payload")
        env = {**os.environ, "EXAKIT_HOME": str(self.home),
               "EXAKIT_NO_UPDATE_NOTICE": "1", "EXAKIT_NO_FANCY": "1"}
        commands = []
        if shutil.which("bash"):
            commands.append([str(ROOT / "setup/exakit")])
        if shutil.which("pwsh"):
            commands.append(["pwsh", "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")])
        if not commands:
            self.skipTest("neither Bash nor PowerShell is available")
        for command in commands:
            with self.subTest(command=command[0]):
                result = subprocess.run([*command, "udf-file", str(source), "models/input.txt"],
                                        env=env, capture_output=True, text=True, check=False, timeout=60)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn("/buckets/bfsdefault/default/models/input.txt", result.stdout)
        self.assertEqual("payload", (self.exa / "bucketfs/bfsdefault/default/models/input.txt").read_text())


if __name__ == "__main__":
    unittest.main()
