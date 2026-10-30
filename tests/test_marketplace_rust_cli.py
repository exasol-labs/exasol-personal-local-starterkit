"""The Rust UDF adapter passes a single receipt-derived environment to its tool."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import rust_cli  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402


class RustCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"components": {"udf_devkit": {"version": "0.1.0"}},
                                                 "runtime": {"dsn": "127.0.0.1:8563", "user": "sys",
                                                             "password_file": str(self.home / "credentials/pw")}}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_no_devkit_refuses_before_tool(self) -> None:
        self.manifest.delete("components.udf_devkit")
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(rust_cli.subprocess, "run") as run:
            self.assertEqual(4, rust_cli.command(self.ctx, ["build", "score", "--json"]))
        self.assertEqual("exakit marketplace udf-devkit", json.loads(output.getvalue())["remedy"])
        run.assert_not_called()

    def test_deploy_maps_bucket_and_credential_file_without_password(self) -> None:
        deployment = self.home / "deployment with spaces"
        bucket = deployment / "local/runtime/exa/bucketfs/bfsdefault/default"
        bucket.mkdir(parents=True)
        self.manifest.set_many({"runtime.deployment_dir": str(deployment),
                                "components.personal.ownership_path": str(self.home / "personal")})
        with patch.object(rust_cli.subprocess, "run", return_value=type("Result", (), {"returncode": 0})()) as run:
            self.assertEqual(0, rust_cli.command(self.ctx, ["deploy", "score", "--json"]))
        args, kwargs = run.call_args
        self.assertEqual(str(bucket), kwargs["env"]["EXAKIT_RUST_BUCKET_DIR"])
        self.assertEqual("/buckets/bfsdefault/default", kwargs["env"]["EXAKIT_RUST_UDF_ROOT"])
        self.assertEqual(str(deployment), kwargs["env"]["EXAKIT_RUST_DEPLOYMENT"])
        self.assertEqual(str(self.home / "credentials/pw"), kwargs["env"]["EXAKIT_PYX_PWFILE"])
        self.assertNotIn("password", " ".join(args[0]))

    def test_missing_bucket_preserves_tool_fallback(self) -> None:
        deployment = self.home / "deployment"
        deployment.mkdir()
        self.manifest.set_many({"runtime.deployment_dir": str(deployment)})
        with patch.object(rust_cli.subprocess, "run", return_value=type("Result", (), {"returncode": 0})()) as run:
            self.assertEqual(0, rust_cli.command(self.ctx, ["deploy", "score"]))
        self.assertEqual("", run.call_args.kwargs["env"]["EXAKIT_RUST_BUCKET_DIR"])


if __name__ == "__main__":
    unittest.main()
