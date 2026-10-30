"""Model CRUD keeps manifest receipts and the trust gate in Python."""

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
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from model_cli import ModelError, command, main  # noqa: E402
import model_tool  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402


class ModelCommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.home = self.base / "kit"
        self.home.mkdir()
        self.deployment = self.base / "deployment"
        self.bucket = self.deployment / "local/runtime/exa/bucketfs/bfsdefault/default"
        self.bucket.mkdir(parents=True)
        self.store = Manifest(self.home / "manifest.json")
        self.store.path.write_text(json.dumps({"runtime": {"deployment_dir": str(self.deployment)},
                                               "components": {"udf_devkit": {"version": "0.1.0"}}}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.store, Path("uv"))
        self.source = self.base / "model.onnx"
        self.source.write_bytes(b"onnx-test-model")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_command(self, *args: str) -> tuple[int, str]:
        output = io.StringIO()
        with redirect_stdout(output):
            code = command(self.ctx, list(args))
        return code, output.getvalue()

    def test_put_list_inspect_remove_and_idempotency(self) -> None:
        code, output = self.run_command("put", str(self.source), "--json")
        self.assertEqual(0, code)
        answer = json.loads(output)
        self.assertEqual("/buckets/bfsdefault/default/models/model.onnx", answer["path"])
        self.assertEqual(self.source.read_bytes(), (self.bucket / "models/model.onnx").read_bytes())
        self.assertEqual(answer["sha256"], self.store.get("components.udf_devkit.models")["model.onnx"]["sha256"])
        before = self.store.get("components.udf_devkit.models")["model.onnx"]["put_at"]
        self.run_command("put", str(self.source), "--json")
        self.assertEqual(before, self.store.get("components.udf_devkit.models")["model.onnx"]["put_at"])
        _, listed = self.run_command("list", "--json")
        self.assertEqual("ok", json.loads(listed)["models"][0]["status"])
        _, inspected = self.run_command("inspect", str(self.source), "--json")
        self.assertEqual("same", json.loads(inspected)["in_bucket"])
        _, removed = self.run_command("rm", "model.onnx", "--json")
        self.assertTrue(json.loads(removed)["removed"])
        self.assertFalse((self.bucket / "models/model.onnx").exists())
        self.assertEqual({}, self.store.get("components.udf_devkit.models"))

    def test_changed_model_needs_replace_and_changed_record_cannot_be_removed(self) -> None:
        self.run_command("put", str(self.source))
        self.source.write_bytes(b"second")
        with self.assertRaisesRegex(ModelError, "already holds a different"):
            self.run_command("put", str(self.source))
        self.run_command("put", str(self.source), "--replace")
        (self.bucket / "models/model.onnx").write_bytes(b"modified after receipt")
        with self.assertRaisesRegex(ModelError, "changed since it was put"):
            self.run_command("rm", "model.onnx")

    def test_untrusted_pickle_requires_explicit_trust_before_copy(self) -> None:
        source = self.base / "untrusted.pkl"
        source.write_bytes(b"\x80\x04untrusted")
        with patch.dict(os.environ, {"EXAKIT_MODEL_TRUST": "0"}):
            with self.assertRaisesRegex(ModelError, "no trusted provenance") as refusal:
                self.run_command("put", str(source), "--json")
        self.assertEqual(6, refusal.exception.code)
        self.assertFalse((self.bucket / "models/untrusted.pkl").exists())
        self.run_command("put", str(source), "--yes")
        self.assertTrue((self.bucket / "models/untrusted.pkl").exists())

    def test_source_change_after_snapshot_does_not_change_uploaded_file(self) -> None:
        original = self.source.read_bytes()
        inspect = model_tool.inspect

        def change_source(staged: str, directory: str, home: str) -> dict:
            self.source.write_bytes(b"changed after snapshot")
            return inspect(staged, directory, home)

        with patch.object(model_tool, "inspect", side_effect=change_source):
            self.run_command("put", str(self.source))
        self.assertEqual(original, (self.bucket / "models/model.onnx").read_bytes())

    def test_template_needs_no_install_or_deployment(self) -> None:
        self.store.delete("components.udf_devkit", "runtime.deployment_dir")
        _, output = self.run_command("template", "--json")
        self.assertIn("score_model.sql", json.loads(output)["template"])

    def test_refusal_json_has_exit_code_and_runnable_remedy(self) -> None:
        self.store.delete("components.udf_devkit")
        output = io.StringIO()
        with patch.dict(os.environ, {"EXAKIT_HOME": str(self.home)}), redirect_stdout(output):
            self.assertEqual(4, main(["list", "--json"]))
        self.assertEqual("exakit marketplace udf-devkit", json.loads(output.getvalue())["remedy"])

    def test_malformed_arguments_do_not_create_bucket(self) -> None:
        shutil.rmtree(self.bucket)
        with self.assertRaisesRegex(ModelError, "no positional argument"):
            self.run_command("list", "unexpected")
        self.assertFalse(self.bucket.exists())

    def test_both_exakit_entry_points_use_model_python_command(self) -> None:
        commands = []
        if shutil.which("bash"):
            commands.append([str(ROOT / "setup/exakit")])
        if shutil.which("pwsh"):
            commands.append(["pwsh", "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")])
        if not commands:
            self.skipTest("neither Bash nor PowerShell is available")
        env = {**os.environ, "EXAKIT_HOME": str(self.home),
               "EXAKIT_NO_UPDATE_NOTICE": "1", "EXAKIT_NO_FANCY": "1"}
        for prefix in commands:
            with self.subTest(command=prefix[0]):
                result = subprocess.run([*prefix, "model", "put", str(self.source), "--json"],
                                        env=env, capture_output=True, text=True, check=False, timeout=60)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual("model.onnx", json.loads(result.stdout)["name"])
                listed = subprocess.run([*prefix, "model", "list", "--json"], env=env,
                                        capture_output=True, text=True, check=False, timeout=60)
                self.assertEqual(0, listed.returncode, listed.stderr)
                self.assertEqual("ok", json.loads(listed.stdout)["models"][0]["status"])


if __name__ == "__main__":
    unittest.main()
